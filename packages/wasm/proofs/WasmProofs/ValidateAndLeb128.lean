import Aeneas
import PionLean
import Wasm.Types
import Wasm.Funs

open Aeneas Aeneas.Std Result Pion wasm

namespace WasmProofs

private lemma result_ok_inj {α : Type} {a b : α} (h : (ok a : Result α) = ok b) : a = b := by
  simpa using h

private lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by
  simp

private lemma i32_ofNat_val_lt256 (n : Nat) (hn : n < 256) :
    (⟨BitVec.ofNat 32 n⟩ : I32).val = (n : Int) := by
  change (BitVec.ofNat 32 n).toInt = (n : Int)
  rw [BitVec.toInt_eq_toNat_cond, BitVec.toNat_ofNat]
  have hmod : n % 2 ^ 32 = n := Nat.mod_eq_of_lt (by omega)
  rw [hmod]
  simp only [show 2 * n < 2 ^ 32 by omega, ↓reduceIte]

private lemma i32_eq_of_nonneg_lt256 (b : I32) (hlo : 0 ≤ b.val) (hhi : b.val < 256) :
    ∃ hi lo : Fin 16, b = ⟨BitVec.ofNat 32 (hi.val * 16 + lo.val)⟩ := by
  refine ⟨⟨b.val.toNat / 16, by omega⟩, ⟨b.val.toNat % 16, by omega⟩, ?_⟩
  apply IScalar.eq_of_val_eq
  have hrec : b.val.toNat / 16 * 16 + b.val.toNat % 16 = b.val.toNat := by omega
  rw [hrec, i32_ofNat_val_lt256 b.val.toNat (by omega)]
  omega

/-- Theorem 14: `stack_type_compat` is symmetric. -/
theorem stack_type_compat_symm (a b : I32) :
    stack_type_compat a b = stack_type_compat b a := by
  unfold stack_type_compat
  apply congrArg ok
  apply Bool.eq_iff_iff.mpr
  simp only [Bool.or_eq_true, beq_iff_eq]
  tauto

/-- Theorem 16: For concrete (non-unknown) stack types, `stack_type_compat` holds iff they are equal. -/
theorem stack_type_compat_concrete_iff (a b : I32) (ha : a ≠ (-1)#i32) (hb : b ≠ (-1)#i32) :
    stack_type_compat a b = ok true ↔ a = b := by
  unfold stack_type_compat
  constructor
  · intro h
    have h1 := result_ok_inj h
    simp only [Bool.or_eq_true, beq_iff_eq] at h1
    rcases h1 with (heq | hna) | hnb
    · exact heq
    · exact absurd hna ha
    · exact absurd hnb hb
  · intro h; subst h; simp

/-- Theorem 17: `limits_err_code` returns `0` iff `lim` satisfies all WebAssembly 2.0 §3.2.5 limits constraints. -/
theorem limits_err_code_valid_iff (lim : Limits) (max_allowed : I64) :
    limits_err_code lim max_allowed = ok 0#i32 ↔
      (lim.shared = false ∧ lim.is_memory64 = false ∧
       0 ≤ lim.min.val ∧ lim.min.val ≤ max_allowed.val ∧
       (∀ mx, lim.max = some mx → lim.min.val ≤ mx.val ∧ mx.val ≤ max_allowed.val)) := by
  unfold limits_err_code
  cases hsh : lim.shared
  · simp only [Bool.false_eq_true, ↓reduceIte]
    cases hm64 : lim.is_memory64
    · simp only [Bool.false_eq_true, ↓reduceIte]
      by_cases hneg : lim.min < 0#i64
      · simp only [hneg, ↓reduceIte]
        have hlt : lim.min.val < 0 := hneg
        constructor
        · intro h; exact absurd (result_ok_inj h) (by decide)
        · intro ⟨_, _, hge, _, _⟩; omega
      · simp only [hneg, ↓reduceIte]
        have hge0 : 0 ≤ lim.min.val := by change ¬(lim.min.val < 0) at hneg; omega
        by_cases hgt : lim.min > max_allowed
        · simp only [hgt, ↓reduceIte]
          have hgtv : max_allowed.val < lim.min.val := hgt
          constructor
          · intro h; exact absurd (result_ok_inj h) (by decide)
          · intro ⟨_, _, _, hle, _⟩; omega
        · simp only [hgt, ↓reduceIte]
          have hle : lim.min.val ≤ max_allowed.val := by
            change ¬(max_allowed.val < lim.min.val) at hgt; omega
          cases hmax : lim.max with
          | none =>
            simp only [true_and, hge0, hle, reduceCtorEq, false_implies, implies_true]
          | some mx =>
            dsimp only
            by_cases hmx_lt : mx < lim.min
            · simp only [hmx_lt, ↓reduceIte]
              have hltv : mx.val < lim.min.val := hmx_lt
              constructor
              · intro h; exact absurd (result_ok_inj h) (by decide)
              · intro ⟨_, _, _, _, hall⟩
                have := (hall mx rfl).1; omega
            · simp only [hmx_lt, ↓reduceIte]
              have hmx_ge : lim.min.val ≤ mx.val := by
                change ¬(mx.val < lim.min.val) at hmx_lt; omega
              by_cases hmx_gt : mx > max_allowed
              · simp only [hmx_gt, ↓reduceIte]
                have hgtv : max_allowed.val < mx.val := hmx_gt
                constructor
                · intro h; exact absurd (result_ok_inj h) (by decide)
                · intro ⟨_, _, _, _, hall⟩
                  have := (hall mx rfl).2; omega
              · simp only [hmx_gt, ↓reduceIte]
                have hmx_le : mx.val ≤ max_allowed.val := by
                  change ¬(max_allowed.val < mx.val) at hmx_gt; omega
                constructor
                · intro _
                  refine ⟨trivial, trivial, hge0, hle, ?_⟩
                  intro mx' hEq
                  cases hEq
                  exact ⟨hmx_ge, hmx_le⟩
                · intro _; trivial
    · simp only [↓reduceIte]
      constructor
      · intro h; exact absurd (result_ok_inj h) (by decide)
      · intro ⟨_, hm, _⟩; exact absurd hm (by decide)
  · simp only [↓reduceIte]
    constructor
    · intro h; exact absurd (result_ok_inj h) (by decide)
    · intro ⟨hs, _⟩; exact absurd hs (by decide)

/-- Theorem 19: `leb128_i32_single_byte` decodes every 7-bit byte `b ∈ [0, 127]` into `[-64, 63]`. -/
theorem leb128_i32_single_byte_range (b : I32) (hlo : 0 ≤ b.val) (hhi : b.val < 128) :
    ∃ v, leb128_i32_single_byte b = ok v ∧ -64 ≤ v.val ∧ v.val ≤ 63 := by
  rcases i32_eq_of_nonneg_lt256 b hlo (by omega) with ⟨hi, lo, rfl⟩
  have hlt : hi.val * 16 + lo.val < 128 := by
    have hv := i32_ofNat_val_lt256 (hi.val * 16 + lo.val) (by omega)
    omega
  unfold leb128_i32_single_byte
  refine ⟨_, rfl, ?_⟩
  have hdec : ∀ a c : Fin 16, a.val * 16 + c.val < 128 →
      let x : I32 := ⟨BitVec.ofNat 32 (a.val * 16 + c.val)⟩
      let v : I32 := if Pion.I32.band x 64#i32 ≠ 0#i32 then Pion.I32.sub x 128#i32 else x;
      -64 ≤ v.val ∧ v.val ≤ 63 := by
    decide
  exact hdec hi lo hlt

/-- Theorem 20: `leb128_u32_5th_valid` accepts exactly `b ∈ [0, 15]` (4-bit payload, bit 7 = 0). -/
theorem leb128_u32_5th_valid_iff (b : I32) :
    leb128_u32_5th_valid b = ok true ↔ (0 ≤ b.val ∧ b.val < 16) := by
  unfold leb128_u32_5th_valid
  constructor
  · intro h
    have h1 := result_ok_inj h
    simp only [Bool.and_eq_true, decide_eq_true_eq] at h1
    exact ⟨h1.1, h1.2⟩
  · intro ⟨h0, h16⟩
    apply congrArg ok
    simp only [Bool.and_eq_true, decide_eq_true_eq]
    exact ⟨h0, h16⟩

/-- Theorem 22: `leb128_i32_5th_valid` accepts a byte `b ∈ [0, 255]` iff `b ∈ [0x00, 0x07]` (positive) or `b ∈ [0x78, 0x7F]` (negative sign-extended) per Wasm 2.0 §5.2.2. -/
theorem leb128_i32_5th_valid_exact (b : I32) (hlo : 0 ≤ b.val) (hhi : b.val < 256) :
    leb128_i32_5th_valid b = ok true ↔ ((0 ≤ b.val ∧ b.val ≤ 7) ∨ (120 ≤ b.val ∧ b.val ≤ 127)) := by
  rcases i32_eq_of_nonneg_lt256 b hlo hhi with ⟨hi, lo, rfl⟩
  have hdec : ∀ a c : Fin 16,
      let x : I32 := ⟨BitVec.ofNat 32 (a.val * 16 + c.val)⟩
      (if Pion.I32.band x 128#i32 ≠ 0#i32 then false
       else
         let sign_bit := Pion.I32.band x 8#i32 != 0#i32
         let high := Pion.I32.band x 112#i32
         (!sign_bit && (high == 0#i32)) || (sign_bit && (high == 112#i32))) = true ↔
      ((0 ≤ x.val ∧ x.val ≤ 7) ∨ (120 ≤ x.val ∧ x.val ≤ 127)) := by
    decide
  have hm := hdec hi lo
  dsimp only at hm
  unfold leb128_i32_5th_valid
  split_ifs at hm ⊢
  · constructor
    · intro h; exact absurd (result_ok_inj h) (by decide)
    · intro h; exact absurd (hm.mpr h) (by decide)
  · constructor
    · intro h; exact hm.mp (result_ok_inj h)
    · intro h; exact congrArg ok (hm.mpr h)

end WasmProofs
