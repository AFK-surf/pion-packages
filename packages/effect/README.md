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

## Head-to-Head Benchmarks (Linux x86_64, `--warmup 1 --rounds 5`, SHA-256 Verified)

| Workload | `pion` (Median / Peak RSS) | `go` (Median / Peak RSS) | `node` (Median / Peak RSS) | `pion` vs `go` |
| --- | ---: | ---: | ---: | ---: |
| W1: Bounded Queue Ping-Pong (50k msgs, cap=16) | 6.038 ms / 2.05 MiB | 4.771 ms / 1.86 MiB | 56.569 ms / 55.86 MiB | 0.79x |
| W2: Virtual-Clock Timer Scheduling (20k fibers/timers) | 35.448 ms / 9.91 MiB | 9.520 ms / 3.36 MiB | 63.760 ms / 57.27 MiB | 0.27x |
| W3: Structured Fan-Out & Join (2,500 × 4 = 10k fibers) | 9.449 ms / 1.84 MiB | 10.673 ms / 2.49 MiB | 64.142 ms / 50.10 MiB | 1.13x |

_Note on W2: Pion spawns 20,000 full structured fibers (`Task` + `Fiber` + `sleep_k` timer + owning `ScopeState`) concurrently, while the Go and Node.js baselines push bare `{at, seq, idx}` structs into a min-heap._

## Formal Verification (Lean 4)

**18** machine-checked, `0-sorry` Lean 4 theorems (**8 A-grade** core invariant theorems + **10 B-grade** primitive theorems; strict standard-axiom whitelist `[propext, Classical.choice, Quot.sound]`, `FunsExternal.lean` 0 axioms, verified via `pionc extract-lean` + Aeneas) cover 12 production `#verify` kernels in `packages/effect/src/`:

### Stage 2 A-Grade Core Theorems (`proofs/EffectProofs/CoreInvariants.lean`)

| Theorem | Production Kernel | Property Proved |
| --- | --- | --- |
| `heap_sift_down_pick_is_min` | `heap_sift_down_pick` | Exact minimum selection among `{parent, left, optional right}` in `TimerHeap::pop` (soundness, completeness, no early stop, right-child dominance) |
| `heap_sift_up_preserves_min_order` | `heap_sift_up_should_swap` | Exact swap predicate in `TimerHeap::push` guaranteeing `parent ≤ child` after conditional swap |
| `heap_right_parent_inv` | `heap_right`, `heap_parent` | Exact right-child parent inverse `heap_parent (heap_right i) = i` and `heap_left i + 1 = heap_right i` |
| `rng_step_u32_bijection` | `rng_step_u32` | Full-domain bijection (explicit left/right inverse on `BitVec 32`) on `[0, 2^32 - 1]` matching Marsaglia `(13, 17, 5)` |
| `rng_step_u32_nonzero_orbit` | `rng_step_u32` | Non-zero orbit closure: `∀ s ∈ [1, 2^32 - 1], rng_step_u32 s ∈ [1, 2^32 - 1]` (never enters the `0` deadlock fixed point) |
| `ring_slot_add_injective_window` | `ring_slot_add` | Logical offsets `0..len-1` map injectively to distinct physical slots (no aliasing/overwrite; exact `RingDeque::grow` order) |
| `ring_slot_add_bijective_mod_cap` | `ring_slot_add` | Full bijection between logical offsets `[0, cap)` and physical buffer slots `[0, cap)` |
| `ring_push_pop_full_consistency` | `ring_slot_add`, `ring_slot_prev` | 4-way `push_front`/`pop_front`/`push_back`/`pop_back` inverse, slot-preservation across `push_front`, and non-aliasing of newly pushed slots |

- **Existing B-Grade Theorems (`RuntimeAndDeque.lean` & `SchedulerAndSync.lean`, 10 theorems)**: xorshift32 non-zero seeding, `rng_below_val` bounds, `RingDeque` capacity growth & wraparound bounds, `TimerHeap` `(at, seq)` strict partial order, `heap_parent` descent & `heap_left` inverse.
- **Differential Cross-Check**: `proofs/EvalDiff.lean` + native Pion value-comparing harness (**34** cases identical via `diff -u`, including `INT_MIN`/`INT_MAX` extremes and 2 verified native+Lean `TRAP` checks).
- **Semantic Mutation Kill Gate (`proofs/mutation_check.sh`)**: **10 / 10 killed (100% ≥ 90%)** across `TimerHeap` sift-down/sift-up/index faults (including the `RT-lean-proofs` flipped sift-down comparison), `xorshift32` shift/mask corruptions, and `RingDeque` wraparound/offset faults.

```sh
LEAN_NUM_THREADS=2 LEAN_MEM_LIMIT=8192 bash packages/effect/proofs/run_proofs.sh
LEAN_NUM_THREADS=2 LEAN_MEM_LIMIT=8192 bash packages/effect/proofs/mutation_check.sh
```
