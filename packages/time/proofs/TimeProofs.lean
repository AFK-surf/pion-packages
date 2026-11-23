/-
Formal verification of `packages/time` (`Time.Funs`, extracted via
`pionc extract-lean` from `packages/time/src/*.pion`).

Modularized into 4 independent Lean modules for fast, bounded-memory builds:
- `TimeProofs.Core`: scalar & bitwise bridge lemmas
- `TimeProofs.Calendar`: leap year, days in month, Neri-Schneider epoch-day bijection
- `TimeProofs.Order`: strict total orders on `Date`, `Time`, `Timestamp`, `DateTime`
- `TimeProofs.Duration`: `SignedDuration` normalization, checked arithmetic & total order

All proofs are complete and kernel-checked, depending only on the three
standard Lean axioms: `propext`, `Classical.choice`, `Quot.sound`.
-/
import TimeProofs.Core
import TimeProofs.Calendar
import TimeProofs.Order
import TimeProofs.Duration
