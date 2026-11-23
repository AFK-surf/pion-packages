/-
Formal verification of `packages/cron` (`Cron.Funs`, extracted via
`pionc extract-lean` from `packages/cron/src/*.pion`).

Modularized into 5 Lean modules for fast, bounded-memory builds:
- `CronProofs.Core`: scalar & bitwise bridge lemmas
- `CronProofs.Bitmask`: 64-bit bitmask kernels (`ctz64`, `msb64`, `next_set_bit`, `prev_set_bit`)
- `CronProofs.CalendarBase`: proleptic Gregorian leap year, `days_in_month`, `days_from_civil` & math lemmas
- `CronProofs.CalendarBijection`: `civil_from_days` & `DateTime` <-> epoch-seconds bijection
- `CronProofs.Matcher`: bitmask matcher safety guards (`matches_fixed_fields`, `matches_day`)

All proofs are complete and kernel-checked, depending only on the three
standard Lean axioms: `propext`, `Classical.choice`, `Quot.sound`.
-/
import CronProofs.Core
import CronProofs.Bitmask
import CronProofs.CalendarBase
import CronProofs.CalendarBijection
import CronProofs.Matcher
