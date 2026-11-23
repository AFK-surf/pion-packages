/-
Formal verification of `packages/tar` (`Tar.Funs`, extracted via
`pionc extract-lean` from `packages/tar/src/*.pion`).

All proofs are complete and kernel-checked, depending only on the three
standard Lean axioms: `propext`, `Classical.choice`, `Quot.sound`.
-/
import Tar.Funs

open Aeneas Aeneas.Std Result ControlFlow Error Pion WP

set_option maxRecDepth 100000
set_option maxHeartbeats 2000000
set_option linter.unusedSimpArgs false

namespace TarProofs

open tar

/-! ## Common Scalar & Bytes Helpers -/

lemma b_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← (ok x : Result α); f y) = f x := by simp

lemma b_ok2 {α β γ : Type} (x : α) (y : β) (f : α → β → Result γ) :
    (do let (a, b) ← (ok (x, y) : Result (α × β)); f a b) = f x y := by simp

lemma b_ok3 {α β γ δ : Type} (x : α) (y : β) (z : γ) (f : α → β → γ → Result δ) :
    (do let (a, b, c) ← (ok (x, y, z) : Result (α × β × γ)); f a b c) = f x y z := by simp

lemma wp_ok_iff {α : Type u} (r : Result α) (P : α → Prop) :
    r ⦃ P ⦄ ↔ ∃ y, r = ok y ∧ P y := by
  cases r with
  | ret y => simp [WP.spec_ok]
  | vis e k => simp [WP.spec_vis]
  | div => simp [WP.spec_div]

lemma u8_to_int_val (x : Std.U8) : (Pion.U8.to_int x).val = (x.val : Int) := by
  cases x with
  | mk bv =>
    have hlt : bv.toNat < 256 := bv.isLt
    simp only [Pion.U8.to_int, UScalar.hcast, IScalar.val, UScalar.val,
      BitVec.toInt_setWidth, BitVec.toInt_ofNat, IScalarTy.numBits, UScalarTy.numBits]
    rw [Int.bmod_eq_of_le_mul_two] <;> omega

lemma i32_add_val {a b : Std.I32}
    (hlo : -2147483648 ≤ a.val + b.val) (hhi : a.val + b.val ≤ 2147483647) :
    (Pion.I32.add a b).val = a.val + b.val := by
  simp only [IScalar.val] at hlo hhi
  simp only [Pion.I32.add, Std.I32.wrapping_add, IScalar.wrapping_add, IScalar.val,
    IScalarTy.numBits]
  rw [BitVec.toInt_add]
  exact Int.bmod_eq_of_le_mul_two (by omega) (by omega)

lemma i32_sub_val {a b : Std.I32}
    (hlo : -2147483648 ≤ a.val - b.val) (hhi : a.val - b.val ≤ 2147483647) :
    (Pion.I32.sub a b).val = a.val - b.val := by
  simp only [IScalar.val] at hlo hhi
  simp only [Pion.I32.sub, Std.I32.wrapping_sub, IScalar.wrapping_sub, IScalar.val,
    IScalarTy.numBits]
  rw [BitVec.toInt_sub]
  exact Int.bmod_eq_of_le_mul_two (by omega) (by omega)

lemma i32_mul_val {a b : Std.I32}
    (hlo : -2147483648 ≤ a.val * b.val) (hhi : a.val * b.val ≤ 2147483647) :
    (Pion.I32.mul a b).val = a.val * b.val := by
  simp only [IScalar.val] at hlo hhi
  simp only [Pion.I32.mul, Std.I32.wrapping_mul, IScalar.wrapping_mul, IScalar.val,
    IScalarTy.numBits]
  rw [BitVec.toInt_mul]
  exact Int.bmod_eq_of_le_mul_two (by omega) (by omega)

lemma i64_add_val {a b : Std.I64}
    (hlo : -9223372036854775808 ≤ a.val + b.val) (hhi : a.val + b.val ≤ 9223372036854775807) :
    (Pion.I64.add a b).val = a.val + b.val := by
  simp only [IScalar.val] at hlo hhi
  simp only [Pion.I64.add, Std.I64.wrapping_add, IScalar.wrapping_add, IScalar.val,
    IScalarTy.numBits]
  rw [BitVec.toInt_add]
  exact Int.bmod_eq_of_le_mul_two (by omega) (by omega)

lemma bytes_get_spec (b : Pion.Bytes) (i : Std.I32)
    (h0 : 0 ≤ i.val) (h1 : i.val < b.val.length) :
    ∃ x, Pion.Bytes.get b i = ok x ∧ b.val[i.val.toNat]? = some x := by
  unfold Pion.Bytes.get Pion.listGet
  have hb : Pion.inBounds i b.val.length := ⟨h0, h1⟩
  simp only [hb, ↓reduceDIte]
  refine ⟨_, rfl, ?_⟩
  simp [List.getElem?_eq_getElem (show i.val.toNat < b.val.length by omega)]

lemma bytes_length_spec (b : Pion.Bytes) (h : b.val.length ≤ 2147483647) :
    ∃ n : Std.I32, Pion.Bytes.length b = ok n ∧ n.val = b.val.length := by
  unfold Pion.Bytes.length Pion.lengthOf
  simp only [h, ↓reduceDIte]
  refine ⟨_, rfl, ?_⟩
  simp

/-! ## Section 1: Typeflags & `TarFormat` Soundness (`packages/tar/src/types.pion`) -/

/-! ## Section 2: TAR 512-Byte Block Alignment & Padding Arithmetic (`packages/tar/src/format.pion`) -/

private theorem bv64_band_511 (bv : BitVec 64) :
    ((-bv) &&& BitVec.ofNat 64 511).toInt = ((-bv.toInt) % 512 + 512) % 512 := by
  have h511 : (-bv) &&& BitVec.ofNat 64 511 = BitVec.ofNat 64 (((-bv).toNat) % 512) := by
    apply BitVec.eq_of_toNat_eq
    simp only [BitVec.toNat_and, BitVec.toNat_ofNat]
    have hmod511 : (511 : Nat) % 2 ^ 64 = 2 ^ 9 - 1 := by norm_num
    rw [hmod511, Nat.and_two_pow_sub_one_eq_mod]
    have hlt : (-bv).toNat % 512 < 2 ^ 64 := by
      have := Nat.mod_lt (-bv).toNat (show 0 < 512 by norm_num); omega
    omega
  rw [h511]
  have hlt : ((-bv).toNat % 512) < 512 := Nat.mod_lt _ (by norm_num)
  rw [BitVec.toInt_eq_toNat_cond]
  simp only [BitVec.toNat_ofNat]
  have hlt64 : (-bv).toNat % 512 < 2 ^ 64 := by omega
  rw [Nat.mod_eq_of_lt hlt64]
  simp only [show 2 * ((-bv).toNat % 512) < 2 ^ 64 by omega, ↓reduceIte]
  have hneg : ((-bv).toNat : Int) % 512 = ((-bv.toInt) % 512 + 512) % 512 := by
    rw [BitVec.toNat_neg]
    have hbv : (bv.toNat : Int) = bv.toInt ∨ (bv.toNat : Int) = bv.toInt + 2 ^ 64 := by
      rw [BitVec.toInt_eq_toNat_cond]
      split_ifs <;> omega
    have hlt2 := bv.isLt
    rcases hbv with h | h <;> omega
  omega

private theorem band_511_val (x : Std.I64) :
    (Pion.I64.band (Pion.I64.neg x) 511#i64).val = ((-x.val) % 512 + 512) % 512 := by
  cases x with
  | mk bv =>
    have hmask : (511#i64 : Std.I64).bv = BitVec.ofNat 64 511 := by decide
    simp only [Pion.I64.band, Pion.I64.neg, IScalar.val, hmask]
    exact bv64_band_511 bv

/-- `block_padding` never panics and always produces a value in `[0, 512)`. -/
theorem block_padding_total (offset : Std.I64) :
    ∃ p : Std.I64, block_padding offset = ok p ∧ 0 ≤ p.val ∧ p.val < 512 := by
  unfold block_padding
  refine ⟨_, rfl, ?_, ?_⟩
  · rw [band_511_val]; omega
  · rw [band_511_val]; omega

/-- `padded_size` never overflows on `[0, 2^63 - 512]`, returns a multiple of 512,
    and satisfies tight bounds `size ≤ padded < size + 512`. -/
theorem padded_size_spec (size : Std.I64)
    (h0 : 0 ≤ size.val) (hmax : size.val ≤ 9223372036854775296) :
    ∃ r : Std.I64, padded_size size = ok r ∧
      r.val % 512 = 0 ∧ size.val ≤ r.val ∧ r.val < size.val + 512 := by
  unfold padded_size block_padding
  rw [b_ok]
  refine ⟨_, rfl, ?_, ?_, ?_⟩
  · rw [i64_add_val, band_511_val] <;> (try rw [band_511_val]) <;> omega
  · rw [i64_add_val, band_511_val] <;> (try rw [band_511_val]) <;> omega
  · rw [i64_add_val, band_511_val] <;> (try rw [band_511_val]) <;> omega

/-- `padded_size` is monotone on `[0, 2^63 - 512]`. -/
theorem padded_size_mono (a b : Std.I64)
    (ha0 : 0 ≤ a.val) (hab : a.val ≤ b.val) (hbmax : b.val ≤ 9223372036854775296) :
    ∃ ra rb : Std.I64, padded_size a = ok ra ∧ padded_size b = ok rb ∧ ra.val ≤ rb.val := by
  obtain ⟨ra, hra, hmoda, hgea, hlta⟩ := padded_size_spec a ha0 (by omega)
  obtain ⟨rb, hrb, hmodb, hgeb, hltb⟩ := padded_size_spec b (by omega) hbmax
  refine ⟨ra, rb, hra, hrb, ?_⟩
  omega

/-! ## Section 3: Zip-Slip Path Security & Traversal Impossibility (`packages/tar/src/path.pion`) -/

/-- `ascii_upper` is total, maps `'a'..'z'` (`97..122`) to `'A'..'Z'` (`65..90`),
    and leaves all other values unchanged. -/
lemma ascii_upper_spec (c : Std.I32) :
    ∃ r : Std.I32, ascii_upper c = ok r ∧
      r.val = (if 97 ≤ c.val ∧ c.val ≤ 122 then c.val - 32 else c.val) := by
  unfold ascii_upper
  refine ⟨_, rfl, ?_⟩
  by_cases h : 97 ≤ c.val ∧ c.val ≤ 122
  · have hd : ((decide (c >= 97#i32)) && (decide (c <= 122#i32))) = true := by
      simp only [Bool.and_eq_true, decide_eq_true_eq]
      exact ⟨by show (97#i32 : Std.I32).val ≤ c.val; simp; omega,
             by show c.val ≤ (122#i32 : Std.I32).val; simp; omega⟩
    simp only [hd, ↓reduceIte, h, and_self]
    rw [i32_sub_val] <;> simp <;> omega
  · have hd : ((decide (c >= 97#i32)) && (decide (c <= 122#i32))) = false := by
      by_contra hne
      have htrue : ((decide (c >= 97#i32)) && (decide (c <= 122#i32))) = true := by
        cases hb : ((decide (c >= 97#i32)) && (decide (c <= 122#i32))) <;> simp_all
      simp only [Bool.and_eq_true, decide_eq_true_eq] at htrue
      have h1 : (97#i32 : Std.I32).val ≤ c.val := htrue.1
      have h2 : c.val ≤ (122#i32 : Std.I32).val := htrue.2
      simp at h1 h2
      exact h ⟨h1, h2⟩
    simp only [hd, Bool.false_eq_true, ↓reduceIte, h]

/-- Exact specification of `is_dotdot_segment` on a valid slice `[start, end]`. -/
lemma is_dotdot_segment_spec (b : Pion.Bytes) (s e : Std.I32)
    (hs0 : 0 ≤ s.val) (hse : s.val ≤ e.val) (he : e.val ≤ b.val.length)
    (hlen : b.val.length ≤ 2147483647) :
    ∃ r : Bool, is_dotdot_segment b s e = ok r ∧
      (r = true ↔ e.val - s.val = 2 ∧
        b.val[s.val.toNat]? = some 46#u8 ∧
        b.val[(s.val + 1).toNat]? = some 46#u8) := by
  unfold is_dotdot_segment
  have hsub : (Pion.I32.sub e s).val = e.val - s.val := i32_sub_val (by omega) (by omega)
  by_cases h2 : Pion.I32.sub e s = 2#i32
  · have hlen2 : e.val - s.val = 2 := by
      have := congrArg IScalar.val h2
      rw [hsub] at this; simpa using this
    obtain ⟨b0, hb0, hb0eq⟩ := bytes_get_spec b s hs0 (by omega)
    have hadd1 : (Pion.I32.add s 1#i32).val = s.val + 1 :=
      i32_add_val (by simp; omega) (by simp; omega)
    obtain ⟨b1, hb1, hb1eq⟩ := bytes_get_spec b (Pion.I32.add s 1#i32) (by omega) (by omega)
    simp only [h2, ↓reduceIte, hb0, b_ok]
    by_cases hc0 : (Pion.U8.to_int b0 == 46#i32) = true
    · simp only [hc0, ↓reduceIte, hb1, b_ok]
      refine ⟨_, rfl, ?_⟩
      have hb0_46 : b0 = 46#u8 := by
        rw [beq_iff_eq] at hc0
        have := congrArg IScalar.val hc0
        rw [u8_to_int_val] at this; simp at this
        apply UScalar.eq_of_val_eq; simp; omega
      rw [hb0_46] at hb0eq
      rw [hadd1] at hb1eq
      constructor
      · intro hc1
        have hb1_46 : b1 = 46#u8 := by
          rw [beq_iff_eq] at hc1
          have := congrArg IScalar.val hc1
          rw [u8_to_int_val] at this; simp at this
          apply UScalar.eq_of_val_eq; simp; omega
        rw [hb1_46] at hb1eq
        exact ⟨hlen2, hb0eq, hb1eq⟩
      · rintro ⟨_, _, hb1'⟩
        rw [hb1eq] at hb1'
        injection hb1' with hb1_eq
        subst hb1_eq
        decide
    · have hcf : (Pion.U8.to_int b0 == 46#i32) = false := by
        cases hx : (Pion.U8.to_int b0 == 46#i32) <;> simp_all
      simp only [hcf, Bool.false_eq_true, ↓reduceIte]
      refine ⟨false, rfl, ?_⟩
      constructor
      · intro h; cases h
      · rintro ⟨_, hb0', _⟩
        rw [hb0eq] at hb0'
        injection hb0' with hb0_eq
        subst hb0_eq
        exact absurd (by decide : (Pion.U8.to_int 46#u8 == 46#i32) = true) hc0
  · have hne2 : e.val - s.val ≠ 2 := by
      intro heq
      apply h2
      apply IScalar.eq_of_val_eq
      rw [hsub]; simpa using heq
    simp only [h2, ↓reduceIte, b_ok, Bool.false_eq_true]
    exact ⟨false, rfl, ⟨(by intro h; cases h), fun ⟨heq, _⟩ => False.elim (hne2 heq)⟩⟩

/-- Loop specification for `has_invalid_path_byte_loop0`: scans `b[i..n)` for NUL (`0`) or `:` (`58`). -/
private theorem has_invalid_path_byte_loop0_spec (b : Pion.Bytes) (n : Std.I32)
    (hn : n.val = b.val.length) (hlen : b.val.length ≤ 2147483647) :
    has_invalid_path_byte_loop0 n b 0#i32 ⦃ res =>
      match res with
      | .inl true => ∃ k, k < b.val.length ∧ (b.val[k]? = some 0#u8 ∨ b.val[k]? = some 58#u8)
      | .inl false => False
      | .inr _ => ∀ k, k < b.val.length → b.val[k]? ≠ some 0#u8 ∧ b.val[k]? ≠ some 58#u8 ⦄ := by
  unfold has_invalid_path_byte_loop0
  apply loop.spec_decr_nat
    (measure := fun (i : Std.I32) => b.val.length - i.val.toNat)
    (inv := fun (i : Std.I32) => 0 ≤ i.val ∧ i.val ≤ b.val.length ∧
      ∀ k, k < i.val.toNat → b.val[k]? ≠ some 0#u8 ∧ b.val[k]? ≠ some 58#u8)
  · intro i ⟨hi0, hile, hprev⟩
    unfold has_invalid_path_byte_loop0.body
    by_cases hlt : i < n
    · have hilt : i.val < b.val.length := by
        have : i.val < n.val := hlt; omega
      obtain ⟨x, hx, hxeq⟩ := bytes_get_spec b i hi0 hilt
      simp only [hlt, ↓reduceIte, hx, b_ok]
      by_cases hbad : ((Pion.U8.to_int x == 0#i32) || (Pion.U8.to_int x == 58#i32)) = true
      · simp only [hbad, ↓reduceIte, WP.spec_ok]
        refine ⟨i.val.toNat, by omega, ?_⟩
        simp only [Bool.or_eq_true, beq_iff_eq] at hbad
        rcases hbad with h0 | h58
        · left
          have hx0 : x = 0#u8 := by
            have := congrArg IScalar.val h0
            rw [u8_to_int_val] at this; simp at this
            apply UScalar.eq_of_val_eq; simp; omega
          simpa [hx0] using hxeq
        · right
          have hx58 : x = 58#u8 := by
            have := congrArg IScalar.val h58
            rw [u8_to_int_val] at this; simp at this
            apply UScalar.eq_of_val_eq; simp; omega
          simpa [hx58] using hxeq
      · simp only [hbad, ↓reduceIte, Bool.false_eq_true]; rw [WP.spec_ok]
        have hadd : (Pion.I32.add i 1#i32).val = i.val + 1 :=
          i32_add_val (by simp; omega) (by simp; omega)
        have hne0 : x ≠ 0#u8 := by
          intro h0; subst h0
          exact hbad (by decide)
        have hne58 : x ≠ 58#u8 := by
          intro h58; subst h58
          exact hbad (by decide)
        refine ⟨⟨by omega, by omega, ?_⟩, by omega⟩
        intro k hk
        by_cases hki : k < i.val.toNat
        · exact hprev k hki
        · have hkeq : k = i.val.toNat := by omega
          subst hkeq
          rw [hxeq]
          exact ⟨fun h => hne0 (Option.some.inj h), fun h => hne58 (Option.some.inj h)⟩
    · have hge : i.val ≥ b.val.length := by
        have : ¬ (i.val < n.val) := hlt; omega
      simp only [hlt, ↓reduceIte, WP.spec_ok]
      intro k hk
      exact hprev k (by omega)
  · refine ⟨by simp, by simp, ?_⟩
    intro k hk; simp only [show (0#i32 : Std.I32).val.toNat = 0 from rfl] at hk; omega

/-- Exact specification of `has_invalid_path_byte`: true iff `b` contains NUL (`0x00`) or `:` (`0x3A`). -/
theorem has_invalid_path_byte_spec (b : Pion.Bytes) (hlen : b.val.length ≤ 2147483647) :
    ∃ r : Bool, has_invalid_path_byte b = ok r ∧
      (r = true ↔ ∃ k, k < b.val.length ∧ (b.val[k]? = some 0#u8 ∨ b.val[k]? = some 58#u8)) := by
  unfold has_invalid_path_byte
  obtain ⟨n, hn, hnv⟩ := bytes_length_spec b hlen
  rw [hn, b_ok]
  dsimp only
  have hloop := has_invalid_path_byte_loop0_spec b n hnv hlen
  rw [wp_ok_iff] at hloop
  obtain ⟨res, hres, hpost⟩ := hloop
  rw [hres, b_ok]
  cases res with
  | inl flag =>
    cases flag with
    | true => exact ⟨true, rfl, ⟨fun _ => hpost, fun _ => rfl⟩⟩
    | false => exact False.elim hpost
  | inr _ =>
    refine ⟨false, rfl, ⟨(by intro h; cases h), ?_⟩⟩
    rintro ⟨k, hk, hbad⟩
    have := hpost k hk
    rcases hbad with h0 | h58
    · exact False.elim (this.1 h0)
    · exact False.elim (this.2 h58)

/-- `is_windows_reserved_name` is total on any valid slice `0 ≤ start ≤ end ≤ b.val.length ≤ 2^31-1`. -/
lemma is_windows_reserved_name_total (b : Pion.Bytes) (s e : Std.I32)
    (hs0 : 0 ≤ s.val) (hse : s.val ≤ e.val) (he : e.val ≤ b.val.length)
    (hlen : b.val.length ≤ 2147483647) :
    ∃ r : Bool, is_windows_reserved_name b s e = ok r := by
  have hloop0 : is_windows_reserved_name_loop0 e b s ⦃ be => s.val ≤ be.val ∧ be.val ≤ e.val ⦄ := by
    unfold is_windows_reserved_name_loop0
    apply loop.spec_decr_nat
      (measure := fun (be : Std.I32) => (e.val - be.val).toNat)
      (inv := fun (be : Std.I32) => s.val ≤ be.val ∧ be.val ≤ e.val)
    · intro be ⟨h1, h2⟩
      unfold is_windows_reserved_name_loop0.body
      by_cases hlt : be < e
      · have hbelt : be.val < e.val := hlt
        obtain ⟨x, hx, _⟩ := bytes_get_spec b be (by omega) (by omega)
        simp only [hlt, ↓reduceIte, hx, b_ok]
        by_cases hne : ((Pion.U8.to_int x) != 46#i32) = true
        · simp only [hne, ↓reduceIte]; rw [WP.spec_ok]
          have hadd : (Pion.I32.add be 1#i32).val = be.val + 1 :=
            i32_add_val (by simp; omega) (by simp; omega)
          exact ⟨⟨by omega, by omega⟩, by omega⟩
        · simp only [hne, ↓reduceIte, Bool.false_eq_true]; rw [WP.spec_ok]
          exact ⟨h1, h2⟩
      · simp only [hlt, ↓reduceIte, b_ok, Bool.false_eq_true]; rw [WP.spec_ok]
        exact ⟨h1, h2⟩
    · exact ⟨le_refl _, hse⟩
  rw [wp_ok_iff] at hloop0
  obtain ⟨be1, hbe1, hbe1_lo, hbe1_hi⟩ := hloop0
  have hloop1 : is_windows_reserved_name_loop1 s b be1 ⦃ be => s.val ≤ be.val ∧ be.val ≤ be1.val ⦄ := by
    unfold is_windows_reserved_name_loop1
    apply loop.spec_decr_nat
      (measure := fun (be : Std.I32) => (be.val - s.val).toNat)
      (inv := fun (be : Std.I32) => s.val ≤ be.val ∧ be.val ≤ be1.val)
    · intro be ⟨h1, h2⟩
      unfold is_windows_reserved_name_loop1.body
      by_cases hgt : be > s
      · have hbgt : be.val > s.val := hgt
        have hsub : (Pion.I32.sub be 1#i32).val = be.val - 1 :=
          i32_sub_val (by simp; omega) (by simp; omega)
        obtain ⟨x, hx, _⟩ := bytes_get_spec b (Pion.I32.sub be 1#i32) (by omega) (by omega)
        simp only [hgt, ↓reduceIte, hx, b_ok]
        by_cases hsp : ((Pion.U8.to_int x) == 32#i32) = true
        · simp only [hsp, ↓reduceIte]; rw [WP.spec_ok]
          exact ⟨⟨by omega, by omega⟩, by omega⟩
        · simp only [hsp, ↓reduceIte, Bool.false_eq_true]; rw [WP.spec_ok]
          exact ⟨h1, h2⟩
      · simp only [hgt, ↓reduceIte, b_ok, Bool.false_eq_true]; rw [WP.spec_ok]
        exact ⟨h1, h2⟩
    · exact ⟨hbe1_lo, le_refl _⟩
  rw [wp_ok_iff] at hloop1
  obtain ⟨be2, hbe2, hbe2_lo, hbe2_hi⟩ := hloop1
  unfold is_windows_reserved_name
  dsimp only
  rw [hbe1, b_ok, hbe2, b_ok]
  have hblen : (Pion.I32.sub be2 s).val = be2.val - s.val :=
    i32_sub_val (by omega) (by omega)
  by_cases h3 : Pion.I32.sub be2 s = 3#i32
  · have hlen3 : be2.val - s.val = 3 := by
      have := congrArg IScalar.val h3; rw [hblen] at this; simpa using this
    obtain ⟨b0, hb0, _⟩ := bytes_get_spec b s hs0 (by omega)
    have ha1 : (Pion.I32.add s 1#i32).val = s.val + 1 := i32_add_val (by simp; omega) (by simp; omega)
    obtain ⟨b1, hb1, _⟩ := bytes_get_spec b (Pion.I32.add s 1#i32) (by omega) (by omega)
    have ha2 : (Pion.I32.add s 2#i32).val = s.val + 2 := i32_add_val (by simp; omega) (by simp; omega)
    obtain ⟨b2, hb2, _⟩ := bytes_get_spec b (Pion.I32.add s 2#i32) (by omega) (by omega)
    obtain ⟨c0, hc0, _⟩ := ascii_upper_spec (Pion.U8.to_int b0)
    obtain ⟨c1, hc1, _⟩ := ascii_upper_spec (Pion.U8.to_int b1)
    obtain ⟨c2, hc2, _⟩ := ascii_upper_spec (Pion.U8.to_int b2)
    simp only [h3, ↓reduceIte, hb0, hb1, hb2, hc0, hc1, hc2, b_ok]
    split_ifs <;> exact ⟨_, rfl⟩
  · by_cases h4 : Pion.I32.sub be2 s = 4#i32
    · have hlen4 : be2.val - s.val = 4 := by
        have := congrArg IScalar.val h4; rw [hblen] at this; simpa using this
      obtain ⟨b0, hb0, _⟩ := bytes_get_spec b s hs0 (by omega)
      have ha1 : (Pion.I32.add s 1#i32).val = s.val + 1 := i32_add_val (by simp; omega) (by simp; omega)
      obtain ⟨b1, hb1, _⟩ := bytes_get_spec b (Pion.I32.add s 1#i32) (by omega) (by omega)
      have ha2 : (Pion.I32.add s 2#i32).val = s.val + 2 := i32_add_val (by simp; omega) (by simp; omega)
      obtain ⟨b2, hb2, _⟩ := bytes_get_spec b (Pion.I32.add s 2#i32) (by omega) (by omega)
      have ha3 : (Pion.I32.add s 3#i32).val = s.val + 3 := i32_add_val (by simp; omega) (by simp; omega)
      obtain ⟨b3, hb3, _⟩ := bytes_get_spec b (Pion.I32.add s 3#i32) (by omega) (by omega)
      obtain ⟨c0, hc0, _⟩ := ascii_upper_spec (Pion.U8.to_int b0)
      obtain ⟨c1, hc1, _⟩ := ascii_upper_spec (Pion.U8.to_int b1)
      obtain ⟨c2, hc2, _⟩ := ascii_upper_spec (Pion.U8.to_int b2)
      simp only [h3, h4, ↓reduceIte, hb0, hb1, hb2, hb3, hc0, hc1, hc2, b_ok]
      split_ifs <;> exact ⟨_, rfl⟩
    · simp only [h3, h4, ↓reduceIte]
      exact ⟨false, rfl⟩

/-- A byte is a path separator (`'/'` or `'\\'`). -/
def IsSepByte (c : Std.U8) : Prop := c = 47#u8 ∨ c = 92#u8

/-- `[s, e)` is a maximal separator-delimited segment of byte list `l`. -/
def IsSegment (l : List Std.U8) (s e : Nat) : Prop :=
  s ≤ e ∧ e ≤ l.length ∧
  (s = 0 ∨ ∃ c, l[s - 1]? = some c ∧ IsSepByte c) ∧
  (e = l.length ∨ ∃ c, l[e]? = some c ∧ IsSepByte c) ∧
  ∀ k, s ≤ k → k < e → ∀ c, l[k]? = some c → ¬ IsSepByte c

/-- `[s, e)` is the parent-directory traversal segment `".."`. -/
def IsDotDot (l : List Std.U8) (s e : Nat) : Prop :=
  e - s = 2 ∧ l[s]? = some 46#u8 ∧ l[s + 1]? = some 46#u8

/-- `[s, e)` is the current-directory segment `"."`. -/
def IsDot (l : List Std.U8) (s e : Nat) : Prop :=
  e - s = 1 ∧ l[s]? = some 46#u8

/-- Core loop invariant for `validate_extract_path_bytes_loop0`:
    If the loop completes without early-returning `false`, then EVERY segment `[s, e)`
    in `b` is free of `..` and free of Windows reserved device names, and `kept > 0`
    implies at least one real (non-empty, non-`.`) segment exists. -/
private theorem validate_extract_path_bytes_loop0_spec (b : Pion.Bytes) (n : Std.I32)
    (hn : n.val = b.val.length) (hlen : b.val.length < 2147483647) :
    validate_extract_path_bytes_loop0 n b 0#i32 0#i32 0#i32 ⦃ res =>
      match res with
      | .inl true => False
      | .inl false => True
      | .inr (_, _, kept) =>
        (∀ s e, IsSegment b.val s e → ¬ IsDotDot b.val s e) ∧
        (∀ (s e : Nat) (hs he : Std.I32),
          hs.val = (s : Int) → he.val = (e : Int) →
          IsSegment b.val s e → e > s → ¬ IsDot b.val s e →
          is_windows_reserved_name b hs he = ok false) ∧
        (kept.val > 0 → ∃ s e, IsSegment b.val s e ∧ e > s ∧ ¬ IsDot b.val s e) ⦄ := by
  unfold validate_extract_path_bytes_loop0
  apply loop.spec_decr_nat
    (measure := fun (i, _, _) => b.val.length + 1 - i.val.toNat)
    (inv := fun (i, start, kept) =>
      0 ≤ start.val ∧ start.val ≤ i.val ∧ i.val ≤ b.val.length + 1 ∧
      0 ≤ kept.val ∧ kept.val ≤ i.val ∧
      (start.val = 0 ∨ start.val = b.val.length + 1 ∨
        ∃ c, b.val[start.val.toNat - 1]? = some c ∧ IsSepByte c) ∧
      (∀ k, start.val.toNat ≤ k → k < i.val.toNat → ∀ c, b.val[k]? = some c → ¬ IsSepByte c) ∧
      (∀ s e, IsSegment b.val s e → e < i.val.toNat → ¬ IsDotDot b.val s e) ∧
      (∀ (s e : Nat) (hs he : Std.I32),
        hs.val = (s : Int) → he.val = (e : Int) →
        IsSegment b.val s e → e < i.val.toNat → e > s → ¬ IsDot b.val s e →
        is_windows_reserved_name b hs he = ok false) ∧
      (kept.val > 0 → ∃ s e, IsSegment b.val s e ∧ e < i.val.toNat ∧ e > s ∧ ¬ IsDot b.val s e))
  · rintro ⟨i, start, kept⟩ ⟨hs0, hsi, hile, hk0, hki, hstart_sep, hno_sep, hnodotdot, hnowin, hkept⟩
    unfold validate_extract_path_bytes_loop0.body
    by_cases hle : i ≤ n
    · have hile_n : i.val ≤ b.val.length := by
        have : i.val ≤ n.val := hle; omega
      have hstart_sep' : start.val = 0 ∨
          ∃ c, b.val[start.val.toNat - 1]? = some c ∧ IsSepByte c := by
        rcases hstart_sep with h0 | hlen1 | hsep
        · exact Or.inl h0
        · omega
        · exact Or.inr hsep
      simp only [hle, ↓reduceIte]
      have his_sep : ∃ isSep : Bool,
          (if i = n then ok true
           else do let __t_4 ← Pion.Bytes.get b i; let __t_5 ← is_path_sep (Pion.U8.to_int __t_4); ok __t_5) = ok isSep ∧
          (isSep = true ↔ i.val = b.val.length ∨
            ∃ c, b.val[i.val.toNat]? = some c ∧ IsSepByte c) := by
        by_cases heq : i = n
        · have hiv : i.val = b.val.length := by
            have := congrArg IScalar.val heq; omega
          exact ⟨true, by simp [heq], ⟨fun _ => Or.inl hiv, fun _ => rfl⟩⟩
        · have hiv : i.val < b.val.length := by
            have hne : i.val ≠ n.val := fun h => heq (IScalar.eq_of_val_eq h)
            omega
          obtain ⟨x, hx, hxeq⟩ := bytes_get_spec b i (by omega) hiv
          simp only [heq, ↓reduceIte, hx, b_ok, is_path_sep]
          refine ⟨_, rfl, ?_⟩
          have hv := u8_to_int_val x
          constructor
          · intro hsep
            right
            refine ⟨x, hxeq, ?_⟩
            simp only [Bool.or_eq_true, beq_iff_eq] at hsep
            rcases hsep with h47 | h92
            · left; apply UScalar.eq_of_val_eq
              have := congrArg IScalar.val h47; rw [hv] at this; simp at this; simp; omega
            · right; apply UScalar.eq_of_val_eq
              have := congrArg IScalar.val h92; rw [hv] at this; simp at this; simp; omega
          · intro h
            rcases h with hlen_eq | ⟨c, hc, hsep⟩
            · omega
            · rw [hxeq] at hc; injection hc with hxc; subst hxc
              rcases hsep with h47 | h92 <;> subst_vars <;> decide
      obtain ⟨isSep, his_sep_eq, his_sep_iff⟩ := his_sep
      rw [his_sep_eq, b_ok]
      have hi1_val : (Pion.I32.add i 1#i32).val = i.val + 1 :=
        i32_add_val (by simp; omega) (by simp; omega)
      cases isSep with
      | false =>
        simp only [Bool.false_eq_true, ↓reduceIte, b_ok, WP.spec_ok]
        have hilt : i.val < b.val.length := by
          by_contra hge
          have : i.val = b.val.length := by omega
          have := his_sep_iff.mpr (Or.inl this)
          cases this
        have hnotsep : ∀ c, b.val[i.val.toNat]? = some c → ¬ IsSepByte c := by
          intro c hc hsep
          have := his_sep_iff.mpr (Or.inr ⟨c, hc, hsep⟩)
          cases this
        refine ⟨⟨hs0, by omega, by omega, hk0, by omega, hstart_sep, ?_, ?_, ?_, ?_⟩, by omega⟩
        · intro k hk1 hk2 c hc
          by_cases hki' : k < i.val.toNat
          · exact hno_sep k hk1 hki' c hc
          · have hkeq : k = i.val.toNat := by omega
            subst hkeq; exact hnotsep c hc
        · intro s e hseg he_lt
          have he_ne : e ≠ i.val.toNat := by
            intro heq; subst heq
            rcases hseg.2.2.2.1 with h1 | ⟨c, hc, hsep⟩
            · omega
            · exact hnotsep c hc hsep
          exact hnodotdot s e hseg (by omega)
        · intro s e hs he hsv hev hseg he_lt
          have he_ne : e ≠ i.val.toNat := by
            intro heq; subst heq
            rcases hseg.2.2.2.1 with h1 | ⟨c, hc, hsep⟩
            · omega
            · exact hnotsep c hc hsep
          exact hnowin s e hs he hsv hev hseg (by omega)
        · intro hkpos
          obtain ⟨s, e, h1, h2, h3, h4⟩ := hkept hkpos
          exact ⟨s, e, h1, by omega, h3, h4⟩
      | true =>
        simp only [↓reduceIte]
        have hcur_seg : IsSegment b.val start.val.toNat i.val.toNat := by
          refine ⟨by omega, by omega, ?_, ?_, hno_sep⟩
          · rcases hstart_sep' with h0 | hsep
            · left; omega
            · right; exact hsep
          · rcases his_sep_iff.mp rfl with hlen_eq | hsep
            · left; omega
            · right; exact hsep
        obtain ⟨isDD, hisDD, hisDD_iff⟩ :=
          is_dotdot_segment_spec b start i hs0 hsi hile_n (by omega)
        rw [hisDD, b_ok]
        cases isDD with
        | true =>
          simp only [↓reduceIte, b_ok, WP.spec_ok]
        | false =>
          simp only [Bool.false_eq_true, ↓reduceIte]
          have hcur_not_dd : ¬ IsDotDot b.val start.val.toNat i.val.toNat := by
            intro hdd
            have h1 : i.val - start.val = 2 := by have := hdd.1; omega
            have h2 : (start.val + 1).toNat = start.val.toNat + 1 := by omega
            have := hisDD_iff.mpr ⟨h1, hdd.2.1, by rw [h2]; exact hdd.2.2⟩
            cases this
          have hseglen : (Pion.I32.sub i start).val = i.val - start.val :=
            i32_sub_val (by omega) (by omega)
          have hkeep_eval : ∃ keepSeg : Bool,
              (if Pion.I32.sub i start > 0#i32 then
                 if Pion.I32.sub i start = 1#i32 then do
                   let t ← Pion.Bytes.get b start
                   ok (!((Pion.U8.to_int t) == 46#i32))
                 else ok (!false)
               else ok false) = ok keepSeg ∧
              (keepSeg = true ↔ i.val.toNat > start.val.toNat ∧ ¬ IsDot b.val start.val.toNat i.val.toNat) := by
            by_cases hgt0 : Pion.I32.sub i start > 0#i32
            · have hpos : i.val - start.val > 0 := by
                have : (Pion.I32.sub i start).val > 0 := hgt0; omega
              by_cases heq1 : Pion.I32.sub i start = 1#i32
              · have h1 : i.val - start.val = 1 := by
                  have := congrArg IScalar.val heq1; rw [hseglen] at this; simpa using this
                obtain ⟨x, hx, hxeq⟩ := bytes_get_spec b start hs0 (by omega)
                simp only [hgt0, heq1, ↓reduceIte, hx, b_ok]
                refine ⟨_, rfl, ?_⟩
                have hv := u8_to_int_val x
                constructor
                · intro hnotdot
                  refine ⟨by omega, ?_⟩
                  intro ⟨_, hx46⟩
                  rw [hxeq] at hx46; injection hx46 with hxe; subst hxe
                  simp at hnotdot
                · rintro ⟨_, hnd⟩
                  simp only [Bool.not_eq_true']
                  by_contra hne
                  have htr : (Pion.U8.to_int x == 46#i32) = true := by
                    cases hb : (Pion.U8.to_int x == 46#i32) <;> simp_all
                  rw [beq_iff_eq] at htr
                  have hx46 : x = 46#u8 := by
                    have := congrArg IScalar.val htr; rw [hv] at this; simp at this
                    apply UScalar.eq_of_val_eq; simp; omega
                  rw [hx46] at hxeq
                  exact hnd ⟨by omega, hxeq⟩
              · have hne1 : i.val - start.val ≠ 1 := by
                  intro h1; apply heq1; apply IScalar.eq_of_val_eq
                  rw [hseglen]; simpa using h1
                simp only [hgt0, heq1, ↓reduceIte, Bool.not_false]
                refine ⟨true, rfl, ⟨fun _ => ⟨by omega, fun ⟨h1, _⟩ => by omega⟩, fun _ => rfl⟩⟩
            · have hle0 : i.val - start.val ≤ 0 := by
                have : ¬ ((Pion.I32.sub i start).val > 0) := hgt0; omega
              simp only [hgt0, ↓reduceIte]
              exact ⟨false, rfl, ⟨(by intro h; cases h), fun ⟨hgt, _⟩ => by omega⟩⟩
          obtain ⟨keepSeg, hkeep_eq, hkeep_iff⟩ := hkeep_eval
          rw [hkeep_eq, b_ok]
          have hseg_unique_start : ∀ s, IsSegment b.val s i.val.toNat → s = start.val.toNat := by
            intro s hseg
            by_contra hne
            have hs_le : s ≤ i.val.toNat := hseg.1
            by_cases hlt_s : s < start.val.toNat
            · rcases hstart_sep' with h0 | ⟨c, hc, hsep⟩
              · omega
              · exact hseg.2.2.2.2 (start.val.toNat - 1) (by omega) (by omega) c hc hsep
            · have hgt_s : start.val.toNat < s := by omega
              rcases hseg.2.2.1 with h0 | ⟨c, hc, hsep⟩
              · omega
              · exact hno_sep (s - 1) (by omega) (by omega) c hc hsep
          have hnext_start_sep : (Pion.I32.add i 1#i32).val = 0 ∨
              (Pion.I32.add i 1#i32).val = b.val.length + 1 ∨
              ∃ c, b.val[(Pion.I32.add i 1#i32).val.toNat - 1]? = some c ∧ IsSepByte c := by
            rcases his_sep_iff.mp rfl with hlen_eq | ⟨c, hc, hsep⟩
            · right; left; omega
            · right; right
              refine ⟨c, ?_, hsep⟩
              have hidx : (Pion.I32.add i 1#i32).val.toNat - 1 = i.val.toNat := by omega
              rw [hidx]; exact hc
          cases keepSeg with
          | false =>
            simp only [Bool.false_eq_true, ↓reduceIte, b_ok, WP.spec_ok]
            refine ⟨⟨by omega, by omega, by omega, hk0, by omega, hnext_start_sep, ?_, ?_, ?_, ?_⟩, by omega⟩
            · intro k hk1 hk2; omega
            · intro s e hseg he_lt
              by_cases he_i : e = i.val.toNat
              · subst he_i
                have hs_eq := hseg_unique_start s hseg
                subst hs_eq; exact hcur_not_dd
              · exact hnodotdot s e hseg (by omega)
            · intro s e hs he hsv hev hseg he_lt hgt_s hnd
              by_cases he_i : e = i.val.toNat
              · subst he_i
                have hs_eq := hseg_unique_start s hseg
                subst hs_eq
                have := hkeep_iff.mpr ⟨hgt_s, hnd⟩
                cases this
              · exact hnowin s e hs he hsv hev hseg (by omega) hgt_s hnd
            · intro hkpos
              obtain ⟨s, e, h1, h2, h3, h4⟩ := hkept hkpos
              exact ⟨s, e, h1, by omega, h3, h4⟩
          | true =>
            simp only [↓reduceIte]
            obtain ⟨isWin, hisWin⟩ :=
              is_windows_reserved_name_total b start i hs0 hsi hile_n (by omega)
            rw [hisWin, b_ok]
            cases isWin with
            | true =>
              simp only [↓reduceIte, b_ok, WP.spec_ok]
            | false =>
              simp only [Bool.false_eq_true, ↓reduceIte, b_ok, WP.spec_ok]
              have hk1_val : (Pion.I32.add kept 1#i32).val = kept.val + 1 :=
                i32_add_val (by simp; omega) (by simp; omega)
              refine ⟨⟨by omega, by omega, by omega, by omega, by omega, hnext_start_sep, ?_, ?_, ?_, ?_⟩, by omega⟩
              · intro k hk1 hk2; omega
              · intro s e hseg he_lt
                by_cases he_i : e = i.val.toNat
                · subst he_i
                  have hs_eq := hseg_unique_start s hseg
                  subst hs_eq; exact hcur_not_dd
                · exact hnodotdot s e hseg (by omega)
              · intro s e hs he hsv hev hseg he_lt hgt_s hnd
                by_cases he_i : e = i.val.toNat
                · subst he_i
                  have hs_eq := hseg_unique_start s hseg
                  subst hs_eq
                  have hseq : hs = start := IScalar.eq_of_val_eq (by omega)
                  have heeq : he = i := IScalar.eq_of_val_eq (by omega)
                  subst hseq; subst heeq
                  exact hisWin
                · exact hnowin s e hs he hsv hev hseg (by omega) hgt_s hnd
              · intro _
                obtain ⟨hgt_s, hnd⟩ := hkeep_iff.mp rfl
                exact ⟨start.val.toNat, i.val.toNat, hcur_seg, by omega, hgt_s, hnd⟩
    · simp only [hle, ↓reduceIte, WP.spec_ok]
      have hgt : i.val > b.val.length := by
        have : ¬ (i.val ≤ n.val) := hle; omega
      refine ⟨?_, ?_, ?_⟩
      · intro s e hseg
        exact hnodotdot s e hseg (by have := hseg.2.1; omega)
      · intro s e hs he hsv hev hseg
        exact hnowin s e hs he hsv hev hseg (by have := hseg.2.1; omega)
      · intro hkpos
        obtain ⟨s, e, h1, _, h3, h4⟩ := hkept hkpos
        exact ⟨s, e, h1, h3, h4⟩
  · refine ⟨by simp, by simp, by simp; omega, by simp, by simp, Or.inl (by simp), ?_, ?_, ?_, ?_⟩
    · intro k _ hk; simp at hk
    · intro s e _ he; simp at he
    · intro s e _ _ _ _ _ he; simp at he
    · intro h; simp at h

/-- **Master Zip-Slip & Extraction Path Safety Theorem**:
    Whenever `validate_extract_path_bytes b = ok true` (for any path fitting in `Int`),
    ALL of the following security invariants hold simultaneously:
    1. Non-empty (`b.val.length > 0`)
    2. Not absolute: does not start with `'/'` (`47`) or `'\\'` (`92`)
    3. Contains no NUL byte (`0x00`) and no `':'` (`0x3A`, blocking Windows drive letters `[A-Za-z]:` and NTFS ADS)
    4. Contains NO parent-directory traversal segment `".."` anywhere (delimited by `'/'` or `'\\'`)
    5. Contains NO Windows reserved device name segment (`CON`, `PRN`, `AUX`, `NUL`, `COM1..9`, `LPT1..9`)
    6. Contains at least one non-empty, non-`"."` path segment. -/
theorem validate_extract_path_bytes_sound (b : Pion.Bytes)
    (hlen : b.val.length < 2147483647)
    (hok : validate_extract_path_bytes b = ok true) :
    b.val.length > 0 ∧
    b.val[0]? ≠ some 47#u8 ∧
    b.val[0]? ≠ some 92#u8 ∧
    (∀ k, k < b.val.length → b.val[k]? ≠ some 0#u8 ∧ b.val[k]? ≠ some 58#u8) ∧
    (∀ s e, IsSegment b.val s e → ¬ IsDotDot b.val s e) ∧
    (∀ (s e : Nat) (hs he : Std.I32), hs.val = (s : Int) → he.val = (e : Int) →
      IsSegment b.val s e → e > s → ¬ IsDot b.val s e →
      is_windows_reserved_name b hs he = ok false) ∧
    (∃ s e, IsSegment b.val s e ∧ e > s ∧ ¬ IsDot b.val s e) := by
  unfold validate_extract_path_bytes at hok
  obtain ⟨n, hn, hnv⟩ := bytes_length_spec b (by omega)
  rw [hn, b_ok] at hok
  by_cases hn0 : n = 0#i32
  · simp [hn0] at hok
  · have hpos : b.val.length > 0 := by
      have : n.val ≠ 0 := fun h => hn0 (IScalar.eq_of_val_eq (by simpa using h))
      omega
    simp only [hn0, ↓reduceIte] at hok
    obtain ⟨b0, hb0, hb0eq⟩ := bytes_get_spec b 0#i32 (by simp) (by simp; omega)
    rw [hb0, b_ok] at hok
    unfold is_path_sep at hok
    rw [b_ok] at hok
    by_cases hsep0 : ((Pion.U8.to_int b0 == 47#i32) || (Pion.U8.to_int b0 == 92#i32)) = true
    · simp only [hsep0, ↓reduceIte, Result.ok.injEq, Bool.false_eq_true] at hok
    · simp only [hsep0, ↓reduceIte] at hok
      have hne47 : b.val[0]? ≠ some 47#u8 := by
        intro h47
        simp only [show (0#i32 : Std.I32).val.toNat = 0 from rfl] at hb0eq
        rw [hb0eq] at h47; injection h47 with h; subst h
        exact hsep0 (by decide)
      have hne92 : b.val[0]? ≠ some 92#u8 := by
        intro h92
        simp only [show (0#i32 : Std.I32).val.toNat = 0 from rfl] at hb0eq
        rw [hb0eq] at h92; injection h92 with h; subst h
        exact hsep0 (by decide)
      obtain ⟨hasBad, hbad_eq, hbad_iff⟩ := has_invalid_path_byte_spec b (by omega)
      rw [hbad_eq, b_ok] at hok
      cases hasBad with
      | true => simp at hok
      | false =>
        simp only [Bool.false_eq_true, ↓reduceIte] at hok
        have hno_bad : ∀ k, k < b.val.length → b.val[k]? ≠ some 0#u8 ∧ b.val[k]? ≠ some 58#u8 := by
          intro k hk
          constructor
          · intro h0; have := hbad_iff.mpr ⟨k, hk, Or.inl h0⟩; cases this
          · intro h58; have := hbad_iff.mpr ⟨k, hk, Or.inr h58⟩; cases this
        have hloop := validate_extract_path_bytes_loop0_spec b n hnv hlen
        rw [wp_ok_iff] at hloop
        obtain ⟨res, hres, hpost⟩ := hloop
        rw [hres, b_ok] at hok
        cases res with
        | inl flag =>
          cases flag with
          | true => exact False.elim hpost
          | false => simp at hok
        | inr triple =>
          rcases triple with ⟨i1, start1, kept1⟩
          simp only [Result.ok.injEq, decide_eq_true_eq] at hok
          have hkpos : kept1.val > 0 := hok
          exact ⟨hpos, hne47, hne92, hno_bad, hpost.1, hpost.2.1, hpost.2.2 hkpos⟩

/-- Uppercase ASCII byte value (for Windows reserved device name matching). -/
def upperByte (x : Std.U8) : Nat :=
  if 97 ≤ x.val ∧ x.val ≤ 122 then x.val - 32 else x.val

/-- Predicate: 3-byte base name is one of `CON`, `PRN`, `AUX`, `NUL` (case-insensitive). -/
def IsWinReserved3 (b0 b1 b2 : Std.U8) : Prop :=
  (upperByte b0 = 67 ∧ upperByte b1 = 79 ∧ upperByte b2 = 78) ∨
  (upperByte b0 = 80 ∧ upperByte b1 = 82 ∧ upperByte b2 = 78) ∨
  (upperByte b0 = 65 ∧ upperByte b1 = 85 ∧ upperByte b2 = 88) ∨
  (upperByte b0 = 78 ∧ upperByte b1 = 85 ∧ upperByte b2 = 76)

/-- Predicate: 4-byte base name is `COM1..COM9` or `LPT1..LPT9` (case-insensitive). -/
def IsWinReserved4 (b0 b1 b2 b3 : Std.U8) : Prop :=
  (49 ≤ b3.val ∧ b3.val ≤ 57) ∧
  ((upperByte b0 = 67 ∧ upperByte b1 = 79 ∧ upperByte b2 = 77) ∨
   (upperByte b0 = 76 ∧ upperByte b1 = 80 ∧ upperByte b2 = 84))

/-- **Windows Reserved Device Name Soundness Theorem**:
    For ANY slice `b[s..e)` whose base name (before the first `'.'`, with trailing spaces stripped)
    has length 3 matching `CON`/`PRN`/`AUX`/`NUL` (case-insensitive), `is_windows_reserved_name`
    provably returns `ok true`. -/
theorem is_windows_reserved_name_sound3 (b : Pion.Bytes) (s e : Std.I32)
    (hs0 : 0 ≤ s.val) (hse : s.val + 3 ≤ e.val) (he : e.val ≤ b.val.length)
    (hlen : b.val.length ≤ 2147483647)
    (b0 b1 b2 : Std.U8)
    (hb0 : b.val[s.val.toNat]? = some b0)
    (hb1 : b.val[s.val.toNat + 1]? = some b1)
    (hb2 : b.val[s.val.toNat + 2]? = some b2)
    (hres3 : IsWinReserved3 b0 b1 b2)
    (hno_dot_after_sp : ∀ k, s.val.toNat + 3 ≤ k → k < e.val.toNat →
      (∀ j, s.val.toNat + 3 ≤ j → j < k → b.val[j]? ≠ some 46#u8) →
      b.val[k]? = some 32#u8 ∨ b.val[k]? = some 46#u8) :
    is_windows_reserved_name b s e = ok true := by
  have hne46 : b0 ≠ 46#u8 ∧ b1 ≠ 46#u8 ∧ b2 ≠ 46#u8 ∧ b2 ≠ 32#u8 := by
    rcases hres3 with ⟨h0, h1, h2⟩ | ⟨h0, h1, h2⟩ | ⟨h0, h1, h2⟩ | ⟨h0, h1, h2⟩ <;>
    · refine ⟨?_, ?_, ?_, ?_⟩ <;> (intro h; subst h; simp [upperByte] at h0 h1 h2)
  -- Loop 0 stops at `be1 ≥ s + 3` where all bytes in `[s+3, be1)` are spaces (`32`)
  have hL0 : is_windows_reserved_name_loop0 e b s ⦃ be1 =>
      s.val + 3 ≤ be1.val ∧ be1.val ≤ e.val ∧
      ∀ k, s.val.toNat + 3 ≤ k → k < be1.val.toNat → b.val[k]? = some 32#u8 ⦄ := by
    unfold is_windows_reserved_name_loop0
    apply loop.spec_decr_nat
      (measure := fun (be : Std.I32) => (e.val - be.val).toNat)
      (inv := fun (be : Std.I32) =>
        s.val ≤ be.val ∧ be.val ≤ e.val ∧
        (∀ k, s.val.toNat ≤ k → k < be.val.toNat → b.val[k]? ≠ some 46#u8) ∧
        (∀ k, s.val.toNat + 3 ≤ k → k < be.val.toNat → b.val[k]? = some 32#u8))
    · intro be ⟨h1, h2, hnodot, hallsp⟩
      unfold is_windows_reserved_name_loop0.body
      by_cases hlt : be < e
      · have hbelt : be.val < e.val := hlt
        obtain ⟨x, hx, hxeq⟩ := bytes_get_spec b be (by omega) (by omega)
        simp only [hlt, ↓reduceIte, hx, b_ok]
        by_cases hne : ((Pion.U8.to_int x) != 46#i32) = true
        · simp only [hne, ↓reduceIte]; rw [WP.spec_ok]
          have hadd : (Pion.I32.add be 1#i32).val = be.val + 1 := i32_add_val (by simp; omega) (by simp; omega)
          have hx_ne46 : x ≠ 46#u8 := by
            intro h; subst h; simp at hne
          refine ⟨⟨by omega, by omega, ?_, ?_⟩, by omega⟩
          · intro k hk1 hk2
            by_cases hkb : k < be.val.toNat
            · exact hnodot k hk1 hkb
            · have hkeq : k = be.val.toNat := by omega
              subst hkeq; rw [hxeq]; intro heq; exact hx_ne46 (Option.some.inj heq)
          · intro k hk1 hk2
            by_cases hkb : k < be.val.toNat
            · exact hallsp k hk1 hkb
            · have hkeq : k = be.val.toNat := by omega
              subst hkeq
              have hsp := hno_dot_after_sp be.val.toNat (by omega) (by omega)
                (fun j hj1 hj2 => hnodot j (by omega) hj2)
              rcases hsp with hs32 | hd46
              · exact hs32
              · rw [hxeq] at hd46; exact False.elim (hx_ne46 (Option.some.inj hd46))
        · simp only [hne, ↓reduceIte, Bool.false_eq_true]; rw [WP.spec_ok]
          have hx46 : x = 46#u8 := by
            simp only [bne_iff_ne, ne_eq, not_not] at hne
            have := congrArg IScalar.val hne; rw [u8_to_int_val] at this; simp at this
            apply UScalar.eq_of_val_eq; simp; omega
          rw [hx46] at hxeq
          have hge3 : s.val + 3 ≤ be.val := by
            by_contra hlt3
            have hcases : be.val.toNat = s.val.toNat ∨ be.val.toNat = s.val.toNat + 1 ∨ be.val.toNat = s.val.toNat + 2 := by omega
            rcases hcases with h0 | h1' | h2'
            · rw [h0, hb0] at hxeq; exact hne46.1 (Option.some.inj hxeq)
            · rw [h1', hb1] at hxeq; exact hne46.2.1 (Option.some.inj hxeq)
            · rw [h2', hb2] at hxeq; exact hne46.2.2.1 (Option.some.inj hxeq)
          exact ⟨hge3, h2, hallsp⟩
      · simp only [hlt, ↓reduceIte, b_ok, Bool.false_eq_true]; rw [WP.spec_ok]
        have hge : be.val ≥ e.val := by have : ¬ (be.val < e.val) := hlt; omega
        exact ⟨by omega, h2, hallsp⟩
    · refine ⟨le_refl _, by omega, ?_, ?_⟩ <;> (intro k hk1 hk2; omega)
  rw [wp_ok_iff] at hL0
  obtain ⟨be1, hbe1, hbe1_lo, hbe1_hi, hbe1_sp⟩ := hL0
  -- Loop 1 trims all trailing spaces in `[s+3, be1)` and stops at `be2 = s + 3`
  have hL1 : is_windows_reserved_name_loop1 s b be1 ⦃ be2 => be2.val = s.val + 3 ⦄ := by
    unfold is_windows_reserved_name_loop1
    apply loop.spec_decr_nat
      (measure := fun (be : Std.I32) => (be.val - (s.val + 3)).toNat)
      (inv := fun (be : Std.I32) => s.val + 3 ≤ be.val ∧ be.val ≤ be1.val)
    · intro be ⟨h1, h2⟩
      unfold is_windows_reserved_name_loop1.body
      have hgt : be > s := by show be.val > s.val; omega
      have hsub : (Pion.I32.sub be 1#i32).val = be.val - 1 := i32_sub_val (by simp; omega) (by simp; omega)
      obtain ⟨x, hx, hxeq⟩ := bytes_get_spec b (Pion.I32.sub be 1#i32) (by omega) (by omega)
      simp only [hgt, ↓reduceIte, hx, b_ok]
      by_cases heq3 : be.val = s.val + 3
      · have hidx2 : (Pion.I32.sub be 1#i32).val.toNat = s.val.toNat + 2 := by omega
        rw [hidx2, hb2] at hxeq; injection hxeq with hxb2; subst hxb2
        have hnot32 : ¬ ((Pion.U8.to_int b2 == 32#i32) = true) := by
          intro h32; rw [beq_iff_eq] at h32
          have := congrArg IScalar.val h32; rw [u8_to_int_val] at this; simp at this
          exact hne46.2.2.2 (UScalar.eq_of_val_eq (by simp; omega))
        simp only [hnot32, ↓reduceIte, Bool.false_eq_true]; rw [WP.spec_ok]; exact heq3
      · have hidx_sp := hbe1_sp (Pion.I32.sub be 1#i32).val.toNat (by omega) (by omega)
        rw [hxeq] at hidx_sp; injection hidx_sp with hx32; subst hx32
        have his32 : (Pion.U8.to_int 32#u8 == 32#i32) = true := by decide
        simp only [his32, ↓reduceIte]; rw [WP.spec_ok]
        exact ⟨⟨by omega, by omega⟩, by omega⟩
    · exact ⟨hbe1_lo, le_refl _⟩
  rw [wp_ok_iff] at hL1
  obtain ⟨be2, hbe2, hbe2_eq⟩ := hL1
  unfold is_windows_reserved_name
  dsimp only
  rw [hbe1, b_ok, hbe2, b_ok]
  have hblen : Pion.I32.sub be2 s = 3#i32 := by
    apply IScalar.eq_of_val_eq
    rw [i32_sub_val (by omega) (by omega)]; simp; omega
  obtain ⟨x0, hx0, hx0eq⟩ := bytes_get_spec b s hs0 (by omega)
  rw [hb0] at hx0eq; injection hx0eq with h; subst h
  have ha1 : (Pion.I32.add s 1#i32).val = s.val + 1 := i32_add_val (by simp; omega) (by simp; omega)
  obtain ⟨x1, hx1, hx1eq⟩ := bytes_get_spec b (Pion.I32.add s 1#i32) (by omega) (by omega)
  rw [show (Pion.I32.add s 1#i32).val.toNat = s.val.toNat + 1 by omega, hb1] at hx1eq
  injection hx1eq with h; subst h
  have ha2 : (Pion.I32.add s 2#i32).val = s.val + 2 := i32_add_val (by simp; omega) (by simp; omega)
  obtain ⟨x2, hx2, hx2eq⟩ := bytes_get_spec b (Pion.I32.add s 2#i32) (by omega) (by omega)
  rw [show (Pion.I32.add s 2#i32).val.toNat = s.val.toNat + 2 by omega, hb2] at hx2eq
  injection hx2eq with h; subst h
  obtain ⟨c0, hc0, hc0v⟩ := ascii_upper_spec (Pion.U8.to_int b0)
  obtain ⟨c1, hc1, hc1v⟩ := ascii_upper_spec (Pion.U8.to_int b1)
  obtain ⟨c2, hc2, hc2v⟩ := ascii_upper_spec (Pion.U8.to_int b2)
  simp only [hblen, ↓reduceIte, hx0, hx1, hx2, hc0, hc1, hc2, b_ok]
  have hu0 : c0.val = (upperByte b0 : Int) := by
    rw [hc0v, u8_to_int_val]; unfold upperByte; split_ifs <;> omega
  have hu1 : c1.val = (upperByte b1 : Int) := by
    rw [hc1v, u8_to_int_val]; unfold upperByte; split_ifs <;> omega
  have hu2 : c2.val = (upperByte b2 : Int) := by
    rw [hc2v, u8_to_int_val]; unfold upperByte; split_ifs <;> omega
  have hcond : ((((((c0 == 67#i32) && (c1 == 79#i32)) && (c2 == 78#i32)) ||
      (((c0 == 80#i32) && (c1 == 82#i32)) && (c2 == 78#i32))) ||
      (((c0 == 65#i32) && (c1 == 85#i32)) && (c2 == 88#i32))) ||
      (((c0 == 78#i32) && (c1 == 85#i32)) && (c2 == 76#i32))) = true := by
    simp only [Bool.or_eq_true, Bool.and_eq_true, beq_iff_eq]
    rcases hres3 with ⟨h0, h1, h2⟩ | ⟨h0, h1, h2⟩ | ⟨h0, h1, h2⟩ | ⟨h0, h1, h2⟩
    · left; left; left; exact ⟨⟨IScalar.eq_of_val_eq (by simp [hu0, h0]), IScalar.eq_of_val_eq (by simp [hu1, h1])⟩, IScalar.eq_of_val_eq (by simp [hu2, h2])⟩
    · left; left; right; exact ⟨⟨IScalar.eq_of_val_eq (by simp [hu0, h0]), IScalar.eq_of_val_eq (by simp [hu1, h1])⟩, IScalar.eq_of_val_eq (by simp [hu2, h2])⟩
    · left; right; exact ⟨⟨IScalar.eq_of_val_eq (by simp [hu0, h0]), IScalar.eq_of_val_eq (by simp [hu1, h1])⟩, IScalar.eq_of_val_eq (by simp [hu2, h2])⟩
    · right; exact ⟨⟨IScalar.eq_of_val_eq (by simp [hu0, h0]), IScalar.eq_of_val_eq (by simp [hu1, h1])⟩, IScalar.eq_of_val_eq (by simp [hu2, h2])⟩
  simp only [hcond, ↓reduceIte]

/-! ## Section 4: TAR Numeric Encoding & Decoding (Octal & GNU Base-256) (`packages/tar/src/format.pion`) -/

private theorem shl_1_i64_val (k : Std.I32) (hk0 : 0 ≤ k.val) (hk63 : k.val < 63) :
    ∃ r : Std.I64, Pion.I64.shl_i32 1#i64 k = ok r ∧ r.val = (2 ^ k.val.toNat : Int) := by
  unfold Pion.I64.shl_i32
  have hk64 : 0 ≤ k.val ∧ k.val < 64 := ⟨hk0, by omega⟩
  simp only [hk64, and_self, ↓reduceIte]
  refine ⟨_, rfl, ?_⟩
  change (BitVec.ofNat 64 1 <<< k.val.toNat).toInt = (2 ^ k.val.toNat : Int)
  have hshift : (BitVec.ofNat 64 1 <<< k.val.toNat) = BitVec.ofNat 64 (2 ^ k.val.toNat) := by
    apply BitVec.eq_of_toNat_eq
    simp only [BitVec.toNat_shiftLeft, BitVec.toNat_ofNat]
    have hlt : 2 ^ k.val.toNat < 2 ^ 64 := Nat.pow_lt_pow_right (by norm_num) (by omega)
    rw [Nat.shiftLeft_eq]
    simp [Nat.mod_eq_of_lt hlt]
  rw [hshift, BitVec.toInt_eq_toNat_cond]
  simp only [BitVec.toNat_ofNat]
  have hlt64 : 2 ^ k.val.toNat < 2 ^ 64 := Nat.pow_lt_pow_right (by norm_num) (by omega)
  have hlt63 : 2 ^ k.val.toNat < 2 ^ 63 := Nat.pow_lt_pow_right (by norm_num) (by omega)
  rw [Nat.mod_eq_of_lt hlt64]
  simp only [show 2 * 2 ^ k.val.toNat < 2 ^ 64 by omega, ↓reduceIte]
  norm_cast

/-- `fits_in_octal` is total (never panics or traps on any `width : Int, x : Int64`)
    and matches the exact TAR octal capacity `[0, 2^(3*(width-1)))`. -/
theorem fits_in_octal_spec (width : Std.I32) (x : Std.I64) :
    ∃ r : Bool, fits_in_octal width x = ok r ∧
      (r = true ↔ 0 ≤ x.val ∧ 1 ≤ width.val ∧
        (width.val ≥ 22 ∨ x.val < (2 ^ (3 * (width.val.toNat - 1)) : Int))) := by
  unfold fits_in_octal
  by_cases hneg : x.val < 0 ∨ width.val ≤ 0
  · have hcond : (decide (x < 0#i64) || decide (width ≤ 0#i32)) = true := by
      simp only [Bool.or_eq_true, decide_eq_true_eq]
      rcases hneg with hx | hw
      · left; show x.val < (0#i64 : Std.I64).val; simp; omega
      · right; show width.val ≤ (0#i32 : Std.I32).val; simp; omega
    simp only [hcond, ↓reduceIte]
    exact ⟨false, rfl, ⟨(by intro h; cases h), fun ⟨hx, hw, _⟩ => False.elim (by omega)⟩⟩
  · have hx0 : 0 ≤ x.val := by omega
    have hw1 : 1 ≤ width.val := by omega
    have hcond : (decide (x < 0#i64) || decide (width ≤ 0#i32)) = false := by
      simp only [Bool.or_eq_false_iff, decide_eq_false_iff_not]
      exact ⟨by show ¬ (x.val < (0#i64 : Std.I64).val); simp; omega,
             by show ¬ (width.val ≤ (0#i32 : Std.I32).val); simp; omega⟩
    simp only [hcond, Bool.false_eq_true, ↓reduceIte]
    by_cases hw22 : width ≥ 22#i32
    · have hwge : width.val ≥ 22 := hw22
      simp only [hw22, ↓reduceIte]
      exact ⟨true, rfl, ⟨fun _ => ⟨hx0, hw1, Or.inl hwge⟩, fun _ => rfl⟩⟩
    · have hwlt : width.val < 22 := by
        have : ¬ (width.val ≥ 22) := hw22; omega
      simp only [hw22, ↓reduceIte]
      have hsub : (Pion.I32.sub width 1#i32).val = width.val - 1 :=
        i32_sub_val (by simp; omega) (by simp; omega)
      have hmul : (Pion.I32.mul (Pion.I32.sub width 1#i32) 3#i32).val = (width.val - 1) * 3 := by
        rw [i32_mul_val (by rw [hsub]; simp; omega) (by rw [hsub]; simp; omega), hsub]; simp
      obtain ⟨lim, hlim, hlim_val⟩ :=
        shl_1_i64_val (Pion.I32.mul (Pion.I32.sub width 1#i32) 3#i32) (by omega) (by omega)
      rw [hlim, b_ok]
      refine ⟨_, rfl, ?_⟩
      have hexp : (Pion.I32.mul (Pion.I32.sub width 1#i32) 3#i32).val.toNat =
          3 * (width.val.toNat - 1) := by omega
      rw [hexp] at hlim_val
      simp only [decide_eq_true_eq]
      constructor
      · intro hlt
        have : x.val < lim.val := hlt
        exact ⟨hx0, hw1, Or.inr (by omega)⟩
      · rintro ⟨_, _, h22 | hlt⟩
        · omega
        · show x.val < lim.val; omega

/-- `fits_in_base256` is total (never panics or traps on any `width : Int, x : Int64`)
    and matches the exact GNU base-256 capacity `[-2^(8*(width-1)), 2^(8*(width-1)))`. -/
theorem fits_in_base256_spec (width : Std.I32) (x : Std.I64) :
    ∃ r : Bool, fits_in_base256 width x = ok r ∧
      (r = true ↔ 1 ≤ width.val ∧
        (width.val ≥ 9 ∨
          (-(2 ^ (8 * (width.val.toNat - 1)) : Int) ≤ x.val ∧
            x.val < (2 ^ (8 * (width.val.toNat - 1)) : Int)))) := by
  unfold fits_in_base256
  by_cases hw0 : width ≤ 0#i32
  · have hwle : width.val ≤ 0 := hw0
    simp only [hw0, ↓reduceIte]
    exact ⟨false, rfl, ⟨(by intro h; cases h), fun ⟨hw1, _⟩ => False.elim (by omega)⟩⟩
  · have hw1 : 1 ≤ width.val := by
      have : ¬ (width.val ≤ 0) := hw0; omega
    simp only [hw0, ↓reduceIte]
    by_cases hw9 : width ≥ 9#i32
    · have hwge : width.val ≥ 9 := hw9
      simp only [hw9, ↓reduceIte]
      exact ⟨true, rfl, ⟨fun _ => ⟨hw1, Or.inl hwge⟩, fun _ => rfl⟩⟩
    · have hwlt : width.val < 9 := by
        have : ¬ (width.val ≥ 9) := hw9; omega
      simp only [hw9, ↓reduceIte]
      have hsub : (Pion.I32.sub width 1#i32).val = width.val - 1 :=
        i32_sub_val (by simp; omega) (by simp; omega)
      have hmul : (Pion.I32.mul (Pion.I32.sub width 1#i32) 8#i32).val = (width.val - 1) * 8 := by
        rw [i32_mul_val (by rw [hsub]; simp; omega) (by rw [hsub]; simp; omega), hsub]; simp
      obtain ⟨lim, hlim, hlim_val⟩ :=
        shl_1_i64_val (Pion.I32.mul (Pion.I32.sub width 1#i32) 8#i32) (by omega) (by omega)
      rw [hlim, b_ok]
      have hexp : (Pion.I32.mul (Pion.I32.sub width 1#i32) 8#i32).val.toNat =
          8 * (width.val.toNat - 1) := by omega
      rw [hexp] at hlim_val
      have hneg_lim : (Pion.I64.neg lim).val = -lim.val := by
        have hlt63 : lim.val < 2 ^ 63 := by
          have : (2 ^ (8 * (width.val.toNat - 1)) : Nat) < 2 ^ 63 :=
            Nat.pow_lt_pow_right (by norm_num) (by omega)
          have : (2 ^ (8 * (width.val.toNat - 1)) : Int) < 2 ^ 63 := by exact_mod_cast this
          omega
        have hpos : 0 < lim.val := by
          rw [hlim_val]; positivity
        cases lim with
        | mk bv =>
          simp only [Pion.I64.neg, IScalar.val, IScalarTy.numBits] at hlt63 hpos ⊢
          change (-bv : BitVec 64).toInt = -(bv : BitVec 64).toInt
          rw [BitVec.toInt_neg]
          change Int.bmod (-(bv : BitVec 64).toInt) (2 ^ 64) = -(bv : BitVec 64).toInt
          exact Int.bmod_eq_of_le_mul_two (by omega) (by omega)
      refine ⟨_, rfl, ?_⟩
      simp only [Bool.and_eq_true, decide_eq_true_eq]
      constructor
      · rintro ⟨hge, hlt⟩
        have h1 : (Pion.I64.neg lim).val ≤ x.val := hge
        have h2 : x.val < lim.val := hlt
        exact ⟨hw1, Or.inr ⟨by omega, by omega⟩⟩
      · rintro ⟨_, h9 | ⟨hge, hlt⟩⟩
        · omega
        · exact ⟨by show (Pion.I64.neg lim).val ≤ x.val; omega,
                 by show x.val < lim.val; omega⟩

/-- Every value fitting in an octal field of `width` bytes also fits in GNU base-256 of `width` bytes. -/
theorem fits_in_octal_imp_fits_in_base256 (width : Std.I32) (x : Std.I64)
    (hoct : fits_in_octal width x = ok true) :
    fits_in_base256 width x = ok true := by
  obtain ⟨r1, hr1, hiff1⟩ := fits_in_octal_spec width x
  rw [hr1, Result.ok.injEq] at hoct; subst hoct
  obtain ⟨hx0, hw1, hbound⟩ := hiff1.mp rfl
  obtain ⟨r2, hr2, hiff2⟩ := fits_in_base256_spec width x
  suffices hr2t : r2 = true by rw [hr2t] at hr2; exact hr2
  apply hiff2.mpr
  refine ⟨hw1, ?_⟩
  by_cases hw9 : width.val ≥ 9
  · exact Or.inl hw9
  · right
    rcases hbound with h22 | hlt
    · omega
    · have hpow : (2 ^ (3 * (width.val.toNat - 1)) : Int) ≤ (2 ^ (8 * (width.val.toNat - 1)) : Int) := by
        exact_mod_cast Nat.pow_le_pow_right (by norm_num) (by omega)
      have hpos : (0 : Int) ≤ 2 ^ (8 * (width.val.toNat - 1)) := by positivity
      omega

private theorem bv64_shl3_or (bv : BitVec 64) (dv : BitVec 32)
    (hbv0 : 0 ≤ bv.toInt) (hbv_hi : bv.toInt < 2 ^ 60)
    (hdv0 : 0 ≤ dv.toInt) (hdv7 : dv.toInt ≤ 7) :
    ((bv <<< 3) ||| dv.signExtend 64).toInt = bv.toInt * 8 + dv.toInt := by
  have hbv_nat : (bv.toNat : Int) = bv.toInt := by
    rw [BitVec.toInt_eq_toNat_cond] at hbv0 ⊢
    have := bv.isLt
    split_ifs at hbv0 ⊢ <;> omega
  have hdv_nat : (dv.toNat : Int) = dv.toInt := by
    rw [BitVec.toInt_eq_toNat_cond] at hdv0 ⊢
    have := dv.isLt
    split_ifs at hdv0 ⊢ <;> omega
  have hdv_sext : (dv.signExtend 64).toNat = dv.toNat := by
    have hlt31 : dv.toNat < 2 ^ 31 := by omega
    have hmsb : dv.msb = false := by
      rw [BitVec.msb_eq_toInt]; exact decide_eq_false (by omega)
    rw [BitVec.signExtend_eq_setWidth_of_msb_false hmsb, BitVec.toNat_setWidth]
    exact Nat.mod_eq_of_lt (by omega)
  have hbor_nat : ((bv <<< 3) ||| dv.signExtend 64).toNat = bv.toNat * 8 + dv.toNat := by
    rw [BitVec.toNat_or, BitVec.toNat_shiftLeft, hdv_sext]
    have hlt : bv.toNat * 8 < 2 ^ 64 := by omega
    rw [Nat.shiftLeft_eq, Nat.mod_eq_of_lt hlt]
    have hdv8 : dv.toNat < 8 := by omega
    have hor8 : ∀ (a b : Nat), b < 8 → (a * 8) ||| b = a * 8 + b := by
      intro a b hb
      apply Nat.eq_of_testBit_eq
      intro k
      rw [Nat.testBit_or]
      cases k with
      | zero =>
        simp only [Nat.testBit_zero]
        have h1 : (a * 8) % 2 = 0 := by omega
        have h2 : (a * 8 + b) % 2 = b % 2 := by omega
        simp [h1, h2]
      | succ k =>
        cases k with
        | zero =>
          simp only [Nat.testBit_succ, Nat.testBit_zero]
          have h1 : (a * 8) / 2 % 2 = 0 := by omega
          have h2 : (a * 8 + b) / 2 % 2 = b / 2 % 2 := by omega
          simp [h1, h2]
        | succ k =>
          cases k with
          | zero =>
            simp only [Nat.testBit_succ, Nat.testBit_zero]
            have h1 : (a * 8) / 2 / 2 % 2 = 0 := by omega
            have h2 : (a * 8 + b) / 2 / 2 % 2 = b / 2 / 2 % 2 := by omega
            simp [h1, h2]
          | succ k =>
            simp only [Nat.testBit_succ]
            have h1 : (a * 8) / 2 / 2 / 2 = a := by omega
            have h2 : b / 2 / 2 / 2 = 0 := by omega
            have h3 : (a * 8 + b) / 2 / 2 / 2 = a := by omega
            rw [h1, h2, h3, Nat.zero_testBit, Bool.or_false]
    exact hor8 bv.toNat dv.toNat hdv8
  rw [BitVec.toInt_eq_toNat_cond, hbor_nat]
  simp only [show 2 * (bv.toNat * 8 + dv.toNat) < 2 ^ 64 by omega, ↓reduceIte]
  omega

/-- Helper: bitwise `(acc << 3) | d` for `0 ≤ acc < 2^60` and `0 ≤ d ≤ 7` equals `8 * acc + d`. -/
private theorem i64_shl3_bor_val (acc : Std.I64) (d : Std.I32)
    (hacc0 : 0 ≤ acc.val) (hacc_hi : acc.val < 2 ^ 60)
    (hd0 : 0 ≤ d.val) (hd7 : d.val ≤ 7) :
    ∃ r : Std.I64, (do let t ← Pion.I64.shl_i32 acc 3#i32; ok (Pion.I64.bor t (Pion.I32.to_int64 d))) = ok r ∧
      r.val = acc.val * 8 + d.val := by
  unfold Pion.I64.shl_i32
  have h3 : (0 : Int) ≤ (3#i32 : Std.I32).val ∧ (3#i32 : Std.I32).val < 64 := by decide
  simp only [h3, and_self, ↓reduceIte, b_ok]
  refine ⟨_, rfl, ?_⟩
  have htoNat : (3#i32 : Std.I32).val.toNat = 3 := by decide
  rw [htoNat]
  cases acc with
  | mk bv =>
    cases d with
    | mk dv =>
      simp only [IScalar.val] at hacc0 hacc_hi hd0 hd7
      simp only [Pion.I64.bor, Pion.I32.to_int64, IScalar.cast, IScalar.val]
      exact bv64_shl3_or bv dv hacc0 hacc_hi hd0 hd7

/-- **Octal Fast-Path Non-Negativity & Safety Theorem**:
    For ANY standard TAR header field (width `end - start ≤ 20`, covering all 8-byte and
    12-byte POSIX/USTAR/GNU/V7 header fields), `parse_octal_slice` NEVER panics, and
    whenever it returns `Ok v`, `0 ≤ v.val < 2^60` (can NEVER silently wrap to a negative
    integer to bypass `max_entry_size`!). -/
theorem parse_octal_slice_fast_nonneg (data : Pion.Bytes) (start «end» : Std.I32)
    (hs0 : 0 ≤ start.val) (hse : start.val ≤ «end».val)
    (he : «end».val ≤ data.val.length) (hlen : data.val.length ≤ 2147483647)
    (hw : «end».val - start.val ≤ 20) :
    parse_octal_slice data start «end» ⦃ res =>
      match res with
      | .Ok v => 0 ≤ v.val ∧ v.val < 2 ^ 60
      | .Err _ => True ⦄ := by
  -- Loop 0: trim leading spaces/NULs
  have hL0 : parse_octal_slice_loop0 «end» data start ⦃ s1 => start.val ≤ s1.val ∧ s1.val ≤ «end».val ⦄ := by
    unfold parse_octal_slice_loop0
    apply loop.spec_decr_nat
      (measure := fun (s : Std.I32) => («end».val - s.val).toNat)
      (inv := fun (s : Std.I32) => start.val ≤ s.val ∧ s.val ≤ «end».val)
    · intro s ⟨h1, h2⟩
      unfold parse_octal_slice_loop0.body
      by_cases hlt : s < «end»
      · have hslt : s.val < «end».val := hlt
        obtain ⟨x, hx, _⟩ := bytes_get_spec data s (by omega) (by omega)
        simp only [hlt, ↓reduceIte, hx, b_ok]
        by_cases hws : ((Pion.U8.to_int x == 32#i32) || (Pion.U8.to_int x == 0#i32)) = true
        · simp only [hws, ↓reduceIte]; rw [WP.spec_ok]
          have hadd : (Pion.I32.add s 1#i32).val = s.val + 1 := i32_add_val (by simp; omega) (by simp; omega)
          exact ⟨⟨by omega, by omega⟩, by omega⟩
        · simp only [hws, ↓reduceIte, Bool.false_eq_true]; rw [WP.spec_ok]
          exact ⟨h1, h2⟩
      · simp only [hlt, ↓reduceIte]; rw [WP.spec_ok]
        exact ⟨h1, h2⟩
    · exact ⟨le_refl _, hse⟩
  rw [wp_ok_iff] at hL0
  obtain ⟨s1, hs1, hs1_lo, hs1_hi⟩ := hL0
  -- Loop 1: trim trailing spaces/NULs
  have hL1 : parse_octal_slice_loop1 s1 data «end» ⦃ e1 => s1.val ≤ e1.val ∧ e1.val ≤ «end».val ⦄ := by
    unfold parse_octal_slice_loop1
    apply loop.spec_decr_nat
      (measure := fun (e : Std.I32) => (e.val - s1.val).toNat)
      (inv := fun (e : Std.I32) => s1.val ≤ e.val ∧ e.val ≤ «end».val)
    · intro e ⟨h1, h2⟩
      unfold parse_octal_slice_loop1.body
      by_cases hgt : e > s1
      · have hegt : e.val > s1.val := hgt
        have hsub : (Pion.I32.sub e 1#i32).val = e.val - 1 := i32_sub_val (by simp; omega) (by simp; omega)
        obtain ⟨x, hx, _⟩ := bytes_get_spec data (Pion.I32.sub e 1#i32) (by omega) (by omega)
        simp only [hgt, ↓reduceIte, hx, b_ok]
        by_cases hws : ((Pion.U8.to_int x == 32#i32) || (Pion.U8.to_int x == 0#i32)) = true
        · simp only [hws, ↓reduceIte]; rw [WP.spec_ok]
          exact ⟨⟨by omega, by omega⟩, by omega⟩
        · simp only [hws, ↓reduceIte, Bool.false_eq_true]; rw [WP.spec_ok]
          exact ⟨h1, h2⟩
      · simp only [hgt, ↓reduceIte]; rw [WP.spec_ok]
        exact ⟨h1, h2⟩
    · exact ⟨hs1_hi, le_refl _⟩
  rw [wp_ok_iff] at hL1
  obtain ⟨e1, he1, he1_lo, he1_hi⟩ := hL1
  unfold parse_octal_slice
  dsimp only
  rw [hs1, b_ok, he1, b_ok]
  by_cases hempty1 : s1 ≥ e1
  · simp only [hempty1, ↓reduceIte]; rw [WP.spec_ok]; simp
  · simp only [hempty1, ↓reduceIte]
    -- Loop 2: stop at first embedded NUL
    have hL2 : parse_octal_slice_loop2 data s1 e1 ⦃ p => s1.val ≤ p.2.val ∧ p.2.val ≤ e1.val ⦄ := by
      unfold parse_octal_slice_loop2
      apply loop.spec_decr_nat
        (measure := fun (p : Std.I32 × Std.I32) => (p.2.val - p.1.val).toNat)
        (inv := fun (p : Std.I32 × Std.I32) => s1.val ≤ p.1.val ∧ p.1.val ≤ p.2.val ∧ p.2.val ≤ e1.val)
      · rintro ⟨i, e⟩ ⟨h1, h2, h3⟩
        dsimp only at h1 h2 h3 ⊢
        unfold parse_octal_slice_loop2.body
        by_cases hlt : i < e
        · have hilt : i.val < e.val := hlt
          obtain ⟨x, hx, _⟩ := bytes_get_spec data i (by omega) (by omega)
          simp only [hlt, ↓reduceIte, hx, b_ok]
          by_cases hnul : Pion.U8.to_int x = 0#i32
          · simp only [hnul, ↓reduceIte]; rw [WP.spec_ok]; dsimp only; omega
          · simp only [hnul, ↓reduceIte]; rw [WP.spec_ok]; dsimp only
            have hadd : (Pion.I32.add i 1#i32).val = i.val + 1 := i32_add_val (by simp; omega) (by simp; omega)
            exact ⟨⟨by omega, by omega, h3⟩, by omega⟩
        · simp only [hlt, ↓reduceIte]; rw [WP.spec_ok]; dsimp only; omega
      · exact ⟨le_refl _, he1_lo, le_refl _⟩
    rw [wp_ok_iff] at hL2
    obtain ⟨⟨i1, e2⟩, hL2eq, he2_lo, he2_hi⟩ := hL2
    dsimp only at he2_lo he2_hi
    rw [hL2eq, b_ok2]
    by_cases hempty2 : s1 ≥ e2
    · simp only [hempty2, ↓reduceIte]; rw [WP.spec_ok]; simp
    · simp only [hempty2, ↓reduceIte]
      have hsub20 : (Pion.I32.sub e2 s1).val = e2.val - s1.val := i32_sub_val (by omega) (by omega)
      have hle20 : Pion.I32.sub e2 s1 ≤ 20#i32 := by
        show (Pion.I32.sub e2 s1).val ≤ (20#i32 : Std.I32).val
        rw [hsub20]; simp; omega
      simp only [hle20, ↓reduceIte]
      -- Loop 3: accumulate up to 20 octal digits
      have hL3 : parse_octal_slice_loop3 e2 data s1 0#i64 ⦃ s =>
          match s with
          | .inl (.Ok v) => 0 ≤ v.val ∧ v.val < 2 ^ 60
          | .inl (.Err _) => True
          | .inr (_, acc) => 0 ≤ acc.val ∧ acc.val < 2 ^ 60 ⦄ := by
        unfold parse_octal_slice_loop3
        apply loop.spec_decr_nat
          (measure := fun (p : Std.I32 × Std.I64) => (e2.val - p.1.val).toNat)
          (inv := fun (p : Std.I32 × Std.I64) =>
            s1.val ≤ p.1.val ∧ p.1.val ≤ e2.val ∧
            0 ≤ p.2.val ∧ p.2.val < (2 ^ (3 * (p.1.val - s1.val).toNat) : Int))
        · rintro ⟨i, acc⟩ ⟨h1, h2, hacc0, hacc_lt⟩
          dsimp only at h1 h2 hacc0 hacc_lt ⊢
          unfold parse_octal_slice_loop3.body
          by_cases hlt : i < e2
          · have hilt : i.val < e2.val := hlt
            obtain ⟨x, hx, _⟩ := bytes_get_spec data i (by omega) (by omega)
            simp only [hlt, ↓reduceIte, hx, b_ok]
            have hd_val : (Pion.I32.sub (Pion.U8.to_int x) 48#i32).val = (x.val : Int) - 48 := by
              have hxv := u8_to_int_val x
              have hxb : x.val < 256 := x.bv.isLt
              rw [i32_sub_val (by rw [hxv]; simp; omega) (by rw [hxv]; simp; omega), hxv]; simp
            by_cases hbad : ((decide (Pion.I32.sub (Pion.U8.to_int x) 48#i32 < 0#i32)) ||
                (decide (Pion.I32.sub (Pion.U8.to_int x) 48#i32 > 7#i32))) = true
            · simp only [hbad, ↓reduceIte]; rw [WP.spec_ok]; trivial
            · simp only [hbad, ↓reduceIte, Bool.false_eq_true]
              have hd_bounds : 0 ≤ (Pion.I32.sub (Pion.U8.to_int x) 48#i32).val ∧
                  (Pion.I32.sub (Pion.U8.to_int x) 48#i32).val ≤ 7 := by
                simp only [Bool.or_eq_true, decide_eq_true_eq, not_or] at hbad
                have h1' : ¬ ((Pion.I32.sub (Pion.U8.to_int x) 48#i32).val < 0) := hbad.1
                have h2' : ¬ ((Pion.I32.sub (Pion.U8.to_int x) 48#i32).val > 7) := hbad.2
                omega
              have hpow_le : (2 ^ (3 * (i.val - s1.val).toNat) : Int) ≤ 2 ^ 57 := by
                exact_mod_cast Nat.pow_le_pow_right (by norm_num) (by omega)
              have hacc_57 : acc.val < 2 ^ 60 := by omega
              obtain ⟨acc1, hacc1, hacc1_val⟩ :=
                i64_shl3_bor_val acc (Pion.I32.sub (Pion.U8.to_int x) 48#i32)
                  hacc0 hacc_57 hd_bounds.1 hd_bounds.2
              unfold Pion.I64.shl_i32 at hacc1 ⊢
              have h3 : (0 : Int) ≤ (3#i32 : Std.I32).val ∧ (3#i32 : Std.I32).val < 64 := by decide
              simp only [h3, and_self, ↓reduceIte, b_ok] at hacc1 ⊢
              rw [Result.ok.injEq] at hacc1
              rw [WP.spec_ok]; dsimp only
              have hadd : (Pion.I32.add i 1#i32).val = i.val + 1 := i32_add_val (by simp; omega) (by simp; omega)
              have hexp1 : 3 * (i.val + 1 - s1.val).toNat = 3 * (i.val - s1.val).toNat + 3 := by omega
              have hpow_mul : (2 ^ (3 * (i.val - s1.val).toNat + 3) : Int) =
                  (2 ^ (3 * (i.val - s1.val).toNat) : Int) * 8 := by
                rw [pow_add]; norm_num
              rw [hacc1]
              refine ⟨⟨by omega, by omega, by omega, ?_⟩, by omega⟩
              rw [hadd, hexp1, hpow_mul]; omega
          · simp only [hlt, ↓reduceIte]; rw [WP.spec_ok]; dsimp only
            have hpow60 : (2 ^ (3 * (i.val - s1.val).toNat) : Int) ≤ 2 ^ 60 := by
              exact_mod_cast Nat.pow_le_pow_right (by norm_num) (by omega)
            omega
        · refine ⟨le_refl _, he2_lo, by simp, ?_⟩
          simp only [sub_self, Int.toNat_zero, Nat.mul_zero, pow_zero]
          show (0#i64 : Std.I64).val < 1; decide
      rw [wp_ok_iff] at hL3
      obtain ⟨s, hs, hpost⟩ := hL3
      rw [hs, b_ok]
      cases s with
      | inl r =>
        rw [WP.spec_ok]
        cases r with
        | Ok v => exact hpost
        | Err _ => trivial
      | inr p =>
        rw [WP.spec_ok]; exact hpost

/-- Helper: `x >>> 63 = 0` on `Std.U64` implies `x.val < 2^63`, so `x.to_int64.val = x.val ≥ 0`
    and `(-(x.to_int64) - 1).val = -x.val - 1 < 0`. -/
private theorem u64_shr63_zero_lt (x : Std.U64)
    (h : ¬ ((⟨x.bv >>> (63#u64 : Std.U64).val⟩ : Std.U64) > 0#u64)) :
    x.val < 2 ^ 63 := by
  have h63 : (63#u64 : Std.U64).val = 63 := by decide
  cases x with
  | mk bv =>
    have hlt := bv.isLt
    change ¬ (bv.toNat >>> 63 > 0) at h
    rw [Nat.shiftRight_eq_div_pow] at h
    simp only [UScalar.val]; omega

private theorem u64_to_i64_nonneg (x : Std.U64) (hlt : x.val < 2 ^ 63) :
    (Pion.U64.to_int64 x).val = (x.val : Int) := by
  cases x with
  | mk bv =>
    simp only [Pion.U64.to_int64, UScalar.hcast, IScalar.val, UScalar.val,
      IScalarTy.numBits, UScalarTy.numBits] at hlt ⊢
    change (BitVec.setWidth 64 (bv : BitVec 64)).toInt = ((bv : BitVec 64).toNat : Int)
    rw [BitVec.toInt_eq_toNat_cond, BitVec.toNat_setWidth]
    have hlt64 : (bv : BitVec 64).toNat < 2 ^ 64 := by omega
    rw [Nat.mod_eq_of_lt hlt64]
    simp only [show 2 * (bv : BitVec 64).toNat < 2 ^ 64 by omega, ↓reduceIte]

private theorem u64_neg_sub1_lt_zero (x : Std.U64) (hlt : x.val < 2 ^ 63) :
    (Pion.I64.sub (Pion.I64.neg (Pion.U64.to_int64 x)) 1#i64).val = -(x.val : Int) - 1 := by
  have hi := u64_to_i64_nonneg x hlt
  have hneg : (Pion.I64.neg (Pion.U64.to_int64 x)).val = -(x.val : Int) := by
    cases h : Pion.U64.to_int64 x with
    | mk bv =>
      rw [h] at hi
      simp only [Pion.I64.neg, IScalar.val, IScalarTy.numBits] at hi ⊢
      change (-bv : BitVec 64).toInt = -(x.val : Int)
      rw [BitVec.toInt_neg]
      change Int.bmod (-(bv : BitVec 64).toInt) (2 ^ 64) = -(x.val : Int)
      have hbv_eq : (bv : BitVec 64).toInt = (x.val : Int) := hi
      rw [hbv_eq]
      exact Int.bmod_eq_of_le_mul_two (by omega) (by omega)
  simp only [Pion.I64.sub, Std.I64.wrapping_sub, IScalar.wrapping_sub, IScalar.val, IScalarTy.numBits]
  rw [BitVec.toInt_sub]
  have h1 : (1#i64 : Std.I64).bv.toInt = 1 := by decide
  rw [h1]
  change Int.bmod ((Pion.I64.neg (Pion.U64.to_int64 x)).val - 1) (2 ^ 64) = -(x.val : Int) - 1
  rw [hneg]
  exact Int.bmod_eq_of_le_mul_two (by omega) (by omega)

/-- **GNU Base-256 Sign-Preservation & Overflow-Immunity Theorem**:
    Whenever a TAR numeric field has the base-256 marker bit (`b[start] & 0x80 ≠ 0`):
    - `parse_numeric_slice` NEVER panics;
    - If the sign bit is clear (`b[start] & 0x40 = 0`, positive base-256), any `Ok v` satisfies **`0 ≤ v.val`**
      (can NEVER silently overflow into a negative size to bypass `max_entry_size`!);
    - If the sign bit is set (`b[start] & 0x40 ≠ 0`, negative base-256), any `Ok v` satisfies **`v.val < 0`**
      (can NEVER silently wrap into a positive size!). -/
theorem parse_numeric_slice_base256_sign (data : Pion.Bytes) (start «end» : Std.I32)
    (hs0 : 0 ≤ start.val) (hslt : start.val < «end».val)
    (he : «end».val ≤ data.val.length) (hlen : data.val.length ≤ 2147483647)
    (b0 : Std.U8) (hb0 : data.val[start.val.toNat]? = some b0)
    (hmarker : (Pion.I32.band (Pion.U8.to_int b0) 128#i32) ≠ 0#i32) :
    parse_numeric_slice data start «end» ⦃ res =>
      match res with
      | .Err _ => True
      | .Ok v =>
        if (Pion.I32.band (Pion.U8.to_int b0) 64#i32) ≠ 0#i32 then v.val < 0 else 0 ≤ v.val ⦄ := by
  unfold parse_numeric_slice
  have hlt_i : start < «end» := hslt
  obtain ⟨x0, hx0, hx0eq⟩ := bytes_get_spec data start hs0 (by omega)
  rw [hb0] at hx0eq; injection hx0eq with hxb; subst hxb
  have hne_b : ((Pion.I32.band (Pion.U8.to_int b0) 128#i32) != 0#i32) = true :=
    bne_iff_ne.mpr hmarker
  simp only [hlt_i, ↓reduceIte, hx0, b_ok, hne_b]
  let inv := if (Pion.I32.band (Pion.U8.to_int b0) 64#i32) ≠ 0#i32 then 255#i32 else 0#i32
  have hL0 : parse_numeric_slice_loop0 «end» data inv start start 0#u64 ⦃ s =>
      match s with | .inl (.Ok _) => False | _ => True ⦄ := by
    unfold parse_numeric_slice_loop0
    apply loop.spec_decr_nat
      (measure := fun (p : Std.I32 × Std.U64) => («end».val - p.1.val).toNat)
      (inv := fun (p : Std.I32 × Std.U64) => start.val ≤ p.1.val ∧ p.1.val ≤ «end».val)
    · rintro ⟨i, x⟩ ⟨h1, h2⟩
      dsimp only at h1 h2 ⊢
      unfold parse_numeric_slice_loop0.body
      by_cases hlt : i < «end»
      · have hilt : i.val < «end».val := hlt
        obtain ⟨bi, hbi, _⟩ := bytes_get_spec data i (by omega) (by omega)
        simp only [hlt, ↓reduceIte, hbi, b_ok]
        have hshr56 : Pion.U64.shr x 56#u64 = ok ⟨x.bv >>> (56#u64 : Std.U64).val⟩ := by
          unfold Pion.U64.shr; simp [show (56#u64 : Std.U64).val < 64 by decide]
        have hshl8 : Pion.U64.shl x 8#u64 = ok ⟨x.bv <<< (8#u64 : Std.U64).val⟩ := by
          unfold Pion.U64.shl; simp [show (8#u64 : Std.U64).val < 64 by decide]
        split_ifs <;> (
          rw [b_ok, hshr56, b_ok]
          by_cases hov : (⟨x.bv >>> (56#u64 : Std.U64).val⟩ : Std.U64) > 0#u64
          · simp only [hov, ↓reduceIte]; rw [WP.spec_ok]; trivial
          · simp only [hov, ↓reduceIte, hshl8, b_ok]; rw [WP.spec_ok]; dsimp only
            have hadd : (Pion.I32.add i 1#i32).val = i.val + 1 := i32_add_val (by simp; omega) (by simp; omega)
            exact ⟨⟨by omega, by omega⟩, by omega⟩)
      · simp only [hlt, ↓reduceIte]; rw [WP.spec_ok]; trivial
    · exact ⟨le_refl _, le_of_lt hslt⟩
  rw [wp_ok_iff] at hL0
  obtain ⟨s, hs, hpost⟩ := hL0
  change (do let __s ← parse_numeric_slice_loop0 «end» data inv start start 0#u64; _) ⦃ _ ⦄
  rw [hs, b_ok]
  cases s with
  | inl r =>
    rw [WP.spec_ok]
    cases r with
    | Err _ => trivial
    | Ok _ => exact False.elim hpost
  | inr p =>
    rcases p with ⟨i1, x1⟩
    dsimp only
    have hshr63 : Pion.U64.shr x1 63#u64 = ok ⟨x1.bv >>> (63#u64 : Std.U64).val⟩ := by
      unfold Pion.U64.shr; simp [show (63#u64 : Std.U64).val < 64 by decide]
    rw [hshr63, b_ok]
    by_cases hov : (⟨x1.bv >>> (63#u64 : Std.U64).val⟩ : Std.U64) > 0#u64
    · simp only [hov, ↓reduceIte]; rw [WP.spec_ok]; trivial
    · simp only [hov, ↓reduceIte]
      have hx1_lt : x1.val < 2 ^ 63 := u64_shr63_zero_lt x1 hov
      by_cases hneg : (Pion.I32.band (Pion.U8.to_int b0) 64#i32) ≠ 0#i32
      · have hinv : (if (Pion.I32.band (Pion.U8.to_int b0) 64#i32) ≠ 0#i32 then 255#i32 else 0#i32) = 255#i32 :=
          ite_eq_left_iff.mpr (fun h => False.elim (h hneg))
        simp only [hinv, ↓reduceIte]; rw [WP.spec_ok]; dsimp only
        split_ifs
        have hlt0 := u64_neg_sub1_lt_zero x1 hx1_lt; omega
      · have hinv : (if (Pion.I32.band (Pion.U8.to_int b0) 64#i32) ≠ 0#i32 then 255#i32 else 0#i32) = 0#i32 :=
          ite_eq_right_iff.mpr (fun h => False.elim (hneg h))
        have hne255 : (0#i32 : Std.I32) ≠ 255#i32 := by decide
        simp only [hinv, hne255, ↓reduceIte]; rw [WP.spec_ok]; dsimp only
        split_ifs
        have hge0 := u64_to_i64_nonneg x1 hx1_lt; omega

/-- `format_octal_into` totality & length preservation on valid buffers. -/
lemma format_octal_into_total (buf : Pion.Bytes) (off width : Std.I32) (x : Std.I64)
    (hoff0 : 0 ≤ off.val) (hw0 : 0 ≤ width.val)
    (hbound : off.val + width.val ≤ buf.val.length) (hlen : buf.val.length ≤ 2147483647) :
    ∃ r : Bool × Pion.Bytes, format_octal_into buf off width x = ok r ∧
      r.2.val.length = buf.val.length ∧
      (r.1 = true ↔ fits_in_octal width x = ok true) := by
  obtain ⟨fits, hfits, _⟩ := fits_in_octal_spec width x
  unfold format_octal_into
  rw [hfits, b_ok]
  cases fits with
  | false =>
    simp only [Bool.not_false, ↓reduceIte]
    have hL0 : format_octal_into_loop0 width off 0#i32 buf ⦃ p => p.2.val.length = buf.val.length ⦄ := by
      unfold format_octal_into_loop0
      apply loop.spec_decr_nat
        (measure := fun (p : Std.I32 × Pion.Bytes) => (width.val - p.1.val).toNat)
        (inv := fun (p : Std.I32 × Pion.Bytes) =>
          0 ≤ p.1.val ∧ p.1.val ≤ width.val ∧ p.2.val.length = buf.val.length)
      · rintro ⟨i, b⟩ ⟨hi0, hile, hblen⟩
        dsimp only at hi0 hile hblen ⊢
        unfold format_octal_into_loop0.body
        have hwm1 : (Pion.I32.sub width 1#i32).val = width.val - 1 :=
          i32_sub_val (by simp; omega) (by simp; omega)
        by_cases hlt : i < Pion.I32.sub width 1#i32
        · have hilt : i.val < width.val - 1 := by
            have : i.val < (Pion.I32.sub width 1#i32).val := hlt; omega
          have hidx : (Pion.I32.add off i).val = off.val + i.val :=
            i32_add_val (by omega) (by omega)
          have hset : Pion.Bytes.set b (Pion.I32.add off i) (Pion.I32.to_byte 48#i32) =
              ok ⟨b.val.set (Pion.I32.add off i).val.toNat (Pion.I32.to_byte 48#i32)⟩ := by
            unfold Pion.Bytes.set Pion.listSet
            have hb : Pion.inBounds (Pion.I32.add off i) b.val.length := ⟨by omega, by omega⟩
            simp only [hb, ↓reduceIte, b_ok]
          simp only [hlt, ↓reduceIte, hset, b_ok]; rw [WP.spec_ok]; dsimp only
          have hi1 : (Pion.I32.add i 1#i32).val = i.val + 1 := i32_add_val (by simp; omega) (by simp; omega)
          exact ⟨⟨by omega, by omega, by simp [hblen]⟩, by omega⟩
        · simp only [hlt, ↓reduceIte]; rw [WP.spec_ok]; exact hblen
      · exact ⟨by simp, by simp; omega, rfl⟩
    rw [wp_ok_iff] at hL0
    obtain ⟨⟨i1, buf1⟩, hL0eq, hbuf1_len⟩ := hL0
    dsimp only at hbuf1_len ⊢
    rw [hL0eq, b_ok2]
    by_cases hwpos : width > 0#i32
    · have hwgt : width.val > 0 := hwpos
      have hidx : (Pion.I32.sub (Pion.I32.add off width) 1#i32).val = off.val + width.val - 1 := by
        have ha : (Pion.I32.add off width).val = off.val + width.val := i32_add_val (by omega) (by omega)
        rw [i32_sub_val (by rw [ha]; simp; omega) (by rw [ha]; simp; omega), ha]; simp
      have hset : Pion.Bytes.set buf1 (Pion.I32.sub (Pion.I32.add off width) 1#i32) (Pion.I32.to_byte 0#i32) =
          ok ⟨buf1.val.set (Pion.I32.sub (Pion.I32.add off width) 1#i32).val.toNat (Pion.I32.to_byte 0#i32)⟩ := by
        unfold Pion.Bytes.set Pion.listSet
        have hb : Pion.inBounds (Pion.I32.sub (Pion.I32.add off width) 1#i32) buf1.val.length :=
          ⟨by omega, by omega⟩
        simp only [hb, ↓reduceIte, b_ok]
      simp only [hwpos, ↓reduceIte, hset, b_ok]
      exact ⟨_, rfl, by simp [hbuf1_len], ⟨(by intro h; cases h), fun h => False.elim (by rw [Result.ok.injEq] at h; cases h)⟩⟩
    · simp only [hwpos, ↓reduceIte, b_ok]
      exact ⟨_, rfl, hbuf1_len, ⟨(by intro h; cases h), fun h => False.elim (by rw [Result.ok.injEq] at h; cases h)⟩⟩
  | true =>
    simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte]
    have hw1 : 1 ≤ width.val := by
      obtain ⟨r, hr, hiff⟩ := fits_in_octal_spec width x
      rw [hfits, Result.ok.injEq] at hr; subst hr
      exact (hiff.mp rfl).2.1
    have hpos0 : (Pion.I32.sub (Pion.I32.add off width) 2#i32).val = off.val + width.val - 2 := by
      have ha : (Pion.I32.add off width).val = off.val + width.val := i32_add_val (by omega) (by omega)
      rw [i32_sub_val (by rw [ha]; simp; omega) (by rw [ha]; simp; omega), ha]; simp
    have hL1 : format_octal_into_loop1 off (Pion.I32.sub (Pion.I32.add off width) 2#i32) buf x
        ⦃ p => p.2.1.val.length = buf.val.length ⦄ := by
      unfold format_octal_into_loop1
      apply loop.spec_decr_nat
        (measure := fun (p : Std.I32 × Pion.Bytes × Std.I64) => (p.1.val - off.val + 1).toNat)
        (inv := fun (p : Std.I32 × Pion.Bytes × Std.I64) =>
          off.val - 1 ≤ p.1.val ∧ p.1.val ≤ off.val + width.val - 1 ∧ p.2.1.val.length = buf.val.length)
      · rintro ⟨pos, b, v⟩ ⟨h1, h2, hblen⟩
        dsimp only at h1 h2 hblen ⊢
        unfold format_octal_into_loop1.body
        by_cases hge : pos ≥ off
        · have hposge : pos.val ≥ off.val := hge
          have hset : Pion.Bytes.set b pos (Pion.I32.to_byte (Pion.I32.add 48#i32 (Pion.I64.to_int (Pion.I64.band v 7#i64)))) =
              ok ⟨b.val.set pos.val.toNat (Pion.I32.to_byte (Pion.I32.add 48#i32 (Pion.I64.to_int (Pion.I64.band v 7#i64))))⟩ := by
            unfold Pion.Bytes.set Pion.listSet
            have hb : Pion.inBounds pos b.val.length := ⟨by omega, by omega⟩
            simp only [hb, ↓reduceIte, b_ok]
          have hshr : Pion.I64.shr_i32 v 3#i32 = ok ⟨v.bv.sshiftRight (3#i32 : Std.I32).val.toNat⟩ := by
            unfold Pion.I64.shr_i32; simp [show (0 : Int) ≤ (3#i32 : Std.I32).val ∧ (3#i32 : Std.I32).val < 64 by decide]
          simp only [hge, ↓reduceIte, hset, hshr, b_ok]; rw [WP.spec_ok]; dsimp only
          have hpos1 : (Pion.I32.sub pos 1#i32).val = pos.val - 1 := i32_sub_val (by simp; omega) (by simp; omega)
          exact ⟨⟨by omega, by omega, by simp [hblen]⟩, by omega⟩
        · simp only [hge, ↓reduceIte]; rw [WP.spec_ok]; exact hblen
      · dsimp only; exact ⟨by omega, by omega, rfl⟩
    rw [wp_ok_iff] at hL1
    obtain ⟨⟨pos1, buf4, v1⟩, hL1eq, hbuf4_len⟩ := hL1
    dsimp only at hbuf4_len ⊢
    rw [hL1eq, b_ok3]
    have hidx : (Pion.I32.sub (Pion.I32.add off width) 1#i32).val = off.val + width.val - 1 := by
      have ha : (Pion.I32.add off width).val = off.val + width.val := i32_add_val (by omega) (by omega)
      rw [i32_sub_val (by rw [ha]; simp; omega) (by rw [ha]; simp; omega), ha]; simp
    have hset : Pion.Bytes.set buf4 (Pion.I32.sub (Pion.I32.add off width) 1#i32) (Pion.I32.to_byte 0#i32) =
        ok ⟨buf4.val.set (Pion.I32.sub (Pion.I32.add off width) 1#i32).val.toNat (Pion.I32.to_byte 0#i32)⟩ := by
      unfold Pion.Bytes.set Pion.listSet
      have hb : Pion.inBounds (Pion.I32.sub (Pion.I32.add off width) 1#i32) buf4.val.length :=
        ⟨by omega, by omega⟩
      simp only [hb, ↓reduceIte, b_ok]
    rw [hset, b_ok]
    exact ⟨_, rfl, by simp [hbuf4_len], ⟨fun _ => trivial, fun _ => rfl⟩⟩

/-- **TAR Numeric Formatter Totality & Capacity Theorem (`format_numeric`)**:
    For ANY positive `width` (`1 ≤ width ≤ 2^31 - 1`) and ANY `x : Int64`, `format_numeric width x`
    NEVER panics, and returns `Ok out` (with `out.val.length = width`) if and only if
    `fits_in_base256 width x = ok true`. -/
theorem format_numeric_spec (width : Std.I32) (x : Std.I64) (hw1 : 1 ≤ width.val) :
    ∃ res : Pion.Res Pion.Bytes TarError, format_numeric width x = ok res ∧
      (match res with
       | .Ok out => out.val.length = width.val.toNat ∧ fits_in_base256 width x = ok true
       | .Err _ => fits_in_base256 width x = ok false) := by
  unfold format_numeric
  have hnotle : ¬ (width ≤ 0#i32) := by
    show ¬ (width.val ≤ (0#i32 : Std.I32).val); simp; omega
  simp only [hnotle, ↓reduceIte]
  let out0 := Pion.Bytes.new width
  have hout0_len : out0.val.length = width.val.toNat := by
    simp [out0, Pion.Bytes.new, Pion.listMake]
  have hlen_bound : out0.val.length ≤ 2147483647 := by
    have := width.hBounds
    simp only [IScalar.max, IScalarTy.numBits] at this
    omega
  unfold format_numeric_into
  obtain ⟨foct, hfoct, _⟩ := fits_in_octal_spec width x
  rw [hfoct, b_ok]
  cases foct with
  | true =>
    simp only [↓reduceIte]
    have hb256 := fits_in_octal_imp_fits_in_base256 width x hfoct
    obtain ⟨⟨ok1, buf1⟩, hfmt, hblen, hok_iff⟩ :=
      format_octal_into_total out0 0#i32 width x (by simp) (by omega) (by simp [hout0_len]) hlen_bound
    have hok_true : ok1 = true := hok_iff.mpr hfoct
    subst hok_true
    dsimp only at hblen ⊢
    rw [hfmt, b_ok2, b_ok2]
    simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte]
    exact ⟨.Ok buf1, rfl, by rw [hblen, hout0_len], hb256⟩
  | false =>
    simp only [Bool.false_eq_true, ↓reduceIte]
    obtain ⟨fb256, hfb256, _⟩ := fits_in_base256_spec width x
    rw [hfb256, b_ok]
    cases fb256 with
    | false =>
      simp only [Bool.false_eq_true, ↓reduceIte]
      obtain ⟨⟨ok1, buf4⟩, hfmt, _, _⟩ :=
        format_octal_into_total out0 0#i32 width 0#i64 (by simp) (by omega) (by simp [hout0_len]) hlen_bound
      rw [hfmt, b_ok2, b_ok2]
      simp only [Bool.not_false, ↓reduceIte]
      exact ⟨.Err _, rfl, trivial⟩
    | true =>
      simp only [↓reduceIte]
      have hwm1 : (Pion.I32.sub width 1#i32).val = width.val - 1 :=
        i32_sub_val (by simp; omega) (by simp; omega)
      have hL0 : format_numeric_into_loop0 0#i32 (Pion.I32.sub width 1#i32) out0 x
          ⦃ p => p.2.1.val.length = out0.val.length ⦄ := by
        unfold format_numeric_into_loop0
        apply loop.spec_decr_nat
          (measure := fun (p : Std.I32 × Pion.Bytes × Std.I64) => (p.1.val + 1).toNat)
          (inv := fun (p : Std.I32 × Pion.Bytes × Std.I64) =>
            -1 ≤ p.1.val ∧ p.1.val ≤ width.val - 1 ∧ p.2.1.val.length = out0.val.length)
        · rintro ⟨i, b, v⟩ ⟨h1, h2, hblen⟩
          dsimp only at h1 h2 hblen ⊢
          unfold format_numeric_into_loop0.body
          by_cases hge : i ≥ 0#i32
          · have hige : i.val ≥ 0 := hge
            have h0v : (0#i32 : Std.I32).val = 0 := rfl
            have hidx : (Pion.I32.add 0#i32 i).val = i.val := by
              rw [i32_add_val (by omega) (by omega), h0v]; omega
            have hset : Pion.Bytes.set b (Pion.I32.add 0#i32 i)
                (Pion.I32.to_byte (Pion.I64.to_int (Pion.I64.band v 255#i64))) =
                ok ⟨b.val.set (Pion.I32.add 0#i32 i).val.toNat
                  (Pion.I32.to_byte (Pion.I64.to_int (Pion.I64.band v 255#i64)))⟩ := by
              unfold Pion.Bytes.set Pion.listSet
              have hb : Pion.inBounds (Pion.I32.add 0#i32 i) b.val.length := ⟨by omega, by omega⟩
              simp only [hb, ↓reduceIte, b_ok]
            have hshr : Pion.I64.shr_i32 v 8#i32 = ok ⟨v.bv.sshiftRight (8#i32 : Std.I32).val.toNat⟩ := by
              unfold Pion.I64.shr_i32; simp [show (0 : Int) ≤ (8#i32 : Std.I32).val ∧ (8#i32 : Std.I32).val < 64 by decide]
            simp only [hge, ↓reduceIte, hset, hshr, b_ok]; rw [WP.spec_ok]; dsimp only
            have hi1 : (Pion.I32.sub i 1#i32).val = i.val - 1 := i32_sub_val (by simp; omega) (by simp; omega)
            exact ⟨⟨by omega, by omega, by simp [hblen]⟩, by omega⟩
          · simp only [hge, ↓reduceIte]; rw [WP.spec_ok]; exact hblen
        · dsimp only; exact ⟨by omega, by omega, rfl⟩
      rw [wp_ok_iff] at hL0
      obtain ⟨⟨i1, buf2, v1⟩, hL0eq, hbuf2_len⟩ := hL0
      dsimp only at hbuf2_len ⊢
      obtain ⟨b0, hb0, _⟩ := bytes_get_spec buf2 0#i32 (by simp) (by simp [hbuf2_len, hout0_len]; omega)
      have hset0 : Pion.Bytes.set buf2 0#i32 (Pion.I32.to_byte (Pion.I32.bor (Pion.U8.to_int b0) 128#i32)) =
          ok ⟨buf2.val.set (0#i32 : Std.I32).val.toNat (Pion.I32.to_byte (Pion.I32.bor (Pion.U8.to_int b0) 128#i32))⟩ := by
        unfold Pion.Bytes.set Pion.listSet
        have hb : Pion.inBounds 0#i32 buf2.val.length := ⟨by simp, by simp [hbuf2_len, hout0_len]; omega⟩
        simp only [hb, ↓reduceIte, b_ok]
      rw [hL0eq, b_ok3, hb0, b_ok, hset0, b_ok, b_ok2]
      simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte]
      exact ⟨.Ok _, rfl, by simp [hbuf2_len, hout0_len], trivial⟩

end TarProofs
