import Aeneas
import PionLean
import Jq.Types
import Jq.Funs

open Aeneas Aeneas.Std Result Pion jq

namespace JqProofs

private lemma i32_bv_toNat_of_nonneg (x : Std.I32) (h0 : 0 ≤ x.val) :
    (x.bv.toNat : Int) = x.val := by
  have h := x.bv.toInt_eq_toNat_cond
  change 0 ≤ x.bv.toInt at h0
  split_ifs at h with hcond
  · exact h.symm
  · have := x.bv.isLt; omega

private lemma i32_val_of_bv_toNat_lt (x : Std.I32) (hlt : x.bv.toNat < 2 ^ 31) :
    x.val = (x.bv.toNat : Int) := by
  have h := x.bv.toInt_eq_toNat_cond
  have h2 : 2 * x.bv.toNat < 2 ^ 32 := by omega
  simp only [h2, ↓reduceIte] at h
  exact h

private lemma i32_add_val (a b : Std.I32)
    (hlo : -2147483648 ≤ a.val + b.val) (hhi : a.val + b.val ≤ 2147483647) :
    (Pion.I32.add a b).val = a.val + b.val := by
  change -2147483648 ≤ a.bv.toInt + b.bv.toInt at hlo
  change a.bv.toInt + b.bv.toInt ≤ 2147483647 at hhi
  change (a.bv + b.bv).toInt = a.bv.toInt + b.bv.toInt
  rw [BitVec.toInt_add]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_sub_val (a b : Std.I32)
    (hlo : -2147483648 ≤ a.val - b.val) (hhi : a.val - b.val ≤ 2147483647) :
    (Pion.I32.sub a b).val = a.val - b.val := by
  change -2147483648 ≤ a.bv.toInt - b.bv.toInt at hlo
  change a.bv.toInt - b.bv.toInt ≤ 2147483647 at hhi
  change (a.bv - b.bv).toInt = a.bv.toInt - b.bv.toInt
  rw [BitVec.toInt_sub]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by simp

/-- Theorem 1: `is_json_ws` matches the exact 4 RFC 8259 §2 whitespace bytes (SP, HTAB, LF, CR). -/
theorem is_json_ws_spec (b : Std.I32) :
    is_json_ws b = ok true ↔ (b.val = 32 ∨ b.val = 9 ∨ b.val = 10 ∨ b.val = 13) := by
  unfold is_json_ws
  simp only [ok.injEq, Bool.or_eq_true, beq_iff_eq]
  constructor
  · intro h
    rcases h with ((h | h) | h) | h
    · left; exact congrArg IScalar.val h
    · right; left; exact congrArg IScalar.val h
    · right; right; left; exact congrArg IScalar.val h
    · right; right; right; exact congrArg IScalar.val h
  · intro h
    rcases h with h | h | h | h
    · left; left; left; exact IScalar.eq_of_val_eq h
    · left; left; right; exact IScalar.eq_of_val_eq h
    · left; right; exact IScalar.eq_of_val_eq h
    · right; exact IScalar.eq_of_val_eq h

/-- Theorem 2: Exact characterization of `is_json_str_fast_byte`. -/
theorem is_json_str_fast_byte_spec (b : Std.I32) :
    is_json_str_fast_byte b = ok true ↔ (32 ≤ b.val ∧ b.val < 128 ∧ b.val ≠ 34 ∧ b.val ≠ 92) := by
  unfold is_json_str_fast_byte
  simp only [ok.injEq, Bool.and_eq_true, decide_eq_true_eq, bne_iff_ne]
  constructor
  · intro ⟨⟨⟨h1, h2⟩, h3⟩, h4⟩
    exact ⟨h1, h2, fun h => h3 (IScalar.eq_of_val_eq h), fun h => h4 (IScalar.eq_of_val_eq h)⟩
  · intro ⟨h1, h2, h3, h4⟩
    exact ⟨⟨⟨h1, h2⟩, fun h => h3 (congrArg IScalar.val h)⟩, fun h => h4 (congrArg IScalar.val h)⟩

/-- Theorem 3: Quotes, backslashes, control characters, and non-ASCII bytes never take the fast path. -/
theorem is_json_str_fast_byte_disjoint_escapes (b : Std.I32)
    (h : b.val < 32 ∨ b.val ≥ 128 ∨ b.val = 34 ∨ b.val = 92) :
    is_json_str_fast_byte b = ok false := by
  have hne : is_json_str_fast_byte b ≠ ok true := by
    intro ht
    rw [is_json_str_fast_byte_spec] at ht
    omega
  unfold is_json_str_fast_byte at hne ⊢
  cases hb : ((((decide (b >= 32#i32)) && (decide (b < 128#i32))) && (b != 34#i32)) && (b != 92#i32))
  · rfl
  · exfalso; exact hne (congrArg ok hb)

/-- Theorem 4: `is_ascii_alpha` and `is_ascii_digit` are strictly disjoint. -/
theorem is_ascii_alpha_digit_disjoint (b : Std.I32) :
    ¬ (is_ascii_alpha b = ok true ∧ is_ascii_digit b = ok true) := by
  intro ⟨ha, hd⟩
  unfold is_ascii_alpha at ha
  unfold is_ascii_digit at hd
  simp only [ok.injEq, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq] at ha hd
  have hd1 : (48 : Int) ≤ b.val := hd.1
  have hd2 : b.val ≤ (57 : Int) := hd.2
  rcases ha with (⟨h1, h2⟩ | ⟨h1, h2⟩) | h3
  · change (65 : Int) ≤ b.val at h1; omega
  · change (97 : Int) ≤ b.val at h1; omega
  · have : b.val = 95 := congrArg IScalar.val h3; omega

/-- Theorem 5: Exact iff characterization of `is_ident_char` (`A-Z`, `a-z`, `0-9`, `_`). -/
theorem is_ident_char_spec (b : Std.I32) :
    is_ident_char b = ok true ↔
      ((65 ≤ b.val ∧ b.val ≤ 90) ∨ (97 ≤ b.val ∧ b.val ≤ 122) ∨ b.val = 95 ∨ (48 ≤ b.val ∧ b.val ≤ 57)) := by
  unfold is_ident_char is_ascii_alpha is_ascii_digit
  simp only [result_bind_ok]
  split_ifs with h1
  · simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq] at h1
    constructor
    · intro _
      rcases h1 with (⟨a, c⟩ | ⟨a, c⟩) | h95
      · left; exact ⟨a, c⟩
      · right; left; exact ⟨a, c⟩
      · right; right; left; exact congrArg IScalar.val h95
    · intro _; rfl
  · simp only [ok.injEq, Bool.and_eq_true, decide_eq_true_eq]
    constructor
    · intro ⟨a, c⟩; right; right; right; exact ⟨a, c⟩
    · intro h
      rcases h with ⟨a, c⟩ | ⟨a, c⟩ | h95 | ⟨a, c⟩
      · exfalso; apply h1
        simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq]
        left; left; exact ⟨a, c⟩
      · exfalso; apply h1
        simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq]
        left; right; exact ⟨a, c⟩
      · exfalso; apply h1
        simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq]
        right; exact IScalar.eq_of_val_eq h95
      · exact ⟨a, c⟩

/-- Theorem 6: `hex_val` returns the exact hex nibble in `[0, 15]` or `-1`. -/
theorem hex_val_range_and_spec (b : Std.I32) :
    ∃ r : Std.I32, hex_val b = ok r ∧
      (r.val = -1 ∨ (0 ≤ r.val ∧ r.val ≤ 15)) ∧
      ((48 ≤ b.val ∧ b.val ≤ 57 → r.val = b.val - 48) ∧
       (65 ≤ b.val ∧ b.val ≤ 70 → r.val = b.val - 55) ∧
       (97 ≤ b.val ∧ b.val ≤ 102 → r.val = b.val - 87)) := by
  unfold hex_val
  have c48 : (48#i32 : Std.I32).val = 48 := rfl
  have c55 : (55#i32 : Std.I32).val = 55 := rfl
  have c87 : (87#i32 : Std.I32).val = 87 := rfl
  refine ⟨_, rfl, ?_⟩
  split_ifs with h1 h2 h3
  · simp only [Bool.and_eq_true, decide_eq_true_eq] at h1
    have ha : (48 : Int) ≤ b.val := h1.1
    have hb : b.val ≤ (57 : Int) := h1.2
    have hsub := i32_sub_val b 48#i32 (by omega) (by omega)
    exact ⟨Or.inr ⟨by omega, by omega⟩, fun _ => by omega, fun h => by omega, fun h => by omega⟩
  · simp only [Bool.and_eq_true, decide_eq_true_eq] at h2
    have ha : (65 : Int) ≤ b.val := h2.1
    have hb : b.val ≤ (70 : Int) := h2.2
    have hsub := i32_sub_val b 55#i32 (by omega) (by omega)
    exact ⟨Or.inr ⟨by omega, by omega⟩, fun h => by omega, fun _ => by omega, fun h => by omega⟩
  · simp only [Bool.and_eq_true, decide_eq_true_eq] at h3
    have ha : (97 : Int) ≤ b.val := h3.1
    have hb : b.val ≤ (102 : Int) := h3.2
    have hsub := i32_sub_val b 87#i32 (by omega) (by omega)
    exact ⟨Or.inr ⟨by omega, by omega⟩, fun h => by omega, fun h => by omega, fun _ => by omega⟩
  · simp only [Bool.and_eq_true, decide_eq_true_eq, not_and] at h1 h2 h3
    exact ⟨Or.inl rfl, fun h => by exfalso; exact h1 h.1 h.2,
           fun h => by exfalso; exact h2 h.1 h.2, fun h => by exfalso; exact h3 h.1 h.2⟩

/-- Theorem 7: `sanitize_utf8_cp` always returns a valid RFC 3629 Unicode scalar value. -/
theorem sanitize_utf8_cp_valid_scalar (cp : Std.I32) :
    ∃ r : Std.I32, sanitize_utf8_cp cp = ok r ∧
      0 ≤ r.val ∧ r.val ≤ 1114111 ∧ ¬ (55296 ≤ r.val ∧ r.val ≤ 57343) := by
  unfold sanitize_utf8_cp
  refine ⟨_, rfl, ?_⟩
  split_ifs with h
  · have cfffd : (65533#i32 : Std.I32).val = 65533 := rfl
    omega
  · simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, not_or, not_and] at h
    have h1 : ¬ (cp.val < (0 : Int)) := h.1.1
    have h2 : ¬ (cp.val > (1114111 : Int)) := h.1.2
    have h3 : (55296 : Int) ≤ cp.val → ¬ (cp.val ≤ 57343) := h.2
    refine ⟨by omega, by omega, fun ⟨a, b⟩ => h3 a b⟩

/-- Theorem 8: `sanitize_utf8_cp` is idempotent. -/
theorem sanitize_utf8_cp_idempotent (cp : Std.I32) :
    (do let r ← sanitize_utf8_cp cp; sanitize_utf8_cp r) = sanitize_utf8_cp cp := by
  obtain ⟨r, hr, hr0, hrhi, hrns⟩ := sanitize_utf8_cp_valid_scalar cp
  rw [hr, result_bind_ok]
  unfold sanitize_utf8_cp
  have hcond : (((decide (r < 0#i32)) || (decide (r > 1114111#i32))) ||
      ((decide (r >= 55296#i32)) && (decide (r <= 57343#i32)))) = false := by
    cases hb : (((decide (r < 0#i32)) || (decide (r > 1114111#i32))) ||
        ((decide (r >= 55296#i32)) && (decide (r <= 57343#i32))))
    · rfl
    · simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq] at hb
      rcases hb with (h1 | h2) | ⟨h3, h4⟩
      · change r.val < 0 at h1; omega
      · change r.val > 1114111 at h2; omega
      · exact (hrns ⟨h3, h4⟩).elim
  rw [hcond]
  rfl

/-- Theorem 9: `is_high_surrogate` and `is_low_surrogate` are disjoint and partition `[0xD800, 0xDFFF]`. -/
theorem surrogate_ranges_disjoint_and_partition (u : Std.I32) :
    ¬ (is_high_surrogate u = ok true ∧ is_low_surrogate u = ok true) ∧
    ((is_high_surrogate u = ok true ∨ is_low_surrogate u = ok true) ↔
      (55296 ≤ u.val ∧ u.val ≤ 57343)) := by
  unfold is_high_surrogate is_low_surrogate
  simp only [ok.injEq, Bool.and_eq_true, decide_eq_true_eq]
  have c55296 : (55296#i32 : Std.I32).val = 55296 := rfl
  have c56319 : (56319#i32 : Std.I32).val = 56319 := rfl
  have c56320 : (56320#i32 : Std.I32).val = 56320 := rfl
  have c57343 : (57343#i32 : Std.I32).val = 57343 := rfl
  constructor
  · intro ⟨⟨_, h1⟩, ⟨h2, _⟩⟩
    change u.val ≤ 56319 at h1
    change 56320 ≤ u.val at h2
    omega
  · constructor
    · intro h
      rcases h with ⟨a, b⟩ | ⟨a, b⟩
      · change (55296 : Int) ≤ u.val at a; change u.val ≤ 56319 at b; omega
      · change (56320 : Int) ≤ u.val at a; change u.val ≤ 57343 at b; omega
    · intro ⟨a, b⟩
      by_cases h : u.val ≤ 56319
      · left; exact ⟨a, h⟩
      · right; exact ⟨by change (56320 : Int) ≤ u.val; omega, b⟩

/-- Theorem 10: `decode_surrogate_pair` computes the exact supplementary Unicode scalar value in `[0x10000, 0x10FFFF]`
    and is preserved unchanged by `sanitize_utf8_cp`. -/
theorem decode_surrogate_pair_spec (hi lo : Std.I32)
    (hhi : is_high_surrogate hi = ok true)
    (hlo : is_low_surrogate lo = ok true) :
    ∃ cp : Std.I32, decode_surrogate_pair hi lo = ok cp ∧
      cp.val = 65536 + (hi.val - 55296) * 1024 + (lo.val - 56320) ∧
      65536 ≤ cp.val ∧ cp.val ≤ 1114111 ∧
      sanitize_utf8_cp cp = ok cp := by
  unfold is_high_surrogate at hhi
  unfold is_low_surrogate at hlo
  simp only [ok.injEq, Bool.and_eq_true, decide_eq_true_eq] at hhi hlo
  have hhi1 : (55296 : Int) ≤ hi.val := hhi.1
  have hhi2 : hi.val ≤ (56319 : Int) := hhi.2
  have hlo1 : (56320 : Int) ≤ lo.val := hlo.1
  have hlo2 : lo.val ≤ (57343 : Int) := hlo.2
  have c55296 : (55296#i32 : Std.I32).val = 55296 := rfl
  have c56320 : (56320#i32 : Std.I32).val = 56320 := rfl
  have c65536 : (65536#i32 : Std.I32).val = 65536 := rfl
  have hdhi : (Pion.I32.sub hi 55296#i32).val = hi.val - 55296 := by
    have h := i32_sub_val hi 55296#i32 (by omega) (by omega)
    omega
  have hdhi_nat : ((Pion.I32.sub hi 55296#i32).bv.toNat : Int) = (Pion.I32.sub hi 55296#i32).val :=
    i32_bv_toNat_of_nonneg (Pion.I32.sub hi 55296#i32) (by omega)
  have hshl : Pion.I32.shl (Pion.I32.sub hi 55296#i32) 10#i32 = ok ⟨(Pion.I32.sub hi 55296#i32).bv <<< 10⟩ := by
    unfold Pion.I32.shl
    have h0 : (0 : Int) ≤ (10#i32 : Std.I32).val := by decide
    have h32 : (10#i32 : Std.I32).val < 32 := by decide
    have h10 : ((10#i32 : Std.I32).val).toNat = 10 := by decide
    simp only [h0, h32, and_self, ↓reduceIte, h10]
  set shifted : Std.I32 := ⟨(Pion.I32.sub hi 55296#i32).bv <<< 10⟩
  have hsh_nat : shifted.bv.toNat = (Pion.I32.sub hi 55296#i32).bv.toNat * 1024 := by
    change ((Pion.I32.sub hi 55296#i32).bv <<< 10).toNat = (Pion.I32.sub hi 55296#i32).bv.toNat * 1024
    rw [BitVec.toNat_shiftLeft, Nat.shiftLeft_eq]
    exact Nat.mod_eq_of_lt (by omega)
  have hsh_val : shifted.val = (hi.val - 55296) * 1024 := by
    have hv := i32_val_of_bv_toNat_lt shifted (by rw [hsh_nat]; omega)
    rw [hv, hsh_nat]; omega
  have hdlo : (Pion.I32.sub lo 56320#i32).val = lo.val - 56320 := by
    have h := i32_sub_val lo 56320#i32 (by omega) (by omega)
    omega
  unfold decode_surrogate_pair
  simp only [hshl, result_bind_ok]
  have hs1 : (Pion.I32.add 65536#i32 shifted).val = 65536 + (hi.val - 55296) * 1024 := by
    have h := i32_add_val 65536#i32 shifted (by omega) (by omega)
    omega
  set cp := Pion.I32.add (Pion.I32.add 65536#i32 shifted) (Pion.I32.sub lo 56320#i32)
  have hcp : cp.val = 65536 + (hi.val - 55296) * 1024 + (lo.val - 56320) := by
    have h := i32_add_val (Pion.I32.add 65536#i32 shifted) (Pion.I32.sub lo 56320#i32) (by omega) (by omega)
    change cp.val = (Pion.I32.add 65536#i32 shifted).val + (Pion.I32.sub lo 56320#i32).val at h
    omega
  refine ⟨cp, rfl, hcp, by omega, by omega, ?_⟩
  unfold sanitize_utf8_cp
  have hcond : (((decide (cp < 0#i32)) || (decide (cp > 1114111#i32))) ||
      ((decide (cp >= 55296#i32)) && (decide (cp <= 57343#i32)))) = false := by
    cases hb : (((decide (cp < 0#i32)) || (decide (cp > 1114111#i32))) ||
        ((decide (cp >= 55296#i32)) && (decide (cp <= 57343#i32))))
    · rfl
    · simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq] at hb
      rcases hb with (h1 | h2) | ⟨h3, h4⟩
      · change cp.val < 0 at h1; omega
      · change cp.val > 1114111 at h2; omega
      · change cp.val ≤ 57343 at h4; omega
  rw [hcond]
  rfl

/-- Theorem 11: `decode_surrogate_pair` is injective on valid UTF-16 surrogate pairs. -/
theorem decode_surrogate_pair_injective (hi1 lo1 hi2 lo2 : Std.I32)
    (hhi1 : is_high_surrogate hi1 = ok true) (hlo1 : is_low_surrogate lo1 = ok true)
    (hhi2 : is_high_surrogate hi2 = ok true) (hlo2 : is_low_surrogate lo2 = ok true)
    (heq : decode_surrogate_pair hi1 lo1 = decode_surrogate_pair hi2 lo2) :
    hi1 = hi2 ∧ lo1 = lo2 := by
  obtain ⟨cp1, hcp1, hv1, _, _, _⟩ := decode_surrogate_pair_spec hi1 lo1 hhi1 hlo1
  obtain ⟨cp2, hcp2, hv2, _, _, _⟩ := decode_surrogate_pair_spec hi2 lo2 hhi2 hlo2
  rw [hcp1, hcp2] at heq
  have hcpeq : cp1 = cp2 := by simpa using heq
  have hval : cp1.val = cp2.val := congrArg IScalar.val hcpeq
  unfold is_high_surrogate at hhi1 hhi2
  unfold is_low_surrogate at hlo1 hlo2
  simp only [ok.injEq, Bool.and_eq_true, decide_eq_true_eq] at hhi1 hlo1 hhi2 hlo2
  have ha1 : (55296 : Int) ≤ hi1.val := hhi1.1
  have ha2 : hi1.val ≤ (56319 : Int) := hhi1.2
  have hb1 : (56320 : Int) ≤ lo1.val := hlo1.1
  have hb2 : lo1.val ≤ (57343 : Int) := hlo1.2
  have hc1 : (55296 : Int) ≤ hi2.val := hhi2.1
  have hc2 : hi2.val ≤ (56319 : Int) := hhi2.2
  have hd1 : (56320 : Int) ≤ lo2.val := hlo2.1
  have hd2 : lo2.val ≤ (57343 : Int) := hlo2.2
  exact ⟨IScalar.eq_of_val_eq (by omega), IScalar.eq_of_val_eq (by omega)⟩

end JqProofs
