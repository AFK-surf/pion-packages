import Aeneas
import PionLean
import Bson.Types
import Bson.Funs

open Aeneas Aeneas.Std Result Pion bson

namespace BsonProofs

private lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by simp

private lemma i32_le_iff (x y : Std.I32) : (x ≤ y) ↔ (x.val ≤ y.val) := Iff.rfl

private lemma i32_beq_iff (x y : Std.I32) : (x == y) = true ↔ x.val = y.val := by
  constructor
  · intro h
    have hbv : x.bv = y.bv := by
      change (x.bv == y.bv) = true at h
      exact eq_of_beq h
    exact congrArg BitVec.toInt hbv
  · intro h
    have hbv : x.bv = y.bv := BitVec.eq_of_toInt_eq h
    change (x.bv == y.bv) = true
    rw [hbv, beq_self_eq_true]

private lemma i32_val_neg1 : ((-1)#i32 : Std.I32).val = -1 := by
  change (BitVec.ofInt 32 (-1)).toInt = -1
  rw [BitVec.toInt_ofInt, Int.bmod_def]; omega

private lemma i32_add_val (x y : Std.I32)
    (hlo : -2147483648 ≤ x.val + y.val) (hhi : x.val + y.val ≤ 2147483647) :
    (Pion.I32.add x y).val = x.val + y.val := by
  change (x.bv + y.bv).toInt = x.bv.toInt + y.bv.toInt
  rw [BitVec.toInt_add, Int.bmod_def]
  change -2147483648 ≤ x.bv.toInt + y.bv.toInt at hlo
  change x.bv.toInt + y.bv.toInt ≤ 2147483647 at hhi
  omega

private lemma i32_sub_val (x y : Std.I32)
    (hlo : -2147483648 ≤ x.val - y.val) (hhi : x.val - y.val ≤ 2147483647) :
    (Pion.I32.sub x y).val = x.val - y.val := by
  change (x.bv - y.bv).toInt = x.bv.toInt - y.bv.toInt
  rw [BitVec.toInt_sub, Int.bmod_def]
  change -2147483648 ≤ x.bv.toInt - y.bv.toInt at hlo
  change x.bv.toInt - y.bv.toInt ≤ 2147483647 at hhi
  omega

private lemma i32_band_255_bounds (x : Std.I32) :
    0 ≤ (Pion.I32.band x 255#i32).val ∧ (Pion.I32.band x 255#i32).val ≤ 255 := by
  change 0 ≤ (x.bv &&& (255#32)).toInt ∧ (x.bv &&& (255#32)).toInt ≤ 255
  have hnat : (x.bv &&& (255#32)).toNat < 256 := by
    have : (x.bv &&& (255#32)).toNat = x.bv.toNat % 256 := by
      rw [BitVec.toNat_and]
      have h255 : (255#32 : BitVec 32).toNat = 2 ^ 8 - 1 := by decide
      rw [h255, Nat.and_two_pow_sub_one_eq_mod]
    omega
  rw [BitVec.toInt_eq_toNat_cond]
  split_ifs <;> omega

private lemma i32_band_255_eq_self (x : Std.I32) (h0 : 0 ≤ x.val) (h255 : x.val ≤ 255) :
    Pion.I32.band x 255#i32 = x := by
  apply IScalar.eq_of_val_eq
  change (x.bv &&& (255#32)).toInt = x.bv.toInt
  have hxnat : x.bv.toNat < 256 := by
    change 0 ≤ x.bv.toInt at h0
    change x.bv.toInt ≤ 255 at h255
    rw [BitVec.toInt_eq_toNat_cond] at h0 h255
    split_ifs at h0 h255 <;> omega
  have hand : (x.bv &&& (255#32)).toNat = x.bv.toNat := by
    rw [BitVec.toNat_and]
    have h255' : (255#32 : BitVec 32).toNat = 2 ^ 8 - 1 := by decide
    rw [h255', Nat.and_two_pow_sub_one_eq_mod]
    exact Nat.mod_eq_of_lt hxnat
  rw [BitVec.toInt_eq_toNat_cond, BitVec.toInt_eq_toNat_cond, hand]

/-- Theorem 1: Full 256-byte wire roundtrip `from_byte b >>= to_byte = ok b` for all `0 ≤ b ≤ 255`. -/
theorem binary_subtype_to_from_byte_roundtrip (b : Std.I32) (h0 : 0 ≤ b.val) (h255 : b.val ≤ 255) :
    (do let s ← BinarySubtype.from_byte b; BinarySubtype.to_byte s) = ok b := by
  unfold BinarySubtype.from_byte
  have hb : Pion.I32.band b 255#i32 = b := i32_band_255_eq_self b h0 h255
  rw [hb, result_bind_ok]
  by_cases c0 : b = 0#i32
  · subst c0; simp only [↓reduceIte]; rfl
  simp only [c0, ↓reduceIte]
  by_cases c1 : b = 1#i32
  · subst c1; simp only [↓reduceIte]; rfl
  simp only [c1, ↓reduceIte]
  by_cases c2 : b = 2#i32
  · subst c2; simp only [↓reduceIte]; rfl
  simp only [c2, ↓reduceIte]
  by_cases c3 : b = 3#i32
  · subst c3; simp only [↓reduceIte]; rfl
  simp only [c3, ↓reduceIte]
  by_cases c4 : b = 4#i32
  · subst c4; simp only [↓reduceIte]; rfl
  simp only [c4, ↓reduceIte]
  by_cases c5 : b = 5#i32
  · subst c5; simp only [↓reduceIte]; rfl
  simp only [c5, ↓reduceIte]
  by_cases c6 : b = 6#i32
  · subst c6; simp only [↓reduceIte]; rfl
  simp only [c6, ↓reduceIte]
  by_cases c7 : b = 7#i32
  · subst c7; simp only [↓reduceIte]; rfl
  simp only [c7, ↓reduceIte]
  by_cases c8 : b = 8#i32
  · subst c8; simp only [↓reduceIte]; rfl
  simp only [c8, ↓reduceIte]
  by_cases c9 : b = 9#i32
  · subst c9; simp only [↓reduceIte]; rfl
  simp only [c9, ↓reduceIte]
  by_cases c128 : b >= 128#i32
  · simp only [c128, ↓reduceIte]; unfold BinarySubtype.to_byte; dsimp only; rw [hb]
  · simp only [c128, ↓reduceIte]; unfold BinarySubtype.to_byte; dsimp only; rw [hb]

private lemma ne_of_val_gt {b k : Std.I32} (h : k.val < b.val) : b ≠ k :=
  fun heq => by rw [heq] at h; omega

/-- Helper: `BinarySubtype.from_byte` maps `0x0A..0x7F` to `Reserved` and `0x80..0xFF` to `UserDefined`. -/
private lemma binary_subtype_from_byte_ranges (b : Std.I32) (h0 : 0 ≤ b.val) (h255 : b.val ≤ 255) :
    (10 ≤ b.val ∧ b.val ≤ 127 → BinarySubtype.from_byte b = ok (BinarySubtype.Reserved b)) ∧
    (128 ≤ b.val ∧ b.val ≤ 255 → BinarySubtype.from_byte b = ok (BinarySubtype.UserDefined b)) := by
  have hb : Pion.I32.band b 255#i32 = b := i32_band_255_eq_self b h0 h255
  constructor
  · rintro ⟨hlo, hhi⟩
    unfold BinarySubtype.from_byte
    rw [hb]
    have n0 : b ≠ 0#i32 := ne_of_val_gt (by change (0 : Int) < b.val; omega)
    have n1 : b ≠ 1#i32 := ne_of_val_gt (by change (1 : Int) < b.val; omega)
    have n2 : b ≠ 2#i32 := ne_of_val_gt (by change (2 : Int) < b.val; omega)
    have n3 : b ≠ 3#i32 := ne_of_val_gt (by change (3 : Int) < b.val; omega)
    have n4 : b ≠ 4#i32 := ne_of_val_gt (by change (4 : Int) < b.val; omega)
    have n5 : b ≠ 5#i32 := ne_of_val_gt (by change (5 : Int) < b.val; omega)
    have n6 : b ≠ 6#i32 := ne_of_val_gt (by change (6 : Int) < b.val; omega)
    have n7 : b ≠ 7#i32 := ne_of_val_gt (by change (7 : Int) < b.val; omega)
    have n8 : b ≠ 8#i32 := ne_of_val_gt (by change (8 : Int) < b.val; omega)
    have n9 : b ≠ 9#i32 := ne_of_val_gt (by change (9 : Int) < b.val; omega)
    have n128 : ¬ (b >= 128#i32) := fun h => by
      have hc := (i32_le_iff 128#i32 b).mp h; change 128 ≤ b.val at hc; omega
    simp only [n0, n1, n2, n3, n4, n5, n6, n7, n8, n9, n128, ↓reduceIte]
  · rintro ⟨hlo, _⟩
    unfold BinarySubtype.from_byte
    rw [hb]
    have n0 : b ≠ 0#i32 := ne_of_val_gt (by change (0 : Int) < b.val; omega)
    have n1 : b ≠ 1#i32 := ne_of_val_gt (by change (1 : Int) < b.val; omega)
    have n2 : b ≠ 2#i32 := ne_of_val_gt (by change (2 : Int) < b.val; omega)
    have n3 : b ≠ 3#i32 := ne_of_val_gt (by change (3 : Int) < b.val; omega)
    have n4 : b ≠ 4#i32 := ne_of_val_gt (by change (4 : Int) < b.val; omega)
    have n5 : b ≠ 5#i32 := ne_of_val_gt (by change (5 : Int) < b.val; omega)
    have n6 : b ≠ 6#i32 := ne_of_val_gt (by change (6 : Int) < b.val; omega)
    have n7 : b ≠ 7#i32 := ne_of_val_gt (by change (7 : Int) < b.val; omega)
    have n8 : b ≠ 8#i32 := ne_of_val_gt (by change (8 : Int) < b.val; omega)
    have n9 : b ≠ 9#i32 := ne_of_val_gt (by change (9 : Int) < b.val; omega)
    have y128 : b >= 128#i32 := (i32_le_iff 128#i32 b).mpr (by change 128 ≤ b.val; omega)
    simp only [n0, n1, n2, n3, n4, n5, n6, n7, n8, n9, y128, ↓reduceIte]

/-- Canonical predicate for `BinarySubtype` (Reserved ∈ [10, 127], UserDefined ∈ [128, 255]). -/
def isCanonicalSubtype : BinarySubtype → Prop
  | .Reserved v => 10 ≤ v.val ∧ v.val ≤ 127
  | .UserDefined v => 128 ≤ v.val ∧ v.val ≤ 255
  | _ => True

/-- Theorem 3: `to_byte s >>= from_byte = ok s` for every canonical `BinarySubtype` (full wire bijection). -/
theorem binary_subtype_from_to_byte_canonical (s : BinarySubtype) (hcan : isCanonicalSubtype s) :
    (do let b ← BinarySubtype.to_byte s; BinarySubtype.from_byte b) = ok s := by
  cases s with
  | Generic => unfold BinarySubtype.to_byte BinarySubtype.from_byte; rw [result_bind_ok]; rfl
  | Function => unfold BinarySubtype.to_byte BinarySubtype.from_byte; rw [result_bind_ok]; rfl
  | BinaryOld => unfold BinarySubtype.to_byte BinarySubtype.from_byte; rw [result_bind_ok]; rfl
  | UuidOld => unfold BinarySubtype.to_byte BinarySubtype.from_byte; rw [result_bind_ok]; rfl
  | Uuid => unfold BinarySubtype.to_byte BinarySubtype.from_byte; rw [result_bind_ok]; rfl
  | Md5 => unfold BinarySubtype.to_byte BinarySubtype.from_byte; rw [result_bind_ok]; rfl
  | Encrypted => unfold BinarySubtype.to_byte BinarySubtype.from_byte; rw [result_bind_ok]; rfl
  | Column => unfold BinarySubtype.to_byte BinarySubtype.from_byte; rw [result_bind_ok]; rfl
  | Sensitive => unfold BinarySubtype.to_byte BinarySubtype.from_byte; rw [result_bind_ok]; rfl
  | Vector => unfold BinarySubtype.to_byte BinarySubtype.from_byte; rw [result_bind_ok]; rfl
  | Reserved v =>
    obtain ⟨hlo, hhi⟩ := hcan
    unfold BinarySubtype.to_byte
    dsimp only
    rw [i32_band_255_eq_self v (by omega) (by omega), result_bind_ok]
    exact (binary_subtype_from_byte_ranges v (by omega) (by omega)).1 ⟨hlo, hhi⟩
  | UserDefined v =>
    obtain ⟨hlo, hhi⟩ := hcan
    unfold BinarySubtype.to_byte
    dsimp only
    rw [i32_band_255_eq_self v (by omega) (by omega), result_bind_ok]
    exact (binary_subtype_from_byte_ranges v (by omega) (by omega)).2 ⟨hlo, hhi⟩

/-- Theorem 10: `oid_hex_val` always returns either `-1` (invalid) or a nibble in `[0, 15]`. -/
theorem oid_hex_val_bounds (c : Std.I32) :
    ∃ r : Std.I32, oid_hex_val c = ok r ∧ (r.val = -1 ∨ (0 ≤ r.val ∧ r.val ≤ 15)) := by
  unfold oid_hex_val
  by_cases h1 : ((decide (c >= 48#i32)) && (decide (c <= 57#i32))) = true
  · simp only [h1, ↓reduceIte]
    simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff] at h1
    change 48 ≤ c.val ∧ c.val ≤ 57 at h1
    have hsub : (Pion.I32.sub c 48#i32).val = c.val - 48 :=
      i32_sub_val c 48#i32 (by change -2147483648 ≤ c.val - 48; omega) (by change c.val - 48 ≤ 2147483647; omega)
    exact ⟨Pion.I32.sub c 48#i32, rfl, Or.inr ⟨by omega, by omega⟩⟩
  · have h1f := Bool.eq_false_iff.mpr h1
    simp only [h1f, Bool.false_eq_true, ↓reduceIte]
    by_cases h2 : ((decide (c >= 97#i32)) && (decide (c <= 102#i32))) = true
    · simp only [h2, ↓reduceIte]
      simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff] at h2
      change 97 ≤ c.val ∧ c.val ≤ 102 at h2
      have hsub : (Pion.I32.sub c 87#i32).val = c.val - 87 :=
        i32_sub_val c 87#i32 (by change -2147483648 ≤ c.val - 87; omega) (by change c.val - 87 ≤ 2147483647; omega)
      exact ⟨Pion.I32.sub c 87#i32, rfl, Or.inr ⟨by omega, by omega⟩⟩
    · have h2f := Bool.eq_false_iff.mpr h2
      simp only [h2f, Bool.false_eq_true, ↓reduceIte]
      by_cases h3 : ((decide (c >= 65#i32)) && (decide (c <= 70#i32))) = true
      · simp only [h3, ↓reduceIte]
        simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff] at h3
        change 65 ≤ c.val ∧ c.val ≤ 70 at h3
        have hsub : (Pion.I32.sub c 55#i32).val = c.val - 55 :=
          i32_sub_val c 55#i32 (by change -2147483648 ≤ c.val - 55; omega) (by change c.val - 55 ≤ 2147483647; omega)
        exact ⟨Pion.I32.sub c 55#i32, rfl, Or.inr ⟨by omega, by omega⟩⟩
      · have h3f := Bool.eq_false_iff.mpr h3
        simp only [h3f, Bool.false_eq_true, ↓reduceIte]
        exact ⟨(-1)#i32, rfl, Or.inl i32_val_neg1⟩

end BsonProofs
