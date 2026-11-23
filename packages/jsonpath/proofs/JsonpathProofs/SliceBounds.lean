import Aeneas
import PionLean
import Jsonpath.Types
import Jsonpath.Funs

open Aeneas Aeneas.Std Result ControlFlow Error Pion jsonpath

namespace JsonpathProofs

private lemma result_bind_ok' {α β : Type} (a : α) (f : α → Result β) :
    (do let x ← ok a; f x) = f a := by simp
private lemma i64_le_iff' (x y : Std.I64) : (x <= y) ↔ (x.val <= y.val) := Iff.rfl
private lemma i64_lt_iff' (x y : Std.I64) : (x < y) ↔ (x.val < y.val) := Iff.rfl

private lemma i64_add_val' (x y : Std.I64)
    (hlo : -9223372036854775808 ≤ x.val + y.val) (hhi : x.val + y.val ≤ 9223372036854775807) :
    (Pion.I64.add x y).val = x.val + y.val := by
  unfold Pion.I64.add
  have hv : (x.bv + y.bv).toInt = x.val + y.val := by
    rw [BitVec.toInt_add]
    have hx : x.bv.toInt = x.val := rfl
    have hy : y.bv.toInt = y.val := rfl
    rw [hx, hy]
    exact Int.bmod_eq_of_le (by omega) (by omega)
  exact hv

private lemma i64_sub_val' (x y : Std.I64)
    (hlo : -9223372036854775808 ≤ x.val - y.val) (hhi : x.val - y.val ≤ 9223372036854775807) :
    (Pion.I64.sub x y).val = x.val - y.val := by
  unfold Pion.I64.sub
  have hv : (x.bv - y.bv).toInt = x.val - y.val := by
    rw [BitVec.toInt_sub]
    have hx : x.bv.toInt = x.val := rfl
    have hy : y.bv.toInt = y.val := rfl
    rw [hx, hy]
    exact Int.bmod_eq_of_le (by omega) (by omega)
  exact hv

private lemma i64_neg_val' (x : Std.I64) (hlo : -9223372036854775807 ≤ x.val) :
    (Pion.I64.neg x).val = -x.val := by
  unfold Pion.I64.neg
  have hv : (-x.bv).toInt = -x.val := by
    rw [BitVec.toInt_neg]
    have hx : x.bv.toInt = x.val := rfl
    rw [hx]
    have hhi := x.hBounds.2
    change x.val < 9223372036854775808 at hhi
    exact Int.bmod_eq_of_le (by omega) (by omega)
  exact hv

/-- Theorem 13: RFC 9535 `Normalize(i, len)` leaves non-negative indices unchanged. -/
lemma rfc9535_normalize_index_nonneg (idx len : Std.I64) (h : 0 ≤ idx.val) :
    rfc9535_normalize_index idx len = ok idx := by
  unfold rfc9535_normalize_index
  have hge : idx >= 0#i64 := (i64_le_iff' 0#i64 idx).mpr h
  simp only [hge, ↓reduceIte]

/-- Theorem 14: RFC 9535 `Normalize(i, len)` adds `len` to negative indices. -/
lemma rfc9535_normalize_index_neg (idx len : Std.I64)
    (hneg : idx.val < 0)
    (hlo : -9223372036854775808 ≤ len.val + idx.val) (hhi : len.val + idx.val ≤ 9223372036854775807) :
    ∃ r : Std.I64, rfc9535_normalize_index idx len = ok r ∧ r.val = len.val + idx.val := by
  unfold rfc9535_normalize_index
  have hnge : ¬ (idx >= 0#i64) := fun h => by
    have hv := (i64_le_iff' 0#i64 idx).mp h; change 0 ≤ idx.val at hv; omega
  simp only [hnge, ↓reduceIte]
  exact ⟨Pion.I64.add len idx, rfl, i64_add_val' len idx hlo hhi⟩

/-- Theorem 15: Negative indices in `[-len, -1]` normalize strictly into valid array bounds `[0, len - 1]`. -/
theorem rfc9535_normalize_index_in_bounds_neg (idx len : Std.I64)
    (hlen : 0 ≤ len.val) (hlo : -len.val ≤ idx.val) (hneg : idx.val < 0) :
    ∃ r : Std.I64, rfc9535_normalize_index idx len = ok r ∧ 0 ≤ r.val ∧ r.val < len.val := by
  have hlen_hi := len.hBounds.2
  change len.val < 9223372036854775808 at hlen_hi
  rcases rfc9535_normalize_index_neg idx len hneg (by omega) (by omega) with ⟨r, hr, hrv⟩
  exact ⟨r, hr, by omega, by omega⟩

/-- Theorem 16: Forward slice clamping (`step > 0`) ALWAYS lands in `[0, len]` (guarantees every `i ∈ [lower, upper)` is in-bounds). -/
theorem rfc9535_clamp_pos_slice_bounds (n len : Std.I64) (hlen : 0 ≤ len.val) :
    ∃ r : Std.I64, rfc9535_clamp_pos_slice n len = ok r ∧
      0 ≤ r.val ∧ r.val ≤ len.val ∧
      (n.val < 0 → r.val = 0) ∧
      (len.val < n.val → r.val = len.val) ∧
      (0 ≤ n.val ∧ n.val ≤ len.val → r.val = n.val) := by
  unfold rfc9535_clamp_pos_slice
  by_cases h0 : n < 0#i64
  · simp only [h0, ↓reduceIte]
    have hv := (i64_lt_iff' n 0#i64).mp h0; change n.val < 0 at hv
    refine ⟨0#i64, rfl, by decide, by change (0 : Int) ≤ len.val; omega, fun _ => rfl, fun hgt => by omega, fun hb => by omega⟩
  · simp only [h0, ↓reduceIte]
    have hv0 : ¬ (n.val < 0) := fun hlt => h0 ((i64_lt_iff' n 0#i64).mpr hlt)
    by_cases hl : n > len
    · simp only [hl, ↓reduceIte]
      have hvl := (i64_lt_iff' len n).mp hl
      refine ⟨len, rfl, by omega, le_refl _, fun hlt => by omega, fun _ => rfl, fun hb => by omega⟩
    · simp only [hl, ↓reduceIte]
      have hvl : ¬ (len.val < n.val) := fun hgt => hl ((i64_lt_iff' len n).mpr hgt)
      refine ⟨n, rfl, by omega, by omega, fun hlt => by omega, fun hgt => by omega, fun _ => rfl⟩

/-- Theorem 17: Forward slice clamping is monotone (`a ≤ b → clamp_pos a len ≤ clamp_pos b len`). -/
theorem rfc9535_clamp_pos_slice_mono (a b len : Std.I64) (hlen : 0 ≤ len.val) (hab : a.val ≤ b.val) :
    ∃ ra rb : Std.I64,
      rfc9535_clamp_pos_slice a len = ok ra ∧
      rfc9535_clamp_pos_slice b len = ok rb ∧
      ra.val ≤ rb.val := by
  rcases rfc9535_clamp_pos_slice_bounds a len hlen with ⟨ra, hra, hra0, hral, ha1, ha2, ha3⟩
  rcases rfc9535_clamp_pos_slice_bounds b len hlen with ⟨rb, hrb, hrb0, hrbl, hb1, hb2, hb3⟩
  refine ⟨ra, rb, hra, hrb, ?_⟩
  by_cases ha_neg : a.val < 0
  · rw [ha1 ha_neg]; exact hrb0
  · by_cases ha_hi : len.val < a.val
    · rw [ha2 ha_hi, hb2 (by omega)]
    · rw [ha3 ⟨by omega, by omega⟩]
      by_cases hb_hi : len.val < b.val
      · rw [hb2 hb_hi]; omega
      · rw [hb3 ⟨by omega, by omega⟩]; omega

/-- Theorem 19: Reverse slice clamping (`step < 0`) ALWAYS lands in `[-1, len - 1]` (guarantees every `i` with `upper ≥ i > lower` is in `[0, len - 1]`). -/
theorem rfc9535_clamp_neg_slice_bounds (n len : Std.I64) (hlen : 0 ≤ len.val) :
    ∃ r : Std.I64, rfc9535_clamp_neg_slice n len = ok r ∧
      -1 ≤ r.val ∧ r.val ≤ len.val - 1 ∧
      (n.val < -1 → r.val = -1) ∧
      (len.val - 1 < n.val → r.val = len.val - 1) ∧
      (-1 ≤ n.val ∧ n.val ≤ len.val - 1 → r.val = n.val) := by
  have hlen_hi := len.hBounds.2
  change len.val < 9223372036854775808 at hlen_hi
  unfold rfc9535_clamp_neg_slice
  set lm1 := Pion.I64.sub len 1#i64
  have hlm1 : lm1.val = len.val - 1 :=
    i64_sub_val' len 1#i64 (by change -9223372036854775808 ≤ len.val - 1; omega) (by change len.val - 1 ≤ 9223372036854775807; omega)
  by_cases h0 : n < (-1)#i64
  · simp only [h0, ↓reduceIte]
    have hv := (i64_lt_iff' n (-1)#i64).mp h0; change n.val < -1 at hv
    refine ⟨(-1)#i64, rfl, by decide, by change (-1 : Int) ≤ len.val - 1; omega, fun _ => rfl, fun hgt => by omega, fun hb => by omega⟩
  · simp only [h0, ↓reduceIte]
    have hv0 : ¬ (n.val < -1) := fun hlt => h0 ((i64_lt_iff' n (-1)#i64).mpr hlt)
    by_cases hl : n > lm1
    · simp only [hl, ↓reduceIte]
      have hvl := (i64_lt_iff' lm1 n).mp hl
      refine ⟨lm1, rfl, by omega, by omega, fun hlt => by omega, fun _ => hlm1, fun hb => by omega⟩
    · simp only [hl, ↓reduceIte]
      have hvl : ¬ (lm1.val < n.val) := fun hgt => hl ((i64_lt_iff' lm1 n).mpr hgt)
      refine ⟨n, rfl, by omega, by omega, fun hlt => by omega, fun hgt => by omega, fun _ => rfl⟩

/-- Theorem 23: Default reverse slice (`step < 0`, `0 ≤ len ≤ 10^15`) normalizes & clamps to exact `[upper = len - 1, lower = -1]` (full reverse scan `[len-1 .. 0]`). -/
theorem rfc9535_default_slice_neg_full_range (len step : Std.I64)
    (hlen0 : 0 ≤ len.val) (hlen_hi : len.val ≤ 1000000000000000) (hstep : step.val < 0) :
    ∃ s e ns ne cs ce : Std.I64,
      rfc9535_default_slice_start len step = ok s ∧
      rfc9535_default_slice_end len step = ok e ∧
      rfc9535_normalize_index s len = ok ns ∧
      rfc9535_normalize_index e len = ok ne ∧
      rfc9535_clamp_neg_slice ns len = ok cs ∧
      rfc9535_clamp_neg_slice ne len = ok ce ∧
      cs.val = len.val - 1 ∧ ce.val = -1 := by
  have hnge : ¬ (step >= 0#i64) := fun h => by
    have hv := (i64_le_iff' 0#i64 step).mp h; change 0 ≤ step.val at hv; omega
  set s := Pion.I64.sub len 1#i64
  set e := Pion.I64.sub (Pion.I64.neg len) 1#i64
  have hs_eq : rfc9535_default_slice_start len step = ok s := by
    unfold rfc9535_default_slice_start; simp only [hnge, ↓reduceIte]; rfl
  have he_eq : rfc9535_default_slice_end len step = ok e := by
    unfold rfc9535_default_slice_end; simp only [hnge, ↓reduceIte]; rfl
  have hs_v : s.val = len.val - 1 :=
    i64_sub_val' len 1#i64 (by change -9223372036854775808 ≤ len.val - 1; omega) (by change len.val - 1 ≤ 9223372036854775807; omega)
  have hneg_v : (Pion.I64.neg len).val = -len.val := i64_neg_val' len (by omega)
  have he_v : e.val = -len.val - 1 := by
    have := i64_sub_val' (Pion.I64.neg len) 1#i64 (by change -9223372036854775808 ≤ (Pion.I64.neg len).val - 1; omega)
      (by change (Pion.I64.neg len).val - 1 ≤ 9223372036854775807; omega)
    change e.val = (Pion.I64.neg len).val - 1 at this; omega
  rcases rfc9535_normalize_index_neg e len (by omega) (by omega) (by omega) with ⟨ne, hne, hne_v⟩
  rcases rfc9535_clamp_neg_slice_bounds ne len hlen0 with ⟨ce, hce, _, _, _, _, hce_eq⟩
  have hce_v : ce.val = -1 := by
    have := hce_eq ⟨by omega, by omega⟩; omega
  by_cases hlen_pos : 0 < len.val
  · have hns := rfc9535_normalize_index_nonneg s len (by omega)
    rcases rfc9535_clamp_neg_slice_bounds s len hlen0 with ⟨cs, hcs, _, _, _, _, hcs_eq⟩
    exact ⟨s, e, s, ne, cs, ce, hs_eq, he_eq, hns, hne, hcs, hce, by rw [hcs_eq ⟨by omega, by omega⟩]; exact hs_v, hce_v⟩
  · have hlen_z : len.val = 0 := by omega
    rcases rfc9535_normalize_index_neg s len (by omega) (by omega) (by omega) with ⟨ns, hns, hns_v⟩
    rcases rfc9535_clamp_neg_slice_bounds ns len hlen0 with ⟨cs, hcs, _, _, _, _, hcs_eq⟩
    exact ⟨s, e, ns, ne, cs, ce, hs_eq, he_eq, hns, hne, hcs, hce, by rw [hcs_eq ⟨by omega, by omega⟩]; omega, hce_v⟩

end JsonpathProofs
