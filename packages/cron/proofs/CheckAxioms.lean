/-
Axiom gate for `packages/cron` formal proofs.
Every theorem below must depend ONLY on standard Lean axioms:
  `propext`, `Classical.choice`, `Quot.sound`.
-/
import CronProofs

-- Part 1: 64-bit bitmask kernels
#print axioms CronProofs.ctz64_spec
#print axioms CronProofs.msb64_spec
#print axioms CronProofs.next_set_bit_spec
#print axioms CronProofs.prev_set_bit_spec

-- Part 2: Proleptic Gregorian calendar & DateTime bijection / safety guards
#print axioms CronProofs.is_leap_year_spec
#print axioms CronProofs.is_leap_year_2000
#print axioms CronProofs.is_leap_year_2100
#print axioms CronProofs.is_leap_year_2400
#print axioms CronProofs.days_in_month_spec
#print axioms CronProofs.datetime_is_valid_spec
#print axioms CronProofs.datetime_valid_shift_bounds
#print axioms CronProofs.days_from_civil_eq
#print axioms CronProofs.civil_from_days_eq
#print axioms CronProofs.from_unix_secs_rejects_out_of_range
#print axioms CronProofs.from_unix_secs_in_range_valid
#print axioms CronProofs.from_to_unix_secs_roundtrip
#print axioms CronProofs.to_from_unix_secs_roundtrip
#print axioms CronProofs.to_unix_secs_strict_mono

-- Part 3: Bitmask matcher safety guards (F5)
#print axioms CronProofs.matches_fixed_fields_rejects_invalid
#print axioms CronProofs.matches_fixed_fields_valid_exact
#print axioms CronProofs.matches_day_rejects_invalid
