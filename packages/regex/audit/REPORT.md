# `packages/regex` 红队审计报告

- 被审版本：`origin/feat/pkg-regex` `434b412`（只读，未改 `src/`、测试、`bench/`）
- 对照：Rust `regex =1.11.1`（`--release`；`Cargo.lock` 锁定 `regex-automata 0.4.19` / `regex-syntax 0.8.12`）
- 工具链：`pionc 0.1.0 (arm64_apple, self-hosted)`，Darwin arm64；Wasm32 经 `pionc run --target wasm32`（Node）
- 一键复现：`sh packages/regex/audit/run_audit.sh`（全量约 8 分钟；`--quick` 约 2 分钟）。产物全部写到 `$AUDIT_OUT`（默认 `/private/tmp/pion-regex-audit`），工作树保持干净
- 单跑红队测试：`pionc test -p regex_audit packages/regex/audit`（16 个红测试当前全部 FAIL，5 个对照测试全部 PASS）

## 结论

**不能宣称与 Rust `regex` 语义等价，也不能宣称 `--release` 可用、对任意输入线性且接近 Rust 速度。**

1. `--release` 构建下 `captures()` / `captures_at()` 对不匹配的输入返回 `Some(垃圾)`，原生直接 SIGSEGV（差分用例 43% 崩溃）。根因是 `pionc` 的发布版误编译，触发条件是本包 `Prefilter::None` 这个变体名。包自带的测试和基准都只跑 debug 或绕开了这个 API，所以没发现。
2. Unicode `\b` / `\B` 会在多字节字符**中间**报告空匹配，`replace_all` / `split` 因此输出非法 UTF-8。
3. 与 Rust 的语义分歧覆盖迭代、锚点、优先级、字符类、Unicode 表与大小写折叠，差分 51,805 例中 18,276 例不一致（大头是可归因的少数几个根因，见 §1）。
4. 编译期 DoS：一个 80 KB 的 `[aaaa…]` 要编译 **30 s**（Rust 20 ms）；`[` 嵌套绕过 `nest_limit`。
5. 运行期性能断崖：只要模式含 `\b`/`\B`、Unicode `\w` 或需要非 One-Pass 捕获，Pion 就落到 PikeVM，比 Rust 慢 **86–637 倍**；含 `\b` 的 200 条 `RegexSet` 超时（>60 s，Rust 2.0 s）。自带 `bench/` 四项负载全是纯 ASCII、无 `\b`、One-Pass 友好的日志，恰好避开了这些断崖。

| 级别 | 编号 | 铁证 | 关键数字 |
|---|---|---|---|
| **P0** | P0-1 | `--release` 下 `captures`/`captures_at` 把 `None` 返回成 `Some(垃圾)`，原生取值即 SIGSEGV | curated 8,783 例中 3,799 例崩溃（原生）/ 输出错误（wasm32）；fuzz 20,000 例中 7,585 例 |
| **P0** | P0-2 | Unicode `\b`/`\B` 在码点中间报空匹配，替换后产出非法 UTF-8 | `\B` 替换 `"k🚀1x"` → `k\xF0[]\x9F\x9A[]\x801[]x`；差分中 320 例 `find_iter` 切在码点中间（含 P1-8） |
| **P0** | B1 | 字符类项数二次方编译（迭代快排遇重复键退化）| `[a×80000]` **30.7 s** vs Rust 0.02 s；`[` 嵌套 2 万层 1.8 s，20 万层超时 |
| **P1** | P1-1 | 紧贴上一个匹配的空匹配没有跳过（`find_iter`/`captures_iter`/`replace_all`/`split`） | 差分 3,383 例；`a*` 替换 `baaac` 得 `-b--c-`，Rust `-b-c-` |
| **P1** | P1-2 | `(?m)$` 在 `\n` 之前的空匹配永远找不到（DFA 路径） | `(?m)$` 替换 `"ab\ncd"` 得 `ab\ncd;`，Rust `ab;\ncd;` |
| **P1** | P1-3 | 可空循环体的 leftmost-first 优先级与空迭代捕获与 Rust 不同 | `(\|a)*` on `aa`：Rust `0-0`，Pion `0-2`；`(a*)*` on `""` 组 1：Rust `0-0`，Pion `None` |
| **P1** | P1-4 | 字符类集合运算 `&&` `--` `~~` 与嵌套类 `[[a]]` 被静默当成字面量 | `[a-c&&b]` 匹配 `a`；`[[a]]` 不匹配 `a` |
| **P1** | P1-5 | `[` 嵌套不计入 `nest_limit` | 300 层 `[` 编译通过（Rust 报嵌套超限） |
| **P1** | P1-6 | `(?i)` 大小写折叠缺 Unicode 等价类 | `(?i)k` 不匹配 `K`（开尔文）、`(?i)s` 不匹配 `ſ`、`(?i)σ` 不匹配 `ς`、`ǅ` 系列 |
| **P1** | P1-7 | Unicode 属性/Perl 类表不完整 | `\w` 不含 `ﬀ`/`K`，`\pN` 不含 `①`，`\p{Lu}` 不含 `İ`，`\p{Ll}` 不含 `ſ`/`ı` |
| **P1** | P1-8 | `(?-u)` 可匹配非法 UTF-8 的类在 `String` 上被接受，匹配切开码点 | `(?-u).` on `中` → `0-1,1-2,2-3`；Rust 编译期拒绝 |
| **P1** | B2 | Unicode `\b` 每次判定都重建并快排整张 `\w` 表 | `\bword\b` **637×**，`\b\w+\b` **220×**，带 `\b` 的捕获 **166×** |
| **P1** | B3 | 非 One-Pass 捕获每次调用都按 NFA 状态数初始化 PikeVM | `(\w+?)(o\|ox)( ?)` **86×**（Unicode `\w`）/ 12×（ASCII 类） |
| **P1** | B4 | 含 `\b` 的 `RegexSet` 整体退到 PikeVM | 16 条规则 **140×**；200/500 条 **超时 >60 s**（Rust 2.0 s / 6.8 s） |
| P1 | B5 | `$` 结尾的模式没有反向/后缀优化，DFA 缓存反复抖动 | `(?:0\|1)*1(?:0\|1){30}$` on 2 MB：1.42 s vs Rust ≈0 |
| P2 | P2-1 | Rust 拒绝、Pion 接受的模式 | `\Q`、`[\w-a]`、`(?x)[ ]` |
| P2 | P2-2 | 重复空表达式/纯断言被拒（Rust 接受） | `^*`、`\b{2}`、`(?:$)+`、`(?:)*`；差分 13,191 例 |
| P2 | P2-3 | 替换模板 `${}` 原样输出（Rust 展开为空） | 145 例 |
| P2 | P2-4 | 编译期内存放大：拒绝重复炸弹前先展开 | `((a{100}){100}){100}` 94 MiB vs 14.6 MiB；`[\s\S]{20000}` 编译通过占 126 MiB（Rust 拒绝） |
| P2 | P2-5 | 递归下降解析/编译：Wasm32 嵌套约 500 层即栈溢出 | `nest_limit` 调到 1e6 时 600 层 `(` 在 wasm32 `RangeError`；Rust 2 万层正常 |
| P2 | P2-6 | `(a){0}` 捕获组计数 | Rust 1.11.1 报 1 组（丢掉 `{0}` 里的组），Pion 报 2 组；属 Rust 怪癖，记录不判错 |
| P2 | B6 | 自带 `bench/` 不具代表性 | 4 项全是 ASCII 日志、无 `\b`、One-Pass 捕获、ReDoS 项被进程启动与编译主导；且只调 `captures_slots_at`，绕开了 P0-1 |

## 需要指挥官决定的事

- **P0-1 根因在编译器，不在本包算法。** 最小复现 `audit/compiler_repro/`（两个 30 行的包）：一个包里只要声明了名为 `None` 的枚举变体，下游包在 `--release` 下收到的 `Option[堆结构体]` 的 `None` 就变成 `Some`。本包可以立刻绕过（把 `Prefilter::None` 改名，例如 `Prefilter::NoPrefilter`），但 `pionc` 本身的缺陷需要交给维护编译器的会话修。
- 是否要求 `(?-u)` 与 Rust 一样在 `String` 上编译期拒绝（P1-8），还是把 Pion 的 `String` 明确定义为字节串并在 README 声明偏离——这是 API 语义选择，本报告按 Rust 行为断言。
- `README.md` 的「Full Rust `regex` / RE2 syntax」「Unicode simple case folding」「100% O(N)」三处表述需要改：前两项被 P1-4/P1-6/P1-7/P2-2 推翻；O(N) 在匹配期成立（未发现指数回溯），但编译期有二次方（B1）。

## 1. 正确性铁证

差分规模（`run_audit.sh` 第 4 步，`regex::compile` 默认选项 vs `Regex::new`）：

| 用例集 | 例数 | 不一致 | 说明 |
|---|---:|---:|---|
| `curated`（214 个攻击模式 × 41 个对抗输入 + 22 种替换模板）| 8,783 | 1,089 | 空匹配、UTF-8 边界、左优先、锚点、flags、Unicode、类、替换模板 |
| `fuzz`（seed 1，随机组合原子/量词/组/flag）| 20,000 | 3,721 | 去掉了 `(?-u)` 与重复断言两类已知噪声后的结果 |
| `capfuzz`（seed 3，捕获组密集、小字母表）| 20,000 | 13,448 | 12,197 例是 P2-2（`(?:)*` 一类被拒）|
| `sets`（`RegexSet`，seed 7）| 3,022 | 18 | 全部是 P2-2 的编译接受度差异；**匹配结果零分歧** |

每个用例比较 `is_match`、`find`、`find_iter`、每个码点边界上的 `find_at`/`is_match_at`、`captures`、`captures_iter`、`replace`、`replace_all`、`replacen(2)`、`split`、`splitn(2/3)`；`RegexSet` 比 `is_match` 与 `matches`。明细在 `$AUDIT_OUT/<集>.mismatch.txt`，`diff/classify.py` 按根因分桶：

| 根因桶 | curated | fuzz | capfuzz | 对应编号 |
|---|---:|---:|---:|---|
| 紧贴上一匹配的空匹配未跳过 | 478 | 1,965 | 940 | P1-1 |
| Pion 拒绝 Rust 接受的模式 | – | 976 | 12,197 | P2-2 |
| Pion 接受 Rust 拒绝的模式 | 164 | – | – | P2-1、P1-8 |
| `find()` 区间不同 | 91 | 273 | 108 | P0-2、P1-2、P1-3 |
| `find_at()` 区间不同 | 76 | 373 | 40 | P0-2、P1-3 |
| 捕获组区间不同 | 64 | 114 | 158 | P1-3 |
| `captures_iter` 后续匹配的组不同 | – | 19 | 5 | P1-3 |
| `is_match` 不同 | 30 | 1 | – | P1-4、P1-7、P0-2 |
| 只有 `replace*` 不同 | 145 | – | – | P2-3 |
| 捕获组计数不同 | 41 | – | – | P2-6 |

崩溃/挂起：debug 原生与 wasm32 均为 **0**。

### P0-1 `--release` 下 `Option[Captures]` 的 `None` 变成 `Some`
`audit/release_probe` 在四种构建下的结果（`run_audit.sh` 第 3 步）：

```text
[debug native]            release_probe_failures=0
[debug wasm32]            release_probe_failures=0
[--release native]        FAIL captures(no match) is None  FAIL captures_at(no match) is None
[--release wasm32]        FAIL captures(no match) is None  FAIL captures_at(no match) is None
```

后果：任何人 `match re.captures(s) { Some(c) => c.get(0) … }` 在 `--release` 原生下对不匹配输入直接 SIGSEGV（`rc=-11`），wasm32 下拿到 `len()==0` 的假捕获。差分驱动在原生 `--release` 下，curated 3,799/8,783、fuzz 7,585/20,000 个用例崩溃；没崩的用例与 debug 输出逐字节一致（`diff/cmp_builds.py`），说明包内部逻辑一致，问题只在跨包返回的 `None`。

根因定位：`src/nfa.pion:23` 的 `pub enum Prefilter { None … }`。最小复现 `audit/compiler_repro/minilib` + `app`：删掉 `Pf::None` 变体即恢复正常；debug `a=false b=false`，`--release` `a=true b=true`。`find`（`Option[Match]`，`val struct`）、`Captures::get`、`capture_names` 不受影响。

### P0-2 Unicode `\b` / `\B` 在码点中间报告空匹配
`src/pikevm.pion` 的 `eval_look` 在每个**字节**位置判定 `WordBoundaryUnicode`/`NotWordBoundaryUnicode`，没有要求位置是字符边界；`decode_utf8_before` 在码点中间解出垃圾值。Rust 在 UTF-8 模式下只在字符边界报告空匹配。

```text
\B on "k🚀1x"   Rust find=6-6           Pion find=2-2, find_iter=2-2,4-4,6-6
               replace_all("[]")  Rust "k🚀1[]x"   Pion "k\xF0[]\x9F\x9A[]\x801[]x"（非法 UTF-8）
\b on "中文"     Rust 0-0,6-6            Pion 0-0,4-4,6-6
\b on "aé"      Rust 0-0,3-3            Pion 0-0,2-2,3-3
```

修复方向：Unicode 断言在非字符边界一律为假；迭代/`find_at` 的空匹配也要落在字符边界。

### P1-1 紧贴上一匹配的空匹配没有跳过
Rust 与 Go 的规则：迭代时若空匹配的位置等于上一个匹配的终点，就丢弃它并从下一个字符继续。`src/regex.pion` 的 `find_spans_into`、`captures_iter`、`replacen`、`splitn` 都没有这条规则。

```text
a*   on "baaac"   Rust 0-0,1-4,5-5      Pion 0-0,1-4,4-4,5-5
     replace_all("-")  Rust "-b-c-"      Pion "-b--c-"
     split             Rust ["","b","c",""]   Pion ["","b","","c",""]
(a)? on "ba"      replace_all("[$0]")  Rust "[]b[a]"   Pion "[]b[a][]"
```

### P1-2 `(?m)$` 在 `\n` 前的空匹配找不到
`src/dfa.pion:755` 用 `match_at_nl` 记录「下一个字节是 `\n` 才成立」的条件匹配，但记录之后没有按 leftmost-first 截断非锚定前缀线程，扫描继续，末尾的 EOI 匹配覆盖了它。PikeVM 路径是对的（`(?m)(?:$|\bZ)` 强制 PikeVM 时得 `1-1`）。

```text
(?m)$   on "a\n"      Rust 1-1   Pion 2-2
(?m)^$  on "\n"       Rust 0-0   Pion 1-1
(?m)$   replace_all(";") on "ab\ncd"   Rust "ab;\ncd;"   Pion "ab\ncd;"
```

### P1-3 可空循环体与空迭代
循环体能匹配空串时（`(|a)*`、`(?:\b|a)+`、`(b*|a)+`、`^(a{0,2}?)*`），Rust 的 PikeVM 在同一位置不会重入已访问状态，所以优先的空分支一旦走过，循环就退出；Pion 继续用低优先级分支吃字符。另一面，Rust 会把最后一次空迭代记进捕获组。

```text
(|a)*        on "aa"      Rust 0-0          Pion 0-2
(?:\b|a)+    on "a"       Rust 0-0          Pion 0-1
(b*|a)+      on "acabac"  Rust 0-0          Pion 0-1
(a*)*        on ""        Rust 组1=0-0      Pion 组1=None
(?U)(a|((中?a)|(?:a+?a*?[ab]*|ab*[ab])?)*?b+) on "aaab"  第 4 个匹配 Rust 组2=3-3，Pion None
```

### P1-4 字符类集合运算与嵌套类被静默误解
解析器不认识 `&&`、`--`、`~~` 与类中的 `[`，把它们当字面量，不报错：

```text
[a-c&&b]  on "a"   Rust 不匹配   Pion 0-1
[a-z--b]  on "b"   Rust 不匹配   Pion 0-1
[[a]]     on "a"   Rust 0-1      Pion 不匹配（被解析成 `[\[a]` 后接字面量 `]`）
[^[a]]    on "中"  Rust 0-3      Pion 不匹配
```

### P1-5 / B1 字符类编译二次方、`[` 不计嵌套
`[` 在类里被当字面量，所以 `[[[[…a]]]]` 不计 `nest_limit`。更严重的是类里的项越多编译越慢：`src/unicode.pion:125` `normalize_ranges` 用迭代快排，键全相同时退化为 O(n²)。

| 模式 | Pion | Rust |
|---|---:|---:|
| `[` + `a`×20,000 + `]` | 2.48 s | 0.21 s |
| `[` + `a`×40,000 + `]` | 9.57 s | 0.02 s |
| `[` + `a`×80,000 + `]` | **30.74 s** | 0.02 s |
| `[`×20,000 + `a]` | 1.97 s | 拒绝（嵌套超限）|
| `[`×200,000 … | **>60 s 超时** | 0.05 s 拒绝 |

不可信模式输入时这是 DoS。

### P1-6 / P1-7 Unicode 大小写折叠与属性表不全
```text
(?i)k     on "K"(U+212A)  Rust 匹配   Pion 不匹配     (?i)[k] 同
(?i)s     on "ſ"           Rust 匹配   Pion 不匹配
(?i)σ     on "ς"           Rust 匹配   Pion 不匹配
(?i)ǅ     on "ǄǅǆDž"        Rust 0-2,2-4,4-6   Pion 2-4
\w        on "ﬀ" / "K"     Rust 匹配   Pion 不匹配     （连带 `\b` on "ﬀ ﬃ" 整句不匹配）
\pN       on "①"           Rust 匹配   Pion 不匹配
\p{Lu}    on "İ"           Rust 匹配   Pion 不匹配
\p{Ll}    on "ſ" / "ı"      Rust 匹配   Pion 不匹配
```
`src/unicode.pion` 的表是手写的区间子集，大小写折叠只有简单一对一映射。应从 Unicode 数据生成完整表（Rust 用 UCD 15 生成）。

### P1-8 `(?-u)` 在 `String` 上被接受
Rust 对 `&str` 拒绝任何可能匹配非法 UTF-8 的模式（`(?-u).`、`(?-u)[^a]`、`(?-u)\W`、`(?-u:\xFF)`）。Pion 接受，结果切开码点：`(?-u).` on `中` → `0-1,1-2,2-3`，`Match.text` 是非法 UTF-8。

### P2-1 / P2-2 / P2-3 语法接受度与替换模板
- Pion 接受、Rust 拒绝：`\Q`、`[\w-a]`（Rust：类作区间端点非法）、`(?x)[ ]`（x 模式下类里的空格被忽略，类为空）。
- Pion 拒绝（`repetition operator missing expression`）、Rust 接受：`^*`、`\b{2}`、`(?:$)+`、`(?m:^)+`、`(?:)*`、`(?:\A){2,}`。
- `${}`：Rust 展开为空串，Pion 原样输出 `${}`。
- 其余模板（`$0`、`$1`、`${1}`、`$10`、`$name`、`${name}`、`$name_x`、`$$`、尾随 `$`、`$99`、`${`、`${1`、`$-1`、`$ {1}`、未参与匹配的组）全部与 Rust 一致。

### 已验证无问题（对照测试，`control_test.pion`）
左优先交替与非贪婪、`(?U)`、One-Pass 多字节捕获、`""` 按码点前进、`RegexSet` 匹配（3,022 例零分歧）、重复计数炸弹立即 `CompiledTooBig`、`(` 嵌套 20 万层立即 `NestLimitExceeded`、ReDoS 经典模式线性。

## 2. 构建模式一致性（Native vs Wasm32）

`diff/cmp_builds.py` 以原生 debug 为基准逐块比较驱动输出：

| 构建 | curated 8,783 | fuzz 20,000 |
|---|---|---|
| wasm32 debug | 8,783 逐字节一致 | 20,000 逐字节一致 |
| wasm32 `--release` | 3,799 不一致（全是 P0-1 的 `captures=`） | 7,585 不一致（同上） |
| native `--release` | 4,984 一致，3,799 SIGSEGV | 12,415 一致，7,585 SIGSEGV |

栈深度：默认 `nest_limit=250` 下四种构建都安全。`nest_limit` 调大后 wasm32 `--release` 在 600 层 `(` 处 `RangeError: Maximum call stack size exceeded`（400 层正常），原生 2 万层正常、20 万层 SIGSEGV（Rust 20 万层也 abort）。Rust 的解析器用堆栈，wasm32 上同样 2 万层正常。

## 3. 安全与 DoS

`run_audit.sh` 第 6 步的完整记录（单次运行，墙钟，`/usr/bin/time -l` 峰值 RSS，超时 60 s；共享机有波动，倍率量级可复现）：

| scenario | pion status | pion ms | pion RSS | rust status | rust ms | rust RSS | pion/rust time | stdout identical |
| --- | --- | ---: | ---: | --- | ---: | ---: | ---: | :---: |
| `compile: rep a{1000000000}` | ok | 10.3 | 1.8 MiB | ok | 19.0 | 14.6 MiB | 0.54x | yes |
| `compile: rep a{0,1000000}` | ok | 24.9 | 74.9 MiB | ok | 11.1 | 15.7 MiB | 2.25x | yes |
| `compile: rep ((a{100}){100}){100}` | ok | 31.0 | 94.0 MiB | ok | 9.7 | 14.6 MiB | 3.21x | yes |
| `compile: rep (?:a{1000}){1000}` | ok | 26.6 | 94.0 MiB | ok | 11.2 | 14.6 MiB | 2.37x | yes |
| `compile: rep \w{1000}` | ok | 29.6 | 48.3 MiB | ok | 38.9 | 16.3 MiB | 0.76x | **NO** |
| `compile: rep \p{L}{200}` | ok | 9.0 | 8.8 MiB | ok | 33.0 | 29.1 MiB | 0.27x | yes |
| `compile: rep [\s\S]{20000}` | ok | 75.0 | 126.2 MiB | ok | 39.2 | 25.9 MiB | 1.91x | **NO** |
| `compile: rep (?i)\w{100}` | ok | 7.5 | 6.6 MiB | ok | 20.1 | 19.9 MiB | 0.37x | yes |
| `compile: rep .{65536}` | ok | 50.6 | 90.7 MiB | ok | 43.1 | 16.7 MiB | 1.17x | yes |
| `compile: rep a{4294967296}` | ok | 14.3 | 1.8 MiB | ok | 15.7 | 2.4 MiB | 0.91x | yes |
| `compile: rep a{2147483648}` | ok | 7.8 | 1.8 MiB | ok | 11.5 | 14.6 MiB | 0.68x | yes |
| `compile: rep a{99999999999999999999}` | ok | 6.4 | 1.8 MiB | ok | 6.4 | 2.4 MiB | 0.99x | yes |
| `nest: ( x300` | ok | 7.1 | 1.9 MiB | ok | 5.9 | 2.7 MiB | 1.21x | yes |
| `nest: (?: x300` | ok | 4.5 | 1.9 MiB | ok | 5.6 | 2.7 MiB | 0.81x | yes |
| `nest: [ x300` | ok | 5.5 | 2.0 MiB | ok | 5.7 | 2.7 MiB | 0.97x | **NO** |
| `nest: (?i: x300` | ok | 5.0 | 1.9 MiB | ok | 4.9 | 2.8 MiB | 1.01x | yes |
| `nest: unclosed ( x300` | ok | 4.3 | 1.9 MiB | ok | 4.5 | 2.6 MiB | 0.95x | yes |
| `nest-nl: ( x300 nest_limit=1e6` | ok | 5.9 | 2.1 MiB | ok | 5.9 | 3.3 MiB | 1.00x | yes |
| `nest-nl: a** x300 nest_limit=1e6` | ok | 7.2 | 2.1 MiB | ok | 6.3 | 3.5 MiB | 1.15x | yes |
| `wide: a\|...\|a x300` | ok | 5.4 | 2.0 MiB | ok | 6.0 | 2.8 MiB | 0.89x | yes |
| `wide: (a)(a).. x300` | ok | 5.4 | 2.1 MiB | ok | 6.9 | 3.2 MiB | 0.78x | yes |
| `chain: a?a?.. x300` | ok | 5.3 | 2.0 MiB | ok | 6.3 | 3.5 MiB | 0.85x | yes |
| `chain: (?:a*)* nested x300` | ok | 5.3 | 1.9 MiB | ok | 6.3 | 2.7 MiB | 0.84x | yes |
| `nest: ( x5000` | ok | 4.9 | 1.9 MiB | ok | 7.1 | 4.9 MiB | 0.69x | yes |
| `nest: (?: x5000` | ok | 4.7 | 2.0 MiB | ok | 6.7 | 4.8 MiB | 0.71x | yes |
| `nest: [ x5000` | ok | 124.7 | 3.4 MiB | ok | 7.3 | 6.0 MiB | 17.01x | **NO** |
| `nest: (?i: x5000` | ok | 6.3 | 2.0 MiB | ok | 7.2 | 6.0 MiB | 0.87x | yes |
| `nest: unclosed ( x5000` | ok | 5.0 | 1.9 MiB | ok | 7.1 | 3.9 MiB | 0.71x | yes |
| `nest-nl: ( x5000 nest_limit=1e6` | ok | 6.7 | 5.9 MiB | ok | 7.5 | 7.2 MiB | 0.89x | yes |
| `nest-nl: a** x5000 nest_limit=1e6` | ok | 6.9 | 5.5 MiB | ok | 10.1 | 9.0 MiB | 0.68x | yes |
| `wide: a\|...\|a x5000` | ok | 5.8 | 4.3 MiB | ok | 7.7 | 4.6 MiB | 0.75x | yes |
| `wide: (a)(a).. x5000` | ok | 6.4 | 4.9 MiB | ok | 8.4 | 6.9 MiB | 0.77x | yes |
| `chain: a?a?.. x5000` | ok | 6.1 | 4.4 MiB | ok | 33.2 | 7.8 MiB | 0.18x | yes |
| `chain: (?:a*)* nested x5000` | ok | 6.3 | 2.0 MiB | ok | 8.0 | 5.5 MiB | 0.78x | yes |
| `nest: ( x20000` | ok | 5.9 | 2.0 MiB | ok | 9.7 | 13.2 MiB | 0.60x | yes |
| `nest: (?: x20000` | ok | 7.2 | 2.0 MiB | ok | 11.5 | 12.9 MiB | 0.62x | yes |
| `nest: [ x20000` | ok | 1989.9 | 7.8 MiB | ok | 10.2 | 13.4 MiB | 194.80x | **NO** |
| `nest: (?i: x20000` | ok | 5.2 | 2.1 MiB | ok | 11.0 | 17.3 MiB | 0.47x | yes |
| `nest: unclosed ( x20000` | ok | 5.4 | 2.0 MiB | ok | 7.1 | 9.7 MiB | 0.76x | yes |
| `nest-nl: ( x20000 nest_limit=1e6` | ok | 10.0 | 17.7 MiB | ok | 13.4 | 18.5 MiB | 0.75x | yes |
| `nest-nl: a** x20000 nest_limit=1e6` | ok | 10.8 | 16.3 MiB | ok | 23.0 | 26.4 MiB | 0.47x | yes |
| `wide: a\|...\|a x20000` | ok | 8.7 | 11.3 MiB | ok | 9.7 | 10.6 MiB | 0.90x | yes |
| `wide: (a)(a).. x20000` | ok | 10.6 | 13.5 MiB | ok | 15.5 | 18.9 MiB | 0.69x | yes |
| `chain: a?a?.. x20000` | ok | 9.4 | 11.9 MiB | ok | 112.0 | 22.8 MiB | 0.08x | yes |
| `chain: (?:a*)* nested x20000` | ok | 6.2 | 2.1 MiB | ok | 11.8 | 15.8 MiB | 0.52x | yes |
| `nest: ( x200000` | ok | 5.3 | 2.7 MiB | ok | 48.0 | 94.2 MiB | 0.11x | yes |
| `nest: (?: x200000` | ok | 6.5 | 3.4 MiB | ok | 50.7 | 96.2 MiB | 0.13x | yes |
| `nest: [ x200000` | TIMEOUT>60s | 60000.0 | - | ok | 52.2 | 102.6 MiB | 1150.50x | **NO** |
| `nest: (?i: x200000` | ok | 6.4 | 3.8 MiB | ok | 66.1 | 136.8 MiB | 0.10x | yes |
| `nest: unclosed ( x200000` | ok | 6.0 | 2.3 MiB | ok | 25.8 | 59.7 MiB | 0.23x | yes |
| `nest-nl: ( x200000 nest_limit=1e6` | CRASH(rc=-11) | 6.6 | 14.8 MiB | CRASH(rc=-6) | 60.4 | 101.8 MiB | 0.11x | **NO** |
| `nest-nl: a** x200000 nest_limit=1e6` | CRASH(rc=-11) | 9.9 | 15.1 MiB | CRASH(rc=-6) | 113.0 | 138.0 MiB | 0.09x | **NO** |
| `wide: a\|...\|a x200000` | ok | 36.6 | 88.8 MiB | ok | 54.3 | 76.1 MiB | 0.67x | yes |
| `wide: (a)(a).. x200000` | ok | 61.7 | 113.2 MiB | ok | 98.9 | 126.0 MiB | 0.62x | **NO** |
| `chain: a?a?.. x200000` | ok | 39.9 | 99.1 MiB | ok | 962.1 | 119.1 MiB | 0.04x | **NO** |
| `chain: (?:a*)* nested x200000` | ok | 5.4 | 3.8 MiB | ok | 63.2 | 124.5 MiB | 0.08x | yes |
| `class: [a x5000] (duplicate class items)` | ok | 121.3 | 2.1 MiB | ok | 6.5 | 4.1 MiB | 18.55x | yes |
| `class: [a x20000] (duplicate class items)` | ok | 1994.5 | 2.4 MiB | ok | 8.2 | 10.0 MiB | 242.36x | yes |
| `class: [a x40000] (duplicate class items)` | ok | 7343.2 | 2.8 MiB | ok | 8.8 | 16.2 MiB | 830.15x | yes |
| `class: [ab..] 20000 distinct-ish items` | ok | 894.5 | 2.4 MiB | ok | 8.1 | 10.0 MiB | 110.11x | yes |
| `literal: 1 MiB literal pattern` | ok | 82.1 | 193.4 MiB | ok | 58.4 | 106.4 MiB | 1.41x | yes |
| `dfa-thrash: .*[01]{20} find` | ok | 11.0 | 4.0 MiB | ok | 9.1 | 4.4 MiB | 1.22x | yes |
| `dfa-thrash: [01]*1[01]{20} find` | ok | 291.2 | 7.4 MiB | ok | 101.9 | 8.5 MiB | 2.86x | yes |
| `dfa-thrash: [a-z]*a[a-z]{18} find` | ok | 12.2 | 5.6 MiB | ok | 11.2 | 4.9 MiB | 1.09x | yes |
| `dfa-thrash: [a-q][^u-z]{13}x is_match` | ok | 20.0 | 10.5 MiB | ok | 11.1 | 4.9 MiB | 1.80x | yes |
| `dfa-thrash: (?s).*1[01]{12} is_match` | ok | 98.2 | 11.1 MiB | ok | 5.6 | 4.1 MiB | 17.43x | yes |
| `perf: high-entropy literal miss 'zqxjk'` | ok | 17.5 | 9.4 MiB | ok | 6.2 | 6.4 MiB | 2.83x | yes |
| `perf: high-entropy alt miss` | ok | 19.7 | 9.4 MiB | ok | 7.2 | 6.5 MiB | 2.74x | yes |
| `perf: prefix literal + class 'Sherlock [A-Z]\w+'` | ok | 13.2 | 6.5 MiB | ok | 9.7 | 5.8 MiB | 1.36x | yes |
| `perf: \p{L}+ on Unicode` | ok | 54.5 | 6.8 MiB | ok | 38.0 | 5.6 MiB | 1.44x | yes |
| `perf: \w+ on Unicode` | ok | 52.4 | 6.7 MiB | ok | 40.3 | 5.6 MiB | 1.30x | yes |
| `perf: \bword\b (PikeVM in Pion)` | ok | 14106.9 | 6.5 MiB | ok | 22.2 | 5.4 MiB | 636.83x | yes |
| `perf: \b\w+\b (PikeVM in Pion)` | ok | 14419.1 | 17.3 MiB | ok | 65.5 | 6.2 MiB | 220.06x | yes |
| `perf: (?i)sherlock\|holmes` | ok | 19.9 | 6.5 MiB | ok | 14.8 | 5.8 MiB | 1.34x | yes |
| `perf: non-one-pass captures (a\|ab)(c\|bcd)?` | ok | 2188.1 | 6.5 MiB | ok | 25.4 | 6.0 MiB | 86.13x | yes |
| `perf: one-pass captures (\w+) (\w+)` | ok | 25.0 | 6.5 MiB | ok | 21.6 | 5.1 MiB | 1.16x | yes |
| `perf: captures with \b (PikeVM)` | ok | 17226.7 | 6.5 MiB | ok | 104.1 | 6.0 MiB | 165.52x | yes |
| `redos: (x+x+)+y on x*20000` | ok | 6.7 | 2.0 MiB | ok | 4.9 | 2.7 MiB | 1.35x | yes |
| `redos: (x*)*$ captures on x*20000` | ok | 4.5 | 2.0 MiB | ok | 5.9 | 2.7 MiB | 0.77x | yes |
| `redos: (?:x\|x)*y on x*20000` | ok | 4.5 | 2.0 MiB | ok | 5.1 | 2.7 MiB | 0.89x | yes |
| `redos: \b(x+)+\b! on x*20000` | ok | 10.4 | 2.0 MiB | ok | 5.6 | 2.7 MiB | 1.87x | yes |
| `empty-match iteration: '' on Unicode` | ok | 48.2 | 26.6 MiB | ok | 46.6 | 4.7 MiB | 1.03x | yes |
| `set: 16 rules (incl. \b) x 40k lines` | ok | 15296.5 | 9.0 MiB | ok | 109.6 | 7.3 MiB | 139.54x | yes |
| `set: 13 rules (no \b) x 40k lines` | ok | 15.2 | 8.9 MiB | ok | 12.6 | 6.3 MiB | 1.20x | yes |
| `set: 200 rules (incl. \b) x 40k lines` | TIMEOUT>60s | 60000.0 | - | ok | 2045.9 | 13.8 MiB | 29.33x | **NO** |
| `set: 160 rules (no \b) x 40k lines` | ok | 56.2 | 19.8 MiB | ok | 36.8 | 9.4 MiB | 1.53x | yes |
| `set: 500 rules (incl. \b) x 40k lines` | TIMEOUT>60s | 60000.0 | - | ok | 6779.8 | 23.3 MiB | 8.85x | **NO** |
| `set: 400 rules (no \b) x 40k lines` | ok | 5049.1 | 34.9 MiB | ok | 2487.3 | 10.5 MiB | 2.03x | yes |

要点：
- 重复计数炸弹（`a{1000000000}`、`((a{100}){100}){100}`、`a{0,1000000}`、`.{65536}`）全部快速拒绝，但 Pion 先展开再判大小，峰值 RSS 75–94 MiB（Rust 15 MiB）；1 MiB 字面量模式 193 MiB（Rust 106 MiB）。
- `\w{1000}` 与 `[\s\S]{20000}`：Rust 超出 10 MiB 编译上限拒绝，Pion 接受（后者 126 MiB）。Pion 的 `size_limit` 与 Rust 的单位不同，记录不判错。
- Lazy DFA 状态爆炸（`.*[01]{20}`、`[01]*1[01]{20}`、`[a-z]*a[a-z]{18}`、`[a-q][^u-z]{13}x`、`[01]*1[01]{25}2`、`1[01]{25}0` 在 1–2 MB 输入上）：结果与 Rust 100% 一致，没有错匹配或卡死；最差 2.9×（`[01]*1[01]{20}`）与 17×（`(?s).*1[01]{12}$`）。
- 经典 ReDoS（`(x+x+)+y`、`(x*)*y`、`(?:x|xx)*y`、`\b(x+)+\b!` on `x`×20000）：全部线性，与 Rust 同量级。

## 4. 性能弱项与基准公平性

### 断崖（同机、同输入、stdout 一致）
| 负载 | Pion | Rust | 倍率 | 根因 |
|---|---:|---:|---:|---|
| `\bword\b`，2.8 MB 混合中英文 | 14.1 s | 22.2 ms | **637×** | B2：`src/unicode.pion:460` `is_unicode_word_cp` 每次调用 `unicode_word_ranges()`，重新拼接并快排整张表 |
| `\bword\b`，`中文 `×20000（无 ASCII）| 1.12 s | ≈0 | – | 同上；纯 ASCII 同长度只要 0.02 s |
| `\b\w+\b`，2.8 MB | 14.4 s | 65.5 ms | 220× | B2 + B3 |
| 捕获 `\b(\w+)@?(\d*)\b` | 17.2 s | 104 ms | 166× | B2 + B3 |
| 非 One-Pass 捕获 `(\w+?)(o\|ox)( ?)` | 2.19 s | 25.4 ms | 86× | B3：`pikevm_search` 每次调用 `visited.push(0)` × 状态数；Unicode `\w` 有上千状态 |
| 同上换 `[a-z]` | 0.38 s | 0.03 s | 12× | 同上 + 无有界回溯器 |
| `RegexSet` 16 条含 `\b` × 4 万行 | 15.3 s | 110 ms | 140× | B4：任一规则含 `\b` 整个集合退到 PikeVM |
| `RegexSet` 200 / 500 条含 `\b` | **>60 s 超时** | 2.0 s / 6.8 s | – | 同上 |
| `RegexSet` 400 条无 `\b` | 5.05 s | 2.49 s | 2.0× | – |
| `(?:0\|1)*1(?:0\|1){30}$`，2 MB | 1.42 s | ≈0 | – | B5：无反向后缀/锚定末尾优化，DFA 缓存抖动 |
| `(?s).*1[01]{12}$` 逐行 | 98 ms | 5.6 ms | 17× | B5 |
| 高熵字面量未命中 `zqxjk`，4 MB×5 | 17.5 ms | 6.2 ms | 2.8× | 标量逐字节比较 vs `memchr` |
| `\p{L}+` / `\w+` on Unicode | 61 / 58 ms | 43 / 44 ms | 1.4× | – |

### 可落地的纯 Pion 提速
1. **B2**：`unicode_word_ranges()` 等表在模块级只构建一次（或生成成常量数组），`is_unicode_word_cp` 先查 ASCII 再二分。预期 `\b` 场景回到线性 ~100 ns/B 以内。
2. **B3**：`pikevm_search` 的 `visited`、线程表、槽位缓冲放进 `Regex` 持有的可复用缓存（或用稀疏集，免 O(状态数) 清零）；对短区间加有界回溯器（Rust 的 `BoundedBacktracker`）。
3. **B4/B2**：Lazy DFA 支持 ASCII `\b`，遇非 ASCII 字节退出交给 PikeVM（Rust 的做法）；`RegexSet` 至少把不含 `\b` 的规则留在 DFA。
4. **B1**：`normalize_ranges` 换成三路快排或归并排序。
5. **B5**：模式以 `$`/`\z` 结尾时先反向 DFA 找起点（Rust 的 reverse-suffix / reverse-anchored 策略）。
6. 字面量预过滤：`find_bytes_at` 用 8 字节 SWAR 或首字节表跳跃，接近 `memchr`。

### `bench/` 公平性
- 四项负载全是纯 ASCII 合成日志，模式都不含 `\b`/`\B`、Unicode 类或非 One-Pass 捕获，恰好全走 Pion 最快路径；README 的「0.54×–0.95× of Rust」不能外推。
- ReDoS 项 250 次 × 4 KB，总耗时约 10 ms，基本是进程启动加编译 `a?^40a^40`，测不出匹配器差异。
- `captures_iter` 基准只用 `captures_slots_at`（返回 `Bool`），从未走 `Option[Captures]`，所以 `--release` 基准测不出 P0-1。
- 建议把 §4 的对抗负载（`stress/run_stress.py`）并入 `bench/`，按 AGENTS.md §1.3 如实报落后项。

## 5. 文件清单

| 路径 | 作用 |
|---|---|
| `run_audit.sh` | 一键跑全部 7 步 |
| `redteam_test.pion` / `control_test.pion` | 16 个红测试（期望 Rust 行为，当前 FAIL）+ 5 个对照测试（PASS） |
| `diff/rust_oracle/` | Rust `regex =1.11.1` 差分 oracle（`Cargo.lock` 锁定） |
| `diff/pion_driver/` | Pion 端同格式驱动（十六进制用例，逐字节可比） |
| `diff/run_diff.py` | 崩溃/挂起容忍的差分执行器（崩溃用例记录后从下一行续跑） |
| `diff/classify.py` / `diff/triage.py` | 按根因分桶 / 按模式压缩分歧 |
| `diff/cmp_builds.py` | native/wasm32 × debug/release 输出一致性 |
| `cases/gen_cases.py` | curated、fuzz、capfuzz、sets 用例生成（固定种子） |
| `stress/` | 编译炸弹、嵌套、DFA 抖动、性能断崖、大 `RegexSet` 的 Pion/Rust 双端驱动与执行器 |
| `release_probe/` | P0-1 的四构建模式探针 |
| `compiler_repro/` | P0-1 的 `pionc` 最小复现（与 regex 无关） |
