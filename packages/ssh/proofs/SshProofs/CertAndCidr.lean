import Aeneas
import PionLean
import Ssh.Types
import Ssh.Funs

open Aeneas Aeneas.Std Result Pion ssh

namespace SshProofs

private lemma result_ok_inj {α : Type} {a b : α} (h : (ok a : Result α) = ok b) : a = b := by
  simpa using h

private lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by
  simp

/-- Theorem 12: Any wire code accepted by `cert_type_from_code` re-encodes to the exact same uint32. -/
theorem cert_type_from_code_roundtrip (raw : U32) (ct : CertType)
    (h : cert_type_from_code raw = ok (some ct)) :
    cert_type_code ct = ok raw := by
  unfold cert_type_from_code at h
  split_ifs at h with h1 h2
  · have hct := Option.some.inj (result_ok_inj h); subst hct; rw [h1]; rfl
  · have hct := Option.some.inj (result_ok_inj h); subst hct; rw [h2]; rfl
  · exact absurd (result_ok_inj h) (by simp)

/-- Theorem 14: `cert_time_valid_code` implements exact OpenSSH `PROTOCOL.certkeys` `[valid_after, valid_before)` semantics with `UINT64_MAX` = forever. -/
theorem cert_time_valid_code_spec (now_unix valid_after valid_before : U64) :
    ∃ r, cert_time_valid_code now_unix valid_after valid_before = ok r ∧
      (r = 1#i32 ↔ now_unix.val < valid_after.val) ∧
      (r = 2#i32 ↔ (valid_after.val ≤ now_unix.val ∧
                    valid_before ≠ 18446744073709551615#u64 ∧
                    valid_before.val ≤ now_unix.val)) ∧
      (r = 0#i32 ↔ (valid_after.val ≤ now_unix.val ∧
                    (valid_before = 18446744073709551615#u64 ∨ now_unix.val < valid_before.val))) := by
  unfold cert_time_valid_code
  refine ⟨_, rfl, ?_, ?_, ?_⟩
  · by_cases h1 : now_unix < valid_after
    · simp only [h1, ↓reduceIte, true_iff]; exact h1
    · simp only [h1, ↓reduceIte]
      have hge : ¬(now_unix.val < valid_after.val) := h1
      simp only [hge, iff_false]
      split_ifs <;> decide
  · by_cases h1 : now_unix < valid_after
    · simp only [h1, ↓reduceIte]
      have hlt : now_unix.val < valid_after.val := h1
      constructor
      · intro h; cases h
      · intro ⟨hge, _⟩; omega
    · simp only [h1, ↓reduceIte]
      have hge : valid_after.val ≤ now_unix.val := by
        have : ¬(now_unix.val < valid_after.val) := h1; omega
      by_cases h2 : ((valid_before != 18446744073709551615#u64) && (decide (now_unix >= valid_before))) = true
      · simp only [h2, ↓reduceIte, true_iff]
        simp only [Bool.and_eq_true, bne_iff_ne, decide_eq_true_eq] at h2
        exact ⟨hge, h2.1, h2.2⟩
      · have h2f : ((valid_before != 18446744073709551615#u64) && (decide (now_unix >= valid_before))) = false :=
          Bool.eq_false_iff.mpr h2
        simp only [h2f, Bool.false_eq_true, ↓reduceIte]
        constructor
        · intro h; cases h
        · intro ⟨_, hne, hge2⟩
          exfalso; apply h2
          simp only [Bool.and_eq_true, bne_iff_ne, decide_eq_true_eq]
          exact ⟨hne, hge2⟩
  · by_cases h1 : now_unix < valid_after
    · simp only [h1, ↓reduceIte]
      have hlt : now_unix.val < valid_after.val := h1
      constructor
      · intro h; cases h
      · intro ⟨hge, _⟩; omega
    · simp only [h1, ↓reduceIte]
      have hge : valid_after.val ≤ now_unix.val := by
        have : ¬(now_unix.val < valid_after.val) := h1; omega
      by_cases h2 : ((valid_before != 18446744073709551615#u64) && (decide (now_unix >= valid_before))) = true
      · simp only [h2, ↓reduceIte]
        simp only [Bool.and_eq_true, bne_iff_ne, decide_eq_true_eq] at h2
        have hge2 : valid_before.val ≤ now_unix.val := h2.2
        constructor
        · intro h; cases h
        · intro ⟨_, hor⟩
          rcases hor with rfl | hlt2
          · exact absurd rfl h2.1
          · omega
      · have h2f : ((valid_before != 18446744073709551615#u64) && (decide (now_unix >= valid_before))) = false :=
          Bool.eq_false_iff.mpr h2
        simp only [h2f, Bool.false_eq_true, ↓reduceIte, true_iff]
        refine ⟨hge, ?_⟩
        by_cases hinf : valid_before = 18446744073709551615#u64
        · exact Or.inl hinf
        · right
          by_contra hlt2
          apply h2
          simp only [Bool.and_eq_true, bne_iff_ne, decide_eq_true_eq]
          exact ⟨hinf, by show valid_before.val ≤ now_unix.val; omega⟩

private lemma cidr_rem_mask_eval (k : I32) (hk : 1 ≤ k.val) (hk7 : k.val ≤ 7) :
    ∃ m, cidr_rem_mask k = ok m := by
  unfold cidr_rem_mask
  have hsub_val : (Pion.I32.sub 8#i32 k).val = 8 - k.val := by
    have hwrap : (Pion.I32.sub 8#i32 k).val = Int.bmod ((8#i32 : I32).val - k.val) (2 ^ 32) := by
      change (I32.wrapping_sub 8#i32 k).val = Int.bmod ((8#i32 : I32).val - k.val) (2 ^ 32)
      simp only [I32.wrapping_sub, IScalar.wrapping_sub, IScalar.val, BitVec.toInt_sub]
      rfl
    have c8 : (8#i32 : I32).val = 8 := rfl
    rw [hwrap, c8]
    exact Int.bmod_eq_of_le (by omega) (by omega)
  have hshl : Pion.I32.shl 255#i32 (Pion.I32.sub 8#i32 k) =
      ok (⟨(255#i32 : I32).bv <<< (Pion.I32.sub 8#i32 k).val.toNat⟩ : I32) := by
    unfold Pion.I32.shl
    have hcond : 0 ≤ (Pion.I32.sub 8#i32 k).val ∧ (Pion.I32.sub 8#i32 k).val < 32 := by omega
    simp only [hcond, and_self, ↓reduceIte]
  rw [hshl, result_bind_ok]
  exact ⟨_, rfl⟩

end SshProofs
