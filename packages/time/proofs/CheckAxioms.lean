/-
Axiom gate for `packages/time` (`packages/time/proofs/run_proofs.sh`):
every theorem below may depend ONLY on `propext`, `Classical.choice`, and `Quot.sound`.
-/
import TimeProofs

-- Calendar & Neri-Schneider bijection (7)
#print axioms TimeProofs.is_leap_year_spec
#print axioms TimeProofs.days_in_month_of_spec
#print axioms TimeProofs.to_epoch_days_spec
#print axioms TimeProofs.from_epoch_days_spec
#print axioms TimeProofs.from_epoch_days_out_of_range
#print axioms TimeProofs.to_epoch_days_from_epoch_days
#print axioms TimeProofs.from_epoch_days_to_epoch_days

-- Strict total orders (8)
#print axioms TimeProofs.date_cmp_lt_iff
#print axioms TimeProofs.date_cmp_eq_zero_iff
#print axioms TimeProofs.to_epoch_days_strict_mono
#print axioms TimeProofs.time_to_second_of_day_spec
#print axioms TimeProofs.time_cmp_spec
#print axioms TimeProofs.timestamp_cmp_spec
#print axioms TimeProofs.datetime_cmp_antisymm
#print axioms TimeProofs.datetime_cmp_trans_lt

-- SignedDuration checked arithmetic & ordering (7)
#print axioms TimeProofs.checked_add_i64_spec
#print axioms TimeProofs.checked_sub_i64_spec
#print axioms TimeProofs.signed_duration_new_sound
#print axioms TimeProofs.signed_duration_checked_neg_sound
#print axioms TimeProofs.signed_duration_checked_add_sound
#print axioms TimeProofs.signed_duration_checked_sub_sound
#print axioms TimeProofs.signed_duration_cmp_spec
