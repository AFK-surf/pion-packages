# 红队审计：`packages/markdown` v0.3.0（`5e9cca5`）——`Document` AST 与 `plain_text`

审计对象：`origin/feat/markdown-v030` @ `5e9cca5`，新增的 `src/ast.pion`（树状 `Document` AST）与
`src/plain_text.pion`（可配置纯文本提取）。工具链 `pionc 0.1.0`（`AFK-surf/pion@66d2b4b`），Darwin arm64。
本目录只新增文件，`src/`、`*_test.pion`、`pion.toml`、`README.md`、`audit/` 0 字节改动。

## 结论

| 级别 | 数量 | 内容 |
| --- | ---: | --- |
| P0 | 0 | 没有崩溃、SIGSEGV、Wasm32 trap，没有非法 UTF-8 输出，没有半个字符 |
| P1 | 3 | P1-1 `<script>`/`<style>` 正文泄漏进预览；P1-2 HTML 块里真小于号 `<` 吞字；P1-3 AST 构建 O(N²) |
| P2 | 6 | 注释尾巴被丢、块级标签无词界、HTML 实体不解码、截断末尾带分隔符、多行模式 HTML 块原样换行、截断切开字素簇 |
| GAP（不门禁） | 1 | `Inline::Math` / `math_placeholder` 没有任何解析路径产出 |
| PRE（不门禁，既有缺陷） | 1 | `parse_extended` 事件流把代码块里的 `[^1]` 改写成脚注引用（AST 路径是对的） |

**客观评价**：AST 本身很扎实。85,208 个用例（pulldown-cmark 0.13.1 自带测试套件 + v0.2 手写语料 +
20 本审计新增用例 + 20,000 个模糊用例，× 4 组选项含扩展模式）里，`render(lower(parse_document*))` 与
`render(parse*)` 逐字节一致，**0 处 AST 侧丢节点、吞字或嵌套错配**。50k `>`、32k `-`、20k 层行内强调在 4 种
构建模式下都不爆栈。`max_chars` 在 241,608 份输出上全是合法 UTF-8，从不切开码点，截断结果总是完整结果的前缀。
问题集中在两处：HTML 剥离器 `pt_write_html_stripped`（P1-1、P1-2、P2-1..3），以及 Text 合并时的字符串拼接
（P1-3）。

## 复现

```sh
sh packages/markdown/audit_v030/run_audit.sh           # 全量，约 30 s；有未修缺陷时 exit 1
QUICK=1 sh packages/markdown/audit_v030/run_audit.sh   # 模糊用例缩到 3000
```

| 步骤 | 内容 | 门禁 |
| --- | --- | --- |
| 2 | `tests/redteam_v030_test.pion`：26 个测试（7 p1、7 p2、1 gap、1 pre、10 ok） | 所有 `p*_` 与 `ok_` 通过 |
| 3 | `scripts/ast_diff.py`：AST → 事件回降（`harness lower_blocks`）后与原事件流各自渲染，逐字节比较，含 front matter | 0 处 AST 侧不一致 |
| 4 | `scripts/pt_check.py`：6 组选项 × 40k 用例，检查 UTF-8 合法、码点数 ≤ `max_chars`、截断是前缀、折叠模式没有首空格/换行/双空格 | 0 违例 |
| 5 | `scripts/dos_scale.py`：N 与 4N 下 AST 路径对比扁平 `parse()` | 4N 时 AST ≤ 10× 事件路径（或 < 0.25 s） |
| 6 | `scripts/four_mode.py`：`native_dbg`/`native_rel`/`wasm_dbg`/`wasm_rel` 跑 19 个探针 | 4 模退出码全为 0，stdout SHA-256 一致 |

期望写的是修复后必须满足的性质，不是某一份具体输出，所以修复分支不改 `audit_v030/` 一个字节也能重跑到 `exit 0`。

## P1

### P1-1 `<script>` / `<style>` 正文泄漏进纯文本预览

`pt_write_html_stripped`（`src/plain_text.pion:181-244`）只删标签本身，标签之间的内容都当可见文本输出。行内
HTML 也一样：解析器给出 `HtmlInline("<script>")`、`Text("alert(1)")`、`HtmlInline("</script>")`，
`pt_emit_inlines` 把中间的 `Text` 正常输出（`:273`、`:308`）。

| 输入 | `to_plain_text(.., default)` |
| --- | --- |
| `<script>\nalert(document.cookie)\n</script>\n\nafter` | `alert(document.cookie) after` |
| `<style>\nbody{color:red}\n</style>\n\nvisible` | `body{color:red} visible` |
| `hi <script>alert(1)</script> there` | `hi alert(1) there` |
| `a <style>p{x:y}</style> b` | `a p{x:y} b` |

影响：monoid、group、board 的会话列表、通知和搜索摘要会显示 JS/CSS 源码。纯文本本身不是 HTML，不直接构成
XSS；但调用方若把预览拼进 HTML 而不转义，泄漏出来的 `<`、`>` 正文会变成注入面。修复方向：遇到 `script`、
`style`（建议再加 `textarea`、`title`、`template`、`noscript`）时跳到对应闭合标签，行内情况要跨
`HtmlInline` 节点带上这个状态。
测试：`p1_html_block_script_body_leaks`、`p1_html_block_style_body_leaks`、`p1_inline_script_body_leaks`、`p1_inline_style_body_leaks`。

### P1-2 HTML 块里的真小于号被当成标签开头，吞掉文字

`:211-237`：任何 `<` 都会一路扫到下一个 `>` 并整段丢弃；找不到 `>` 时直接 `i = n`（`:234`），把块的剩余部分全部丢掉。
HTML 分词规则里，`<` 后面必须紧跟 ASCII 字母、`/`、`!` 或 `?` 才算标签开头。

| 输入 | 输出 |
| --- | --- |
| `<div>\n1 < 2 && 3 > 2\n</div>` | `1 2` |
| `<div>\nprice < 100 yuan\n</div>` | `price` |
| `<div>\na <3 b and more text` | `a` |

普通段落里的 `1 < 2 && 3 > 2` 不受影响，因为它不是 HTML 节点（`ok_real_less_than_in_paragraph_kept`）。
测试：`p1_html_block_less_than_swallows_text`、`p1_html_block_less_than_drops_tail`、`p1_html_block_unterminated_lt_drops_rest`。

### P1-3 `Document` AST 构建 O(N²)：相邻 Text 合并用字符串拼接

`push_inline_coalesced`（`src/ast.pion:73-92`）每合并一个相邻的 `Event::Text` 就执行一次
`out[n-1] = Inline::Text(prev + s)`（`:83`），整段文字被反复复制。解析器在转义、实体、未配对的 `[`/`]` 等处会
把一段文字拆成许多个 Text 事件，所以只要一行里有足够多这类字符就会触发。`plain_text` 先构建完整 AST，
`max_chars: 64` 的短预览同样要付全价。

| 输入（单段落） | 大小 | `parse()` 事件流 | `parse_document` + `plain_text` |
| --- | ---: | ---: | ---: |
| `a\*&amp;[` × 16k → 64k | 128 KB → 512 KB | 0.007 → 0.013 s | 0.018 → 1.69 s（AST/事件 = 128×） |
| `[` × 128k（`brackets`） | 256 KB | 0.012 s | 0.69 s（57×） |
| 真实样式：`var\_name\_N` × 30k | 499 KB | — | 2.06 s（`max_chars=64` 预览） |
| 真实样式：`R&amp;D &lt;N&gt;` × 20k | 429 KB | — | 0.89 s |
| 真实样式：250 KB 压缩 JSON（`[` 很多） | 252 KB | — | 0.42 s |

`inline_html`、`cjk`、`table_rows`、`html_lt` 是线性的，AST/事件 ≈ 1–2×。修复方向：先把连续 Text 收进一个
`StringBuilder`，遇到非 Text 事件或帧关闭时再落成一个 `Inline::Text`（`rewrite_footnote_refs` 已经这样做）。
门禁：`dos_scale.py`。

## P2

| # | 缺陷 | 最小复现 → 输出 | 根因 | 测试 |
| --- | --- | --- | --- | --- |
| P2-1 | 注释后紧跟的 ≤ 2 字节文字被丢；`<!-->` / `<!--->`（HTML 里是完整的空注释）会吞到块尾 | `<!-- footnote -->1` → `""`；`<!-->visible text` → `""` | `:204` `if j + 2 >= n` 分不清「在末尾附近找到了 `-->`」和「没找到」；扫描从 `i+4` 开始，看不到 `<!-->` 里的 `-->` | `p2_html_comment_tail_dropped`、`p2_html_empty_comment_swallows_rest` |
| P2-2 | 除 `p`/`div`/`br` 外，块级标签都不产生词界，相邻文字粘连 | `<td>alpha</td><td>beta</td>` → `alphabeta`；`<li>one</li><li>two</li>` → `onetwo`；`<h1>Title</h1><section>Body</section>` → `TitleBody` | `pt_is_break_html_tag`（`:156-178`）只认 3 个标签 | `p2_html_block_tags_glue_words` |
| P2-3 | 原始 HTML 里的字符引用原样输出 | `<div>Tom &amp; Jerry &lt;3 &#x4F60;</div>` → `Tom &amp; Jerry &lt;3 &#x4F60;` | 剥离器不解码实体（`lookup_entity` 已有） | `p2_html_entities_not_decoded` |
| P2-4 | 截断落在分隔符上时，预览以空格或 `\n` 结尾，并且分隔符占掉 1 个字符额度 | `hello world`，`max_chars=6` → `hello `；多行模式 `para one\n\npara two`，`max_chars=9` → `para one\n` | `pt_flush_sep`（`:65-91`）写出分隔符并计数后才检查是否已满 | `p2_truncation_ends_with_separator` |
| P2-5 | 多行模式（`collapse_whitespace=false`）把 HTML 块里的原始换行照抄，输出以 `\n` 开头，中间出现连续空行 | `<div>\nx\n</div>\n\ny` → `"\nx\n \n\ny"`（开头是 `\n`，原始换行、`</div>` 的分隔空格和块分隔叠在一起） | `pt_write_span` 非折叠分支逐字节照抄 HTML 文本节点 | `p2_multiline_html_block_raw_newlines` |
| P2-6 | `max_chars` 按码点计数，会切开字素簇：ZWJ 序列只剩半截，基字符和组合附加符号被拆开 | `👨‍👩‍👧 family`，max=2 → `👨‍`（悬空 ZWJ）；`étude`，max=1 → `e` | 设计上按码点截断（`:107-121`）；UTF-8 本身合法，但显示是坏字形 | `p2_truncation_splits_grapheme` |

## GAP（不门禁）

**GAP-1**：`Inline::Math(Bool, String)`（`ast.pion:47`）、`PlainTextOptions.math_placeholder` 以及 README
里的 `"[公式]"` 示例都在，但 `Event` 里没有 Math 事件，`events_to_inlines` 也不会生成 `Inline::Math`。
`$E=mc^2$`、`$$…$$` 永远是普通 `Text`，占位符从不生效，只有手工构造的 AST 才能用到（`ast_plain_text_test.pion:379`
就是手工构造的）。要么实现 math 选项，要么在 README 写明。测试：`gap_math_never_produced_by_parser`。

## PRE（既有缺陷，不在 v0.3.0 diff 内，不门禁）

**PRE-1**：`rewrite_footnote_refs`（`src/extensions.pion:589`）按 Text 事件扫描 `[^label]`，不区分是否在代码块里，
所以 ```` ```\n[^1]\n``` ```` 经 `parse_extended` 会渲染成 `<pre><code><sup class="footnote-reference">…`。
`parse_document_extended` 只改写段落和单元格，保持字面量，是对的，于是两个 API 结果不同。AST 差分里有 74 个
这类用例，`ast_diff.py` 单独归类为 PRE-1，不计入 AST 缺陷。测试：`pre_extended_events_footnote_ref_inside_code_block`。

## 实测摘要（`run_audit.sh` 全量，本机）

- `pionc test`：26 个，10 通过、16 失败（p1 7、p2 7、gap 1、pre 1）；10 个 `ok_` 护栏全部通过。
- AST 往返差分：85,208 个用例，AST 侧不一致 **0**（另有 74 个属于 PRE-1）。
- `plain_text` 不变量：40,268 个用例、241,608 份输出，I1（UTF-8 合法）、I2（码点数 ≤ max）、I3（截断是前缀）、
  I4（折叠模式空白规整）**全部 0 违例**。非法 UTF-8 输入经 `fs_read` 已经变成 U+FFFD，输出依然合法。
- 扩展性：`escapes`、`brackets` 两项不通过（见 P1-3）；其余 4 项线性。
- 4 模一致性：19 个探针（50k `>`、32k `-`/`1.`、10k `> - `、20k `*`/`**`/`[`/链接、100 KB 连续 `<`、
  未闭合 `<`、注释、引号，50k 行内 HTML，5k 列、20k 行表格，CJK+Emoji，以及两份模糊语料）在
  `native_dbg`/`native_rel`/`wasm_dbg`/`wasm_rel` 下退出码全为 0，SHA-256 全部一致：0 SIGSEGV，0 Wasm32 RangeError。
- `pt_write_html_stripped` 的 100 KB 连续 `<`、未闭合 `<`、未闭合注释、未闭合引号都是线性的（≤ 6 ms），
  没有 O(N²) 退化。
- 顺带观察到的既有问题：`- ` × 32k 在事件路径和 AST 路径上都约 0.5 s，并且呈平方增长，是 v0.2 解析器的问题，
  `audit/REPORT.md` 的 P0-2 已经记录。

## 非缺陷观察（设计取舍，供参考）

- AST 不保存 `LinkType` 和引用 id，自动链接、行内链接、引用链接无法区分；邮件自动链接的 url 已经带上 `mailto:` 前缀。
- 行内代码没有占位选项，`code_block_placeholder` 只管围栏代码块和缩进代码块。
- 脚注定义的正文会追加在预览末尾（`x[^1]` + 定义 → `x note body`）；脚注引用本身什么也不输出。
- 折叠模式只折叠 ASCII 空白，全角空格 U+3000 和 NBSP 原样保留（对中文排版可能就是想要的效果）。
- 多行模式下块与块之间只用一个 `\n`，与软换行无法区分。
