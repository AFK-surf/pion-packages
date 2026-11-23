/-
Formal verification of `packages/uuid` (`Uuid.Funs`, extracted via
`pionc extract-lean` from `packages/uuid/src/{uuid,ulid,types}.pion`).

All proofs are complete and kernel-checked, depending only on the three
standard Lean axioms: `propext`, `Classical.choice`, `Quot.sound`.
-/
import Uuid.Funs

open Aeneas Aeneas.Std Result Pion

set_option maxRecDepth 100000
set_option maxHeartbeats 2000000
set_option linter.unusedSimpArgs false
set_option linter.deprecated false

namespace UuidProofs

open uuid

/-! ## Core BitVec & Scalar Helpers -/

lemma b_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← (ok x : Result α); f y) = f x := by simp

lemma u64_ext {a b : Std.U64} (h : a.val = b.val) : a = b := by
  cases a; cases b
  congr 1
  exact BitVec.eq_of_toNat_eq h

lemma u64_ext_bv {a b : Std.U64} (h : a.bv = b.bv) : a = b := by
  cases a; cases b
  congr 1

lemma i64_ext_bv {a b : Std.I64} (h : a.bv = b.bv) : a = b := by
  cases a; cases b
  congr 1

lemma i32_ext_val {a b : Std.I32} (h : a.val = b.val) : a = b := by
  cases a; cases b
  congr 1
  exact BitVec.eq_of_toInt_eq h

lemma i64_to_u64_bv (x : Std.I64) : (Pion.I64.to_uint64 x).bv = x.bv := by
  simp only [Pion.I64.to_uint64, IScalar.hcast_bv_eq]
  apply BitVec.eq_of_toNat_eq
  rw [BitVec.signExtend_eq_setWidth_of_le x.bv (by decide), BitVec.toNat_setWidth]
  exact Nat.mod_eq_of_lt x.bv.isLt

lemma u64_to_i64_bv (x : Std.U64) : (Pion.U64.to_int64 x).bv = x.bv := by
  simp only [Pion.U64.to_int64, UScalar.hcast_bv_eq]
  apply BitVec.eq_of_toNat_eq
  rw [BitVec.toNat_setWidth]
  exact Nat.mod_eq_of_lt x.bv.isLt

lemma u64_to_i64_to_u64 (x : Std.U64) :
    Pion.I64.to_uint64 (Pion.U64.to_int64 x) = x := by
  apply u64_ext_bv
  rw [i64_to_u64_bv, u64_to_i64_bv]

lemma i64_to_u64_to_i64 (x : Std.I64) :
    Pion.U64.to_int64 (Pion.I64.to_uint64 x) = x := by
  apply i64_ext_bv
  rw [u64_to_i64_bv, i64_to_u64_bv]

lemma i64_to_u64_inj {a b : Std.I64}
    (h : Pion.I64.to_uint64 a = Pion.I64.to_uint64 b) : a = b := by
  have hbv : a.bv = b.bv := by
    rw [← i64_to_u64_bv a, ← i64_to_u64_bv b, h]
  exact i64_ext_bv hbv

lemma i64_nonneg_to_u64_val {x : Std.I64} (h0 : 0 ≤ x.val) :
    ((Pion.I64.to_uint64 x).val : Int) = x.val := by
  have hbv : (Pion.I64.to_uint64 x).bv = x.bv := i64_to_u64_bv x
  change ((Pion.I64.to_uint64 x).bv.toNat : Int) = x.bv.toInt
  rw [hbv]
  have htoInt := BitVec.toInt_eq_toNat_cond x.bv
  change 0 ≤ x.bv.toInt at h0
  have hlt : 2 * x.bv.toNat < 2 ^ 64 := by
    split_ifs at htoInt with h
    · exact h
    · have := x.bv.isLt
      omega
  rw [BitVec.toInt_eq_toNat_of_lt hlt]

lemma u64_lt_2p63_to_i64_val {x : Std.U64} (hlt : x.val < 2 ^ 63) :
    (Pion.U64.to_int64 x).val = (x.val : Int) := by
  have hbv : (Pion.U64.to_int64 x).bv = x.bv := u64_to_i64_bv x
  change (Pion.U64.to_int64 x).bv.toInt = (x.bv.toNat : Int)
  rw [hbv]
  have h2 : 2 * x.bv.toNat < 2 ^ 64 := by
    change x.bv.toNat < 2 ^ 63 at hlt
    omega
  exact BitVec.toInt_eq_toNat_of_lt h2

lemma u64_val_lt (x : Std.U64) : x.val < 2 ^ 64 := x.bv.isLt

lemma u64_zero_val : (Pion.I64.to_uint64 0#i64).val = 0 := by decide

lemma u64_max_val : (Pion.I64.to_uint64 (-1)#i64).val = 2 ^ 64 - 1 := by decide

lemma i32_neg_one : Pion.I32.neg 1#i32 = (-1)#i32 := by decide
lemma i32_neg_neg_one : Pion.I32.neg (-1)#i32 = 1#i32 := by decide
lemma i32_neg_zero : Pion.I32.neg 0#i32 = 0#i32 := by decide

lemma result_ok_inj {α : Type} {a b : α} (h : (ok a : Result α) = ok b) : a = b := by
  simpa using h

lemma res_ok_inj {α β : Type} {a b : α} (h : (Pion.Res.Ok a : Pion.Res α β) = Pion.Res.Ok b) : a = b :=
  Pion.Res.Ok.inj h

/-- Mathematical 128-bit unsigned integer value of a `(hi, lo)` pair. -/
def u128Val (hi lo : Std.I64) : Nat :=
  (Pion.I64.to_uint64 hi).val * 2 ^ 64 + (Pion.I64.to_uint64 lo).val

/-- Mathematical 128-bit unsigned value of a `Uuid`. -/
def uuidVal (u : Uuid) : Nat := u128Val u.hi u.lo

/-- Mathematical 128-bit unsigned value of a `Ulid`. -/
def ulidVal (u : Ulid) : Nat := u128Val u.hi u.lo

lemma u128Val_lt_iff (ah al bh bl : Std.I64) :
    u128Val ah al < u128Val bh bl ↔
      (Pion.I64.to_uint64 ah < Pion.I64.to_uint64 bh) ∨
      (Pion.I64.to_uint64 ah = Pion.I64.to_uint64 bh ∧
       Pion.I64.to_uint64 al < Pion.I64.to_uint64 bl) := by
  unfold u128Val
  have hal := u64_val_lt (Pion.I64.to_uint64 al)
  have hbl := u64_val_lt (Pion.I64.to_uint64 bl)
  constructor
  · intro h
    by_cases hhi : (Pion.I64.to_uint64 ah).val < (Pion.I64.to_uint64 bh).val
    · left; exact hhi
    · right
      have hheq : (Pion.I64.to_uint64 ah).val = (Pion.I64.to_uint64 bh).val := by omega
      refine ⟨u64_ext hheq, ?_⟩
      change (Pion.I64.to_uint64 al).val < (Pion.I64.to_uint64 bl).val
      omega
  · intro h
    rcases h with hlt | ⟨heq, hlt⟩
    · have h1 : (Pion.I64.to_uint64 ah).val < (Pion.I64.to_uint64 bh).val := hlt
      omega
    · have h1 : (Pion.I64.to_uint64 ah).val = (Pion.I64.to_uint64 bh).val := by rw [heq]
      have h2 : (Pion.I64.to_uint64 al).val < (Pion.I64.to_uint64 bl).val := hlt
      omega

lemma u128Val_eq_iff (ah al bh bl : Std.I64) :
    u128Val ah al = u128Val bh bl ↔ ah = bh ∧ al = bl := by
  unfold u128Val
  have hal := u64_val_lt (Pion.I64.to_uint64 al)
  have hbl := u64_val_lt (Pion.I64.to_uint64 bl)
  constructor
  · intro h
    have hhi : (Pion.I64.to_uint64 ah).val = (Pion.I64.to_uint64 bh).val := by omega
    have hlo : (Pion.I64.to_uint64 al).val = (Pion.I64.to_uint64 bl).val := by omega
    exact ⟨i64_to_u64_inj (u64_ext hhi), i64_to_u64_inj (u64_ext hlo)⟩
  · rintro ⟨rfl, rfl⟩
    rfl

lemma uuid_ext {a b : Uuid} (hhi : a.hi = b.hi) (hlo : a.lo = b.lo) : a = b := by
  cases a; cases b; simp_all

lemma ulid_ext {a b : Ulid} (hhi : a.hi = b.hi) (hlo : a.lo = b.lo) : a = b := by
  cases a; cases b; simp_all

lemma uuidVal_eq_iff (a b : Uuid) : uuidVal a = uuidVal b ↔ a = b := by
  unfold uuidVal
  rw [u128Val_eq_iff]
  constructor
  · rintro ⟨h1, h2⟩; exact uuid_ext h1 h2
  · rintro rfl; exact ⟨rfl, rfl⟩

lemma ulidVal_eq_iff (a b : Ulid) : ulidVal a = ulidVal b ↔ a = b := by
  unfold ulidVal
  rw [u128Val_eq_iff]
  constructor
  · rintro ⟨h1, h2⟩; exact ulid_ext h1 h2
  · rintro rfl; exact ⟨rfl, rfl⟩

/-! ## 1. 128-bit Unsigned Strict Total Order & `Uuid` / `Ulid` Equivalence -/

theorem uuid_from_as_u64_pair (u : Uuid) :
    (do let (hi, lo) ← Uuid.as_u64_pair u; Uuid.from_u64_pair hi lo) = ok u := by
  unfold Uuid.as_u64_pair Uuid.from_u64_pair
  rw [b_ok]
  change ok (Uuid.mk (Pion.U64.to_int64 (Pion.I64.to_uint64 u.hi)) (Pion.U64.to_int64 (Pion.I64.to_uint64 u.lo))) = ok u
  rw [i64_to_u64_to_i64, i64_to_u64_to_i64]

lemma uuid_compare_total (a b : Uuid) :
    ∃ r : Std.I32, Uuid.compare a b = ok r ∧
      (r = (-1)#i32 ∨ r = 0#i32 ∨ r = 1#i32) := by
  unfold Uuid.compare
  dsimp only
  split_ifs <;> exact ⟨_, rfl, by decide⟩

theorem uuid_compare_spec_lt (a b : Uuid) :
    Uuid.compare a b = ok (-1)#i32 ↔ uuidVal a < uuidVal b := by
  unfold Uuid.compare uuidVal
  rw [u128Val_lt_iff]
  dsimp only
  split_ifs with h1 h2 h3 h4
  · simp only [true_iff]; left; exact h1
  · simp only [ok.injEq, show (1#i32 = (-1)#i32) ↔ False by decide, false_iff, not_or, not_and]
    constructor
    · exact fun h => by
        have : (Pion.I64.to_uint64 a.hi).val < (Pion.I64.to_uint64 b.hi).val := h
        have : (Pion.I64.to_uint64 b.hi).val < (Pion.I64.to_uint64 a.hi).val := h2
        omega
    · intro heq; rw [heq] at h2; exact absurd h2 (Nat.lt_irrefl _)
  · simp only [true_iff]; right
    have heq : Pion.I64.to_uint64 a.hi = Pion.I64.to_uint64 b.hi := by
      apply u64_ext
      have h1' : ¬ (Pion.I64.to_uint64 a.hi).val < (Pion.I64.to_uint64 b.hi).val := h1
      have h2' : ¬ (Pion.I64.to_uint64 b.hi).val < (Pion.I64.to_uint64 a.hi).val := h2
      omega
    exact ⟨heq, h3⟩
  · simp only [ok.injEq, show (1#i32 = (-1)#i32) ↔ False by decide, false_iff, not_or, not_and]
    exact ⟨h1, fun _ => h3⟩
  · simp only [ok.injEq, show (0#i32 = (-1)#i32) ↔ False by decide, false_iff, not_or, not_and]
    exact ⟨h1, fun _ => h3⟩

lemma uuid_compare_spec_gt (a b : Uuid) :
    Uuid.compare a b = ok 1#i32 ↔ uuidVal b < uuidVal a := by
  unfold Uuid.compare uuidVal
  rw [u128Val_lt_iff]
  dsimp only
  split_ifs with h1 h2 h3 h4
  · simp only [ok.injEq, show ((-1)#i32 = 1#i32) ↔ False by decide, false_iff, not_or, not_and]
    constructor
    · intro h
      have : (Pion.I64.to_uint64 a.hi).val < (Pion.I64.to_uint64 b.hi).val := h1
      have : (Pion.I64.to_uint64 b.hi).val < (Pion.I64.to_uint64 a.hi).val := h
      omega
    · intro heq; rw [heq] at h1; exact absurd h1 (Nat.lt_irrefl _)
  · simp only [true_iff]; left; exact h2
  · simp only [ok.injEq, show ((-1)#i32 = 1#i32) ↔ False by decide, false_iff, not_or, not_and]
    exact ⟨h2, fun _ => by
      intro h
      have : (Pion.I64.to_uint64 a.lo).val < (Pion.I64.to_uint64 b.lo).val := h3
      have : (Pion.I64.to_uint64 b.lo).val < (Pion.I64.to_uint64 a.lo).val := h
      omega⟩
  · simp only [true_iff]; right
    have heq : Pion.I64.to_uint64 b.hi = Pion.I64.to_uint64 a.hi := by
      apply u64_ext
      have h1' : ¬ (Pion.I64.to_uint64 a.hi).val < (Pion.I64.to_uint64 b.hi).val := h1
      have h2' : ¬ (Pion.I64.to_uint64 b.hi).val < (Pion.I64.to_uint64 a.hi).val := h2
      omega
    exact ⟨heq, h4⟩
  · simp only [ok.injEq, show (0#i32 = 1#i32) ↔ False by decide, false_iff, not_or, not_and]
    exact ⟨h2, fun _ => h4⟩

theorem uuid_compare_spec_eq (a b : Uuid) :
    Uuid.compare a b = ok 0#i32 ↔ a = b := by
  rw [← uuidVal_eq_iff]
  rcases uuid_compare_total a b with ⟨r, hr, hcases⟩
  rw [hr]
  constructor
  · intro h0
    have hr0 : r = 0#i32 := result_ok_inj h0
    subst hr0
    have hnotlt : ¬ uuidVal a < uuidVal b := by
      rw [← uuid_compare_spec_lt, hr]
      intro h; exact absurd (result_ok_inj h) (by decide)
    have hnotgt : ¬ uuidVal b < uuidVal a := by
      rw [← uuid_compare_spec_gt, hr]
      intro h; exact absurd (result_ok_inj h) (by decide)
    omega
  · intro heq
    rcases hcases with rfl | rfl | rfl
    · have := (uuid_compare_spec_lt a b).mp hr; omega
    · rfl
    · have := (uuid_compare_spec_gt a b).mp hr; omega

lemma ulid_compare_eq_uuid_compare (a b : Ulid) :
    Ulid.compare a b = Uuid.compare (Uuid.mk a.hi a.lo) (Uuid.mk b.hi b.lo) := rfl

lemma ulid_compare_spec_lt (a b : Ulid) :
    Ulid.compare a b = ok (-1)#i32 ↔ ulidVal a < ulidVal b :=
  uuid_compare_spec_lt (Uuid.mk a.hi a.lo) (Uuid.mk b.hi b.lo)

theorem uuid_nil_min (u : Uuid) :
    ∃ r : Std.I32, (do let n ← Uuid.nil; Uuid.compare n u) = ok r ∧ r.val ≤ 0 := by
  unfold Uuid.nil
  rw [b_ok]
  rcases uuid_compare_total (Uuid.mk 0#i64 0#i64) u with ⟨r, hr, hcases⟩
  refine ⟨r, hr, ?_⟩
  rcases hcases with rfl | rfl | rfl
  · decide
  · decide
  · exfalso
    have hgt := (uuid_compare_spec_gt (Uuid.mk 0#i64 0#i64) u).mp hr
    unfold uuidVal u128Val at hgt
    rw [u64_zero_val] at hgt
    omega

theorem uuid_max_max (u : Uuid) :
    ∃ r : Std.I32, (do let m ← Uuid.max; Uuid.compare u m) = ok r ∧ r.val ≤ 0 := by
  unfold Uuid.max
  rw [b_ok]
  rcases uuid_compare_total u (Uuid.mk (-1)#i64 (-1)#i64) with ⟨r, hr, hcases⟩
  refine ⟨r, hr, ?_⟩
  rcases hcases with rfl | rfl | rfl
  · decide
  · decide
  · exfalso
    have hgt := (uuid_compare_spec_gt u (Uuid.mk (-1)#i64 (-1)#i64)).mp hr
    unfold uuidVal u128Val at hgt
    rw [u64_max_val] at hgt
    have h1 := u64_val_lt (Pion.I64.to_uint64 u.hi)
    have h2 := u64_val_lt (Pion.I64.to_uint64 u.lo)
    omega

/-! ## 2. RFC 9562 UUID Version & Variant Bitfield Invariants -/

private theorem u64_shr_ok (x : Std.U64) (s : Std.U64) (n : Nat) (heq : s.val = n) (hn : n < 64) :
    Pion.U64.shr x s = ok ⟨x.bv >>> n⟩ := by
  unfold Pion.U64.shr
  rw [heq, ite_eq_left hn]

private theorem u64_shl_ok (x : Std.U64) (s : Std.U64) (n : Nat) (heq : s.val = n) (hn : n < 64) :
    Pion.U64.shl x s = ok ⟨x.bv <<< n⟩ := by
  unfold Pion.U64.shl
  rw [heq, ite_eq_left hn]

private theorem bv64_and_le_right (x y : BitVec 64) : (x &&& y).toNat ≤ y.toNat := by
  rw [BitVec.toNat_and]
  exact Nat.and_le_right

private theorem bv64_getElem_ofNat_lt (n i : Nat) (hi : i < 64) (hlt : n < 2 ^ i) :
    (BitVec.ofNat 64 n)[i] = false := by
  rw [BitVec.getElem_eq_testBit_toNat, BitVec.toNat_ofNat]
  have hlt2 : n < 2 ^ 64 := by
    have : 2 ^ i ≤ 2 ^ 64 := Nat.pow_le_pow_right (by omega) (by omega)
    omega
  rw [Nat.mod_eq_of_lt hlt2]
  exact Nat.testBit_eq_false_of_lt hlt

private theorem forall_nat_of_all {n : Nat} (f : Nat → Bool)
    (h : (List.range n).all f = true) : ∀ k : Nat, k < n → f k = true := by
  intro k hk
  exact List.all_eq_true.mp h k (List.mem_range.mpr hk)

private theorem mask_lo16_bit_true (i : Nat) (h : i < 16) : (65535#64)[i]'(by omega) = true := by
  have hall : (List.range 16).all (fun k => (65535#64).getLsbD k) = true := by decide
  have hk := forall_nat_of_all _ hall i h
  rwa [BitVec.getLsbD_eq_getElem (by omega)] at hk

private theorem mask_hi48_bit_false (i : Nat) (h : i < 16) :
    (18446744073709486080#64)[i]'(by omega) = false := by
  have hall : (List.range 16).all (fun k => !(18446744073709486080#64).getLsbD k) = true := by decide
  have hk := forall_nat_of_all _ hall i h
  simp only [Bool.not_eq_true'] at hk
  rwa [BitVec.getLsbD_eq_getElem (by omega)] at hk

private theorem v7_const_bit_false (i : Nat) (h : i < 12) :
    (28672#64)[i]'(by omega) = false := by
  have hall : (List.range 12).all (fun k => !(28672#64).getLsbD k) = true := by decide
  have hk := forall_nat_of_all _ hall i h
  simp only [Bool.not_eq_true'] at hk
  rwa [BitVec.getLsbD_eq_getElem (by omega)] at hk

/-- Bitvector lemma: masking bits 62..63 to `10` sets `top3 = (lo >>> 61) &&& 7` to `4` or `5`. -/
private theorem rfc4122_top3_range (lo : BitVec 64) :
    let nl : BitVec 64 := (lo &&& 4611686018427387903#64) ||| 9223372036854775808#64
    let top3 : BitVec 64 := (nl >>> 61) &&& 7#64
    top3 = 4#64 ∨ top3 = 5#64 := by
  intro nl top3
  by_cases h61 : lo[61] = true
  · right
    apply BitVec.eq_of_getElem_eq
    intro i hi
    simp only [top3, nl, BitVec.getElem_and, BitVec.getElem_ushiftRight, BitVec.getElem_or]
    match i with
    | 0 => simp [h61]
    | 1 => simp
    | 2 => simp
    | k + 3 =>
      have h7 : (7#64)[k + 3] = false := bv64_getElem_ofNat_lt 7 (k + 3) hi (by
        have : 2 ^ 3 ≤ 2 ^ (k + 3) := Nat.pow_le_pow_right (by omega) (by omega)
        omega)
      have h5 : (5#64)[k + 3] = false := bv64_getElem_ofNat_lt 5 (k + 3) hi (by
        have : 2 ^ 3 ≤ 2 ^ (k + 3) := Nat.pow_le_pow_right (by omega) (by omega)
        omega)
      simp [h7, h5]
  · left
    have h61f : lo[61] = false := by cases h : lo[61] <;> simp_all
    apply BitVec.eq_of_getElem_eq
    intro i hi
    simp only [top3, nl, BitVec.getElem_and, BitVec.getElem_ushiftRight, BitVec.getElem_or]
    match i with
    | 0 => simp [h61f]
    | 1 => simp
    | 2 => simp
    | k + 3 =>
      have h7 : (7#64)[k + 3] = false := bv64_getElem_ofNat_lt 7 (k + 3) hi (by
        have : 2 ^ 3 ≤ 2 ^ (k + 3) := Nat.pow_le_pow_right (by omega) (by omega)
        omega)
      have h4 : (4#64)[k + 3] = false := bv64_getElem_ofNat_lt 4 (k + 3) hi (by
        have : 2 ^ 3 ≤ 2 ^ (k + 3) := Nat.pow_le_pow_right (by omega) (by omega)
        omega)
      simp [h7, h4]

/-- Any `lo` with bits 63..62 = `10` is neither `0` nor `-1` (so `is_nil` and `is_max` are false). -/
private theorem rfc4122_lo_ne_zero (lo : BitVec 64) :
    ((lo &&& 4611686018427387903#64) ||| 9223372036854775808#64) ≠ 0#64 := by
  intro h
  have h63 := congrArg (fun v : BitVec 64 => v[63]) h
  simp at h63

private theorem rfc4122_lo_ne_allones (lo : BitVec 64) :
    ((lo &&& 4611686018427387903#64) ||| 9223372036854775808#64) ≠ (-1 : BitVec 64) := by
  intro h
  have h62 := congrArg (fun v : BitVec 64 => v[62]) h
  simp at h62

private theorem u64_to_i64_ne_zero_of_bv {x : Std.U64} (h : x.bv ≠ 0#64) :
    Pion.U64.to_int64 x ≠ 0#i64 := by
  intro heq
  apply h
  rw [← u64_to_i64_bv x, heq]
  rfl

private theorem u64_to_i64_ne_neg1_of_bv {x : Std.U64} (h : x.bv ≠ (-1 : BitVec 64)) :
    Pion.U64.to_int64 x ≠ (-1)#i64 := by
  intro heq
  apply h
  rw [← u64_to_i64_bv x, heq]
  decide

/-- Bitvector lemma: version nibble extracted from `set_version_and_variant` equals `ver &&& 15`. -/
private theorem set_version_extract_bv (hi ver : BitVec 64) :
    ((((hi &&& 18446744073709490175#64) ||| ((ver &&& 15#64) <<< 12)) >>> 12) &&& 15#64) =
      ver &&& 15#64 := by
  apply BitVec.eq_of_getElem_eq
  intro i hi_lt
  simp only [BitVec.getElem_and, BitVec.getElem_ushiftRight, BitVec.getElem_or,
             BitVec.getElem_shiftLeft]
  match i with
  | 0 => simp
  | 1 => simp
  | 2 => simp
  | 3 => simp
  | k + 4 =>
    have h15 : (15#64)[k + 4] = false := bv64_getElem_ofNat_lt 15 (k + 4) hi_lt (by
      have : 2 ^ 4 ≤ 2 ^ (k + 4) := Nat.pow_le_pow_right (by omega) (by omega)
      omega)
    simp [h15]

/-- Bitvector lemma: `((ts <<< 16) ||| 0x7000 ||| (ra &&& 0xFFF))` has version nibble `7`. -/
private theorem v7_version_extract_bv (ts ra : BitVec 64) :
    ((((ts <<< 16) ||| 28672#64 ||| (ra &&& 4095#64)) >>> 12) &&& 15#64) = 7#64 := by
  apply BitVec.eq_of_getElem_eq
  intro i hi_lt
  simp only [BitVec.getElem_and, BitVec.getElem_ushiftRight, BitVec.getElem_or,
             BitVec.getElem_shiftLeft]
  match i with
  | 0 => simp
  | 1 => simp
  | 2 => simp
  | 3 => simp
  | k + 4 =>
    have h15 : (15#64)[k + 4] = false := bv64_getElem_ofNat_lt 15 (k + 4) hi_lt (by
      have : 2 ^ 4 ≤ 2 ^ (k + 4) := Nat.pow_le_pow_right (by omega) (by omega)
      omega)
    have h7 : (7#64)[k + 4] = false := bv64_getElem_ofNat_lt 7 (k + 4) hi_lt (by
      have : 2 ^ 4 ≤ 2 ^ (k + 4) := Nat.pow_le_pow_right (by omega) (by omega)
      omega)
    simp [h15, h7]

/-- Bitvector lemma: `((ts <<< 16) ||| low16) >>> 16 = ts` when `ts.toNat < 2^48` and `low16.toNat < 2^16`. -/
private theorem hi48_pack_unpack_bv (ts low16 : BitVec 64)
    (hts : ts.toNat < 2 ^ 48) (hlow : low16.toNat < 2 ^ 16) :
    (((ts <<< 16) ||| low16) >>> 16) = ts := by
  apply BitVec.eq_of_getElem_eq
  intro i hi_lt
  simp only [BitVec.getElem_ushiftRight, BitVec.getElem_or, BitVec.getElem_shiftLeft]
  by_cases hlt : 16 + i < 64
  · have hlow_bit : low16[16 + i] = false := by
      rw [BitVec.getElem_eq_testBit_toNat]
      apply Nat.testBit_eq_false_of_lt
      have : 2 ^ 16 ≤ 2 ^ (16 + i) := Nat.pow_le_pow_right (by omega) (by omega)
      omega
    have hlow_lsb : low16.getLsbD (16 + i) = false := by
      rw [BitVec.getLsbD_eq_getElem hlt]; exact hlow_bit
    have hts_eq : ts.getLsbD i = ts[i] := BitVec.getLsbD_eq_getElem hi_lt
    simp [hlt, hlow_bit, hlow_lsb, hts_eq]
  · have hts_bit : ts[i] = false := by
      rw [BitVec.getElem_eq_testBit_toNat]
      apply Nat.testBit_eq_false_of_lt
      have : 2 ^ 48 ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) (by omega)
      omega
    have hlow_oob : low16.getLsbD (16 + i) = false :=
      BitVec.getLsbD_of_ge low16 (16 + i) (by omega)
    simp [hlt, hts_bit, hlow_oob]

/-- Helper: `((ts <<< 16) ||| low16).toNat = ts.toNat * 2^16 + low16.toNat` when `ts < 2^48, low16 < 2^16`. -/
private theorem hi48_pack_toNat (ts low16 : BitVec 64)
    (hts : ts.toNat < 2 ^ 48) (hlow : low16.toNat < 2 ^ 16) :
    ((ts <<< 16) ||| low16).toNat = ts.toNat * 2 ^ 16 + low16.toNat := by
  have hdisj : (ts <<< 16) &&& low16 = 0#64 := by
    apply BitVec.eq_of_getElem_eq
    intro i hi_lt
    simp only [BitVec.getElem_and, BitVec.getElem_shiftLeft, BitVec.getElem_zero]
    by_cases h16 : i < 16
    · simp [h16]
    · have hlow_bit : low16[i] = false := by
        rw [BitVec.getElem_eq_testBit_toNat]
        apply Nat.testBit_eq_false_of_lt
        have : 2 ^ 16 ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) (by omega)
        omega
      simp [hlow_bit]
  have hor_eq_add : (ts <<< 16) ||| low16 = (ts <<< 16) + low16 :=
    (BitVec.add_eq_or_of_and_eq_zero (ts <<< 16) low16 hdisj).symm
  rw [hor_eq_add, BitVec.toNat_add, BitVec.toNat_shiftLeft]
  have h1 : ts.toNat <<< 16 = ts.toNat * 2 ^ 16 := Nat.shiftLeft_eq _ _
  rw [h1]
  have hmod1 : ts.toNat * 2 ^ 16 % 2 ^ 64 = ts.toNat * 2 ^ 16 :=
    Nat.mod_eq_of_lt (by omega)
  rw [hmod1]
  exact Nat.mod_eq_of_lt (by omega)

/-- For ANY `hi, lo, ver : U64`, `set_version_and_variant` ALWAYS produces variant `Rfc4122`. -/
theorem set_version_and_variant_variant (hi lo ver : Std.U64) :
    (do let u ← set_version_and_variant hi lo ver; Uuid.variant u) = ok UuidVariant.Rfc4122 := by
  unfold set_version_and_variant Uuid.variant
  rw [u64_shl_ok _ 12#u64 12 (by decide) (by decide), b_ok]
  dsimp only
  rw [b_ok]
  simp only [u64_to_i64_to_u64]
  rw [u64_shr_ok _ 61#u64 61 (by decide) (by decide), b_ok]
  have htop := rfc4122_top3_range lo.bv
  rcases htop with h4 | h5
  · have hu : Pion.U64.band ⟨(Pion.U64.bor (Pion.U64.band lo 4611686018427387903#u64) 9223372036854775808#u64).bv >>> 61⟩ 7#u64 = 4#u64 :=
      u64_ext_bv h4
    rw [hu]; rfl
  · have hu : Pion.U64.band ⟨(Pion.U64.bor (Pion.U64.band lo 4611686018427387903#u64) 9223372036854775808#u64).bv >>> 61⟩ 7#u64 = 5#u64 :=
      u64_ext_bv h5
    rw [hu]; rfl

/-- For ANY `hi, lo, ver : U64`, `set_version_and_variant` sets `version_num` to `ver & 0xF`. -/
theorem set_version_and_variant_version_num (hi lo ver : Std.U64) :
    (do let u ← set_version_and_variant hi lo ver; Uuid.version_num u) =
      ok (Pion.U64.to_int (Pion.U64.band ver 15#u64)) := by
  unfold set_version_and_variant Uuid.version_num
  rw [u64_shl_ok _ 12#u64 12 (by decide) (by decide), b_ok]
  dsimp only
  rw [b_ok]
  simp only [u64_to_i64_to_u64]
  rw [u64_shr_ok _ 12#u64 12 (by decide) (by decide), b_ok]
  congr 2
  apply u64_ext_bv
  exact set_version_extract_bv hi.bv ver.bv

private theorem set_version_and_variant_not_nil (hi lo ver : Std.U64) :
    (do let u ← set_version_and_variant hi lo ver; Uuid.is_nil u) = ok false := by
  unfold set_version_and_variant Uuid.is_nil
  rw [u64_shl_ok _ 12#u64 12 (by decide) (by decide), b_ok]
  dsimp only
  rw [b_ok]
  simp only [ok.injEq, Bool.and_eq_false_iff, beq_eq_false_iff_ne]
  right
  exact u64_to_i64_ne_zero_of_bv (rfc4122_lo_ne_zero lo.bv)

private theorem set_version_and_variant_not_max (hi lo ver : Std.U64) :
    (do let u ← set_version_and_variant hi lo ver; Uuid.is_max u) = ok false := by
  unfold set_version_and_variant Uuid.is_max
  rw [u64_shl_ok _ 12#u64 12 (by decide) (by decide), b_ok]
  dsimp only
  rw [b_ok]
  simp only [ok.injEq, Bool.and_eq_false_iff, beq_eq_false_iff_ne]
  right
  exact u64_to_i64_ne_neg1_of_bv (rfc4122_lo_ne_allones lo.bv)

private theorem set_version_and_variant_version_aux (hi lo v : Std.U64) (ev : UuidVersion) (vi : Std.I32)
    (hvi : Pion.U64.to_int (Pion.U64.band v 15#u64) = vi)
    (hev : (if vi = 1#i32 then UuidVersion.Mac
            else if vi = 2#i32 then UuidVersion.Dce
            else if vi = 3#i32 then UuidVersion.Md5
            else if vi = 4#i32 then UuidVersion.Random
            else if vi = 5#i32 then UuidVersion.Sha1
            else if vi = 6#i32 then UuidVersion.SortMac
            else if vi = 7#i32 then UuidVersion.SortRand
            else if vi = 8#i32 then UuidVersion.Custom
            else UuidVersion.Unknown vi) = ev) :
    (do let u ← set_version_and_variant hi lo v; Uuid.version u) = ok ev := by
  have hok : ∃ u, set_version_and_variant hi lo v = ok u := by
    unfold set_version_and_variant
    rw [u64_shl_ok _ 12#u64 12 (by decide) (by decide), b_ok]
    exact ⟨_, rfl⟩
  rcases hok with ⟨u, hu⟩
  rw [hu, b_ok]
  unfold Uuid.version
  have hnil := set_version_and_variant_not_nil hi lo v
  rw [hu, b_ok] at hnil
  have hmax := set_version_and_variant_not_max hi lo v
  rw [hu, b_ok] at hmax
  have hvnum := set_version_and_variant_version_num hi lo v
  rw [hu, b_ok, hvi] at hvnum
  rw [hnil, b_ok, ite_eq_right (by decide), hmax, b_ok, ite_eq_right (by decide), hvnum, b_ok, hev]

/-- RFC 9562 v3/v5/v8 tagging via `set_version_and_variant` always yields `Rfc4122` and the exact expected version. -/
lemma set_version_and_variant_v3_v5_v8 (hi lo : Std.U64) :
    (do let u ← set_version_and_variant hi lo 3#u64; Uuid.version u) = ok UuidVersion.Md5 ∧
    (do let u ← set_version_and_variant hi lo 5#u64; Uuid.version u) = ok UuidVersion.Sha1 ∧
    (do let u ← set_version_and_variant hi lo 8#u64; Uuid.version u) = ok UuidVersion.Custom :=
  ⟨set_version_and_variant_version_aux hi lo 3#u64 .Md5 3#i32 (by decide) (by simp),
   set_version_and_variant_version_aux hi lo 5#u64 .Sha1 5#i32 (by decide) (by simp),
   set_version_and_variant_version_aux hi lo 8#u64 .Custom 8#i32 (by decide) (by simp)⟩

/-- `Uuid.new_v8` on any 16-byte payload succeeds and yields `Rfc4122` variant and `Custom` (v8) version. -/
theorem new_v8_spec (custom : Pion.Bytes) (hlen : custom.val.length = 16) :
    ∃ u : Uuid,
      Uuid.new_v8 custom = ok (.Ok u) ∧
      Uuid.variant u = ok UuidVariant.Rfc4122 ∧
      Uuid.version u = ok UuidVersion.Custom := by
  have hfb : ∃ u0, Uuid.from_bytes custom = ok (.Ok u0) := by
    unfold Uuid.from_bytes Pion.Bytes.length Pion.lengthOf
    simp only [hlen, show (16 : Nat) ≤ 2147483647 by omega, ↓reduceDIte]
    rw [b_ok]
    have h16 : (Std.I32.ofIntCore (16 : Nat) ⟨by simp [IScalarTy.numBits], by simp [IScalarTy.numBits]⟩) = 16#i32 := by decide
    rw [h16, ite_eq_right (by decide)]
    have hget : ∀ (k : Std.I32), 0 ≤ k.val → k.val < 16 → ∃ b, Pion.Bytes.get custom k = ok b := by
      intro k hk0 hk1
      unfold Pion.Bytes.get Pion.listGet
      have hinb : Pion.inBounds k custom.val.length := by
        unfold Pion.inBounds; rw [hlen]; exact ⟨hk0, hk1⟩
      rw [dif_pos hinb]
      exact ⟨_, rfl⟩
    rcases hget 0#i32 (by decide) (by decide) with ⟨b0, hb0⟩
    rcases hget 1#i32 (by decide) (by decide) with ⟨b1, hb1⟩
    rcases hget 2#i32 (by decide) (by decide) with ⟨b2, hb2⟩
    rcases hget 3#i32 (by decide) (by decide) with ⟨b3, hb3⟩
    rcases hget 4#i32 (by decide) (by decide) with ⟨b4, hb4⟩
    rcases hget 5#i32 (by decide) (by decide) with ⟨b5, hb5⟩
    rcases hget 6#i32 (by decide) (by decide) with ⟨b6, hb6⟩
    rcases hget 7#i32 (by decide) (by decide) with ⟨b7, hb7⟩
    rcases hget 8#i32 (by decide) (by decide) with ⟨b8, hb8⟩
    rcases hget 9#i32 (by decide) (by decide) with ⟨b9, hb9⟩
    rcases hget 10#i32 (by decide) (by decide) with ⟨b10, hb10⟩
    rcases hget 11#i32 (by decide) (by decide) with ⟨b11, hb11⟩
    rcases hget 12#i32 (by decide) (by decide) with ⟨b12, hb12⟩
    rcases hget 13#i32 (by decide) (by decide) with ⟨b13, hb13⟩
    rcases hget 14#i32 (by decide) (by decide) with ⟨b14, hb14⟩
    rcases hget 15#i32 (by decide) (by decide) with ⟨b15, hb15⟩
    simp only [hb0, hb1, hb2, hb3, hb4, hb5, hb6, hb7,
               hb8, hb9, hb10, hb11, hb12, hb13, hb14, hb15, b_ok,
               u64_shl_ok _ 56#u64 56 (by decide) (by decide),
               u64_shl_ok _ 48#u64 48 (by decide) (by decide),
               u64_shl_ok _ 40#u64 40 (by decide) (by decide),
               u64_shl_ok _ 32#u64 32 (by decide) (by decide),
               u64_shl_ok _ 24#u64 24 (by decide) (by decide),
               u64_shl_ok _ 16#u64 16 (by decide) (by decide),
               u64_shl_ok _ 8#u64 8 (by decide) (by decide)]
    exact ⟨_, rfl⟩
  rcases hfb with ⟨u0, hu0⟩
  have hok : ∃ u, set_version_and_variant (Pion.I64.to_uint64 u0.hi) (Pion.I64.to_uint64 u0.lo) 8#u64 = ok u := by
    unfold set_version_and_variant; rw [u64_shl_ok _ 12#u64 12 (by decide) (by decide), b_ok]; exact ⟨_, rfl⟩
  rcases hok with ⟨u, hu⟩
  refine ⟨u, ?_, ?_, ?_⟩
  · unfold Uuid.new_v8
    rw [hu0, b_ok]
    dsimp only
    rw [hu, b_ok]
  · have hv := set_version_and_variant_variant (Pion.I64.to_uint64 u0.hi) (Pion.I64.to_uint64 u0.lo) 8#u64
    rw [hu, b_ok] at hv; exact hv
  · have hv := (set_version_and_variant_v3_v5_v8 (Pion.I64.to_uint64 u0.hi) (Pion.I64.to_uint64 u0.lo)).2.2
    rw [hu, b_ok] at hv; exact hv

/-- `Uuid.new_v7_from_parts` succeeds for every valid 48-bit timestamp `0 ≤ ts_ms ≤ 2^48 - 1` and ALL random payloads,
    preserving `variant = Rfc4122`, `version = SortRand` (7), and exact `timestamp_ms = some ts_ms`. -/
theorem new_v7_from_parts_spec (ts_ms : Std.I64) (rand_a : Std.I32) (rand_b : Std.I64)
    (h0 : 0 ≤ ts_ms.val) (h1 : ts_ms.val ≤ 281474976710655) :
    ∃ u : Uuid,
      Uuid.new_v7_from_parts ts_ms rand_a rand_b = ok (.Ok u) ∧
      Uuid.variant u = ok UuidVariant.Rfc4122 ∧
      Uuid.version u = ok UuidVersion.SortRand ∧
      Uuid.timestamp_ms u = ok (some ts_ms) := by
  have hcond : ((decide (ts_ms < 0#i64)) || (decide (ts_ms > 281474976710655#i64))) = false := by
    have hlt : ¬ ts_ms < 0#i64 := by change ¬ ts_ms.val < 0; omega
    have hgt : ¬ ts_ms > 281474976710655#i64 := by change ¬ ts_ms.val > 281474976710655; omega
    rw [decide_eq_false hlt, decide_eq_false hgt]; rfl
  set hi_u : Std.U64 :=
    Pion.U64.bor (Pion.U64.bor ⟨(Pion.I64.to_uint64 ts_ms).bv <<< 16⟩ 28672#u64)
      (Pion.U64.band (Pion.I64.to_uint64 (Pion.I32.to_int64 rand_a)) 4095#u64)
  set lo_u : Std.U64 :=
    Pion.U64.bor (Pion.U64.band (Pion.I64.to_uint64 rand_b) 4611686018427387903#u64) 9223372036854775808#u64
  set u : Uuid := Uuid.mk (Pion.U64.to_int64 hi_u) (Pion.U64.to_int64 lo_u)
  have hnew : Uuid.new_v7_from_parts ts_ms rand_a rand_b = ok (.Ok u) := by
    unfold Uuid.new_v7_from_parts
    rw [hcond, ite_eq_right (by decide), u64_shl_ok _ 16#u64 16 (by decide) (by decide), b_ok]
  have hvar : Uuid.variant u = ok UuidVariant.Rfc4122 := by
    unfold Uuid.variant
    simp only [u, u64_to_i64_to_u64, lo_u]
    rw [u64_shr_ok _ 61#u64 61 (by decide) (by decide), b_ok]
    have htop := rfc4122_top3_range (Pion.I64.to_uint64 rand_b).bv
    rcases htop with h4 | h5
    · have hu : Pion.U64.band ⟨(Pion.U64.bor (Pion.U64.band (Pion.I64.to_uint64 rand_b) 4611686018427387903#u64) 9223372036854775808#u64).bv >>> 61⟩ 7#u64 = 4#u64 :=
        u64_ext_bv h4
      rw [hu]; rfl
    · have hu : Pion.U64.band ⟨(Pion.U64.bor (Pion.U64.band (Pion.I64.to_uint64 rand_b) 4611686018427387903#u64) 9223372036854775808#u64).bv >>> 61⟩ 7#u64 = 5#u64 :=
        u64_ext_bv h5
      rw [hu]; rfl
  have hnotnil : Uuid.is_nil u = ok false := by
    unfold Uuid.is_nil
    simp only [u, ok.injEq, Bool.and_eq_false_iff, beq_eq_false_iff_ne]
    right
    exact u64_to_i64_ne_zero_of_bv (rfc4122_lo_ne_zero (Pion.I64.to_uint64 rand_b).bv)
  have hnotmax : Uuid.is_max u = ok false := by
    unfold Uuid.is_max
    simp only [u, ok.injEq, Bool.and_eq_false_iff, beq_eq_false_iff_ne]
    right
    exact u64_to_i64_ne_neg1_of_bv (rfc4122_lo_ne_allones (Pion.I64.to_uint64 rand_b).bv)
  have hvnum : Uuid.version_num u = ok 7#i32 := by
    unfold Uuid.version_num
    simp only [u, u64_to_i64_to_u64, hi_u]
    rw [u64_shr_ok _ 12#u64 12 (by decide) (by decide), b_ok]
    have h7 : Pion.U64.band ⟨(Pion.U64.bor (Pion.U64.bor ⟨(Pion.I64.to_uint64 ts_ms).bv <<< 16⟩ 28672#u64) (Pion.U64.band (Pion.I64.to_uint64 (Pion.I32.to_int64 rand_a)) 4095#u64)).bv >>> 12⟩ 15#u64 = 7#u64 :=
      u64_ext_bv (v7_version_extract_bv (Pion.I64.to_uint64 ts_ms).bv (Pion.I64.to_uint64 (Pion.I32.to_int64 rand_a)).bv)
    rw [h7]; rfl
  have hver : Uuid.version u = ok UuidVersion.SortRand := by
    unfold Uuid.version
    rw [hnotnil, b_ok, ite_eq_right (by decide), hnotmax, b_ok, ite_eq_right (by decide), hvnum, b_ok]
    simp
  have hts_eq : Uuid.timestamp_ms u = ok (some ts_ms) := by
    unfold Uuid.timestamp_ms
    rw [hver, b_ok]
    simp only [u, u64_to_i64_to_u64, hi_u]
    rw [u64_shr_ok _ 16#u64 16 (by decide) (by decide), b_ok]
    congr 2
    apply i64_ext_bv
    rw [u64_to_i64_bv]
    have hts_u : (Pion.I64.to_uint64 ts_ms).val < 2 ^ 48 := by
      have hv := i64_nonneg_to_u64_val h0
      omega
    have hlow_lt : (28672#64 ||| ((Pion.I64.to_uint64 (Pion.I32.to_int64 rand_a)).bv &&& 4095#64)).toNat < 2 ^ 16 := by
      have hdisj : (28672#64 : BitVec 64) &&& ((Pion.I64.to_uint64 (Pion.I32.to_int64 rand_a)).bv &&& 4095#64) = 0#64 := by
        apply BitVec.eq_of_getElem_eq
        intro i hi_lt
        simp only [BitVec.getElem_and, BitVec.getElem_zero]
        by_cases h12 : i < 12
        · simp [v7_const_bit_false i h12]
        · have hb : (4095#64)[i] = false := bv64_getElem_ofNat_lt 4095 i hi_lt (by
            have : 2 ^ 12 ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) (by omega)
            omega)
          simp [hb]
      rw [(BitVec.add_eq_or_of_and_eq_zero _ _ hdisj).symm, BitVec.toNat_add]
      have hle := bv64_and_le_right (Pion.I64.to_uint64 (Pion.I32.to_int64 rand_a)).bv 4095#64
      have h28672 : (28672#64 : BitVec 64).toNat = 28672 := by decide
      have h4095 : (4095#64 : BitVec 64).toNat = 4095 := by decide
      rw [Nat.mod_eq_of_lt (by omega)]
      omega
    have hassoc : (((Pion.I64.to_uint64 ts_ms).bv <<< 16) ||| 28672#64) |||
        ((Pion.I64.to_uint64 (Pion.I32.to_int64 rand_a)).bv &&& 4095#64) =
        ((Pion.I64.to_uint64 ts_ms).bv <<< 16) |||
        (28672#64 ||| ((Pion.I64.to_uint64 (Pion.I32.to_int64 rand_a)).bv &&& 4095#64)) :=
      BitVec.or_assoc _ _ _
    change ((((Pion.I64.to_uint64 ts_ms).bv <<< 16) ||| 28672#64) |||
        ((Pion.I64.to_uint64 (Pion.I32.to_int64 rand_a)).bv &&& 4095#64)) >>> 16 = ts_ms.bv
    rw [hassoc, hi48_pack_unpack_bv _ _ hts_u hlow_lt]
    exact i64_to_u64_bv ts_ms
  exact ⟨u, hnew, hvar, hver, hts_eq⟩

/-- **UUIDv7 Strict Time-Order Monotonicity**: for any `0 ≤ ts1 < ts2 < 2^48` and ANY random payloads,
    `Uuid.compare (v7 ts1 ...) (v7 ts2 ...) = ok (-1)`. -/
theorem new_v7_from_parts_strict_monotonic
    (ts1 ts2 : Std.I64) (ra1 ra2 : Std.I32) (rb1 rb2 : Std.I64) (u1 u2 : Uuid)
    (h0 : 0 ≤ ts1.val) (hlt : ts1.val < ts2.val) (hmax : ts2.val ≤ 281474976710655)
    (hu1 : Uuid.new_v7_from_parts ts1 ra1 rb1 = ok (.Ok u1))
    (hu2 : Uuid.new_v7_from_parts ts2 ra2 rb2 = ok (.Ok u2)) :
    Uuid.compare u1 u2 = ok (-1)#i32 := by
  rcases new_v7_from_parts_spec ts1 ra1 rb1 h0 (by omega) with ⟨u1', hu1', _, hver1, hts1_ext⟩
  rcases new_v7_from_parts_spec ts2 ra2 rb2 (by omega) hmax with ⟨u2', hu2', _, hver2, hts2_ext⟩
  have heq1 : u1 = u1' := res_ok_inj (result_ok_inj (hu1.symm.trans hu1'))
  have heq2 : u2 = u2' := res_ok_inj (result_ok_inj (hu2.symm.trans hu2'))
  subst heq1; subst heq2
  rw [uuid_compare_spec_lt]
  unfold uuidVal
  rw [u128Val_lt_iff]
  left
  have extract_div : ∀ (u : Uuid) (ts : Std.I64),
      Uuid.version u = ok UuidVersion.SortRand →
      Uuid.timestamp_ms u = ok (some ts) →
      (Pion.I64.to_uint64 u.hi).val / 2 ^ 16 = (Pion.I64.to_uint64 ts).val := by
    intro u ts hver hts
    unfold Uuid.timestamp_ms at hts
    rw [hver, b_ok] at hts
    dsimp only at hts
    rw [u64_shr_ok _ 16#u64 16 (by decide) (by decide), b_ok] at hts
    have hts' : Pion.U64.to_int64 ⟨(Pion.I64.to_uint64 u.hi).bv >>> 16⟩ = ts :=
      Option.some.inj (result_ok_inj hts)
    have hbv : (Pion.I64.to_uint64 u.hi).bv >>> 16 = (Pion.I64.to_uint64 ts).bv := by
      rw [← hts', u64_to_i64_to_u64]
    have hnat := congrArg BitVec.toNat hbv
    rw [BitVec.toNat_ushiftRight] at hnat
    simpa [UScalar.val, Nat.shiftRight_eq_div_pow] using hnat
  have h1 := extract_div u1 ts1 hver1 hts1_ext
  have h2 := extract_div u2 ts2 hver2 hts2_ext
  have hts1_val := i64_nonneg_to_u64_val h0
  have hts2_val := i64_nonneg_to_u64_val (by omega : 0 ≤ ts2.val)
  change (Pion.I64.to_uint64 u1.hi).val < (Pion.I64.to_uint64 u2.hi).val
  omega

/-! ## 3. ULID 48-bit Timestamp + 80-bit Random Bijection, Monotonicity & Increment -/

/-- `Ulid.from_parts` roundtrips `timestamp_ms` and `random_parts` for all `0 ≤ ts_ms ≤ 2^48 - 1`. -/
theorem ulid_from_parts_roundtrip (ts_ms rand_hi rand_lo : Std.I64)
    (h0 : 0 ≤ ts_ms.val) (h1 : ts_ms.val ≤ 281474976710655) :
    ∃ u : Ulid,
      Ulid.from_parts ts_ms rand_hi rand_lo = ok (.Ok u) ∧
      Ulid.timestamp_ms u = ok ts_ms ∧
      Ulid.random_parts u = ok (Pion.U64.to_int64 (Pion.U64.band (Pion.I64.to_uint64 rand_hi) 65535#u64), rand_lo) := by
  have hcond : ((decide (ts_ms < 0#i64)) || (decide (ts_ms > 281474976710655#i64))) = false := by
    have hlt : ¬ ts_ms < 0#i64 := by change ¬ ts_ms.val < 0; omega
    have hgt : ¬ ts_ms > 281474976710655#i64 := by change ¬ ts_ms.val > 281474976710655; omega
    rw [decide_eq_false hlt, decide_eq_false hgt]; rfl
  set hi_u : Std.U64 :=
    Pion.U64.bor ⟨(Pion.I64.to_uint64 ts_ms).bv <<< 16⟩ (Pion.U64.band (Pion.I64.to_uint64 rand_hi) 65535#u64)
  set u : Ulid := Ulid.mk (Pion.U64.to_int64 hi_u) rand_lo
  refine ⟨u, ?_, ?_, ?_⟩
  · unfold Ulid.from_parts
    rw [hcond, ite_eq_right (by decide), u64_shl_ok _ 16#u64 16 (by decide) (by decide), b_ok]
  · unfold Ulid.timestamp_ms
    simp only [u, u64_to_i64_to_u64, hi_u]
    rw [u64_shr_ok _ 16#u64 16 (by decide) (by decide), b_ok]
    congr 1
    apply i64_ext_bv
    rw [u64_to_i64_bv]
    have hts_u : (Pion.I64.to_uint64 ts_ms).val < 2 ^ 48 := by
      have hv := i64_nonneg_to_u64_val h0
      omega
    have hlow_lt : ((Pion.I64.to_uint64 rand_hi).bv &&& 65535#64).toNat < 2 ^ 16 := by
      have hle := bv64_and_le_right (Pion.I64.to_uint64 rand_hi).bv 65535#64
      have : (65535#64 : BitVec 64).toNat = 65535 := by decide
      omega
    change (((Pion.I64.to_uint64 ts_ms).bv <<< 16) ||| ((Pion.I64.to_uint64 rand_hi).bv &&& 65535#64)) >>> 16 = ts_ms.bv
    rw [hi48_pack_unpack_bv _ _ hts_u hlow_lt]
    exact i64_to_u64_bv ts_ms
  · unfold Ulid.random_parts
    simp only [u, u64_to_i64_to_u64, hi_u, ok.injEq, Prod.mk.injEq, and_true]
    congr 1
    apply u64_ext_bv
    apply BitVec.eq_of_getElem_eq
    intro i hi_lt
    simp only [Pion.U64.band, Pion.U64.bor, BitVec.getElem_and, BitVec.getElem_or, BitVec.getElem_shiftLeft]
    by_cases h16 : i < 16
    · simp [h16]
    · have hb : (65535#64)[i] = false := bv64_getElem_ofNat_lt 65535 i hi_lt (by
        have : 2 ^ 16 ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) (by omega)
        omega)
      simp [hb]

/-- **ULID Bijection**: decomposing ANY `Ulid` into `(timestamp_ms, random_parts)` and passing back to
    `Ulid.from_parts` reconstructs the exact original `Ulid`. -/
theorem ulid_parts_bijection (u : Ulid) :
    (do
      let ts ← Ulid.timestamp_ms u
      let (rhi, rlo) ← Ulid.random_parts u
      Ulid.from_parts ts rhi rlo) = ok (.Ok u) := by
  unfold Ulid.timestamp_ms Ulid.random_parts Ulid.from_parts
  rw [u64_shr_ok _ 16#u64 16 (by decide) (by decide), b_ok, b_ok, b_ok]
  set ts_u : Std.U64 := ⟨(Pion.I64.to_uint64 u.hi).bv >>> 16⟩
  have hts_lt : ts_u.val < 2 ^ 48 := by
    change ((Pion.I64.to_uint64 u.hi).bv >>> 16).toNat < 2 ^ 48
    rw [BitVec.toNat_ushiftRight, Nat.shiftRight_eq_div_pow]
    have hlt := u64_val_lt (Pion.I64.to_uint64 u.hi)
    omega
  have hts_i : (Pion.U64.to_int64 ts_u).val = (ts_u.val : Int) :=
    u64_lt_2p63_to_i64_val (by omega)
  have hcond : ((decide (Pion.U64.to_int64 ts_u < 0#i64)) || (decide (Pion.U64.to_int64 ts_u > 281474976710655#i64))) = false := by
    have h1 : ¬ Pion.U64.to_int64 ts_u < 0#i64 := by change ¬ (Pion.U64.to_int64 ts_u).val < 0; omega
    have h2 : ¬ Pion.U64.to_int64 ts_u > 281474976710655#i64 := by change ¬ (Pion.U64.to_int64 ts_u).val > 281474976710655; omega
    rw [decide_eq_false h1, decide_eq_false h2]; rfl
  change (if ((decide (Pion.U64.to_int64 ts_u < 0#i64)) || (decide (Pion.U64.to_int64 ts_u > 281474976710655#i64))) = true then
      ok (Pion.Res.Err (UlidError.InvalidTimestamp (Pion.U64.to_int64 ts_u)))
    else do
      let __t ← Pion.U64.shl (Pion.I64.to_uint64 (Pion.U64.to_int64 ts_u)) 16#u64
      let hi := Pion.U64.bor __t (Pion.U64.band (Pion.I64.to_uint64 (Pion.U64.to_int64 (Pion.U64.band (Pion.I64.to_uint64 u.hi) 65535#u64))) 65535#u64)
      ok (Pion.Res.Ok (Ulid.mk (Pion.U64.to_int64 hi) u.lo))) = ok (.Ok u)
  rw [hcond, ite_eq_right (by decide), u64_to_i64_to_u64, u64_shl_ok _ 16#u64 16 (by decide) (by decide), b_ok, u64_to_i64_to_u64]
  change ok (Pion.Res.Ok (Ulid.mk (Pion.U64.to_int64 (Pion.U64.bor ⟨ts_u.bv <<< 16⟩ (Pion.U64.band (Pion.U64.band (Pion.I64.to_uint64 u.hi) 65535#u64) 65535#u64))) u.lo)) = ok (.Ok u)
  congr 2
  cases u with | mk uhi ulo =>
  congr 1
  apply i64_ext_bv
  rw [u64_to_i64_bv]
  apply BitVec.eq_of_getElem_eq
  intro i hi_lt
  simp only [ts_u, Pion.U64.band, Pion.U64.bor, BitVec.getElem_or, BitVec.getElem_shiftLeft,
             BitVec.getElem_ushiftRight, BitVec.getElem_and, i64_to_u64_bv]
  by_cases h16 : i < 16
  · simp [h16, mask_lo16_bit_true i h16]
  · have hsub : 16 + (i - 16) = i := by omega
    have hb : (65535#64)[i] = false := bv64_getElem_ofNat_lt 65535 i hi_lt (by
      have : 2 ^ 16 ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) (by omega)
      omega)
    have hlsb : uhi.bv.getLsbD i = uhi.bv[i] := BitVec.getLsbD_eq_getElem hi_lt
    simp [h16, hi_lt, hsub, hb, hlsb]

/-- **ULID Strict Time-Order Monotonicity**: for any `0 ≤ ts1 < ts2 < 2^48` and ANY random payloads,
    `Ulid.compare u1 u2 = ok (-1)`. -/
theorem ulid_from_parts_strict_monotonic
    (ts1 ts2 rh1 rl1 rh2 rl2 : Std.I64) (u1 u2 : Ulid)
    (h0 : 0 ≤ ts1.val) (hlt : ts1.val < ts2.val) (hmax : ts2.val ≤ 281474976710655)
    (hu1 : Ulid.from_parts ts1 rh1 rl1 = ok (.Ok u1))
    (hu2 : Ulid.from_parts ts2 rh2 rl2 = ok (.Ok u2)) :
    Ulid.compare u1 u2 = ok (-1)#i32 := by
  rcases ulid_from_parts_roundtrip ts1 rh1 rl1 h0 (by omega) with ⟨u1', hu1', hts1, _⟩
  rcases ulid_from_parts_roundtrip ts2 rh2 rl2 (by omega) hmax with ⟨u2', hu2', hts2, _⟩
  have heq1 : u1 = u1' := res_ok_inj (result_ok_inj (hu1.symm.trans hu1'))
  have heq2 : u2 = u2' := res_ok_inj (result_ok_inj (hu2.symm.trans hu2'))
  subst heq1; subst heq2
  rw [ulid_compare_spec_lt]
  unfold ulidVal
  rw [u128Val_lt_iff]
  left
  have extract_div : ∀ (u : Ulid) (ts : Std.I64),
      Ulid.timestamp_ms u = ok ts →
      (Pion.I64.to_uint64 u.hi).val / 2 ^ 16 = (Pion.I64.to_uint64 ts).val := by
    intro u ts hts
    unfold Ulid.timestamp_ms at hts
    rw [u64_shr_ok _ 16#u64 16 (by decide) (by decide), b_ok] at hts
    have hts' : Pion.U64.to_int64 ⟨(Pion.I64.to_uint64 u.hi).bv >>> 16⟩ = ts := result_ok_inj hts
    have hbv : (Pion.I64.to_uint64 u.hi).bv >>> 16 = (Pion.I64.to_uint64 ts).bv := by
      rw [← hts', u64_to_i64_to_u64]
    have hnat := congrArg BitVec.toNat hbv
    rw [BitVec.toNat_ushiftRight] at hnat
    simpa [UScalar.val, Nat.shiftRight_eq_div_pow] using hnat
  have h1 := extract_div u1 ts1 hts1
  have h2 := extract_div u2 ts2 hts2
  have hts1_val := i64_nonneg_to_u64_val h0
  have hts2_val := i64_nonneg_to_u64_val (by omega : 0 ≤ ts2.val)
  change (Pion.I64.to_uint64 u1.hi).val < (Pion.I64.to_uint64 u2.hi).val
  omega

/-- **ULID Monotonic Increment**: when the 80-bit random payload is not saturated, `Ulid.increment`
    succeeds with `ulidVal u' = ulidVal u + 1`, preserves `timestamp_ms`, and satisfies `compare u u' = -1`. -/
theorem ulid_increment_ok (u : Ulid)
    (hnot_sat : Pion.I64.to_uint64 u.lo ≠ 18446744073709551615#u64 ∨
                Pion.U64.band (Pion.I64.to_uint64 u.hi) 65535#u64 ≠ 65535#u64) :
    ∃ u' : Ulid,
      Ulid.increment u = ok (.Ok u') ∧
      ulidVal u' = ulidVal u + 1 ∧
      Ulid.timestamp_ms u' = Ulid.timestamp_ms u ∧
      Ulid.compare u u' = ok (-1)#i32 := by
  unfold Ulid.increment
  dsimp only
  by_cases hlo : Pion.I64.to_uint64 u.lo = 18446744073709551615#u64
  · have hrhi : Pion.U64.band (Pion.I64.to_uint64 u.hi) 65535#u64 ≠ 65535#u64 := by
      rcases hnot_sat with h | h
      · exact absurd hlo h
      · exact h
    rw [ite_eq_left hlo, ite_eq_right hrhi]
    set hi := Pion.I64.to_uint64 u.hi
    set rhi := Pion.U64.band hi 65535#u64
    set next_hi := Pion.U64.bor (Pion.U64.band hi 18446744073709486080#u64) (Pion.U64.add rhi 1#u64)
    set u' := Ulid.mk (Pion.U64.to_int64 next_hi) 0#i64
    have hrhi_lt : rhi.val < 65535 := by
      have hle : rhi.val ≤ 65535 := by
        change (hi.bv &&& 65535#64).toNat ≤ 65535
        have h1 := bv64_and_le_right hi.bv 65535#64
        have h65535 : (65535#64 : BitVec 64).toNat = 65535 := by decide
        omega
      have hne : rhi.val ≠ 65535 := fun heq => hrhi (u64_ext heq)
      omega
    have hmod : rhi.val = hi.val % 2 ^ 16 := by
      change (hi.bv &&& 65535#64).toNat = hi.bv.toNat % 2 ^ 16
      have hmask : (hi.bv &&& 65535#64) = BitVec.ofNat 64 (hi.bv.toNat % 2 ^ 16) := by
        apply BitVec.eq_of_getElem_eq
        intro i hi_lt
        rw [BitVec.getElem_and, BitVec.getElem_eq_testBit_toNat (x := BitVec.ofNat 64 (hi.bv.toNat % 2 ^ 16)), BitVec.toNat_ofNat]
        have hlt2 : hi.bv.toNat % 2 ^ 16 < 2 ^ 64 := by
          have := Nat.mod_lt hi.bv.toNat (show 0 < 2 ^ 16 by decide)
          omega
        rw [Nat.mod_eq_of_lt hlt2, Nat.testBit_mod_two_pow]
        by_cases h16 : i < 16
        · simp [h16, mask_lo16_bit_true i h16, BitVec.getElem_eq_testBit_toNat]
        · have hb : (65535#64)[i] = false := bv64_getElem_ofNat_lt 65535 i hi_lt (by
            have : 2 ^ 16 ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) (by omega)
            omega)
          simp [h16, hb]
      rw [hmask, BitVec.toNat_ofNat]
      exact Nat.mod_eq_of_lt (by have := Nat.mod_lt hi.bv.toNat (show 0 < 2 ^ 16 by decide); omega)
    have hhi_decomp : hi.val = (hi.val / 2 ^ 16) * 2 ^ 16 + rhi.val := by omega
    have hnext_hi_val : next_hi.val = hi.val + 1 := by
      have htop_eq : (Pion.U64.band hi 18446744073709486080#u64).bv = (hi.bv >>> 16) <<< 16 := by
        apply BitVec.eq_of_getElem_eq
        intro i hi_lt
        simp only [Pion.U64.band, BitVec.getElem_and, BitVec.getElem_shiftLeft, BitVec.getElem_ushiftRight]
        by_cases h16 : i < 16
        · simp [h16, mask_hi48_bit_false i h16]
        · have hsub : 16 + (i - 16) = i := by omega
          have hb : (18446744073709486080#64)[i] = true := by
            have hinv : (18446744073709486080#64 : BitVec 64) = ~~~(65535#64 : BitVec 64) := by decide
            rw [hinv, BitVec.getElem_not]
            have h0 : (65535#64)[i] = false := bv64_getElem_ofNat_lt 65535 i hi_lt (by
              have : 2 ^ 16 ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) (by omega)
              omega)
            simp [h0]
          have hlsb : hi.bv.getLsbD i = hi.bv[i] := BitVec.getLsbD_eq_getElem hi_lt
          simp [h16, hi_lt, hsub, hb, hlsb]
      have hadd_val : (Pion.U64.add rhi 1#u64).bv.toNat = rhi.val + 1 := by
        change (rhi.bv + 1#64).toNat = rhi.bv.toNat + 1
        rw [BitVec.toNat_add]
        have h1 : (1#64 : BitVec 64).toNat = 1 := by decide
        rw [h1]
        have hrhi_bv : rhi.bv.toNat < 65535 := hrhi_lt
        exact Nat.mod_eq_of_lt (by omega)
      have hts_lt : (hi.bv >>> 16).toNat < 2 ^ 48 := by
        rw [BitVec.toNat_ushiftRight, Nat.shiftRight_eq_div_pow]
        have := hi.bv.isLt; omega
      have hadd_lt : (Pion.U64.add rhi 1#u64).bv.toNat < 2 ^ 16 := by omega
      have hpack := hi48_pack_toNat (hi.bv >>> 16) (Pion.U64.add rhi 1#u64).bv hts_lt hadd_lt
      change next_hi.bv.toNat = hi.val + 1
      have hnbv : next_hi.bv = ((hi.bv >>> 16) <<< 16) ||| (Pion.U64.add rhi 1#u64).bv := by
        change (Pion.U64.band hi 18446744073709486080#u64).bv ||| (Pion.U64.add rhi 1#u64).bv = _
        rw [htop_eq]
      rw [hnbv, hpack, hadd_val, BitVec.toNat_ushiftRight, Nat.shiftRight_eq_div_pow]
      change hi.val / 2 ^ 16 * 2 ^ 16 + (rhi.val + 1) = hi.val + 1
      omega
    have hval : ulidVal u' = ulidVal u + 1 := by
      unfold ulidVal u128Val
      simp only [u', u64_to_i64_to_u64, u64_zero_val]
      have hlo_val : (Pion.I64.to_uint64 u.lo).val = 2 ^ 64 - 1 := by rw [hlo]; decide
      change next_hi.val * 2 ^ 64 + 0 = hi.val * 2 ^ 64 + (Pion.I64.to_uint64 u.lo).val + 1
      rw [hnext_hi_val, hlo_val]
      omega
    have hts : Ulid.timestamp_ms u' = Ulid.timestamp_ms u := by
      unfold Ulid.timestamp_ms
      simp only [u', u64_to_i64_to_u64]
      rw [u64_shr_ok _ 16#u64 16 (by decide) (by decide), u64_shr_ok _ 16#u64 16 (by decide) (by decide), b_ok, b_ok]
      congr 1
      apply i64_ext_bv
      rw [u64_to_i64_bv, u64_to_i64_bv]
      apply BitVec.eq_of_toNat_eq
      rw [BitVec.toNat_ushiftRight, BitVec.toNat_ushiftRight,
          Nat.shiftRight_eq_div_pow, Nat.shiftRight_eq_div_pow]
      change next_hi.val / 2 ^ 16 = hi.val / 2 ^ 16
      omega
    refine ⟨u', rfl, hval, hts, ?_⟩
    rw [ulid_compare_spec_lt, hval]
    omega
  · rw [ite_eq_right hlo]
    set lo := Pion.I64.to_uint64 u.lo
    set u' := Ulid.mk u.hi (Pion.U64.to_int64 (Pion.U64.add lo 1#u64))
    have hlo_lt : lo.val < 2 ^ 64 - 1 := by
      have hlt := u64_val_lt lo
      have hne : lo.val ≠ 2 ^ 64 - 1 := fun heq => hlo (u64_ext (by simpa using heq))
      omega
    have hlo_add : (Pion.U64.add lo 1#u64).val = lo.val + 1 := by
      change (lo.bv + 1#64).toNat = lo.bv.toNat + 1
      rw [BitVec.toNat_add]
      have h1 : (1#64 : BitVec 64).toNat = 1 := by decide
      rw [h1]
      have hlo_bv : lo.bv.toNat < 2 ^ 64 - 1 := hlo_lt
      exact Nat.mod_eq_of_lt (by omega)
    have hval : ulidVal u' = ulidVal u + 1 := by
      unfold ulidVal u128Val
      simp only [u', u64_to_i64_to_u64]
      change (Pion.I64.to_uint64 u.hi).val * 2 ^ 64 + (Pion.U64.add lo 1#u64).val =
             (Pion.I64.to_uint64 u.hi).val * 2 ^ 64 + lo.val + 1
      rw [hlo_add]
      omega
    refine ⟨u', rfl, hval, rfl, ?_⟩
    rw [ulid_compare_spec_lt, hval]
    omega

/-! ## 4. Hex & Crockford Base32 Single-Character Codecs -/

private def i32OfNat (n : Nat) : Std.I32 := ⟨BitVec.ofNat 32 n⟩

private def resI32IsOkEq (r : Result Std.I32) (expected : Std.I32) : Bool :=
  r.reducesTo expected

private theorem resI32IsOkEq_eq_ok {r : Result Std.I32} {e : Std.I32}
    (h : resI32IsOkEq r e = true) : r = ok e := by
  unfold resI32IsOkEq Result.reducesTo at h
  cases hm : r.match with
  | ok v =>
    rw [hm] at h
    simp only [beq_iff_eq] at h
    rw [h] at hm
    exact Result.match.isOk.mp hm
  | vis _ _ => rw [hm] at h; cases h
  | div => rw [hm] at h; cases h

private def resI32Eq (r1 r2 : Result Std.I32) : Bool :=
  match r1.match, r2.match with
  | .ok v1, .ok v2 => v1 == v2
  | _, _ => false

private theorem resI32Eq_eq {r1 r2 : Result Std.I32} (h : resI32Eq r1 r2 = true) : r1 = r2 := by
  unfold resI32Eq at h
  cases hm1 : r1.match <;> cases hm2 : r2.match <;> rw [hm1, hm2] at h
  · simp only [beq_iff_eq] at h
    have h1 := Result.match.isOk.mp hm1
    have h2 := Result.match.isOk.mp hm2
    rw [h1, h2, h]
  all_goals cases h

private theorem i32_eq_i32OfNat (d : Std.I32) (h0 : 0 ≤ d.val) (h1 : d.val < 256) :
    d = i32OfNat d.val.toNat := by
  apply i32_ext_val
  unfold i32OfNat
  change d.val = (BitVec.ofNat 32 d.val.toNat).toInt
  have hlt : 2 * (BitVec.ofNat 32 d.val.toNat).toNat < 2 ^ 32 := by
    rw [BitVec.toNat_ofNat]
    have : d.val.toNat % 2 ^ 32 = d.val.toNat := Nat.mod_eq_of_lt (by omega)
    omega
  rw [BitVec.toInt_eq_toNat_of_lt hlt, BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)]
  omega

/-- Lowercase hex encode → decode roundtrip for all 4-bit nibbles `0..15`. -/
theorem hex_lower_roundtrip (d : Std.I32) (h0 : 0 ≤ d.val) (h1 : d.val < 16) :
    (do let b ← hex_char_lower d; hex_val_char (Pion.U8.to_int b)) = ok d := by
  have hall : ∀ k : Nat, k < 16 →
      (do let b ← hex_char_lower (i32OfNat k); hex_val_char (Pion.U8.to_int b)) =
        ok (i32OfNat k) := by
    intro k hk
    match k with
    | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 =>
      unfold hex_char_lower Pion.I32.shr
      rw [ite_eq_left (by decide), b_ok, b_ok]
      rfl
    | _ + 16 => omega
  rw [i32_eq_i32OfNat d h0 (by omega)]
  exact hall d.val.toNat (by omega)

/-- `hex_val_char` always succeeds and returns either a valid nibble `0..15` or `-1`. -/
theorem hex_val_char_range (c : Std.I32) :
    ∃ v : Std.I32, hex_val_char c = ok v ∧ ((0 ≤ v.val ∧ v.val < 16) ∨ v = (-1)#i32) := by
  unfold hex_val_char
  split_ifs with h1 h2 h3
  · simp only [Bool.and_eq_true, decide_eq_true_eq] at h1
    have hall : ∀ k : Fin 10,
        0 ≤ (Pion.I32.sub (i32OfNat (48 + k.val)) 48#i32).val ∧
        (Pion.I32.sub (i32OfNat (48 + k.val)) 48#i32).val < 16 := by decide
    refine ⟨Pion.I32.sub c 48#i32, rfl, Or.inl ?_⟩
    have hc0 : 48 ≤ c.val := h1.1
    have hc1 : c.val ≤ 57 := h1.2
    rw [i32_eq_i32OfNat c (by omega) (by omega)]
    have heq : c.val.toNat = 48 + (c.val.toNat - 48) := by omega
    rw [heq]
    exact hall ⟨c.val.toNat - 48, by omega⟩
  · simp only [Bool.and_eq_true, decide_eq_true_eq] at h2
    have hall : ∀ k : Fin 6,
        0 ≤ (Pion.I32.sub (i32OfNat (65 + k.val)) 55#i32).val ∧
        (Pion.I32.sub (i32OfNat (65 + k.val)) 55#i32).val < 16 := by decide
    refine ⟨Pion.I32.sub c 55#i32, rfl, Or.inl ?_⟩
    have hc0 : 65 ≤ c.val := h2.1
    have hc1 : c.val ≤ 70 := h2.2
    rw [i32_eq_i32OfNat c (by omega) (by omega)]
    have heq : c.val.toNat = 65 + (c.val.toNat - 65) := by omega
    rw [heq]
    exact hall ⟨c.val.toNat - 65, by omega⟩
  · simp only [Bool.and_eq_true, decide_eq_true_eq] at h3
    have hall : ∀ k : Fin 6,
        0 ≤ (Pion.I32.sub (i32OfNat (97 + k.val)) 87#i32).val ∧
        (Pion.I32.sub (i32OfNat (97 + k.val)) 87#i32).val < 16 := by decide
    refine ⟨Pion.I32.sub c 87#i32, rfl, Or.inl ?_⟩
    have hc0 : 97 ≤ c.val := h3.1
    have hc1 : c.val ≤ 102 := h3.2
    rw [i32_eq_i32OfNat c (by omega) (by omega)]
    have heq : c.val.toNat = 97 + (c.val.toNat - 97) := by omega
    rw [heq]
    exact hall ⟨c.val.toNat - 97, by omega⟩
  · exact ⟨(-1)#i32, rfl, Or.inr rfl⟩

end UuidProofs
