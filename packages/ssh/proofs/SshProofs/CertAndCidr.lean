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

/-- Theorem 11: `cert_type_from_code ∘ cert_type_code = some` for both `User` and `Host`. -/
theorem cert_type_code_roundtrip (ct : CertType) :
    (do let c ← cert_type_code ct; cert_type_from_code c) = ok (some ct) := by
  cases ct <;> simp [cert_type_code, cert_type_from_code]

/-- Theorem 12: Any wire code accepted by `cert_type_from_code` re-encodes to the exact same uint32. -/
theorem cert_type_from_code_roundtrip (raw : U32) (ct : CertType)
    (h : cert_type_from_code raw = ok (some ct)) :
    cert_type_code ct = ok raw := by
  unfold cert_type_from_code at h
  split_ifs at h with h1 h2
  · have hct := Option.some.inj (result_ok_inj h); subst hct; rw [h1]; rfl
  · have hct := Option.some.inj (result_ok_inj h); subst hct; rw [h2]; rfl
  · exact absurd (result_ok_inj h) (by simp)

/-- Theorem 13: `cert_type_code` is injective. -/
theorem cert_type_code_injective (a b : CertType) (h : cert_type_code a = cert_type_code b) :
    a = b := by
  cases a <;> cases b <;> first | rfl | (unfold cert_type_code at h; exact absurd (result_ok_inj h) (by decide))

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

/-- Theorem 15: A certificate with `valid_before = UINT64_MAX` (forever) never expires once `now ≥ valid_after`. -/
theorem cert_time_valid_forever (now_unix valid_after : U64) (hle : valid_after.val ≤ now_unix.val) :
    cert_time_valid_code now_unix valid_after 18446744073709551615#u64 = ok 0#i32 := by
  rcases cert_time_valid_code_spec now_unix valid_after 18446744073709551615#u64 with ⟨r, hr, _, _, h0⟩
  rw [hr, h0.mpr ⟨hle, Or.inl rfl⟩]

/-- Theorem 16: Half-open validity boundary: for finite `valid_after < valid_before`, `valid_after` is valid (`0`) while `valid_before` is expired (`2`). -/
theorem cert_time_valid_half_open_boundary (valid_after valid_before : U64)
    (hfin : valid_before ≠ 18446744073709551615#u64)
    (hlt : valid_after.val < valid_before.val) :
    cert_time_valid_code valid_after valid_after valid_before = ok 0#i32 ∧
    cert_time_valid_code valid_before valid_after valid_before = ok 2#i32 := by
  constructor
  · rcases cert_time_valid_code_spec valid_after valid_after valid_before with ⟨r, hr, _, _, h0⟩
    rw [hr, h0.mpr ⟨by omega, Or.inr hlt⟩]
  · rcases cert_time_valid_code_spec valid_before valid_after valid_before with ⟨r, hr, _, h2, _⟩
    rw [hr, h2.mpr ⟨by omega, hfin, by omega⟩]

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

/-- Theorem 17: `cidr_rem_mask` produces the exact 7 non-empty CIDR partial-byte masks `0x80, 0xC0, 0xE0, 0xF0, 0xF8, 0xFC, 0xFE`. -/
theorem cidr_rem_mask_exact_values :
    cidr_rem_mask 1#i32 = ok 128#i32 ∧
    cidr_rem_mask 2#i32 = ok 192#i32 ∧
    cidr_rem_mask 3#i32 = ok 224#i32 ∧
    cidr_rem_mask 4#i32 = ok 240#i32 ∧
    cidr_rem_mask 5#i32 = ok 248#i32 ∧
    cidr_rem_mask 6#i32 = ok 252#i32 ∧
    cidr_rem_mask 7#i32 = ok 254#i32 := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals
    unfold cidr_rem_mask Pion.I32.shl
    split_ifs with h
    · rw [result_bind_ok]
      apply congrArg ok
      decide
    · exact absurd (by decide) h

/-- Theorem 18: `cidr_byte_match` is reflexive for all `rem_bits ∈ [1, 7]`. -/
theorem cidr_byte_match_refl (x rem_bits : I32) (h1 : 1 ≤ rem_bits.val) (h7 : rem_bits.val ≤ 7) :
    cidr_byte_match x x rem_bits = ok true := by
  rcases cidr_rem_mask_eval rem_bits h1 h7 with ⟨m, hm⟩
  unfold cidr_byte_match
  rw [hm, result_bind_ok]
  exact congrArg ok (beq_self_eq_true _)

/-- Theorem 19: `cidr_byte_match` is symmetric for all `rem_bits ∈ [1, 7]`. -/
theorem cidr_byte_match_symm (x y rem_bits : I32) (h1 : 1 ≤ rem_bits.val) (h7 : rem_bits.val ≤ 7) :
    cidr_byte_match x y rem_bits = cidr_byte_match y x rem_bits := by
  rcases cidr_rem_mask_eval rem_bits h1 h7 with ⟨m, hm⟩
  unfold cidr_byte_match
  rw [hm, result_bind_ok, result_bind_ok]
  apply congrArg ok
  apply Bool.eq_iff_iff.mpr
  simp only [beq_iff_eq]
  exact eq_comm

/-- Theorem 20: `cidr_byte_match` is transitive for all `rem_bits ∈ [1, 7]` (hence an equivalence relation on bytes). -/
theorem cidr_byte_match_trans (x y z rem_bits : I32)
    (h1 : 1 ≤ rem_bits.val) (h7 : rem_bits.val ≤ 7)
    (hxy : cidr_byte_match x y rem_bits = ok true)
    (hyz : cidr_byte_match y z rem_bits = ok true) :
    cidr_byte_match x z rem_bits = ok true := by
  rcases cidr_rem_mask_eval rem_bits h1 h7 with ⟨m, hm⟩
  unfold cidr_byte_match at hxy hyz ⊢
  rw [hm, result_bind_ok] at hxy hyz ⊢
  have h1' : Pion.I32.band (Pion.I32.band x 255#i32) m = Pion.I32.band (Pion.I32.band y 255#i32) m :=
    beq_iff_eq.mp (result_ok_inj hxy)
  have h2' : Pion.I32.band (Pion.I32.band y 255#i32) m = Pion.I32.band (Pion.I32.band z 255#i32) m :=
    beq_iff_eq.mp (result_ok_inj hyz)
  rw [h1', h2']
  exact congrArg ok (beq_self_eq_true _)

end SshProofs
