/-
Axiom gate for `packages/semver` (`packages/semver/proofs/run_proofs.sh`):
every theorem below may depend ONLY on `propext`, `Classical.choice`, and `Quot.sound`.
-/
import SemverProofs

#print axioms SemverProofs.cmp_core_total
#print axioms SemverProofs.cmp_core_refl
#print axioms SemverProofs.cmp_core_lt_iff
#print axioms SemverProofs.cmp_core_eq_zero_iff
#print axioms SemverProofs.cmp_core_antisymm
#print axioms SemverProofs.cmp_core_trans_lt
#print axioms SemverProofs.cmp_core_trans_le
#print axioms SemverProofs.cmp_precedence_release_gt_pre
#print axioms SemverProofs.cmp_precedence_pre_lt_release
#print axioms SemverProofs.cmp_precedence_ignores_build
#print axioms SemverProofs.cmp_precedence_same_except_build
#print axioms SemverProofs.cmp_pre_segment_order_numeric_lt_alpha
#print axioms SemverProofs.cmp_pre_segment_order_refl
#print axioms SemverProofs.cmp_pre_segment_order_antisymm
#print axioms SemverProofs.cmp_pre_segment_order_trans_lt
#print axioms SemverProofs.matches_release_total_no_overflow
#print axioms SemverProofs.matches_release_caret_major_pos
#print axioms SemverProofs.matches_release_caret_zero_minor_pos
#print axioms SemverProofs.matches_release_caret_zero_zero
#print axioms SemverProofs.matches_release_tilde_spec
#print axioms SemverProofs.matches_release_caret_u64_max
#print axioms SemverProofs.matches_release_tilde_u64_max
#print axioms SemverProofs.matches_release_greater_u64_max
#print axioms SemverProofs.matches_release_exact_iff
#print axioms SemverProofs.matches_release_wildcard_eq_exact
#print axioms SemverProofs.matches_release_refl_ge
#print axioms SemverProofs.matches_release_refl_caret
#print axioms SemverProofs.matches_release_refl_tilde
#print axioms SemverProofs.matches_release_lt_ge_complement
#print axioms SemverProofs.matches_release_gt_le_complement
#print axioms SemverProofs.matches_release_ge_monotone
#print axioms SemverProofs.pre_is_compatible_spec
