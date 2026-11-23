import WebsocketProofs.Core

open Aeneas Aeneas.Std Result Pion websocket

namespace WebsocketProofs

/-- RFC 3629 UTF-8 DFA: error state (`st < 0`) is sticky on every input byte. -/
theorem utf8_dfa_sticky_error (st b : Std.I32) (hneg : st.val < 0) :
    utf8_dfa_step st b = ok (-1)#i32 := by
  unfold utf8_dfa_step
  have hlt : st < 0#i32 := (iscalar_lt_iff st 0#i32).mpr (by norm_num; omega)
  simp only [hlt, ↓reduceIte]

/-- RFC 3629 UTF-8 DFA: ASCII bytes (`0x00..0x7F`) transition `0 -> 0`. -/
theorem utf8_dfa_ascii_accept (b : Std.I32) (h : 0 ≤ b.val ∧ b.val < 128) :
    utf8_dfa_step 0#i32 b = ok 0#i32 := by
  unfold utf8_dfa_step
  have h0 : ¬((0#i32 : Std.I32) < 0#i32) := by
    rw [iscalar_lt_iff]; norm_num
  have hc : ((decide (b ≥ 0#i32)) && (decide (b < 128#i32))) = true := by
    simp only [Bool.and_eq_true, decide_eq_true_eq, iscalar_le_iff, iscalar_lt_iff]
    norm_num; omega
  simp only [h0, hc, ↓reduceIte]

/-- RFC 3629 UTF-8 DFA: `0xE0` enters state `3` and rejects overlong 3-byte second bytes `< 0xA0`. -/
theorem utf8_dfa_rejects_overlong_e0 (b1 : Std.I32) (h : b1.val < 160 ∨ 191 < b1.val) :
    utf8_dfa_step 0#i32 224#i32 = ok 3#i32 ∧ utf8_dfa_step 3#i32 b1 = ok (-1)#i32 := by
  refine ⟨by unfold utf8_dfa_step; rfl, ?_⟩
  unfold utf8_dfa_step
  have hlt : ¬((3#i32 : Std.I32) < 0#i32) := by rw [iscalar_lt_iff]; norm_num
  simp only [hlt, ↓reduceIte]
  congr 1
  have hne0 : (3#i32 : Std.I32) ≠ 0#i32 := by decide
  have hne1 : (3#i32 : Std.I32) ≠ 1#i32 := by decide
  have hne2 : (3#i32 : Std.I32) ≠ 2#i32 := by decide
  simp only [hne0, hne1, hne2, ↓reduceIte]
  have hc : ((decide (b1 < 160#i32)) || (decide (b1 > 191#i32))) = true := by
    simp only [Bool.or_eq_true, decide_eq_true_eq, iscalar_lt_iff]; norm_num; omega
  rw [hc]; rfl

/-- RFC 3629 UTF-8 DFA: any valid 2-byte sequence (`0xC2..0xDF`, `0x80..0xBF`) returns to accept state `0`. -/
theorem utf8_dfa_accepts_valid_2byte (b0 b1 : Std.I32)
    (h0 : 194 ≤ b0.val ∧ b0.val ≤ 223)
    (h1 : 128 ≤ b1.val ∧ b1.val ≤ 191) :
    (do let s1 ← utf8_dfa_step 0#i32 b0; utf8_dfa_step s1 b1) = ok 0#i32 := by
  have hs1 : utf8_dfa_step 0#i32 b0 = ok 1#i32 := by
    unfold utf8_dfa_step
    have hlt : ¬((0#i32 : Std.I32) < 0#i32) := by rw [iscalar_lt_iff]; norm_num
    simp only [hlt, ↓reduceIte]
    congr 1
    simp only [Bool.and_eq_true, decide_eq_true_eq, iscalar_le_iff, iscalar_lt_iff]
    split_ifs <;> norm_num at * <;> omega
  rw [hs1, result_bind_ok]
  unfold utf8_dfa_step
  have hlt : ¬((1#i32 : Std.I32) < 0#i32) := by rw [iscalar_lt_iff]; norm_num
  have hne0 : (1#i32 : Std.I32) ≠ 0#i32 := by decide
  simp only [hlt, hne0, ↓reduceIte]
  congr 1
  have hband : Pion.I32.band b1 192#i32 = 128#i32 := by
    unfold Pion.I32.band
    change (⟨b1.bv &&& 192#32⟩ : Std.I32) = 128#i32
    have hb1_nat : b1.bv.toNat = b1.val.toNat := by
      have hti := BitVec.toInt_eq_toNat_cond b1.bv
      have hsb : b1.bv.toInt = b1.val := rfl
      have hlt2 : 2 * b1.bv.toNat < 2 ^ 32 := by
        by_contra hge
        push Not at hge
        rw [ite_eq_right (by omega)] at hti
        have hbn : b1.bv.toNat < 2 ^ 32 := b1.bv.isLt
        omega
      rw [ite_eq_left hlt2] at hti
      omega
    have heq_bv : b1.bv &&& 192#32 = 128#32 := by
      apply BitVec.eq_of_toNat_eq
      rw [BitVec.toNat_and, hb1_nat]
      have h192 : (192#32).toNat = 192 := by norm_num
      have h128 : (128#32).toNat = 128 := by norm_num
      rw [h192, h128]
      apply Nat.eq_of_testBit_eq
      intro k
      rw [Nat.testBit_and]
      by_cases hk : k < 8
      · rcases (by omega : k = 0 ∨ k = 1 ∨ k = 2 ∨ k = 3 ∨ k = 4 ∨ k = 5 ∨ k = 6 ∨ k = 7) with
          rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl
        all_goals (simp [Nat.testBit_eq_decide_div_mod_eq]; try omega)
      · have h192_0 : (192 : Nat).testBit k = false := by
          rw [Nat.testBit_eq_decide_div_mod_eq, decide_eq_false_iff_not]
          have hpow : 256 ≤ 2 ^ k := by
            have : 2 ^ 8 ≤ 2 ^ k := Nat.pow_le_pow_right (by norm_num) (by omega)
            omega
          have : 192 / 2 ^ k = 0 := Nat.div_eq_of_lt (by omega)
          omega
        have h128_0 : (128 : Nat).testBit k = false := by
          rw [Nat.testBit_eq_decide_div_mod_eq, decide_eq_false_iff_not]
          have hpow : 256 ≤ 2 ^ k := by
            have : 2 ^ 8 ≤ 2 ^ k := Nat.pow_le_pow_right (by norm_num) (by omega)
            omega
          have : 128 / 2 ^ k = 0 := Nat.div_eq_of_lt (by omega)
          omega
        rw [h192_0, h128_0, Bool.and_false]
    rw [heq_bv]; rfl
  have hne : ¬(Pion.I32.band b1 192#i32 ≠ 128#i32) := not_not.mpr hband
  simp only [hne, ↓reduceIte]

private lemma ite_in_dfa_range (c : Prop) [Decidable c] (a b : Std.I32)
    (ha : -1 ≤ a.val ∧ a.val ≤ 7) (hb : -1 ≤ b.val ∧ b.val ≤ 7) :
    -1 ≤ (if c then a else b).val ∧ (if c then a else b).val ≤ 7 := by
  by_cases h : c
  · simp only [h, ↓reduceIte]; exact ha
  · simp only [h, ↓reduceIte]; exact hb

/-- RFC 3629 UTF-8 DFA: every transition produces a total result in `[-1, 7]`. -/
theorem utf8_dfa_state_bounds (st b : Std.I32) :
    ∃ r : Std.I32, utf8_dfa_step st b = ok r ∧ -1 ≤ r.val ∧ r.val ≤ 7 := by
  unfold utf8_dfa_step
  by_cases hneg : st < 0#i32
  · simp only [hneg, ↓reduceIte]
    exact ⟨(-1)#i32, rfl, by norm_num, by norm_num⟩
  · simp only [hneg, ↓reduceIte]
    refine ⟨_, rfl, ?_⟩
    apply ite_in_dfa_range
    · apply ite_in_dfa_range
      · exact ⟨by norm_num, by norm_num⟩
      · apply ite_in_dfa_range
        · exact ⟨by norm_num, by norm_num⟩
        · apply ite_in_dfa_range
          · exact ⟨by norm_num, by norm_num⟩
          · apply ite_in_dfa_range
            · exact ⟨by norm_num, by norm_num⟩
            · apply ite_in_dfa_range
              · exact ⟨by norm_num, by norm_num⟩
              · apply ite_in_dfa_range
                · exact ⟨by norm_num, by norm_num⟩
                · apply ite_in_dfa_range
                  · exact ⟨by norm_num, by norm_num⟩
                  · apply ite_in_dfa_range <;> exact ⟨by norm_num, by norm_num⟩
    · apply ite_in_dfa_range
      · apply ite_in_dfa_range <;> exact ⟨by norm_num, by norm_num⟩
      · apply ite_in_dfa_range
        · apply ite_in_dfa_range <;> exact ⟨by norm_num, by norm_num⟩
        · apply ite_in_dfa_range
          · apply ite_in_dfa_range <;> exact ⟨by norm_num, by norm_num⟩
          · apply ite_in_dfa_range
            · apply ite_in_dfa_range <;> exact ⟨by norm_num, by norm_num⟩
            · apply ite_in_dfa_range
              · apply ite_in_dfa_range <;> exact ⟨by norm_num, by norm_num⟩
              · apply ite_in_dfa_range
                · apply ite_in_dfa_range <;> exact ⟨by norm_num, by norm_num⟩
                · apply ite_in_dfa_range
                  · apply ite_in_dfa_range <;> exact ⟨by norm_num, by norm_num⟩
                  · exact ⟨by norm_num, by norm_num⟩

end WebsocketProofs
