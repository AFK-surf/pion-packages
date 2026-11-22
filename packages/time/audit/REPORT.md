# 红队审计报告：`packages/time` @ `b423882`（`feat/opt-time`）

- 审计对象：`AFK-surf/pion-packages` `packages/time`，commit `b423882`（`perf(time): zero-alloc RFC 3339 slice/bytes & packed civil calendar optimizations`）
- 参照实现：Rust `jiff 0.2.46`（`rust/Cargo.lock` 锁定，rustc 1.100.0，`--release` + LTO）、Go 1.27.3 标准库（`time`、`net/http`、`net/mail`）
- 环境：Apple M5 Max，macOS（Darwin arm64），`pionc 0.1.0 (arm64_apple, self-hosted)`
- 审计没有改动 `packages/time/src/**`、原有测试和仓库根目录，新增文件全部在 `packages/time/audit/` 下。

## 一键复现

```sh
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
sh packages/time/audit/run_audit.sh                 # 全部：断言 + 差分 + 穷举 + 鲁棒性 + 功能鸿沟 + 公平基准 + 分配普查
SKIP_BENCH=1 sh packages/time/audit/run_audit.sh    # 只跑正确性部分（约 20 s）
pionc test --json -p time_redteam_audit packages/time/audit   # 只跑 28 条红队断言
```

构建产物与数据统一写到 `$OUT_DIR`（默认 `/tmp/pion-time-redteam`），worktree 保持干净。

## 结论摘要

| 级别 | 数量 | 一句话 |
| --- | ---: | --- |
| **P0** | 2 组（6 条断言） | 解析或格式化**悄悄给出错误的值**：`IsoDuration::parse` 把 Int64 截断成 Int（`P4294967297D` → `P1D`，`PT2147483648M` → 负数）；`SignedDuration::to_iso_string` 在 `i64::MIN` 上取负溢出，输出 `-PT-8.999999999S` / `-PT` |
| **P1** | 5 组（14 条断言 + 基准） | 自己格式化出来的 RFC 3339 / ISO 8601 字符串，自己的解析器读不回来；b423882 新增的 raw/packed API 对越界输入不做任何校验，`-1` 错误哨兵还能被当成日期继续算；所有值类型的字段都是 `pub`，不变量可以绕过；**换成惯用的类型化 API 后性能全面落后 jiff**（W5 慢 13.5 倍） |
| **P2** | 8 条断言 + 50 条差分 | jiff 能接受、Pion 拒绝的 RFC 9557 / ISO 8601 / RFC 9110 合法输入 |
| 功能鸿沟 | — | 没有 `Zoned`、`TimeZone`（IANA / TZif / POSIX）、DST 歧义消解、日历 `Span`、`round`、`strftime`/`strptime` |
| 无罪证据 | — | 民用历法在全部 7,304,484 天上与 jiff **逐字节一致**；packed API 与 typed API 全量一致；raw RFC 3339 解析器在全部 70 条用例上与 typed 解析器一致 |

`pionc test --json -p time_redteam_audit packages/time/audit` 的结果：`total=28 passed=0 failed=28`。每条失败都对应下面的一条发现，失败原因已逐条核对，都是预期的那个原因，没有因为别的 panic 而失败。

---

## P0：悄悄给出错误的值

### P0-1 `IsoDuration::parse`：Int64 → Int 截断，正数可以变成负数

`src/format.pion:2014-2046`：`years/months/weeks/days/hours/minutes = num.to_int()`。`num` 是 `parse_u64_at` 返回的 Int64，这里直接截成 32 位，**不报错**。

| 输入 | jiff `Span` 解析 | Pion `IsoDuration::parse` |
| --- | --- | --- |
| `P4294967297D` | `Err` | `Ok(P1D)` |
| `PT4294967297H` | `Err` | `Ok(PT1H)` |
| `PT2147483648M` | `Err` | `Ok(PT-2147483648M)`（**正数输入，负数结果**） |
| `P2147483648W` | `Err` | `Ok(P-2147483648W)` |
| `P99999999999Y` | `Err` | `Ok(P1215752191Y)` |
| `P20000Y` | `Err`（上限 19998 年） | `Ok(P20000Y)` |

影响：任何拿 ISO 8601 时长做超时、保留期、限流窗口的调用方，攻击者都可以构造一个字符串，让它悄悄变成 1 天、1 小时，或者一个负值。
断言：`p0_iso_duration_{days,hours}_silently_truncated_mod_2_32`、`p0_iso_duration_minutes_sign_flip`、`p0_iso_duration_years_silently_truncated`。

### P0-2 `SignedDuration::to_iso_string`：`i64::MIN` 取负溢出

`src/format.pion:1900`：`s = -s`，没有处理 `i64::MIN`。

| 值 | jiff `Display` | Pion `to_iso_string` |
| --- | --- | --- |
| `SignedDuration::min()` = `(i64::MIN, -999999999)` | `-PT2562047788015215H30M8.999999999S` | `-PT-8.999999999S` |
| `(i64::MIN, 0)` | `-PT2562047788015215H30M8S` | `-PT` |
| 字段直接构造的 `{secs: 5, nanos: -999999999}` | （jiff 无法构造） | `-PT-5.999999999S` |

两种输出都不是合法的 ISO 8601，Pion 自己的 `parse_iso` 也会拒绝（见 P1-1）。
断言：`p0_signed_duration_min_to_iso_string_overflows`、`p0_signed_duration_i64_min_secs_to_iso_string_empty`。

---

## P1

### P1-1 自己格式化的字符串，自己读不回来

| 值 | `to_rfc3339_with_offset` / `to_iso_string` 输出 | 自己的 `parse_*` | jiff |
| --- | --- | --- | --- |
| `Timestamp::min()` | `-009999-01-02T01:59:59+00:00` | `Err(PARSE_RFC3339)`（只支持 4 位年份，`src/format.pion:677` 起） | 能 round-trip |
| 0000 年之前的任意时刻（如 `-62198755200`） | `-000001-01-01T00:00:00+00:00` | `Err` | 能 round-trip |
| 偏移 `+05:45:15`（`Offset::from_seconds(20715)` 返回 Ok） | `…+05:45:15` —— **不符合 RFC 3339**：`time-numoffset = ("+" / "-") time-hour ":" time-minute`（`src/format.pion:178`） | `Err` | 输出 `+05:45`，符合 RFC 3339 |
| `Offset::max()` = +25:59:59 | `…+25:59:59` | `Err`（`if oh > 23`，`src/format.pion:774`） | jiff 解析器接受 25 以内的小时 |
| `Offset::from_hours(24)` 返回 Ok | `…+24:00` | `Err` | jiff 能读回 |
| `SignedDuration::min()` | `-PT-8.999999999S` | `Err(PARSE_DURATION)` | 能 round-trip |
| `-PT9223372036854775808S`（jiff 的 `SignedDuration::MIN` 秒数） | — | `Err(OVERFLOW)`：`parse_u64_at` 按正数累加，在 2^63 处溢出（`src/format.pion:1728`） | `Ok` |

问题的根源：`Offset` 允许的范围（±93599 s）和 RFC 3339 解析器接受的范围（±23:59）不一致；`Timestamp` 的合法年份范围是 -9999..9999，解析器却只认 0000..9999。
断言：`p1_roundtrip_{timestamp_min,negative_year,offset_max,offset_24h,signed_duration_min}`、`p1_rfc3339_output_offset_with_seconds_is_not_rfc3339`、`p1_parse_iso_signed_duration_min_secs`。

### P1-2 b423882 新增的 raw/packed API 完全信任输入

`epoch_days_to_packed_date` 出错时返回 `-1`（`src/civil.pion:993`），但下游函数都不检查这个哨兵，也不检查字段范围：

```
packed_date_add_days(-1 /*error sentinel*/, 0) = -1 -> y/m/d -10001/15/31
packed_date_to_epoch_days(-1) = -4371862
packed_date_to_packed_iso_week(-1) = 110 -> -10000-W13-6
packed 2025-02-31 (never validated) -> epoch_days 20150 (= 2025-03-03)
format_rfc3339_raw_bytes(0, -1, 0) = 1970-01-01T00:00:00./99999999+00:00
format_rfc3339_raw_bytes(0, 1000000000, 0) = 1970-01-01T00:00:00.:+00:00
format_rfc3339_raw_bytes(0, 0, 360000) = 1970-01-05T04:00:00+:0:00
format_rfc3339_raw_bytes(253402300800, 0, 0) = :000-01-01T00:00:00+00:00
format_rfc3339_raw_bytes(9223372036854775807, 0, 0) = I2\xNN$-01-21T.4:29:51+00:00   (非 UTF-8 字节)
```

（来自 `run_audit.sh` 第 4 段 `pion_probe --robust`。）`parse_rfc3339_slice_raw` 也要求调用方自己传一个长度 ≥ 2 的 `Array[Int64]`，签名本身无法保证这一点。jiff 没有对应的不安全接口：同样的需求在 jiff 里用类型化 API 就能拿到同等性能（见 P1-4，W2 `rust_jiff_sd`）。
断言：`p1_packed_error_sentinel_flows_through_as_date`、`p1_packed_iso_week_of_sentinel`、`p1_raw_formatter_emits_garbage_{nanos_negative,year_10000,offset}`。

### P1-3 `pub val struct` 的字段全是 `pub`，不变量形同虚设

`src/types.pion`：`Date`、`Time`、`Timestamp`、`SignedDuration`、`Offset` 等类型的字段全部是 `pub`，可以用字面量直接构造非法值，而 jiff 的字段是私有的。

```
Timestamp::{secs:0, nanos:-5}.to_rfc3339()          = 1970-01-01T00:00:00./99999995Z
Date::{2025,2,31}.to_string()                       = 2025-02-31   (to_epoch_days = 2025-03-03)
SignedDuration::{5, -999999999}.to_iso_string()     = -PT-5.999999999S
```

README 写着「Normalized non-negative nanoseconds」「Same-sign (secs, nanos) normalization」，这些保证只在构造函数里成立，类型本身并不保证。
断言：`p1_public_fields_bypass_invariants_{timestamp,date}`。

### P1-4 基准公平性：README 的「领先 / 接近 jiff」只适用于为基准特制的 API

`bench/pion_rfc3339` 用的是 `parse_rfc3339_slice_raw` + `format_rfc3339_raw_bytes`（out-param + 裸整数），`bench/pion_civil` 用的是 bit-packed `Int`。而 jiff 和 Go 那边跑的是普通的类型化 API。下面换成**普通用户真正会写的 Pion 代码**，在同一台机器、同一份输入上，按 `scripts/bench_compare.py --warmup 1 --rounds 7` 严格交替运行，**每组 stdout 的 SHA-256 全部一致**。

**W1：RFC 3339 解析 + 平移到 +09:00 + 格式化，20 万条**（`sha256:1172c154…`）

| 实现 | 中位数 ms | min | p95 | MB/s | ns/op | 峰值 RSS | 相对 jiff |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_raw_b423882`（原基准） | 42.833 | 41.100 | 49.091 | 146.50 | 214.16 | 13.70 MiB | 1.06x |
| `pion_typed_slice`（`Timestamp::parse_rfc3339_slice` + `to_rfc3339_with_offset`） | 56.577 | 53.358 | 59.056 | 110.91 | 282.88 | 13.72 MiB | **0.80x** |
| `pion_typed_split`（`split("\n")` + `parse_rfc3339`） | 55.453 | 52.450 | 65.990 | 113.16 | 277.27 | 22.86 MiB | **0.82x** |
| `rust_jiff` | 45.388 | 43.152 | 47.201 | 138.25 | 226.94 | 7.83 MiB | 1.00x |
| `go_time` | 53.485 | 51.066 | 55.064 | 117.32 | 267.43 | 24.75 MiB | 0.85x |

**W2：民用历法 200 万次**（`sha256:65a54274…`）

| 实现 | 中位数 ms | min | p95 | ns/op | 峰值 RSS | 相对 jiff |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_packed_b423882`（原基准） | 58.201 | 55.141 | 68.858 | 29.10 | 1.70 MiB | 0.88x |
| `pion_typed`（`Date::from_epoch_days` / `iso_week_date` / `add_days` / `to_epoch_days`） | 97.895 | 91.499 | 124.209 | 48.95 | 1.69 MiB | **0.52x** |
| `rust_jiff`（原基准，用日历 `Span`） | 51.196 | 44.835 | 56.958 | 25.60 | 1.75 MiB | 1.00x |
| `rust_jiff_sd`（jiff 惯用的 `SignedDuration` 天数运算） | 44.098 | 39.510 | 51.741 | 22.05 | 1.77 MiB | 1.16x |
| `go_time` | 77.831 | 71.655 | 92.891 | 38.92 | 4.61 MiB | 0.66x |

原基准对 jiff 也不公平：它在 jiff 一侧用的是较慢的 `Span` 路径。双方都用惯用写法时，Pion typed 只有 jiff 的 **0.45x**（44.1 / 97.9）。

**W3：ISO 8601 `SignedDuration` 解析 + 格式化，20 万条**（`sha256:6a27f572…`；Go 标准库没有 ISO 8601 时长）

| 实现 | 中位数 ms | min | p95 | ns/op | 峰值 RSS | 相对 jiff |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 63.742 | 61.148 | 65.281 | 318.71 | 17.30 MiB | **0.63x** |
| `rust_jiff` | 40.312 | 37.953 | 43.455 | 201.56 | 5.44 MiB | 1.00x |

**W4：HTTP-date（IMF-fixdate）解析 + 格式化，20 万条**（`sha256:651bbb31…`）

| 实现 | 中位数 ms | min | p95 | ns/op | 峰值 RSS | 相对 jiff |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 72.828 | 67.131 | 75.439 | 364.14 | 21.27 MiB | **0.66x** |
| `rust_jiff` | 47.900 | 46.136 | 49.369 | 239.50 | 7.58 MiB | 1.00x |
| `go_time` | 76.613 | 74.656 | 78.361 | 383.07 | 25.97 MiB | 0.63x |

**W5：`SignedDuration` 的 checked add/mul/div/sub + `Timestamp::checked_add`/`since`，500 万次**（`sha256:6fed3af8…`）

| 实现 | 中位数 ms | min | p95 | ns/op | 峰值 RSS | 相对 jiff |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 1129.807 | 1056.307 | 1247.178 | 225.96 | 1.72 MiB | **0.07x（慢 13.5 倍）** |
| `rust_jiff` | 83.368 | 75.569 | 85.319 | 16.67 | 1.77 MiB | 1.00x |
| `go_time` | 72.490 | 69.881 | 80.001 | 14.50 | 4.47 MiB | 1.15x |

**W5 的根因**（`run_audit.sh` 第 7 段，对 `pion_sd_arith` 反汇编，统计每个函数里 `_pion_alloc*` 的调用点）：

```
8  Timestamp::checked_add      8  SignedDuration::checked_mul    8  SignedDuration::checked_add
6  Timestamp::new              6  SignedDuration::new            4  SignedDuration::checked_div
3  SignedDuration::checked_sub 2  checked_mul_i64                1  checked_add_i64 / checked_sub_i64
```

`checked_add_i64` 返回的 `Option[Int64]` 是通过指针读取的（`ldr x2, [x0]`），每个 `Result[SignedDuration, TimeError]` 都要走 `pion_alloc_uninit`，同时伴随 `pion_rc_inc`/`rc_dec`。也就是说，「value-type core、zero heap allocation」（README）在 `Option`/`Result` 包装这一层并不成立。每一次 checked 运算都要做 1–3 次堆分配。b423882 把基准改成 packed `Int` / out-param，恰好绕开了这一点，但普通用户的代码绕不开。

---

## P2：jiff 能接受、Pion 拒绝的合法输入（差分 50 条 + 格式差异 1 条）

完整表格见 `run_audit.sh` 第 2 段（`$OUT_DIR/differential.md`）。分类如下：

| 类别 | 例子 | jiff | Go | Pion |
| --- | --- | --- | --- | --- |
| RFC 9557 标注 | `…-05:00[America/New_York]`、`…Z[UTC]`、`…[!Etc/UTC]`、`…Z[u-ca=iso8601]` | Ok | Err | Err |
| ISO 8601 扩展年份 | `-000001-01-01T00:00:00Z`、`+002025-…`、`-009999-01-02T01:59:59Z`（= `Timestamp::MIN`） | Ok | Err | Err |
| 偏移写法 | `+24:00`、`+25:59`、`+05:30:15`、`+0530`、`-05` | Ok | `+24:00` 为 Ok | Err |
| 闰秒 `:60`（RFC 3339 §5.6：`time-second = 2DIGIT ; 00-58, 00-59, 00-60`） | `2016-12-31T23:59:60Z` | Ok（截到 :59） | Err | Err |
| ISO 8601 逗号小数、basic 格式、降低精度 | `…00,5Z`、`20250101T000000Z`、`2025-01-01T00:00Z` | Ok | 逗号为 Ok | Err |
| HTTP-date 旧格式（RFC 9110 §5.6.7：接收方 **MUST** 接受三种格式） | `Sunday, 06-Nov-94 08:49:37 GMT`、`Sun Nov  6 08:49:37 1994` | Err | **Ok**（`net/http.ParseTime`） | Err |
| civil `DateTime` / `Date` | `2025-01-01T12`、`…12:34:60`、`…T123456`、`…+01:00`、`20250101` | Ok | — | Err |
| 格式规范化 | `IsoDuration::parse("PT1.5H").to_string()` | `PT1H30M` | — | `PT1H1800S` |

断言：`p2_rfc9557_annotation_rejected`、`p2_extended_years_rejected`、`p2_offset_forms_rejected`、`p2_leap_second_rejected`、`p2_iso8601_forms_rejected`、`p2_http_date_obsolete_formats_rejected_rfc9110_must`、`p2_iso_duration_fractional_hour_format`、`p2_civil_datetime_forms_rejected`。

---

## 功能鸿沟：jiff 的核心卖点，Pion 完全没有 API

`run_audit.sh` 第 5 段先运行 `rust/src/bin/gaps.rs`，再在 `packages/time/src/*.pion` 的 `pub fn` 里搜索 zone/tz/dst/posix/strf/strp/span/round/disamb，只搜到 `SignedDuration::round_secs` 和 `round_millis`。

```
gap   Compatible: 2024-03-10T03:30:00-04:00[America/New_York]     # DST 跳跃（不存在的 02:30）
gap   Earlier:    2024-03-10T01:30:00-05:00[America/New_York]
gap   Reject: true
fold  Earlier: 2024-11-03T01:30:00-04:00[America/New_York]        # DST 折叠（01:30 出现两次）
fold  Later:   2024-11-03T01:30:00-05:00[America/New_York]
rfc9557 +1 day across DST: 2024-03-10T12:00:00-04:00[America/New_York] (elapsed PT23H)
offset conflict rejected: true                                      # 偏移与时区不一致时拒绝
posix  EST5EDT 2024-07-01T12:00Z -> 2024-07-01T08:00:00-04:00
span   2024-01-31 + 1 month = 2024-02-29
span   2020-02-29 until 2025-01-15 (largest=year) = P4Y10M17D         # Pion Date::until 只返回天数 Int
round  2024-06-01T12:34:56.789Z -> 15-minute HalfExpand: 2024-06-01T12:30:00Z
strftime: Saturday, March 9, 2024 at 12:00 EST
strptime: 2024-12-31T23:05:00
tzif   Lord_Howe 2024-01-01T00:00Z offset: +11                        # 系统 TZif 加载，半小时 DST
```

Pion 缺少的部分：`Zoned`、`TimeZone`（IANA 库 / TZif 解析 / POSIX TZ）、`Disambiguation`、按时区做日历运算、`Span`（`until`/`since` 的 largest unit、`total`、`round`）、`Timestamp`/`DateTime` 的 `round`、`strftime`/`strptime`、读取 RFC 9557 里的时区。Pion 只有固定偏移的 `FixedDateTime`。任何涉及「本地时间」的真实业务（排班、账单周期、提醒、日志按本地日切分）都无法用它正确实现。

---

## 无罪证据（如实记录 Pion 做对的地方）

- **民用历法穷举**：在 -9999-01-01..=9999-12-31 的 **7,304,484 天**上，对比 epoch-day / Y-M-D / ISO 周日期 / day-of-year，Pion typed API 的输出与 jiff **逐字节一致**，`sha256:920db6c728df7fc9987ed2a0438896f108b415b84571e3e3afc1e8bba8114b68`。b423882 的 packed API（`epoch_days_to_packed_date`、`packed_date_to_epoch_days`、`packed_date_to_packed_iso_week`）与 typed API 也是 **0 处不一致**。乘移位倒数优化在合法输入上没有引入错误。
- **raw RFC 3339 解析器**：`parse_rfc3339_slice_raw` 在全部 68 条 `ts` 用例上与 `Timestamp::parse_rfc3339` 一致；`write_rfc3339_bytes` 在全部 18 条 `tsfmt` 用例上与 `to_rfc3339_with_offset` 一致（0 条 `!!RAW_MISMATCH`）。
- 下面这些行为与 jiff **完全一致**：非法日期（`1900-02-29`、`2100-02-29`、`2025-02-29`、`04-31`）、超过 9 位的小数、`.Z` 空小数、`-23:60`、前后多余字符、非 ASCII 数字或符号、`Timestamp` 上下界、`Timestamp + SignedDuration` 溢出、`add_months`/`add_years` 的月末夹紧、`add_days` 边界、`until`、`DateTime + SignedDuration` 边界、RFC 2822 的全部 13 条用例。
- 原基准里 `pion_raw` 的 W1 优势（1.06x）是真实的，但只在特制 API 上成立。

## 文件清单

| 路径 | 作用 |
| --- | --- |
| `pion.toml` | audit 子 workspace（`tests`、`probe`、`bench/pion_*`） |
| `tests/redteam_test.pion` | 28 条断言；每条失败都是一个发现 |
| `probe/src/main.pion` | Pion 差分探针（`<cases.tsv>` / `--civil-all` / `--robust`） |
| `rust/src/bin/probe.rs`、`gaps.rs` | jiff 参照探针、功能鸿沟演示 |
| `go/cmd/probe` | Go 标准库参照探针 |
| `cases/differential.tsv` | 266 条差分用例 |
| `diff.py` | 三方差分，区分语义差异 / 格式差异 / 内部不一致 |
| `bench/pion_*`、`rust/src/bin/*.rs`、`go/cmd/*` | W1–W5 公平基准（三方实现的 stdout 字节一致） |
| `gen_data.py` | W3/W4 输入（W1 沿用 `packages/time/bench/gen_data.py`） |
| `run_audit.sh` | 一键运行 |
