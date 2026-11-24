# 红队审计报告：Pion `packages/decimal` @ `9128ea9`（`feat/pkg-decimal`）

对照实现：Rust [`rust_decimal`](https://github.com/paupino/rust-decimal) **=1.37.2**（`features = ["maths"]`，`--release`，与 `bench/rust` 同版本）。
环境：Apple M5 Max (Darwin arm64，`pionc 0.1.0`，`rustc 1.100.0`，node 运行 wasm32），2026-11-23。整机同时有其他负载，时间以同一轮交替运行的**倍率**为准。

## 一键复现

```sh
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
sh packages/decimal/audit/run_audit.sh            # 全量约 6 分钟（含 ~100 s 纯 Python 生成 50k 快排杀手序列）
QUICK=1 sh packages/decimal/audit/run_audit.sh    # 杀手序列缩到 16k
BIG=1   sh packages/decimal/audit/run_audit.sh    # 另跑 1,107,139 条（100 万随机）差分
cd packages/decimal && pionc test --json audit    # 只跑红队单测：12 个 redteam_* FAIL = 12 条铁证，4 个 control_* PASS
```

所有构建产物、语料、输出都写到 `$AUDIT_OUT`（默认 `/private/tmp/pion-decimal-audit`，wasm32 运行时按 realpath 解析参数，所以用真实路径），不写进 worktree；`pionc test packages/decimal`（原有 14 个测试）不受影响。

| 文件 | 作用 |
|---|---|
| `redteam_test.pion` · `src/lib.pion` | 12 个 `redteam_*`（期望值全部由 Rust 预言机实跑得出；FAIL 即铁证，修好变绿）+ 4 个 `control_*`（Pion 扛住且与 Rust 逐位一致的攻击，必须保持绿色） |
| `oracle/src/main.rs` · `probe/src/main.pion` | 差分双端：同一协议 `OP<TAB>args` → `D <flags lo mid hi> <to_string>` / `E <类>` / `NONE` / `PANIC`，逐行逐字节比对（值、scale、符号位、字符串、错误类） |
| `gen_corpus.py` · `diff_corpus.py` | 107,139 条确定性边界矩阵 + N 条随机（默认 60,000，seed 1372），33 种操作；分类汇总并解码反例 |
| `judge_exact.py` | 值不一致时用 Python `fractions`/120 位 `decimal` 精确值仲裁谁更准 |
| `gen_dos.py` | 20 个恶意输入（200k 前导零、1M 位尾数、`1e99999999999999999`、`powi(1e9)`、`MAX % 1e-28` …） |
| `gen_qsort_killer.py` | McIlroy “A Killer Adversary for Quicksort” 针对 `Decimal::sort` 的精确移植，生成 Θ(n²) 输入 |
| `advbench/` · `oracle/src/advbench.rs` · `gen_bench_inputs.py` | 6 组对抗 benchmark 双端实现，stdout 逐字节一致（`scripts/bench_compare.py` SHA-256 校验） |

---

## 结论速览

| 级别 | # | 指控 | 证据 |
|---|---|---|---|
| **P0** | F-1 | `Decimal::sort` 是无兜底的三数取中快排，可被构造成 **Θ(n²)** | 50k 条普通两位小数金额：Pion **2,873 ms**，Rust `sort_unstable` 11.3 ms（**254 倍**）；同一批值随机顺序 Pion 只要 21 ms |
| **P1** | F-2 | 负零泄漏：`round_dp`/`round`/`round_dp_with_strategy` 把小负数舍成 `-0.00`，`from_str("-0.00")` 也保留符号位 | `(-0.004).round_dp(2)` → Pion `"-0.00"`，Rust `"0.00"`；16 字节 `serialize` 也不同（`0x80020000` vs `0x00020000`）。60k 语料 1,039 例，100 万语料 10,566 例 |
| **P1** | F-3 | `checked_div` 结果 scale 与 Rust 不一致（`unscale_96` 与 `normalize` 共用，移植偏离上游） | `1/5` Pion `"0.2"`、Rust `"0.20"`；`19.99/5` `"3.998"` vs `"3.9980"`。60k 语料 5.0%、BIG=1 语料 2.1% 的除法字符串/字节不同 |
| **P1** | F-4 | `Decimal::from_str` 静默接受科学计数法（失败后回退 `from_scientific_lossy`），Rust `FromStr` 一律拒绝 | `"1e28"` → Pion `10000000000000000000000000000`，Rust 报错；`"0e0"`、`"1E5"`、`"2.5e-3"` 同理 |
| **P1** | F-5 | `deserialize` 与 Rust 二进制不互通：Pion 读 8 位 scale，Rust 用 `0x801F_0000` 掩码（5 位）且 29..31 的进位规则不同 | 同 16 字节：scale 字节 `0x20`、尾数 12345 → Rust `12345`，Pion `0.0000000000000000000000000001`；`0x3C` → Rust `…0012345`，Pion `0` |
| P2 | F-6 | `trunc_with_scale` 不补零 | `1.trunc_with_scale(2)` Rust `"1.00"`，Pion `"1"`（2,780/6,562 例） |
| P2 | F-7 | `powi`/`powu`：负指数溢出被吞成 `Ok(0)`；倒数优先路径丢末位；exp=1/2 的 scale 规则不同 | `2^-96` Rust `None` / Pion `0`；`0.3^-3` Rust `…037`（正确）/ Pion `…036`；`1.10^2` `"1.2100"` vs `"1.21"` |
| P2 | F-8 | 零与符号的边角：`0.0+0`、`0+(-0.0)`、`fract(0.0)`、`sqrt(-0)`、`(-0.5).to_u64()` | 见下表，全部与 Rust 不同 |
| P2 | F-9 | `to_f64` 不是正确舍入（循环 `/10.0`），且 `-0` 转出 `-0.0` | 有差异的 393 例中 349 例 Rust 更接近精确值；`1e-19` 差 1 ULP |
| P2 | F-10 | `from_str_radix` 小数位溢出直接报错，Rust 舍掉多余位 | `("voqk09r5fbi23km1gk.rjclolh0jqd", 36)` Rust `9078744452314980059341770981`，Pion `Err(Overflow)` |
| P2 | F-11 | 热点性能：满宽乘 0.44x、除法 0.32x、`from_scientific` 0.38x、`sqrt` 0.41x；`checked_div` 每次调用 3–6 次堆分配 | 见第 6 节 |
| info | F-12 | 错误码与 Rust 不同（Pion 更细，但不是 1:1） | 解析溢出 Pion `Overflow`、Rust `ErrorString`；`1e4294967296` Pion `ScaleExceedsMaximumPrecision(4294967295)`、Rust `ErrorString` |

### 审过但没坐实的指控（如实记录）

- **核心算术逐位一致**：1,107,139 条（BIG=1）差分里 `checked_mul` 0/82,916、`checked_rem` 0/72,849、`compare` 0/20,521 不一致；`checked_add`/`checked_sub` 的 780 例不一致**全部**含零操作数（F-8），两边都非零时 0 例不一致。`checked_div` 只有 scale 不同（F-3），**值 0 例不同**。
- **96-bit / scale-28 极限**：`MAX + 0.4 = MAX`、`MAX + 0.5`/`0.6` 溢出、`(MAX-1) + 0.5` 银行家舍入回 `MAX-1`、`MAX % 1e-28 = 0`（scale 28）、`MAX / 1e-28` 溢出、满宽 `7.92…² = 62.771017353866807638357894230`，全部与 Rust 一致（`control_max_plus_fraction_boundaries` 等）。
- **7 种舍入策略全矩阵**：精确中点（奇/偶）、中点 ±1、`dp > scale`、`dp = 0`、`dp = 28`、`-0.00`、`MAX`，共 17,329 例，**唯一差异是结果为零时的符号位**（F-2）；数值与 scale 全部一致。
- **解析超 28 位的舍入**：`0.00…005`、`0.00…015`、`7.92281625142643375935439503355`（第 29 位进位溢出 96 位后降 scale）、`1.0000000000000000000000000000_5` 都与 Rust 一致。
- **DoS**：所有恶意输入 Pion 都是线性时间、无 panic、无 OOM（第 5 节）。`powi(2, 1e9)`、`powi(x, i64::MIN)`、`1e±99999999999999999`、1M 位尾数都在 ≤ 0.04 s 内返回。
- **Wasm32 vs Native**：167,139 条语料在 native debug / native release / wasm32 debug / wasm32 release 四种产物上 **stdout SHA-256 完全一致**（`f2e21d63…20d5fb`）。
- **sqrt 的 28 位精度**：100k 随机值（A6）两边结果逐位相同；`sqrt(0/1/2/MAX/1e-28/完美平方)` 值一致，只有 scale 继承 F-3 的差异（`sqrt(0.25)` Rust `0.500000000000000000000`、Pion `0.5`）。负数两边都 `None`；没观察到 Rust 的 “geo mean circuit breaker” panic。
- **Pion 比 Rust 好的地方**（如实记录，都是 Rust 1.37.2 自身的 bug）：
  - Rust `from_str` 在超过 28 位小数后**忽略剩余所有字符**：`"1.3333…(1M 位)e5"` 返回 `1.333…`（丢了 `e5`），`"0.15459181813287931185973205269321761E"` 被接受；Pion 正确处理或拒绝。
  - Rust `from_scientific` 因上一条接受垃圾：`"…466-04367E+3"`、`"… e0"`（BIG=1 语料 70 例）；Pion 拒绝。
  - Rust `from_str_exact` 把 28 位后的尾随 `_` 当多余位，`"0.2428389718463473682465583165_"` 报 `Underflow`；Pion 正确接受。
  - Rust `rescale(29)` 产出 **scale = 29 的非法 Decimal**（`0x001d0000`），`rescale(255)` / `trunc_with_scale(255)` **panic**；Pion 夹到 28。
  - Rust `from_str_radix` 对 97 个 `1`（radix 2）或 1M 前导零 **panic**；在 96 位边界还会给出**错误的值**（`"00df801.30aed43ae2b85c26b9b"`, 16 → Rust 尾数 `0x0df80130aed43ae2b85c2700`，Pion 精确 `0xdf80130aed43ae2b85c26b9b`）。
  - `powi` 负指数精度：差异中 83 例 Pion 更准、28 例 Rust 更准（如 `0.5^-29`：Rust `536870912.00000000001441151881`，Pion 精确 `536870912`）。
  - `deserialize` scale 30/31 的进位：Rust 拿 `/100`、`/1000` 的完整余数与 5 比较（`15/100` 也进位），数学上 Pion 对。但 F-5 的问题是**二进制不互通**，见下。

---

## P0

### F-1 `Decimal::sort` 可被构造成 Θ(n²)（`src/cmp.pion:178` `quicksort_dec`）

实现是确定性的三数取中（lo/mid/hi）Hoare 快排，17 个元素以下插入排序，**没有深度上限、没有堆排序兜底、没有随机化**。按 McIlroy 1999 的方法，用 `gen_qsort_killer.py` 精确复刻这段算法并让比较器惰性赋值，得到的排列重放时会逼出同样的比较序列：模拟中 50,000 个元素需要 **625,099,919 次比较**（n log₂n ≈ 800,000）。输出的是普通两位小数金额（`1000.00`–`50999.99`），看起来就是一列账单数据。

| 场景（`bench_compare.py`，5 轮交替，SHA-256 一致） | Pion 中位数 | Rust `sort_unstable` | 倍率 |
|---|---:|---:|---:|
| A1 杀手排列 50k | **2,872.7 ms** | 11.3 ms | **0.004x（254 倍慢）** |
| A2 同一批值、随机顺序 50k | 21.3 ms | 11.5 ms | 0.54x |

比较次数按 n² 增长：实测 8k 0.09 s、50k 2.9 s，按 n² 外推 500k 约 290 s。任何“把用户提交的金额列排序”的服务都能被一个 50k 行的 CSV 卡住 3 秒。`bench/` 的 Bench 3 只用随机顺序数据，所以没暴露这个问题。

**修法**：换成 pdqsort / introsort（递归深度超过 2·log₂n 改走堆排序），或至少随机选主元；Rust 的 `sort_unstable` 就是 pdqsort，最坏 O(n log n)。复现：`run_audit.sh` 第 6 节 A1。

---

## P1

### F-2 负零泄漏到输出（`src/round.pion:228`、`:291`，`src/parse.pion:104/151/181`）

`round_dp_code` 用 `make_decimal(q, …, negative, dp)` 构造结果，没在尾数为零时清掉符号；解析器同样把 `-` 直接写进 flags。rust_decimal 在这两处都会把零结果的符号位清掉。

| 输入 | rust_decimal | Pion |
|---|---|---|
| `(-0.004).round_dp(2)` | `0.00` | **`-0.00`** |
| `(-0.1).round()` | `0` | **`-0`** |
| `(-0.5).round_dp_with_strategy(0, MidpointNearestEven)` | `0` | **`-0`** |
| `(-0.004).round_dp_with_strategy(2, ToPositiveInfinity)` | `0.00` | **`-0.00`** |
| `from_str("-0.00")` / `from_str_exact("-0")` / `from_scientific("-0e0")` / `from_str_radix("-0", 8)` | `0.00` / `0` / `0` / `0` | **`-0.00` / `-0` / `-0` / `-0`** |

账单场景里，一笔 -0.004 的调整四舍五入后在发票上印成 `-0.00`；16 字节 `serialize` 的 flags 也变成 `0x80020000`，与 Rust 端存的 `0x00020000` 字节不同（数值比较相等，但按字节去重/校验和会不一致）。60k 语料中 1,039 例（`RDS`/`RND`/`RDP`/`FS`/`FSX`/`SCI` 的 sign-bit 类），BIG=1 的 100 万语料中 10,566 例。单测：`redteam_round_dp_to_zero_has_no_minus_sign`、`redteam_parse_negative_zero_is_positive_zero`。
（注意 Rust 的 `rescale` 在这里**保留** `-0.00`，Pion 也保留，两边一致；所以修的时候只改舍入和解析的出口，不要改 `rescale`。）

### F-3 `checked_div` 结果 scale 偏离上游（`src/ops.pion:528` `unscale_96`，调用点 `:936`）

rust_decimal `div::unscale` 是：`while lo == 0 && scale >= 8` 除 10⁸；然后 10⁴、10²、10¹ **各最多一次**（`if`）。Pion 的 `unscale_96` 为了给 `normalize()` 复用，改成了 `while (q[0] & 0xFF) == 0` 和 4 个 `while`，会把尾零全部剥掉。数值相同，但 `to_string()` 和 `serialize()` 不同：

| 运算 | rust_decimal | Pion |
|---|---|---|
| `1 / 5` | `0.20` | `0.2` |
| `1 / 0.5` | `2.0` | `2` |
| `10 / 4` · `7 / 2` | `2.50` · `3.50` | `2.5` · `3.5` |
| `19.99 / 5` | `3.9980` | `3.998` |
| `sqrt(0.25)`（继承） | `0.500000000000000000000` | `0.5` |

60k 语料（以边界矩阵为主）824/16,600（5.0%），BIG=1 语料 2,001/93,259（2.1%）。跨语言账本若比对字符串或 16 字节表示，会出现“值相等但对不上”。**修法**：给除法单独写一个逐行照搬上游的 `unscale_div`，`normalize()` 继续用现在的版本。单测：`redteam_div_result_scale_matches_rust`。

### F-4 `from_str` 静默接受科学计数法（`src/parse.pion:195`）

`Decimal::from_str` 在普通解析失败后，只要字符串里有 `e`/`E` 就转去 `from_scientific_lossy`。rust_decimal 的 `FromStr`（`parse_str_radix_10`）不认指数，`"1e28"`、`"0e0"`、`"1E5"`、`"2.5e-3"`、`"-7e+2"` 全部报错，Pion 全部返回数值（60k 语料 349 例 E→D）。依赖“`from_str` 只收普通小数”做输入校验的调用方（金额字段、配额配置）会放过 `1e28` 这种值；同一字符串在 Rust 和 Pion 服务里一个拒绝一个接受。README 把这当成特性写了，但它与“`rust_decimal` port”的承诺冲突。**修法**：`from_str` 不回退；需要的人显式调 `from_scientific`。单测：`redteam_from_str_rejects_exponent_like_rust`。

### F-5 `deserialize` 与 Rust 二进制不互通（`src/fmt.pion:290`、`:307`）

rust_decimal 1.37.2 `deserialize`：`flags & 0x801F_0000`（scale 只有 5 位），scale 为 29/30/31 时分别除 10/100/1000，**完整余数 ≥ 5 就进位**；其他保留位丢弃。Pion：`(flags & 0x00FF0000) >> 16` 取 8 位 scale，`> 28` 时按 `10^(s-28)` 一路除下去、以 `pow/2` 为界进位。

| 16 字节（flags, lo） | rust_decimal | Pion |
|---|---|---|
| `0x00200000`, 12345 | `12345`（scale 掩成 0） | `0.0000000000000000000000000001` |
| `0x003C0000`, 12345 | `0.0000000000000000000000012345`（掩成 28） | `0.0000000000000000000000000000` |
| `0x001E0000`, 15 | `0.0000000000000000000000000001` | `0.0000000000000000000000000000` |
| `0x001F0000`, 149 | `0.0000000000000000000000000001` | `0.0000000000000000000000000000` |

正常 `serialize` 产物（scale ≤ 28）两边逐字节一致（`SER` 0/1,593 不一致）。但任务要求的是与 Rust 逐字节对拍：只要存储里有一个被翻转了 scale 位的记录、或者来自别的实现的 16 字节，Rust 服务和 Pion 服务会读出完全不同的金额（60k 语料 DES 8,749/10,493 不一致）。两种语义都不报错（Pion 签名是 `Result`，却从不对坏 scale 返回 `Err`）。**修法**：严格照搬 Rust 的掩码与进位规则；或者明确偏离并对 `scale > 28` 返回 `Err`，在 README 写清楚不兼容。单测：`redteam_deserialize_matches_rust_bit_for_bit`。

---

## P2

### F-6 `trunc_with_scale` 不补零（`src/round.pion:76` `truncate_core`）
`cur_scale <= target` 时直接返回原值；Rust 的 `truncate_internal` 会 rescale 到目标 scale：`1.trunc_with_scale(2)` → `1.00`，`1.239.trunc_with_scale(5)` → `1.23900`，`0.trunc_with_scale(2)` → `0.00`（Pion 都不补）。单测 `redteam_trunc_with_scale_pads_like_rust`。

### F-7 `powi` / `powu`（`src/math.pion:58`、`:70`）
1. `|x| >= 1` 且负指数时 `checked_powu` 溢出被 `Err(_) => Ok(ZERO)` 吞掉：`2^-96`、`2^-1000`、`2^i64::MIN` Rust 返回 `None`，Pion 返回 `0`（60k 语料 239 例）。
2. `|x| < 1` 先取倒数再乘方，倒数已舍入一次：`0.3^-3` 精确值 `37.037037…`，Rust（`1/0.027`）`37.037037037037037037037037037`，Pion `…036`。精确仲裁：差异中 Pion 更准 83 例、Rust 更准 28 例（这 28 例里 Pion 比 Rust 多约 2 ULP 误差）。
3. scale 规则：Rust exp=1 原样返回、exp=2 是 `checked_mul`（不 normalize）、exp≥3 才 normalize，`is_one` 时返回整数 `1`。Pion 一律 normalize 且 exp==1 先于判零：`1.10^2` Rust `1.2100` / Pion `1.21`；`(-1.0)^2` `1.00` / `1`；`1.0^1` `1` / `1.0`；`(-0)^1` `0` / `-0`。
单测 `redteam_powi_negative_exponent_overflow_is_an_error`、`redteam_powi_reciprocal_precision`、`redteam_pow_scale_rules_match_rust`。

### F-8 零与符号的边角（`src/ops.pion:217`、`:284`，`src/math.pion:81`、`:179`）

| 表达式 | rust_decimal | Pion |
|---|---|---|
| `0.0 + 0` | `0`（左边为零返回右边） | `0.0`（取较大 scale） |
| `0 + (-0.0)` | `-0.0` | `0.0` |
| `fract(0.0)` · `fract(-0)` | `0` · `-0` | `0.0` · `0` |
| `sqrt(-0)` | `None`（先判负号） | `Some(0)` |
| `(-0.5).to_u64()` · `(-0).to_u64()` | `None` | `Some(0)` |

单测 `redteam_zero_sign_and_scale_rules`。

### F-9 `to_f64` 不是正确舍入（`src/math.pion:191`）
把 96 位尾数转成 double 后循环 `/1e9`、`/10.0`，每步一次舍入。差异 393/1,601 例，精确仲裁 349 例 Rust 更接近（`1e-19`：Rust `0x3bfd83c94fb6d2ac` 是最近的 double，Pion `…ad`）；`-0` 转成 `-0.0`，Rust 给 `+0.0`。单测 `redteam_to_f64_correctly_rounded`。修法：照搬 rust_decimal 的 `to_f64`（整数部分 + 小数部分分开转换）。

### F-10 `from_str_radix` 溢出语义（`src/parse.pion` `from_str_radix`）
Pion 一旦 96 位放不下就 `Err(Overflow)`；Rust 在小数位溢出时舍掉剩余位并降 scale（38 例 D→E）。单测 `redteam_radix_overflowing_fraction_rounds`。（Rust 这条路径本身也有 bug，见“Pion 比 Rust 好”；修的时候应对齐 Rust 的正确部分，不要复刻它的错值和 panic。）

### F-11 性能：对抗场景 0.32x–0.44x，`checked_div` 堆分配

| 场景（`--warmup 1 --rounds 5`，SHA-256 一致） | Pion 中位数 | Rust 中位数 | Pion 倍率 |
|---|---:|---:|---:|
| A3 满宽 96×96 `checked_mul`（2M，混合 scale） | 180.8 ms（90 ns/op） | 79.7 ms | 0.44x |
| A4 `checked_div`，32/64/96 位除数轮换（2M） | 311.3 ms（156 ns/op） | 100.0 ms | **0.32x** |
| A5 `from_scientific`（50k × 10） | 71.3 ms | 27.2 ms | 0.38x |
| A6 `sqrt`（100k，随机 96 位） | 845.1 ms | 346.0 ms | 0.41x |

（数字来自 `run_audit.sh` 最近一次运行；同机重复运行波动约 ±10%。）

- **`checked_div`**（`src/ops.pion:701–916`）：每次调用固定分配 `q`、`d` 两个 `FixedArray[UInt]`；64 位除数再加 `rem`；96 位除数再加 `rem`、`d_shift`，且**每轮补位循环**再分配一个 `tmp_r`（`:916`），补位循环每轮最多补 9 位，一次 96 位除法通常 3–4 轮，即 6–8 次堆分配。Rust 的 `Buf12`/`Buf16` 全在栈上。改成标量局部变量（`q0,q1,q2`、`r0..r3`）或 `val struct Buf12 { w0 : UInt, w1 : UInt, w2 : UInt }` 用 `mut` 参数传递，预计可去掉 A4 的大部分差距；A6 `sqrt` 每次迭代 2 次 `checked_div`，会一起受益。
- **`checked_mul` 一般路径**（`:388`）与 64×64 溢出路径（`:369`）分配 6 字 `buf`，`u192_rescale` 再按下标访问；同样可改成标量。`round_dp_code` 的 96 位路径（`src/round.pion:192` 起）一次分配 4 个数组（`value`/`offset`/`dec_part`/`cap`），而 Rust 只做一次带余除法。
- **`from_scientific`**（`src/parse.pion` `from_scientific_core`）：先逐字符把底数拷进新 `Bytes`、`to_string()` 再解析，然后对正指数走 `checked_mul` + `normalize`；Rust 直接对切片解析。可以让 `parse_radix10_core` 接受 `[start, end)` 区间，省掉拷贝。
- **现有 `bench/` 的公平性**：三个基准两边写法对称，SHA-256 校验真实有效，没有挑数据作弊；但它们没覆盖最坏情况：Bench 2 的除数 `qty` 是 1–25，只走 32 位除数快路径（A4 显示 96 位除数路径 0.32x）；Bench 3 只用随机顺序，掩盖了 F-1。建议把 A1/A4 加进 `bench/` 并同步到根 `BENCHMARKS.md`。

### F-12（信息）错误码不是 1:1
Pion 的错误枚举更细，但与 Rust 不对应：超 96 位的整数串 Pion `Overflow`、Rust `ErrorString("Invalid decimal: overflow from too many digits")`；`1e4294967296` / `1e99999999999999999` Pion `ScaleExceedsMaximumPrecision(4294967295)`（哨兵值），Rust `ErrorString("Failed to parse")`；`from_str("1e29")` Pion `ScaleExceedsMaximumPrecision(29)`，Rust 是普通解析错误（F-4 的后果）。60k 语料 E 类不同 995 例，不影响成败判定，只影响按错误类型分支的调用方。

---

## 差分覆盖面（seed 1372，60k 随机 + 边界矩阵 = 167,139 条）

| 操作 | 不一致 / 总数 | 说明 |
|---|---|---|
| `checked_mul` · `checked_rem` · `compare` | 0/15,951 · 0/15,299 · 0/1,190 | 逐位一致 |
| `checked_add` · `checked_sub` | 56/16,045 · 52/15,963 | 全部是零操作数（F-8） |
| `checked_div` | 824/16,600 | 只有 scale（F-3），值 0 例不同 |
| `round_dp_with_strategy` · `round` · `round_dp` | 522/17,329 · 317/1,677 · 102/1,204 | 只有零结果的符号位（F-2） |
| `floor` `ceil` `trunc` `normalize` `abs` `neg` `is_integer` `set_scale` `serialize` `to_i64` `try_new` | 全部 0 | 逐位一致 |
| `from_str` · `from_str_exact` · `from_scientific` | 1,005/6,253 · 148/2,504 · 255/3,748 | F-2、F-4、F-12，以及 Rust 自身 bug |
| `deserialize` | 8,749/10,493 | F-5（语料刻意随机化 scale 字节与保留位） |
| `trunc_with_scale` · `rescale` | 2,780/6,562 · 509/7,211 | F-6；`rescale` 全部是 Rust 产出 scale 29 或 panic |
| `powi` · `powu` · `sqrt` | 419/2,685 · 31/1,247 · 46/2,851 | F-7、F-8、F-3 |
| `to_f64` · `to_u64` | 393/1,601 · 335/1,538 | F-9、F-8 |
| `from_str_radix` | 158/1,295 | F-10、F-12，及 Rust panic / 错值 |

完整反例（解码后的操作数、两边输出）在 `$AUDIT_OUT/diff.txt` 与 `diff.json`。
