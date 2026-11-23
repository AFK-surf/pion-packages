/-
Formal verification of `packages/jwt` (`Jwt.Funs`, extracted via
`pionc extract-lean` from `packages/jwt/src/*.pion`).

All proofs are complete and kernel-checked, depending only on the three
standard Lean axioms: `propext`, `Classical.choice`, `Quot.sound`.
-/
import Jwt.Funs

open Aeneas Aeneas.Std Result ControlFlow Error Pion WP

set_option maxRecDepth 2048
set_option maxHeartbeats 400000
set_option linter.unusedSimpArgs false

namespace JwtProofs

open jwt

/-! ## Common Scalar, BitVec & Container Helpers -/

theorem b_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← (ok x : Result α); f y) = f x := by simp

theorem wp_ok_iff {α : Type u} (r : Result α) (P : α → Prop) :
    r ⦃ P ⦄ ↔ ∃ y, r = ok y ∧ P y := by
  cases r with
  | ret y => simp [WP.spec_ok]
  | vis e k => simp [WP.spec_vis]
  | div => simp [WP.spec_div]

theorem u8_to_int_val (x : Std.U8) : (Pion.U8.to_int x).val = (x.val : Int) := by
  cases x with
  | mk bv =>
    have hlt : bv.toNat < 256 := bv.isLt
    simp only [Pion.U8.to_int, UScalar.hcast, IScalar.val, UScalar.val,
      BitVec.toInt_setWidth, BitVec.toInt_ofNat, IScalarTy.numBits, UScalarTy.numBits]
    rw [Int.bmod_eq_of_le_mul_two] <;> omega

theorem i32_to_byte_val {x : Std.I32} (h0 : 0 ≤ x.val) (hhi : x.val < 256) :
    (Pion.I32.to_byte x).val = x.val.toNat := by
  cases x with
  | mk bv =>
    change 0 ≤ bv.toInt at h0
    change bv.toInt < 256 at hhi
    have hlt : bv.toNat < 4294967296 := bv.isLt
    have hbv : bv.toInt = (bv.toNat : Int) := by
      rw [BitVec.toInt_eq_toNat_cond] at h0 ⊢
      change (if 2 * bv.toNat < 4294967296 then (bv.toNat : Int) else (bv.toNat : Int) - 4294967296) ≥ 0 at h0
      change (if 2 * bv.toNat < 4294967296 then (bv.toNat : Int) else (bv.toNat : Int) - 4294967296) = (bv.toNat : Int)
      split_ifs at h0 ⊢ <;> omega
    have hnat : bv.toNat < 256 := by omega
    simp only [Pion.I32.to_byte, IScalar.hcast, UScalar.val, UScalarTy.numBits]
    change (BitVec.signExtend 8 bv).toNat = bv.toInt.toNat
    rw [BitVec.signExtend_eq_setWidth_of_le bv (by decide), BitVec.toNat_setWidth]
    omega

theorem i32_add_val {a b : Std.I32}
    (hlo : -2147483648 ≤ a.val + b.val) (hhi : a.val + b.val ≤ 2147483647) :
    (Pion.I32.add a b).val = a.val + b.val := by
  simp only [IScalar.val] at hlo hhi
  simp only [Pion.I32.add, Std.I32.wrapping_add, IScalar.wrapping_add, IScalar.val,
    IScalarTy.numBits]
  rw [BitVec.toInt_add]
  exact Int.bmod_eq_of_le_mul_two (by omega) (by omega)

theorem i32_sub_val {a b : Std.I32}
    (hlo : -2147483648 ≤ a.val - b.val) (hhi : a.val - b.val ≤ 2147483647) :
    (Pion.I32.sub a b).val = a.val - b.val := by
  simp only [IScalar.val] at hlo hhi
  simp only [Pion.I32.sub, Std.I32.wrapping_sub, IScalar.wrapping_sub, IScalar.val,
    IScalarTy.numBits]
  rw [BitVec.toInt_sub]
  exact Int.bmod_eq_of_le_mul_two (by omega) (by omega)

theorem i32_mul_val {a b : Std.I32}
    (hlo : -2147483648 ≤ a.val * b.val) (hhi : a.val * b.val ≤ 2147483647) :
    (Pion.I32.mul a b).val = a.val * b.val := by
  simp only [IScalar.val] at hlo hhi
  simp only [Pion.I32.mul, Std.I32.wrapping_mul, IScalar.wrapping_mul, IScalar.val,
    IScalarTy.numBits]
  rw [BitVec.toInt_mul]
  exact Int.bmod_eq_of_le_mul_two (by omega) (by omega)

theorem i64_add_val {a b : Std.I64}
    (hlo : -9223372036854775808 ≤ a.val + b.val) (hhi : a.val + b.val ≤ 9223372036854775807) :
    (Pion.I64.add a b).val = a.val + b.val := by
  simp only [IScalar.val] at hlo hhi
  simp only [Pion.I64.add, Std.I64.wrapping_add, IScalar.wrapping_add, IScalar.val,
    IScalarTy.numBits]
  rw [BitVec.toInt_add]
  exact Int.bmod_eq_of_le_mul_two (by omega) (by omega)

theorem i64_sub_val {a b : Std.I64}
    (hlo : -9223372036854775808 ≤ a.val - b.val) (hhi : a.val - b.val ≤ 9223372036854775807) :
    (Pion.I64.sub a b).val = a.val - b.val := by
  simp only [IScalar.val] at hlo hhi
  simp only [Pion.I64.sub, Std.I64.wrapping_sub, IScalar.wrapping_sub, IScalar.val,
    IScalarTy.numBits]
  rw [BitVec.toInt_sub]
  exact Int.bmod_eq_of_le_mul_two (by omega) (by omega)

theorem i64_bounds (x : Std.I64) :
    -9223372036854775808 ≤ x.val ∧ x.val ≤ 9223372036854775807 := by
  have h := x.hBounds
  simp only [IScalar.min, IScalar.max, IScalarTy.numBits] at h
  omega

theorem i64_max_lit_val : (9223372036854775807#i64).val = 9223372036854775807 := by
  change (BitVec.ofInt 64 9223372036854775807).toInt = 9223372036854775807
  rw [BitVec.toInt_ofInt]
  exact Int.bmod_eq_of_le_mul_two (by omega) (by omega)

theorem i64_min_expr_val :
    (Pion.I64.sub (-9223372036854775807)#i64 1#i64).val = -9223372036854775808 := by
  have hneg : ((-9223372036854775807)#i64).val = -9223372036854775807 := by
    change (BitVec.ofInt 64 (-9223372036854775807)).toInt = -9223372036854775807
    rw [BitVec.toInt_ofInt]
    exact Int.bmod_eq_of_le_mul_two (by omega) (by omega)
  have h1v : (1#i64).val = 1 := by simp
  have hsub := i64_sub_val (a := (-9223372036854775807)#i64) (b := 1#i64) (by omega) (by omega)
  omega

theorem u8_bounds (x : Std.U8) : x.val ≤ 255 := by
  have h := x.hBounds
  simp only [UScalar.max, UScalarTy.numBits] at h
  omega

theorem bytes_get_spec (b : Pion.Bytes) (i : Std.I32)
    (h0 : 0 ≤ i.val) (h1 : i.val < b.val.length) :
    ∃ x, Pion.Bytes.get b i = ok x ∧ b.val[i.val.toNat]? = some x := by
  unfold Pion.Bytes.get Pion.listGet
  have hb : Pion.inBounds i b.val.length := ⟨h0, h1⟩
  simp only [hb, ↓reduceDIte]
  refine ⟨_, rfl, ?_⟩
  simp [List.getElem?_eq_getElem (show i.val.toNat < b.val.length by omega)]

theorem bytes_length_spec (b : Pion.Bytes) (h : b.val.length ≤ 2147483647) :
    ∃ n : Std.I32, Pion.Bytes.length b = ok n ∧ n.val = b.val.length := by
  unfold Pion.Bytes.length Pion.lengthOf
  simp only [h, ↓reduceDIte]
  refine ⟨_, rfl, ?_⟩
  simp

theorem array_get_spec {α : Type u} (a : Pion.Array α) (i : Std.I32)
    (h0 : 0 ≤ i.val) (h1 : i.val < a.val.length) :
    ∃ x, Pion.Array.get a i = ok x ∧ a.val[i.val.toNat]? = some x := by
  unfold Pion.Array.get Pion.listGet
  have hb : Pion.inBounds i a.val.length := ⟨h0, h1⟩
  simp only [hb, ↓reduceDIte]
  refine ⟨_, rfl, ?_⟩
  simp [List.getElem?_eq_getElem (show i.val.toNat < a.val.length by omega)]

theorem array_length_spec {α : Type u} (a : Pion.Array α) (h : a.val.length ≤ 2147483647) :
    ∃ n : Std.I32, Pion.Array.length a = ok n ∧ n.val = a.val.length := by
  unfold Pion.Array.length Pion.lengthOf
  simp only [h, ↓reduceDIte]
  refine ⟨_, rfl, ?_⟩
  simp

private theorem bv_or_eq_zero_iff {w : Nat} (x y : BitVec w) :
    (x ||| y) = 0#w ↔ x = 0#w ∧ y = 0#w := by
  constructor
  · intro h
    constructor <;> (ext k hk; have := congrArg (fun v => v[k]) h; simp_all)
  · rintro ⟨rfl, rfl⟩
    ext k hk; simp

private theorem bv_xor_eq_zero_iff {w : Nat} (x y : BitVec w) :
    (x ^^^ y) = 0#w ↔ x = y := by
  constructor
  · intro h
    ext k hk
    have := congrArg (fun v => v[k]) h
    simp only [BitVec.getElem_xor, BitVec.getElem_zero] at this
    cases hx : x[k] <;> cases hy : y[k] <;> simp_all
  · rintro rfl
    ext k hk; simp

private theorem u8_to_int_eq_iff (x y : Std.U8) :
    Pion.U8.to_int x = Pion.U8.to_int y ↔ x = y := by
  constructor
  · intro h
    have hv := congrArg IScalar.val h
    rw [u8_to_int_val, u8_to_int_val] at hv
    apply UScalar.eq_of_val_eq
    omega
  · rintro rfl; rfl

/-! ## Section 1: Constant-Time Byte Comparison (`packages/jwt/src/crypto.pion`) -/

private theorem constant_time_eq_loop0_spec (a b : Pion.Bytes) (n : Std.I32)
    (hna : n.val = a.val.length) (hnb : n.val = b.val.length)
    (hlen : a.val.length ≤ 2147483647) :
    constant_time_eq_loop0 n a b 0#i32 0#i32 ⦃ res =>
      (res.2 == 0#i32) = true ↔
        ∀ k, k < a.val.length → a.val[k]? = b.val[k]? ⦄ := by
  unfold constant_time_eq_loop0
  apply loop.spec_decr_nat
    (measure := fun (p : Std.I32 × Std.I32) => a.val.length - p.1.val.toNat)
    (inv := fun (p : Std.I32 × Std.I32) =>
      0 ≤ p.1.val ∧ p.1.val ≤ a.val.length ∧
      (p.2.bv = 0#32 ↔ ∀ k, k < p.1.val.toNat → a.val[k]? = b.val[k]?))
  · rintro ⟨i, diff⟩ ⟨hi0, hile, hinv⟩
    dsimp only at hi0 hile hinv ⊢
    unfold constant_time_eq_loop0.body
    by_cases hlt : i < n
    · have hilt_a : i.val < a.val.length := by have : i.val < n.val := hlt; omega
      have hilt_b : i.val < b.val.length := by omega
      obtain ⟨xa, hxa, hxaeq⟩ := bytes_get_spec a i hi0 hilt_a
      obtain ⟨xb, hxb, hxbeq⟩ := bytes_get_spec b i hi0 hilt_b
      simp only [hlt, ↓reduceIte, hxa, hxb, b_ok, WP.spec_ok]
      have h1v : (1#i32).val = 1 := by simp
      have hi1 : (Pion.I32.add i 1#i32).val = i.val + 1 :=
        i32_add_val (a := i) (b := 1#i32) (by omega) (by omega)
      refine ⟨⟨by omega, by omega, ?_⟩, by omega⟩
      change (diff.bv ||| ((Pion.U8.to_int xa).bv ^^^ (Pion.U8.to_int xb).bv)) = 0#32 ↔ _
      rw [bv_or_eq_zero_iff, bv_xor_eq_zero_iff]
      constructor
      · rintro ⟨hdiff0, hxybv⟩ k hk
        by_cases hki : k < i.val.toNat
        · exact hinv.mp hdiff0 k hki
        · have hkeq : k = i.val.toNat := by omega
          subst hkeq
          have hxy : Pion.U8.to_int xa = Pion.U8.to_int xb := by
            cases h1 : Pion.U8.to_int xa; cases h2 : Pion.U8.to_int xb
            rw [h1, h2] at hxybv
            exact congrArg IScalar.mk hxybv
          have : xa = xb := (u8_to_int_eq_iff xa xb).mp hxy
          rw [hxaeq, hxbeq, this]
      · intro hall
        refine ⟨hinv.mpr (fun k hk => hall k (by omega)), ?_⟩
        have hcur := hall i.val.toNat (by omega)
        rw [hxaeq, hxbeq] at hcur
        injection hcur with hxeq
        rw [hxeq]
    · simp only [hlt, ↓reduceIte, WP.spec_ok]
      have hieq : i.val = a.val.length := by
        have : ¬ (i.val < n.val) := hlt
        omega
      have hnat : i.val.toNat = a.val.length := by omega
      rw [hnat] at hinv
      simp only [beq_iff_eq]
      constructor
      · intro h0
        have hbv : diff.bv = 0#32 := by rw [h0]; rfl
        exact hinv.mp hbv
      · intro hall
        have hbv : diff.bv = 0#32 := hinv.mpr hall
        cases diff with
        | mk bv =>
          change bv = 0#32 at hbv
          subst hbv
          rfl
  · dsimp only
    have h0v : (0#i32).val = 0 := by simp
    refine ⟨by omega, by omega, ?_⟩
    constructor
    · intro _ k hk; simp [h0v] at hk
    · intro _; rfl

/-- `constant_time_eq` never panics and decides exact `Bytes` equality. -/
theorem constant_time_eq_spec (a b : Pion.Bytes)
    (ha : a.val.length ≤ 2147483647) (hb : b.val.length ≤ 2147483647) :
    constant_time_eq a b = ok (decide (a = b)) := by
  unfold constant_time_eq
  obtain ⟨na, hna, hnav⟩ := bytes_length_spec a ha
  obtain ⟨nb, hnb, hnbv⟩ := bytes_length_spec b hb
  rw [hna, b_ok, hnb, b_ok]
  by_cases hne : na ≠ nb
  · rw [ite_eq_left_of_eq_true _ _ (eq_true hne)]
    have hneq : a ≠ b := by
      intro heq
      subst heq
      apply hne
      apply IScalar.eq_of_val_eq
      omega
    simp [hneq]
  · rw [ite_eq_right_of_eq_false _ _ (eq_false hne)]
    dsimp only
    have hlen_eq : a.val.length = b.val.length := by
      have heq : na = nb := Classical.not_not.mp hne
      have := congrArg IScalar.val heq
      omega
    have hloop := constant_time_eq_loop0_spec a b na hnav (by omega) ha
    rw [wp_ok_iff] at hloop
    obtain ⟨⟨i1, diff1⟩, hres, hiff⟩ := hloop
    rw [hres, b_ok]
    change ok (diff1 == 0#i32) = ok (decide (a = b))
    dsimp only at hiff
    congr 1
    apply Bool.eq_iff_iff.mpr
    rw [hiff, decide_eq_true_iff]
    constructor
    · intro hall
      cases a with | mk la =>
      cases b with | mk lb =>
      simp only [Pion.Bytes.mk.injEq] at *
      exact List.ext_getElem? fun k => by
        by_cases hk : k < la.length
        · exact hall k hk
        · rw [List.getElem?_eq_none (by omega), List.getElem?_eq_none (by omega)]
    · intro heq k hk
      rw [heq]

/-- `constant_time_eq` is total on all valid `Bytes` (never panics or goes OOB). -/
theorem constant_time_eq_total (a b : Pion.Bytes)
    (ha : a.val.length ≤ 2147483647) (hb : b.val.length ≤ 2147483647) :
    ∃ r : Bool, constant_time_eq a b = ok r :=
  ⟨decide (a = b), constant_time_eq_spec a b ha hb⟩

/-- `constant_time_eq a b = ok true ↔ a = b` (no false accepts, no false rejects). -/
theorem constant_time_eq_iff (a b : Pion.Bytes)
    (ha : a.val.length ≤ 2147483647) (hb : b.val.length ≤ 2147483647) :
    constant_time_eq a b = ok true ↔ a = b := by
  rw [constant_time_eq_spec a b ha hb]
  simp

/-- `constant_time_eq` is reflexive on valid `Bytes`. -/
theorem constant_time_eq_refl (a : Pion.Bytes) (ha : a.val.length ≤ 2147483647) :
    constant_time_eq a a = ok true :=
  (constant_time_eq_iff a a ha ha).mpr rfl

/-- `constant_time_eq` is symmetric on valid `Bytes`. -/
theorem constant_time_eq_symm (a b : Pion.Bytes)
    (ha : a.val.length ≤ 2147483647) (hb : b.val.length ≤ 2147483647) :
    constant_time_eq a b = constant_time_eq b a := by
  rw [constant_time_eq_spec a b ha hb, constant_time_eq_spec b a hb ha]
  congr 1
  exact Bool.eq_iff_iff.mpr (by simp [eq_comm])

/-! ## Section 2: Anti-CVE Algorithm & HMAC Key Security Gate (`src/types.pion`, `src/jwt.pion`) -/

/-- `algorithm_equals` decides exact `Algorithm` equality. -/
theorem algorithm_equals_iff (a b : Algorithm) :
    algorithm_equals a b = ok true ↔ a = b := by
  cases a <;> cases b <;> simp [algorithm_equals]

theorem algorithm_equals_total (a b : Algorithm) :
    ∃ r : Bool, algorithm_equals a b = ok r ∧ (r = true ↔ a = b) := by
  cases a <;> cases b <;> simp [algorithm_equals]

/-- `algorithm_from_str (algorithm_as_str a) = ok (.Ok a)` for all supported algorithms. -/
theorem algorithm_from_str_as_str (a : Algorithm) :
    (do let s ← algorithm_as_str a; algorithm_from_str s) = ok (.Ok a) := by
  cases a <;> simp [algorithm_as_str, algorithm_from_str]

/-- `algorithm_from_str` accepts ONLY `"HS256"`, `"HS384"`, `"HS512"`. -/
theorem algorithm_from_str_ok_iff (s : String) (a : Algorithm) :
    algorithm_from_str s = ok (.Ok a) ↔
      (s = "HS256" ∧ a = .HS256) ∨
      (s = "HS384" ∧ a = .HS384) ∨
      (s = "HS512" ∧ a = .HS512) := by
  unfold algorithm_from_str
  by_cases h1 : s = "HS256"
  · subst h1; simp [eq_comm]
  · by_cases h2 : s = "HS384"
    · subst h2; simp [eq_comm]
    · by_cases h3 : s = "HS512"
      · subst h3; simp [eq_comm]
      · simp only [h1, h2, h3, ↓reduceIte, is_alg_none_str, b_ok]
        split_ifs <;> simp

/-- `algorithm_from_str` ALWAYS rejects all 16 case variants of `"none"` with `AlgorithmNoneNotAllowed`. -/
theorem algorithm_from_str_rejects_none_variants (s : String)
    (hnone : is_alg_none_str s = ok true) :
    algorithm_from_str s = ok (.Err .AlgorithmNoneNotAllowed) := by
  unfold is_alg_none_str at hnone
  simp only [Result.ok.injEq, Bool.or_eq_true, beq_iff_eq] at hnone
  rcases hnone with (((((((((((((((h | h) | h) | h) | h) | h) | h) | h) | h) | h) | h) | h) | h) | h) | h) | h) <;>
    (subst h; simp [algorithm_from_str, is_alg_none_str])

/-- `algorithm_from_str` rejects `"none"`, `"None"`, `"NONE"`, `"nOnE"` and every unknown string. -/
theorem algorithm_from_str_rejects_unknown (s : String)
    (h1 : s ≠ "HS256") (h2 : s ≠ "HS384") (h3 : s ≠ "HS512") :
    ∃ e : JwtError, algorithm_from_str s = ok (.Err e) := by
  unfold algorithm_from_str
  simp only [h1, h2, h3, ↓reduceIte, is_alg_none_str, b_ok]
  split_ifs
  · exact ⟨.AlgorithmNoneNotAllowed, rfl⟩
  · exact ⟨.UnsupportedAlgorithm s, rfl⟩

/-- `hmac_key_valid` never accepts empty HMAC keys (`key.length == 0`). -/
theorem hmac_key_valid_iff (key : Pion.Bytes) (hlen : key.val.length ≤ 2147483647) :
    hmac_key_valid key = ok true ↔ key.val.length > 0 := by
  unfold hmac_key_valid
  obtain ⟨n, hn, hnv⟩ := bytes_length_spec key hlen
  rw [hn, b_ok]
  simp only [Result.ok.injEq, decide_eq_true_eq]
  change n.val > (0#i32).val ↔ key.val.length > 0
  have h0 : (0#i32).val = 0 := by simp
  omega

/-- Empty `Bytes` is unconditionally rejected by `hmac_key_valid`. -/
theorem hmac_key_valid_rejects_empty :
    hmac_key_valid ⟨[]⟩ = ok false := by
  unfold hmac_key_valid
  obtain ⟨n, hn, hnv⟩ := bytes_length_spec ⟨[]⟩ (by simp)
  rw [hn, b_ok]
  simp only [Result.ok.injEq, decide_eq_false_iff_not]
  change ¬ (n.val > (0#i32).val)
  have h0 : (0#i32).val = 0 := by simp
  simp at hnv
  omega

private theorem alg_in_allowlist_loop0_spec (alg : Algorithm) (list : Pion.Array Algorithm)
    (hlen : list.val.length ≤ 2147483647) :
    alg_in_allowlist_loop0 list alg 0#i32 ⦃ res =>
      match res with
      | .inl true => alg ∈ list.val
      | .inl false => False
      | .inr _ => alg ∉ list.val ⦄ := by
  unfold alg_in_allowlist_loop0
  apply loop.spec_decr_nat
    (measure := fun (i : Std.I32) => list.val.length - i.val.toNat)
    (inv := fun (i : Std.I32) =>
      0 ≤ i.val ∧ i.val ≤ list.val.length ∧
      ∀ k, k < i.val.toNat → list.val[k]? ≠ some alg)
  · intro i ⟨hi0, hile, hprev⟩
    unfold alg_in_allowlist_loop0.body
    obtain ⟨n, hn, hnv⟩ := array_length_spec list hlen
    rw [hn, b_ok]
    by_cases hlt : i < n
    · have hilt : i.val < list.val.length := by have : i.val < n.val := hlt; omega
      obtain ⟨x, hx, hxeq⟩ := array_get_spec list i hi0 hilt
      obtain ⟨eqb, heqb, heqb_iff⟩ := algorithm_equals_total alg x
      simp only [hlt, ↓reduceIte, hx, heqb, b_ok]
      cases eqb with
      | true =>
        simp only [↓reduceIte, WP.spec_ok]
        have heq : alg = x := heqb_iff.mp rfl
        subst heq
        have hlt_nat : i.val.toNat < list.val.length := by omega
        rw [List.getElem?_eq_getElem hlt_nat] at hxeq
        injection hxeq with hget
        rw [← hget]
        exact List.getElem_mem hlt_nat
      | false =>
        simp only [Bool.false_eq_true, ↓reduceIte, WP.spec_ok]
        have hne : alg ≠ x := fun h => by have := heqb_iff.mpr h; cases this
        have h1v : (1#i32).val = 1 := by simp
        have hi1 : (Pion.I32.add i 1#i32).val = i.val + 1 :=
          i32_add_val (a := i) (b := 1#i32) (by omega) (by omega)
        refine ⟨⟨by omega, by omega, ?_⟩, by omega⟩
        intro k hk
        by_cases hki : k < i.val.toNat
        · exact hprev k hki
        · have hkeq : k = i.val.toNat := by omega
          subst hkeq
          rw [hxeq]
          intro hsome
          injection hsome with hxa
          exact hne hxa.symm
    · simp only [hlt, ↓reduceIte, WP.spec_ok]
      have hieq : i.val = list.val.length := by
        have : ¬ (i.val < n.val) := hlt; omega
      intro hmem
      obtain ⟨k, hk, hget⟩ := List.getElem_of_mem hmem
      have hne := hprev k (by omega)
      rw [List.getElem?_eq_getElem hk, hget] at hne
      exact hne rfl
  · have h0v : (0#i32).val = 0 := by simp
    refine ⟨by omega, by omega, ?_⟩
    intro k hk; simp [h0v] at hk

/-- `alg_in_allowlist` is total and returns `true` iff `alg ∈ list.val`. -/
theorem alg_in_allowlist_spec (alg : Algorithm) (list : Pion.Array Algorithm)
    (hlen : list.val.length ≤ 2147483647) :
    ∃ r : Bool, alg_in_allowlist alg list = ok r ∧ (r = true ↔ alg ∈ list.val) := by
  unfold alg_in_allowlist
  dsimp only
  have hloop := alg_in_allowlist_loop0_spec alg list hlen
  rw [wp_ok_iff] at hloop
  obtain ⟨res, hres, hpost⟩ := hloop
  rw [hres, b_ok]
  cases res with
  | inl b =>
    cases b with
    | true => exact ⟨true, rfl, ⟨fun _ => hpost, fun _ => rfl⟩⟩
    | false => exact False.elim hpost
  | inr _ =>
    exact ⟨false, rfl, ⟨(fun h => by cases h), (fun h => False.elim (hpost h))⟩⟩

/-- Empty allowlist rejects every algorithm. -/
theorem alg_in_allowlist_empty (alg : Algorithm) :
    alg_in_allowlist alg ⟨[]⟩ = ok false := by
  obtain ⟨r, hr, hiff⟩ := alg_in_allowlist_spec alg ⟨[]⟩ (by simp)
  cases r with
  | false => exact hr
  | true => exact False.elim (by simpa using hiff.mp rfl)

/-- `check_verifier_alg` enforces BOTH allowlist membership AND exact header/verifier algorithm match. -/
theorem check_verifier_alg_iff (header_alg verifier_alg : Algorithm)
    (allowlist : Pion.Array Algorithm) (hlen : allowlist.val.length ≤ 2147483647) :
    check_verifier_alg header_alg verifier_alg allowlist = ok true ↔
      header_alg ∈ allowlist.val ∧ header_alg = verifier_alg := by
  unfold check_verifier_alg
  obtain ⟨r, hr, hriff⟩ := alg_in_allowlist_spec header_alg allowlist hlen
  rw [hr, b_ok]
  cases r with
  | true =>
    simp only [↓reduceIte]
    obtain ⟨eqb, heqb, heqb_iff⟩ := algorithm_equals_total header_alg verifier_alg
    rw [heqb, b_ok]
    simp only [Result.ok.injEq]
    exact ⟨fun h => ⟨hriff.mp rfl, heqb_iff.mp h⟩, fun ⟨_, heq⟩ => heqb_iff.mpr heq⟩
  | false =>
    simp only [Bool.false_eq_true, ↓reduceIte, Result.ok.injEq, false_iff]
    rintro ⟨hmem, _⟩
    exact Bool.noConfusion (hriff.mpr hmem)

/-! ## Section 3: Saturating `exp` / `nbf` Time-Window & Leeway Overflow Immunity (`src/jwt.pion`) -/

private theorem saturating_add_nonneg_helper (M a b : Std.I64)
    (hM : M.val = 9223372036854775807) (hb : 0 ≤ b.val) :
    (if a > Pion.I64.sub M b then M else Pion.I64.add a b).val =
      min 9223372036854775807 (a.val + b.val) := by
  have ha := i64_bounds a
  have hbb := i64_bounds b
  have hsub : (Pion.I64.sub M b).val = 9223372036854775807 - b.val := by
    have := i64_sub_val (a := M) (b := b) (by omega) (by omega)
    omega
  split_ifs with hgt
  · have : a.val > (Pion.I64.sub M b).val := hgt
    omega
  · have : ¬ (a.val > (Pion.I64.sub M b).val) := hgt
    have hadd : (Pion.I64.add a b).val = a.val + b.val :=
      i64_add_val (a := a) (b := b) (by omega) (by omega)
    omega

/-- `saturating_add_nonneg a b` computes exact `min(INT64_MAX, a + b)` in `ℤ` for all `b ≥ 0`. -/
theorem saturating_add_nonneg_spec (a b : Std.I64) (hb : 0 ≤ b.val) :
    ∃ r : Std.I64, saturating_add_nonneg a b = ok r ∧
      r.val = min 9223372036854775807 (a.val + b.val) :=
  ⟨_, rfl, saturating_add_nonneg_helper 9223372036854775807#i64 a b i64_max_lit_val hb⟩

private theorem saturating_sub_nonneg_helper (M a b : Std.I64)
    (hM : M.val = -9223372036854775808) (hb : 0 ≤ b.val) :
    (if a < Pion.I64.add M b then M else Pion.I64.sub a b).val =
      max (-9223372036854775808) (a.val - b.val) := by
  have ha := i64_bounds a
  have hbb := i64_bounds b
  have hadd : (Pion.I64.add M b).val = -9223372036854775808 + b.val := by
    have := i64_add_val (a := M) (b := b) (by omega) (by omega)
    omega
  split_ifs with hlt
  · have : a.val < (Pion.I64.add M b).val := hlt
    omega
  · have : ¬ (a.val < (Pion.I64.add M b).val) := hlt
    have hsub : (Pion.I64.sub a b).val = a.val - b.val :=
      i64_sub_val (a := a) (b := b) (by omega) (by omega)
    omega

/-- `saturating_sub_nonneg a b` computes exact `max(INT64_MIN, a - b)` in `ℤ` for all `b ≥ 0`. -/
theorem saturating_sub_nonneg_spec (a b : Std.I64) (hb : 0 ≤ b.val) :
    ∃ r : Std.I64, saturating_sub_nonneg a b = ok r ∧
      r.val = max (-9223372036854775808) (a.val - b.val) :=
  ⟨_, rfl, saturating_sub_nonneg_helper (Pion.I64.sub (-9223372036854775807)#i64 1#i64) a b i64_min_expr_val hb⟩

/-- `normalize_leeway` clamps negative leeway to `0` and preserves non-negative leeway. -/
theorem normalize_leeway_spec (leeway : Std.I64) :
    ∃ r : Std.I64, normalize_leeway leeway = ok r ∧ r.val = max 0 leeway.val := by
  unfold normalize_leeway
  refine ⟨_, rfl, ?_⟩
  have h0 : (0#i64).val = 0 := by simp
  by_cases hlt : leeway < 0#i64
  · simp only [hlt, ↓reduceIte]
    have : leeway.val < (0#i64).val := hlt
    omega
  · simp only [hlt, ↓reduceIte]
    have : ¬ (leeway.val < (0#i64).val) := hlt
    omega

/-- Overflow-immune `exp` soundness: for ALL `Int64` inputs (including `INT64_MIN`/`INT64_MAX`),
    if `now ≥ exp + max(0, leeway)` in exact `ℤ`, `is_expired` ALWAYS returns `ok true`. -/
theorem is_expired_sound (now_unix exp_ts leeway : Std.I64)
    (hexp : now_unix.val ≥ exp_ts.val + max 0 leeway.val) :
    is_expired now_unix exp_ts leeway = ok true := by
  unfold is_expired
  obtain ⟨lw, hlw, hlwv⟩ := normalize_leeway_spec leeway
  rw [hlw, b_ok]
  obtain ⟨sub, hsub, hsubv⟩ := saturating_sub_nonneg_spec now_unix lw (by omega)
  rw [hsub, b_ok]
  have he := i64_bounds exp_ts
  simp only [Result.ok.injEq, decide_eq_true_eq]
  change sub.val ≥ exp_ts.val
  omega

/-- Exact `exp` equivalence whenever `exp > INT64_MIN` (or no underflow). -/
theorem is_expired_iff_of_gt_min (now_unix exp_ts leeway : Std.I64)
    (hgt : exp_ts.val > -9223372036854775808) :
    is_expired now_unix exp_ts leeway = ok true ↔
      now_unix.val ≥ exp_ts.val + max 0 leeway.val := by
  unfold is_expired
  obtain ⟨lw, hlw, hlwv⟩ := normalize_leeway_spec leeway
  rw [hlw, b_ok]
  obtain ⟨sub, hsub, hsubv⟩ := saturating_sub_nonneg_spec now_unix lw (by omega)
  rw [hsub, b_ok]
  simp only [Result.ok.injEq, decide_eq_true_eq]
  change sub.val ≥ exp_ts.val ↔ now_unix.val ≥ exp_ts.val + max 0 leeway.val
  omega

/-- With `leeway = 0`, `is_expired` is strictly equivalent to `now ≥ exp` across all `Int64`. -/
theorem is_expired_zero_leeway (now_unix exp_ts : Std.I64) :
    is_expired now_unix exp_ts 0#i64 = ok (decide (now_unix.val ≥ exp_ts.val)) := by
  unfold is_expired
  obtain ⟨lw, hlw, hlwv⟩ := normalize_leeway_spec 0#i64
  rw [hlw, b_ok]
  have h0 : (0#i64).val = 0 := by simp
  obtain ⟨sub, hsub, hsubv⟩ := saturating_sub_nonneg_spec now_unix lw (by omega)
  rw [hsub, b_ok]
  have hn := i64_bounds now_unix
  congr 1
  apply Bool.eq_iff_iff.mpr
  simp only [decide_eq_true_eq]
  change sub.val ≥ exp_ts.val ↔ now_unix.val ≥ exp_ts.val
  omega

/-- Overflow-immune `nbf` exact specification: for ALL `Int64` inputs (including `INT64_MIN`/`INT64_MAX`),
    `is_immature` decides exact `now + max(0, leeway) < nbf` in `ℤ` with zero overflow. -/
theorem is_immature_spec (now_unix nbf_ts leeway : Std.I64) :
    is_immature now_unix nbf_ts leeway = ok (decide (now_unix.val + max 0 leeway.val < nbf_ts.val)) := by
  unfold is_immature
  obtain ⟨lw, hlw, hlwv⟩ := normalize_leeway_spec leeway
  rw [hlw, b_ok]
  obtain ⟨sum, hsum, hsumv⟩ := saturating_add_nonneg_spec now_unix lw (by omega)
  rw [hsum, b_ok]
  have hnbf := i64_bounds nbf_ts
  congr 1
  apply Bool.eq_iff_iff.mpr
  simp only [decide_eq_true_eq]
  change sum.val < nbf_ts.val ↔ now_unix.val + max 0 leeway.val < nbf_ts.val
  omega

/-- With `leeway = 0`, `is_immature` is strictly equivalent to `now < nbf` across all `Int64`. -/
theorem is_immature_zero_leeway (now_unix nbf_ts : Std.I64) :
    is_immature now_unix nbf_ts 0#i64 = ok (decide (now_unix.val < nbf_ts.val)) := by
  rw [is_immature_spec]
  have h0 : (0#i64).val = 0 := by simp
  congr 1
  apply Bool.eq_iff_iff.mpr
  simp only [decide_eq_true_eq]
  omega

/-! ## Section 4: Strict Unpadded Base64URL Character Codec & Canonical Tail Bits (`src/base64url.pion`) -/

/-- Exact 6-bit Base64URL roundtrip: for ALL `0 ≤ v < 64`, `decode(encode(v)) = ok v`. -/
theorem b64url_encode_decode_roundtrip (v : Std.I32) (h0 : 0 ≤ v.val) (h64 : v.val < 64) :
    (do let b ← b64url_encode_val v; b64url_decode_byte b) = ok v := by
  unfold b64url_encode_val b64url_decode_byte
  have h0v : (0#i32).val = 0 := by simp
  have h26v : (26#i32).val = 26 := by simp
  have h52v : (52#i32).val = 52 := by simp
  have h62v : (62#i32).val = 62 := by simp
  have h63v : (63#i32).val = 63 := by simp
  have h65v : (65#i32).val = 65 := by simp
  have h97v : (97#i32).val = 97 := by simp
  have h48v : (48#i32).val = 48 := by simp
  by_cases h1 : v.val < 26
  · have hc1 : (decide (v >= 0#i32) && decide (v < 26#i32)) = true := by
      simp only [Bool.and_eq_true, decide_eq_true_eq]
      exact ⟨by change v.val ≥ (0#i32).val; omega, by change v.val < (26#i32).val; omega⟩
    simp only [hc1, ↓reduceIte, b_ok]
    have hadd : (Pion.I32.add 65#i32 v).val = 65 + v.val := by
      have := i32_add_val (a := 65#i32) (b := v) (by omega) (by omega); omega
    have hbyte : (Pion.I32.to_byte (Pion.I32.add 65#i32 v)).val = (65 + v.val).toNat := by
      rw [i32_to_byte_val (by omega) (by omega), hadd]
    have hc : (Pion.U8.to_int (Pion.I32.to_byte (Pion.I32.add 65#i32 v))).val = 65 + v.val := by
      rw [u8_to_int_val, hbyte]; omega
    have hcond : (decide (Pion.U8.to_int (Pion.I32.to_byte (Pion.I32.add 65#i32 v)) >= 65#i32) &&
                  decide (Pion.U8.to_int (Pion.I32.to_byte (Pion.I32.add 65#i32 v)) <= 90#i32)) = true := by
      simp only [Bool.and_eq_true, decide_eq_true_eq]
      have h90 : (90#i32).val = 90 := by simp
      exact ⟨by change _ ≥ (65#i32).val; omega, by change _ ≤ (90#i32).val; omega⟩
    simp only [hcond, ↓reduceIte, Result.ok.injEq]
    apply IScalar.eq_of_val_eq
    have := i32_sub_val (a := Pion.U8.to_int (Pion.I32.to_byte (Pion.I32.add 65#i32 v))) (b := 65#i32) (by omega) (by omega)
    omega
  · by_cases h2 : v.val < 52
    · have hc1 : (decide (v >= 0#i32) && decide (v < 26#i32)) = false := by
        simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not]
        right; change ¬ (v.val < (26#i32).val); omega
      have hc2 : (decide (v >= 26#i32) && decide (v < 52#i32)) = true := by
        simp only [Bool.and_eq_true, decide_eq_true_eq]
        exact ⟨by change v.val ≥ (26#i32).val; omega, by change v.val < (52#i32).val; omega⟩
      simp only [hc1, hc2, Bool.false_eq_true, ↓reduceIte, b_ok]
      have hsub1 : (Pion.I32.sub v 26#i32).val = v.val - 26 := by
        have := i32_sub_val (a := v) (b := 26#i32) (by omega) (by omega); omega
      have hadd : (Pion.I32.add 97#i32 (Pion.I32.sub v 26#i32)).val = 97 + (v.val - 26) := by
        have := i32_add_val (a := 97#i32) (b := Pion.I32.sub v 26#i32) (by omega) (by omega); omega
      have hbyte : (Pion.I32.to_byte (Pion.I32.add 97#i32 (Pion.I32.sub v 26#i32))).val = (97 + (v.val - 26)).toNat := by
        rw [i32_to_byte_val (by omega) (by omega), hadd]
      have hc : (Pion.U8.to_int (Pion.I32.to_byte (Pion.I32.add 97#i32 (Pion.I32.sub v 26#i32)))).val = 97 + (v.val - 26) := by
        rw [u8_to_int_val, hbyte]; omega
      have h90 : (90#i32).val = 90 := by simp
      have h122 : (122#i32).val = 122 := by simp
      have hcond1 : (decide (Pion.U8.to_int (Pion.I32.to_byte (Pion.I32.add 97#i32 (Pion.I32.sub v 26#i32))) >= 65#i32) &&
                     decide (Pion.U8.to_int (Pion.I32.to_byte (Pion.I32.add 97#i32 (Pion.I32.sub v 26#i32))) <= 90#i32)) = false := by
        simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not]
        right; change ¬ (_ ≤ (90#i32).val); omega
      have hcond2 : (decide (Pion.U8.to_int (Pion.I32.to_byte (Pion.I32.add 97#i32 (Pion.I32.sub v 26#i32))) >= 97#i32) &&
                     decide (Pion.U8.to_int (Pion.I32.to_byte (Pion.I32.add 97#i32 (Pion.I32.sub v 26#i32))) <= 122#i32)) = true := by
        simp only [Bool.and_eq_true, decide_eq_true_eq]
        exact ⟨by change _ ≥ (97#i32).val; omega, by change _ ≤ (122#i32).val; omega⟩
      simp only [hcond1, hcond2, Bool.false_eq_true, ↓reduceIte, Result.ok.injEq]
      apply IScalar.eq_of_val_eq
      set x := Pion.U8.to_int (Pion.I32.to_byte (Pion.I32.add 97#i32 (Pion.I32.sub v 26#i32)))
      have hsub2 : (Pion.I32.sub x 97#i32).val = v.val - 26 := by
        have := i32_sub_val (a := x) (b := 97#i32) (by omega) (by omega); omega
      have := i32_add_val (a := Pion.I32.sub x 97#i32) (b := 26#i32) (by omega) (by omega)
      omega
    · by_cases h3 : v.val < 62
      · have hc1 : (decide (v >= 0#i32) && decide (v < 26#i32)) = false := by
          simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not]
          right; change ¬ (v.val < (26#i32).val); omega
        have hc2 : (decide (v >= 26#i32) && decide (v < 52#i32)) = false := by
          simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not]
          right; change ¬ (v.val < (52#i32).val); omega
        have hc3 : (decide (v >= 52#i32) && decide (v < 62#i32)) = true := by
          simp only [Bool.and_eq_true, decide_eq_true_eq]
          exact ⟨by change v.val ≥ (52#i32).val; omega, by change v.val < (62#i32).val; omega⟩
        simp only [hc1, hc2, hc3, Bool.false_eq_true, ↓reduceIte, b_ok]
        have hsub1 : (Pion.I32.sub v 52#i32).val = v.val - 52 := by
          have := i32_sub_val (a := v) (b := 52#i32) (by omega) (by omega); omega
        have hadd : (Pion.I32.add 48#i32 (Pion.I32.sub v 52#i32)).val = 48 + (v.val - 52) := by
          have := i32_add_val (a := 48#i32) (b := Pion.I32.sub v 52#i32) (by omega) (by omega); omega
        have hbyte : (Pion.I32.to_byte (Pion.I32.add 48#i32 (Pion.I32.sub v 52#i32))).val = (48 + (v.val - 52)).toNat := by
          rw [i32_to_byte_val (by omega) (by omega), hadd]
        have hc : (Pion.U8.to_int (Pion.I32.to_byte (Pion.I32.add 48#i32 (Pion.I32.sub v 52#i32)))).val = 48 + (v.val - 52) := by
          rw [u8_to_int_val, hbyte]; omega
        have h57 : (57#i32).val = 57 := by simp
        have hcond1 : (decide (Pion.U8.to_int (Pion.I32.to_byte (Pion.I32.add 48#i32 (Pion.I32.sub v 52#i32))) >= 65#i32) &&
                       decide (Pion.U8.to_int (Pion.I32.to_byte (Pion.I32.add 48#i32 (Pion.I32.sub v 52#i32))) <= 90#i32)) = false := by
          simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not]
          left; change ¬ (_ ≥ (65#i32).val); omega
        have hcond2 : (decide (Pion.U8.to_int (Pion.I32.to_byte (Pion.I32.add 48#i32 (Pion.I32.sub v 52#i32))) >= 97#i32) &&
                       decide (Pion.U8.to_int (Pion.I32.to_byte (Pion.I32.add 48#i32 (Pion.I32.sub v 52#i32))) <= 122#i32)) = false := by
          simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not]
          left; change ¬ (_ ≥ (97#i32).val); omega
        have hcond3 : (decide (Pion.U8.to_int (Pion.I32.to_byte (Pion.I32.add 48#i32 (Pion.I32.sub v 52#i32))) >= 48#i32) &&
                       decide (Pion.U8.to_int (Pion.I32.to_byte (Pion.I32.add 48#i32 (Pion.I32.sub v 52#i32))) <= 57#i32)) = true := by
          simp only [Bool.and_eq_true, decide_eq_true_eq]
          exact ⟨by change _ ≥ (48#i32).val; omega, by change _ ≤ (57#i32).val; omega⟩
        simp only [hcond1, hcond2, hcond3, Bool.false_eq_true, ↓reduceIte, Result.ok.injEq]
        apply IScalar.eq_of_val_eq
        set x := Pion.U8.to_int (Pion.I32.to_byte (Pion.I32.add 48#i32 (Pion.I32.sub v 52#i32)))
        have hsub2 : (Pion.I32.sub x 48#i32).val = v.val - 52 := by
          have := i32_sub_val (a := x) (b := 48#i32) (by omega) (by omega); omega
        have := i32_add_val (a := Pion.I32.sub x 48#i32) (b := 52#i32) (by omega) (by omega)
        omega
      · by_cases h4 : v.val = 62
        · have hv : v = 62#i32 := IScalar.eq_of_val_eq (by omega)
          subst hv
          have hc1 : (decide (62#i32 >= 0#i32) && decide (62#i32 < 26#i32)) = false := by
            simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not]; right; change ¬ ((62#i32).val < (26#i32).val); omega
          have hc2 : (decide (62#i32 >= 26#i32) && decide (62#i32 < 52#i32)) = false := by
            simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not]; right; change ¬ ((62#i32).val < (52#i32).val); omega
          have hc3 : (decide (62#i32 >= 52#i32) && decide (62#i32 < 62#i32)) = false := by
            simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not]; right; change ¬ ((62#i32).val < (62#i32).val); omega
          simp only [hc1, hc2, hc3, Bool.false_eq_true, ↓reduceIte, b_ok]
          have h45 : (45#i32).val = 45 := by simp
          have hc45 : (Pion.U8.to_int (Pion.I32.to_byte 45#i32)).val = 45 := by
            rw [u8_to_int_val, i32_to_byte_val (by omega) (by omega)]; omega
          have heq45 : Pion.U8.to_int (Pion.I32.to_byte 45#i32) = 45#i32 := IScalar.eq_of_val_eq (by omega)
          rw [heq45]
          have hd1 : (decide (45#i32 >= 65#i32) && decide (45#i32 <= 90#i32)) = false := by
            simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not]; left; change ¬ ((45#i32).val ≥ (65#i32).val); omega
          have hd2 : (decide (45#i32 >= 97#i32) && decide (45#i32 <= 122#i32)) = false := by
            simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not]; left; change ¬ ((45#i32).val ≥ (97#i32).val); omega
          have hd3 : (decide (45#i32 >= 48#i32) && decide (45#i32 <= 57#i32)) = false := by
            simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not]; left; change ¬ ((45#i32).val ≥ (48#i32).val); omega
          simp only [hd1, hd2, hd3, Bool.false_eq_true, ↓reduceIte]
        · have hv : v = 63#i32 := IScalar.eq_of_val_eq (by omega)
          subst hv
          have hc1 : (decide (63#i32 >= 0#i32) && decide (63#i32 < 26#i32)) = false := by
            simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not]; right; change ¬ ((63#i32).val < (26#i32).val); omega
          have hc2 : (decide (63#i32 >= 26#i32) && decide (63#i32 < 52#i32)) = false := by
            simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not]; right; change ¬ ((63#i32).val < (52#i32).val); omega
          have hc3 : (decide (63#i32 >= 52#i32) && decide (63#i32 < 62#i32)) = false := by
            simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not]; right; change ¬ ((63#i32).val < (62#i32).val); omega
          have hne62 : (63#i32 : Std.I32) ≠ 62#i32 := by intro h; have := congrArg IScalar.val h; omega
          simp only [hc1, hc2, hc3, hne62, Bool.false_eq_true, ↓reduceIte, b_ok]
          have h95 : (95#i32).val = 95 := by simp
          have h90 : (90#i32).val = 90 := by simp
          have h57 : (57#i32).val = 57 := by simp
          have h45 : (45#i32).val = 45 := by simp
          have hc95 : (Pion.U8.to_int (Pion.I32.to_byte 95#i32)).val = 95 := by
            rw [u8_to_int_val, i32_to_byte_val (by omega) (by omega)]; omega
          have heq95 : Pion.U8.to_int (Pion.I32.to_byte 95#i32) = 95#i32 := IScalar.eq_of_val_eq (by omega)
          rw [heq95]
          have hd1 : (decide (95#i32 >= 65#i32) && decide (95#i32 <= 90#i32)) = false := by
            simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not]; right; change ¬ ((95#i32).val ≤ (90#i32).val); omega
          have hd2 : (decide (95#i32 >= 97#i32) && decide (95#i32 <= 122#i32)) = false := by
            simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not]; left; change ¬ ((95#i32).val ≥ (97#i32).val); omega
          have hd3 : (decide (95#i32 >= 48#i32) && decide (95#i32 <= 57#i32)) = false := by
            simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not]; right; change ¬ ((95#i32).val ≤ (57#i32).val); omega
          have hne45 : (95#i32 : Std.I32) ≠ 45#i32 := by intro h; have := congrArg IScalar.val h; omega
          simp only [hd1, hd2, hd3, hne45, Bool.false_eq_true, ↓reduceIte]

/-- `b64url_decode_byte` is total and accepts ONLY RFC 4648 §5 alphabet bytes (`A-Z`, `a-z`, `0-9`, `-`, `_`). -/
theorem b64url_decode_byte_spec (b : Std.U8) :
    ∃ r : Std.I32, b64url_decode_byte b = ok r ∧
      (if (65 ≤ b.val ∧ b.val ≤ 90) ∨ (97 ≤ b.val ∧ b.val ≤ 122) ∨
          (48 ≤ b.val ∧ b.val ≤ 57) ∨ b.val = 45 ∨ b.val = 95
       then 0 ≤ r.val ∧ r.val < 64
       else r.val = -1) := by
  unfold b64url_decode_byte
  dsimp only
  have hc := u8_to_int_val b
  have hb := u8_bounds b
  refine ⟨_, rfl, ?_⟩
  have h65 : (65#i32).val = 65 := by simp
  have h90 : (90#i32).val = 90 := by simp
  have h97 : (97#i32).val = 97 := by simp
  have h122 : (122#i32).val = 122 := by simp
  have h48 : (48#i32).val = 48 := by simp
  have h57 : (57#i32).val = 57 := by simp
  have h45 : (45#i32).val = 45 := by simp
  have h95 : (95#i32).val = 95 := by simp
  have h26 : (26#i32).val = 26 := by simp
  have h52 : (52#i32).val = 52 := by simp
  have h62 : (62#i32).val = 62 := by simp
  have h63 : (63#i32).val = 63 := by simp
  have hm1 : ((-1)#i32).val = -1 := by simp
  by_cases c1 : 65 ≤ b.val ∧ b.val ≤ 90
  · have hcond : (decide (Pion.U8.to_int b >= 65#i32) && decide (Pion.U8.to_int b <= 90#i32)) = true := by
      simp only [Bool.and_eq_true, decide_eq_true_eq]
      exact ⟨by change _ ≥ (65#i32).val; omega, by change _ ≤ (90#i32).val; omega⟩
    simp only [hcond, ↓reduceIte, c1, true_or, ite_true]
    have hsub := i32_sub_val (a := Pion.U8.to_int b) (b := 65#i32) (by omega) (by omega)
    exact ⟨by omega, by omega⟩
  · have hcond1 : (decide (Pion.U8.to_int b >= 65#i32) && decide (Pion.U8.to_int b <= 90#i32)) = false := by
      simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not]
      by_cases hlt : b.val < 65
      · left; change ¬ (_ ≥ (65#i32).val); omega
      · right; change ¬ (_ ≤ (90#i32).val); omega
    by_cases c2 : 97 ≤ b.val ∧ b.val ≤ 122
    · have hcond2 : (decide (Pion.U8.to_int b >= 97#i32) && decide (Pion.U8.to_int b <= 122#i32)) = true := by
        simp only [Bool.and_eq_true, decide_eq_true_eq]
        exact ⟨by change _ ≥ (97#i32).val; omega, by change _ ≤ (122#i32).val; omega⟩
      simp only [hcond1, hcond2, Bool.false_eq_true, ↓reduceIte, c2, and_self, true_or, or_true, ite_true]
      have hsub := i32_sub_val (a := Pion.U8.to_int b) (b := 97#i32) (by omega) (by omega)
      have hadd := i32_add_val (a := Pion.I32.sub (Pion.U8.to_int b) 97#i32) (b := 26#i32) (by omega) (by omega)
      exact ⟨by omega, by omega⟩
    · have hcond2 : (decide (Pion.U8.to_int b >= 97#i32) && decide (Pion.U8.to_int b <= 122#i32)) = false := by
        simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not]
        by_cases hlt : b.val < 97
        · left; change ¬ (_ ≥ (97#i32).val); omega
        · right; change ¬ (_ ≤ (122#i32).val); omega
      by_cases c3 : 48 ≤ b.val ∧ b.val ≤ 57
      · have hcond3 : (decide (Pion.U8.to_int b >= 48#i32) && decide (Pion.U8.to_int b <= 57#i32)) = true := by
          simp only [Bool.and_eq_true, decide_eq_true_eq]
          exact ⟨by change _ ≥ (48#i32).val; omega, by change _ ≤ (57#i32).val; omega⟩
        simp only [hcond1, hcond2, hcond3, Bool.false_eq_true, ↓reduceIte, c3, and_self, true_or, or_true, ite_true]
        have hsub := i32_sub_val (a := Pion.U8.to_int b) (b := 48#i32) (by omega) (by omega)
        have hadd := i32_add_val (a := Pion.I32.sub (Pion.U8.to_int b) 48#i32) (b := 52#i32) (by omega) (by omega)
        exact ⟨by omega, by omega⟩
      · have hcond3 : (decide (Pion.U8.to_int b >= 48#i32) && decide (Pion.U8.to_int b <= 57#i32)) = false := by
          simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not]
          by_cases hlt : b.val < 48
          · left; change ¬ (_ ≥ (48#i32).val); omega
          · right; change ¬ (_ ≤ (57#i32).val); omega
        simp only [hcond1, hcond2, hcond3, Bool.false_eq_true, ↓reduceIte]
        by_cases c4 : b.val = 45
        · have heq4 : Pion.U8.to_int b = 45#i32 := IScalar.eq_of_val_eq (by omega)
          simp only [heq4, ↓reduceIte, c4, true_or, or_true, ite_true]
          exact ⟨by omega, by omega⟩
        · have hne4 : Pion.U8.to_int b ≠ 45#i32 := by
            intro h; have := congrArg IScalar.val h; omega
          by_cases c5 : b.val = 95
          · have heq5 : Pion.U8.to_int b = 95#i32 := IScalar.eq_of_val_eq (by omega)
            have h95ne45 : (95#i32 : Std.I32) ≠ 45#i32 := by intro h; have := congrArg IScalar.val h; omega
            simp only [heq5, h95ne45, ↓reduceIte, c5, or_true, ite_true]
            exact ⟨by omega, by omega⟩
          · have hne5 : Pion.U8.to_int b ≠ 95#i32 := by
              intro h; have := congrArg IScalar.val h; omega
            simp only [hne4, hne5, ↓reduceIte, c1, c2, c3, c4, c5, or_self]
            exact hm1

private theorem b64url_decode_invalid_of_spec (b : Std.U8)
    (h : ¬ ((65 ≤ b.val ∧ b.val ≤ 90) ∨ (97 ≤ b.val ∧ b.val ≤ 122) ∨
            (48 ≤ b.val ∧ b.val ≤ 57) ∨ b.val = 45 ∨ b.val = 95)) :
    b64url_decode_byte b = ok ((-1)#i32) := by
  obtain ⟨r, hr, hspec⟩ := b64url_decode_byte_spec b
  simp only [h, ↓reduceIte] at hspec
  rw [hr]
  congr 1
  apply IScalar.eq_of_val_eq
  have hm1 : ((-1)#i32).val = -1 := by simp
  omega

/-- Standard Base64 `+`, `/`, padding `=`, whitespace, and NUL are unconditionally rejected (`-1`). -/
theorem b64url_decode_rejects_invalid_chars :
    b64url_decode_byte 43#u8 = ok ((-1)#i32) ∧
    b64url_decode_byte 47#u8 = ok ((-1)#i32) ∧
    b64url_decode_byte 61#u8 = ok ((-1)#i32) ∧
    b64url_decode_byte 32#u8 = ok ((-1)#i32) ∧
    b64url_decode_byte 10#u8 = ok ((-1)#i32) ∧
    b64url_decode_byte 13#u8 = ok ((-1)#i32) ∧
    b64url_decode_byte 9#u8 = ok ((-1)#i32) ∧
    b64url_decode_byte 0#u8 = ok ((-1)#i32) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;>
    (apply b64url_decode_invalid_of_spec; simp)

private theorem i32_band_3_val (x : Std.I32) : (Pion.I32.band x 3#i32).val = x.val % 4 := by
  cases x with
  | mk bv =>
    have hlt : bv.toNat < 2 ^ 32 := bv.isLt
    have htoNat : (bv &&& (3#i32).bv).toNat = bv.toNat % 4 := by
      have h3 : (3#i32).bv.toNat = 3 := rfl
      rw [BitVec.toNat_and, h3]
      exact Nat.and_two_pow_sub_one_eq_mod bv.toNat 2
    change (bv &&& (3#i32).bv).toInt = bv.toInt % 4
    rw [BitVec.toInt_eq_toNat_cond, BitVec.toInt_eq_toNat_cond]
    simp only [htoNat]
    have hlt4 : bv.toNat % 4 < 4 := Nat.mod_lt _ (by decide)
    have hpos : 2 * (bv.toNat % 4) < 2 ^ IScalarTy.I32.numBits := by
      change 2 * (bv.toNat % 4) < 2 ^ 32; omega
    simp only [hpos, ↓reduceIte]
    split_ifs with hsign
    · omega
    · change (bv.toNat % 4 : Int) = ((bv.toNat : Int) - 2 ^ 32) % 4
      omega

private theorem i32_band_15_val (x : Std.I32) : (Pion.I32.band x 15#i32).val = x.val % 16 := by
  cases x with
  | mk bv =>
    have hlt : bv.toNat < 2 ^ 32 := bv.isLt
    have htoNat : (bv &&& (15#i32).bv).toNat = bv.toNat % 16 := by
      have h15 : (15#i32).bv.toNat = 15 := rfl
      rw [BitVec.toNat_and, h15]
      exact Nat.and_two_pow_sub_one_eq_mod bv.toNat 4
    change (bv &&& (15#i32).bv).toInt = bv.toInt % 16
    rw [BitVec.toInt_eq_toNat_cond, BitVec.toInt_eq_toNat_cond]
    simp only [htoNat]
    have hlt16 : bv.toNat % 16 < 16 := Nat.mod_lt _ (by decide)
    have hpos : 2 * (bv.toNat % 16) < 2 ^ IScalarTy.I32.numBits := by
      change 2 * (bv.toNat % 16) < 2 ^ 32; omega
    simp only [hpos, ↓reduceIte]
    split_ifs with hsign
    · omega
    · change (bv.toNat % 16 : Int) = ((bv.toNat : Int) - 2 ^ 32) % 16
      omega

/-- `base64url_len_valid` accepts `len` iff `len ≥ 0` and `len % 4 ≠ 1`. -/
theorem base64url_len_valid_iff (len : Std.I32) :
    base64url_len_valid len = ok true ↔ 0 ≤ len.val ∧ len.val % 4 ≠ 1 := by
  unfold base64url_len_valid
  simp only [Result.ok.injEq, Bool.and_eq_true, decide_eq_true_eq, bne_iff_ne]
  have h0 : (0#i32).val = 0 := by simp
  have h1 : (1#i32).val = 1 := by simp
  have hb := i32_band_3_val len
  constructor
  · rintro ⟨hge, hne⟩
    refine ⟨by change len.val ≥ (0#i32).val at hge; omega, ?_⟩
    intro hmod
    apply hne
    apply IScalar.eq_of_val_eq
    omega
  · rintro ⟨hge, hne⟩
    refine ⟨by change len.val ≥ (0#i32).val; omega, ?_⟩
    intro heq
    have := congrArg IScalar.val heq
    omega

/-- Any length with `len % 4 = 1` is unconditionally rejected. -/
theorem base64url_len_valid_rejects_mod4_eq1 (len : Std.I32) (h : len.val % 4 = 1) :
    base64url_len_valid len = ok false := by
  have hne : ¬ (base64url_len_valid len = ok true) := by
    rw [base64url_len_valid_iff]
    omega
  unfold base64url_len_valid at hne ⊢
  cases hval : (decide (len >= 0#i32) && (Pion.I32.band len 3#i32 != 1#i32))
  · rfl
  · rw [hval] at hne; exact False.elim (hne rfl)

/-- `base64url_tail_bits_valid` enforces canonical zero trailing bits:
    `rem = 0`, or (`rem = 2 ∧ last_val % 16 = 0`), or (`rem = 3 ∧ last_val % 4 = 0`). -/
theorem base64url_tail_bits_valid_iff (rem last_val : Std.I32) :
    base64url_tail_bits_valid rem last_val = ok true ↔
      rem.val = 0 ∨
      (rem.val = 2 ∧ last_val.val % 16 = 0) ∨
      (rem.val = 3 ∧ last_val.val % 4 = 0) := by
  unfold base64url_tail_bits_valid
  have h0 : (0#i32).val = 0 := by simp
  have h2 : (2#i32).val = 2 := by simp
  have h3 : (3#i32).val = 3 := by simp
  have hb15 := i32_band_15_val last_val
  have hb3 := i32_band_3_val last_val
  by_cases hr2 : rem = 2#i32
  · subst hr2
    simp only [↓reduceIte, Result.ok.injEq, beq_iff_eq]
    constructor
    · intro h; right; left
      have := congrArg IScalar.val h
      omega
    · intro h
      apply IScalar.eq_of_val_eq
      rcases h with h | ⟨_, h⟩ | ⟨h, _⟩ <;> omega
  · by_cases hr3 : rem = 3#i32
    · subst hr3
      simp only [hr2, ↓reduceIte, Result.ok.injEq, beq_iff_eq]
      constructor
      · intro h; right; right
        have := congrArg IScalar.val h
        omega
      · intro h
        apply IScalar.eq_of_val_eq
        rcases h with h | ⟨h, _⟩ | ⟨_, h⟩ <;> omega
    · simp only [hr2, hr3, ↓reduceIte, Result.ok.injEq, beq_iff_eq]
      have hne2 : rem.val ≠ 2 := fun h => hr2 (IScalar.eq_of_val_eq (by omega))
      have hne3 : rem.val ≠ 3 := fun h => hr3 (IScalar.eq_of_val_eq (by omega))
      constructor
      · intro h; left
        have := congrArg IScalar.val h
        omega
      · intro h
        apply IScalar.eq_of_val_eq
        rcases h with h | ⟨h, _⟩ | ⟨h, _⟩ <;> omega

/-- `base64url_decoded_len (base64url_encoded_len n) = n` for all valid `0 ≤ n ≤ 1610612733`. -/
theorem base64url_encoded_decoded_len_roundtrip (n : Std.I32)
    (h0 : 0 ≤ n.val) (hhi : n.val ≤ 1610612733) :
    ∃ enc : Std.I32,
      base64url_encoded_len n = ok enc ∧
      base64url_len_valid enc = ok true ∧
      base64url_decoded_len enc = ok n := by
  unfold base64url_encoded_len base64url_decoded_len
  have h3 : (3#i32).val = 3 := by simp
  have h4 : (4#i32).val = 4 := by simp
  have h2 : (2#i32).val = 2 := by simp
  have h1 : (1#i32).val = 1 := by simp
  have h0v : (0#i32).val = 0 := by simp
  have hdiv_wp : Pion.I32.div n 3#i32 ⦃ z => z.val = Int.tdiv n.val 3 ⦄ :=
    Pion.I32.div_spec (by omega) (by omega)
  rw [wp_ok_iff] at hdiv_wp
  obtain ⟨full, hfull, hfullv⟩ := hdiv_wp
  have hfull_eq : full.val = n.val / 3 := by
    rw [hfullv, Int.tdiv_eq_ediv_of_nonneg (by omega)]
  rw [hfull, b_ok]
  have hmul3 : (Pion.I32.mul full 3#i32).val = full.val * 3 := by
    have := i32_mul_val (a := full) (b := 3#i32) (by rw [h3]; omega) (by rw [h3]; omega)
    rw [h3] at this; exact this
  have hremv : (Pion.I32.sub n (Pion.I32.mul full 3#i32)).val = n.val % 3 := by
    rw [i32_sub_val (a := n) (b := Pion.I32.mul full 3#i32) (by omega) (by omega), hmul3, hfull_eq]
    omega
  have hmul4 : (Pion.I32.mul full 4#i32).val = full.val * 4 := by
    have := i32_mul_val (a := full) (b := 4#i32) (by rw [h4]; omega) (by rw [h4]; omega)
    rw [h4] at this; exact this
  set rem := Pion.I32.sub n (Pion.I32.mul full 3#i32)
  set tail := if rem = 0#i32 then 0#i32 else Pion.I32.add rem 1#i32
  have htailv : tail.val = if n.val % 3 = 0 then 0 else n.val % 3 + 1 := by
    by_cases hrz : rem = 0#i32
    · have hmz : n.val % 3 = 0 := by
        have := congrArg IScalar.val hrz; omega
      simp [tail, hrz, hmz]
    · have hmnz : n.val % 3 ≠ 0 := by
        intro hmz; exact hrz (IScalar.eq_of_val_eq (by omega))
      simp only [tail, hrz, hmnz, ↓reduceIte]
      rw [i32_add_val (a := rem) (b := 1#i32) (by omega) (by omega), hremv, h1]
  set enc := Pion.I32.add (Pion.I32.mul full 4#i32) tail
  have hencv : enc.val = full.val * 4 + (if n.val % 3 = 0 then 0 else n.val % 3 + 1) := by
    rw [i32_add_val (a := Pion.I32.mul full 4#i32) (b := tail) (by omega) (by omega), hmul4, htailv]
  refine ⟨enc, rfl, ?_, ?_⟩
  · rw [base64url_len_valid_iff]
    split_ifs at hencv <;> omega
  · have hshr_wp : Pion.I32.shr enc 2#i32 ⦃ z => z.bv = enc.bv.sshiftRight 2 ⦄ :=
      Pion.I32.shr_spec enc (by omega) (by omega)
    rw [wp_ok_iff] at hshr_wp
    obtain ⟨dfull, hdfull, hdfullbv⟩ := hshr_wp
    rw [hdfull, b_ok]
    have hdfullv : dfull.val = enc.val / 4 := by
      have henc0 : 0 ≤ enc.val := by split_ifs at hencv <;> omega
      cases dfull with
      | mk dbv =>
        change dbv = enc.bv.sshiftRight 2 at hdfullbv
        change dbv.toInt = enc.bv.toInt / 4
        rw [hdfullbv, BitVec.toInt_sshiftRight]
        simp [Int.shiftRight_eq_div_pow]
    have hdremv : (Pion.I32.band enc 3#i32).val = enc.val % 4 := i32_band_3_val enc
    have hdmul : (Pion.I32.mul dfull 3#i32).val = dfull.val * 3 := by
      have := i32_mul_val (a := dfull) (b := 3#i32) (by rw [h3]; omega) (by rw [h3]; omega)
      rw [h3] at this; exact this
    dsimp only
    congr 1
    apply IScalar.eq_of_val_eq
    by_cases hdz : Pion.I32.band enc 3#i32 = 0#i32
    · simp only [hdz, ↓reduceIte]
      have hmod0 : enc.val % 4 = 0 := by have := congrArg IScalar.val hdz; omega
      rw [i32_add_val (a := Pion.I32.mul dfull 3#i32) (b := 0#i32) (by omega) (by omega), hdmul, h0v]
      split_ifs at hencv <;> omega
    · simp only [hdz, ↓reduceIte]
      have hmodnz : enc.val % 4 ≠ 0 := fun h => hdz (IScalar.eq_of_val_eq (by omega))
      have hdsub : (Pion.I32.sub (Pion.I32.band enc 3#i32) 1#i32).val = enc.val % 4 - 1 := by
        rw [i32_sub_val (a := Pion.I32.band enc 3#i32) (b := 1#i32) (by omega) (by omega), hdremv, h1]
      rw [i32_add_val (a := Pion.I32.mul dfull 3#i32) (b := Pion.I32.sub (Pion.I32.band enc 3#i32) 1#i32) (by omega) (by omega), hdmul, hdsub]
      split_ifs at hencv <;> omega

/-! ## Section 5: SHA-256 Bitwise Primitives (`packages/jwt/src/crypto.pion`) -/

/-- `sha256_ch x y y = ok y` (choice on identical inputs is the identity). -/
theorem sha256_ch_same (x y : Std.U32) :
    sha256_ch x y y = ok y := by
  unfold sha256_ch
  congr 1
  cases x with | mk bx =>
  cases y with | mk by_ =>
  change UScalar.mk ((bx &&& by_) ^^^ ((bx ^^^ (4294967295#u32).bv) &&& by_)) = UScalar.mk by_
  congr 1
  ext i hi
  simp only [BitVec.getElem_xor, BitVec.getElem_and]
  have hones : (4294967295#u32).bv[i] = true := by
    change (BitVec.ofNat 32 4294967295)[i] = true
    have : BitVec.ofNat 32 4294967295 = BitVec.allOnes 32 := rfl
    rw [this, BitVec.getElem_allOnes]
  rw [hones]
  cases bx[i] <;> cases by_[i] <;> rfl

/-- `sha256_maj x x y = ok x` (majority with two equal inputs selects that input). -/
theorem sha256_maj_same_xy (x y : Std.U32) :
    sha256_maj x x y = ok x := by
  unfold sha256_maj
  congr 1
  cases x with | mk bx =>
  cases y with | mk by_ =>
  change UScalar.mk (((bx &&& bx) ^^^ (bx &&& by_)) ^^^ (bx &&& by_)) = UScalar.mk bx
  congr 1
  ext i hi
  simp only [BitVec.getElem_xor, BitVec.getElem_and]
  cases bx[i] <;> cases by_[i] <;> rfl

/-- `sha256_maj` is symmetric in its first two arguments. -/
theorem sha256_maj_symm_xy (x y z : Std.U32) :
    sha256_maj x y z = sha256_maj y x z := by
  unfold sha256_maj
  congr 1
  cases x with | mk bx =>
  cases y with | mk by_ =>
  cases z with | mk bz =>
  change UScalar.mk (((bx &&& by_) ^^^ (bx &&& bz)) ^^^ (by_ &&& bz)) =
         UScalar.mk (((by_ &&& bx) ^^^ (by_ &&& bz)) ^^^ (bx &&& bz))
  congr 1
  ext i hi
  simp only [BitVec.getElem_xor, BitVec.getElem_and]
  cases bx[i] <;> cases by_[i] <;> cases bz[i] <;> rfl

/-- `sha256_rotr x n` is total for `0 < n < 32` and equals `BitVec.rotateRight x.bv n.val`. -/
theorem sha256_rotr_spec (x n : Std.U32) (hpos : 0 < n.val) (hlt : n.val < 32) :
    ∃ r : Std.U32, sha256_rotr x n = ok r ∧ r.bv = x.bv.rotateRight n.val := by
  unfold sha256_rotr
  have hshr : Pion.U32.shr x n = ok ⟨x.bv >>> n.val⟩ := by
    unfold Pion.U32.shr; simp [hlt]
  have hsub_val : (Pion.U32.sub 32#u32 n).val = 32 - n.val := by
    cases n with | mk bn =>
    simp only [UScalar.val, UScalarTy.numBits] at hpos hlt ⊢
    simp only [Pion.U32.sub, Std.U32.wrapping_sub, UScalar.wrapping_sub, UScalar.val,
      UScalarTy.numBits, BitVec.toNat_sub]
    have h32 : (32#u32).bv.toNat = 32 := rfl
    rw [h32]
    omega
  have hshl : Pion.U32.shl x (Pion.U32.sub 32#u32 n) = ok ⟨x.bv <<< (32 - n.val)⟩ := by
    unfold Pion.U32.shl
    rw [hsub_val]
    simp [show 32 - n.val < 32 by omega]
  rw [hshr, b_ok, hshl, b_ok]
  refine ⟨_, rfl, ?_⟩
  change (x.bv >>> n.val) ||| (x.bv <<< (32 - n.val)) = x.bv.rotateRight n.val
  have hnmod : n.val % 32 = n.val := Nat.mod_eq_of_lt hlt
  ext i hi
  simp only [BitVec.getElem_or, BitVec.getElem_ushiftRight,
    BitVec.getElem_shiftLeft, BitVec.getElem_rotateRight, hnmod]
  by_cases hsum : i < 32 - n.val
  · simp only [hsum, ↓reduceDIte, decide_true, Bool.not_true, Bool.false_and, Bool.or_false]
    rw [BitVec.getLsbD_eq_getElem (by omega)]
  · simp only [hsum, ↓reduceDIte, decide_false, Bool.not_false, Bool.true_and]
    have hge : 32 ≤ n.val + i := by omega
    have hmsb : x.bv.getLsbD (n.val + i) = false := BitVec.getLsbD_of_ge x.bv (n.val + i) hge
    rw [hmsb, Bool.false_or]

/-- Composing two 32-bit right rotations adds their shift amounts (`a + b < 32`). -/
theorem sha256_rotr_compose (x a b : Std.U32)
    (ha : 0 < a.val) (hb : 0 < b.val) (hab : a.val + b.val < 32) :
    (do let r1 ← sha256_rotr x a; sha256_rotr r1 b) = sha256_rotr x (Pion.U32.add a b) := by
  obtain ⟨r1, hr1, hr1bv⟩ := sha256_rotr_spec x a ha (by omega)
  obtain ⟨r2, hr2, hr2bv⟩ := sha256_rotr_spec r1 b hb (by omega)
  have haddv : (Pion.U32.add a b).val = a.val + b.val := by
    cases a with | mk ba =>
    cases b with | mk bb =>
    simp only [UScalar.val, UScalarTy.numBits] at ha hb hab ⊢
    simp only [Pion.U32.add, Std.U32.wrapping_add, UScalar.wrapping_add, UScalar.val,
      UScalarTy.numBits, BitVec.toNat_add]
    omega
  obtain ⟨r3, hr3, hr3bv⟩ := sha256_rotr_spec x (Pion.U32.add a b) (by omega) (by omega)
  rw [hr1, b_ok, hr2, hr3]
  congr 1
  cases r2 with | mk b2 =>
  cases r3 with | mk b3 =>
  congr 1
  change b2 = r1.bv.rotateRight b.val at hr2bv
  change b3 = x.bv.rotateRight (Pion.U32.add a b).val at hr3bv
  rw [hr2bv, hr1bv, hr3bv, haddv]
  have hamod : a.val % 32 = a.val := Nat.mod_eq_of_lt (by omega)
  have hbmod : b.val % 32 = b.val := Nat.mod_eq_of_lt (by omega)
  have habmod : (a.val + b.val) % 32 = a.val + b.val := Nat.mod_eq_of_lt (by omega)
  ext i hi
  simp only [BitVec.getElem_rotateRight, hamod, hbmod, habmod]
  split_ifs <;> (congr 1; try omega)

/-- All four SHA-256 sigma functions (`Σ0`, `Σ1`, `σ0`, `σ1`) are total (zero shift-overflow). -/
theorem sha256_sigmas_total (x : Std.U32) :
    (∃ r, sha256_sigma0 x = ok r) ∧
    (∃ r, sha256_sigma1 x = ok r) ∧
    (∃ r, sha256_lsigma0 x = ok r) ∧
    (∃ r, sha256_lsigma1 x = ok r) := by
  refine ⟨?_, ?_, ?_, ?_⟩
  · unfold sha256_sigma0
    obtain ⟨r1, hr1, _⟩ := sha256_rotr_spec x 2#u32 (by simp) (by simp)
    obtain ⟨r2, hr2, _⟩ := sha256_rotr_spec x 13#u32 (by simp) (by simp)
    obtain ⟨r3, hr3, _⟩ := sha256_rotr_spec x 22#u32 (by simp) (by simp)
    rw [hr1, b_ok, hr2, b_ok, hr3, b_ok]
    exact ⟨_, rfl⟩
  · unfold sha256_sigma1
    obtain ⟨r1, hr1, _⟩ := sha256_rotr_spec x 6#u32 (by simp) (by simp)
    obtain ⟨r2, hr2, _⟩ := sha256_rotr_spec x 11#u32 (by simp) (by simp)
    obtain ⟨r3, hr3, _⟩ := sha256_rotr_spec x 25#u32 (by simp) (by simp)
    rw [hr1, b_ok, hr2, b_ok, hr3, b_ok]
    exact ⟨_, rfl⟩
  · unfold sha256_lsigma0
    obtain ⟨r1, hr1, _⟩ := sha256_rotr_spec x 7#u32 (by simp) (by simp)
    obtain ⟨r2, hr2, _⟩ := sha256_rotr_spec x 18#u32 (by simp) (by simp)
    have hshr : Pion.U32.shr x 3#u32 = ok ⟨x.bv >>> 3⟩ := by unfold Pion.U32.shr; simp
    rw [hr1, b_ok, hr2, b_ok, hshr, b_ok]
    exact ⟨_, rfl⟩
  · unfold sha256_lsigma1
    obtain ⟨r1, hr1, _⟩ := sha256_rotr_spec x 17#u32 (by simp) (by simp)
    obtain ⟨r2, hr2, _⟩ := sha256_rotr_spec x 19#u32 (by simp) (by simp)
    have hshr : Pion.U32.shr x 10#u32 = ok ⟨x.bv >>> 10⟩ := by unfold Pion.U32.shr; simp
    rw [hr1, b_ok, hr2, b_ok, hshr, b_ok]
    exact ⟨_, rfl⟩

end JwtProofs
