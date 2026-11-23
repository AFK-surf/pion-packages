# `effect`

Deterministic, single-threaded cooperative structured-concurrency runtime, virtual/live clock, fiber primitives, and preemptive priority lane scheduler in pure Pion (**zero `World` dependency**, 100% Native and `wasm32` compatible).

## Features

- **Deterministic Runtime (`Runtime`)**:
  - Virtual clock (`Runtime::new`, `Runtime::new_seeded`, `Runtime::new_at`) with FIFO or seeded-shuffled scheduling (`Rng`, xorshift32), `advance(ms)`, `frame(at)`, and `run_ready()`.
  - Host clock injection (`Runtime::live(now_fn)`) with `tick()`, `on_wake`, `on_timer`, `outside_clock`, and `outside_event` hooks.
  - Built-in diagnostics: `holding()`, `timer_slots()`, `unsettled()`, `trace()` / `trace_text()`, `defects`, `outside_start` / `outside_end` / `outside_k`.
- **Structured Concurrency (`EffectScope`, `Fiber`)**:
  - Scoped fiber lifetimes (`fork`, `fork_named`, `fork_quiet`, `fork_quiet_named`, `fork_daemon`), nested `child()` scopes, LIFO finalizers (`add_finalizer`), and `acquire_release_k` / `scoped_k`.
  - Cooperative interruption (`interrupt`, `interrupt_and_wait_k`, `uninterruptible_k`, `is_interrupted`, `never_k`).
- **Synchronization & Combinators**:
  - `Deferred[X]`, `Queue[X]` (`unbounded` / `bounded` / `shutdown`, backed by `RingDeque[T]`), `Semaphore` (`with_permit_k`).
  - `race_k`, `race_first_k`, `all_k`, `timeout_k`, `pause_k`, `sleep_k`, `sleep_later_k`, `next_frame_k`.
- **Preemptive Priority Lane Scheduler (`Scheduler`, `Preempt`)**:
  - Six priority tiers (`priority_asked`, `priority_focused`, `priority_shown`, `priority_detail`, `priority_background`, `priority_idle`), `urgent_room` overflow slots, serialized background execution, per-key deduplication, nested `foreground_begin()` refcounting, dynamic prefix priority boosts (`prioritize`), idle preemption (`Preempt::wait_k` / `is_preempted`), and `on_idle` callbacks.
- **Deterministic Simulation Services**:
  - `SimNet` (`Packet`, `Net`) with configurable latency, jitter, and packet loss.
  - `SimFiles` (`Files`) in-memory virtual-clock filesystem with fault injection.
  - `host_call_k` callback bridge with cancellation hook and `for_seeds` / `for_seeds_with` deterministic replay runner.

## Quick Verification

```sh
sh scripts/verify.sh packages/effect
sh packages/effect/bench/run_bench.sh
```

## Head-to-Head Benchmarks (Darwin arm64, `--warmup 1 --rounds 5`, SHA-256 Verified)

| Workload | `pion` (Median / Peak RSS) | `go` (Median / Peak RSS) | `node` (Median / Peak RSS) | `pion` vs `go` |
| --- | ---: | ---: | ---: | ---: |
| W1: Bounded Queue Ping-Pong (50k msgs, cap=16) | 18.318 ms / 1.83 MiB | 17.479 ms / 4.59 MiB | 57.203 ms / 48.62 MiB | 0.95x |
| W2: Virtual-Clock Timer Scheduling (20k fibers/timers) | 47.402 ms / 28.23 MiB | 18.574 ms / 5.95 MiB | 58.455 ms / 49.86 MiB | 0.39x |
| W3: Structured Fan-Out & Join (2,500 × 4 = 10k fibers) | 19.481 ms / 1.84 MiB | 18.090 ms / 5.42 MiB | 51.110 ms / 45.16 MiB | 0.93x |

_Note on W2: Pion spawns 20,000 full structured fibers (`Task` + `Fiber` + `sleep_k` timer + scope watcher) concurrently, while the Go and Node.js baselines push bare `{at, seq, idx}` structs into a min-heap._
