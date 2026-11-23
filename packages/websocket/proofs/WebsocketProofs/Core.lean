import Aeneas
import PionLean
import Websocket.Types
import Websocket.Funs

open Aeneas Aeneas.Std Result Pion websocket

namespace WebsocketProofs

lemma iscalar_le_iff {ty : IScalarTy} (a b : IScalar ty) : a ≤ b ↔ a.val ≤ b.val := Iff.rfl
lemma iscalar_lt_iff {ty : IScalarTy} (a b : IScalar ty) : a < b ↔ a.val < b.val := Iff.rfl
lemma iscalar_eq_iff {ty : IScalarTy} (a b : IScalar ty) : a = b ↔ a.val = b.val := by
  constructor
  · intro h; subst h; rfl
  · intro h; cases a; cases b; congr; exact BitVec.eq_of_toInt_eq h

lemma result_ok_inj {α : Type} {a b : α} (h : (ok a : Result α) = ok b) : a = b := by
  simpa using h

lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by
  simp

lemma i64_val_of_int (n : Int) (hlo : -(2 ^ 63 : Int) ≤ n) (hhi : n < 2 ^ 63) :
    (BitVec.ofInt 64 n).toInt = n := by
  rw [BitVec.toInt_ofInt]
  have hpow : (2 : Int) ^ 64 = 18446744073709551616 := by norm_num
  have hhalf : (2 : Int) ^ 63 = 9223372036854775808 := by norm_num
  rw [Int.bmod_eq_of_le] <;> omega

lemma i64_bounds (x : Std.I64) :
    -(9223372036854775808 : Int) ≤ x.val ∧ x.val ≤ 9223372036854775807 := by
  have h1 := x.hBounds
  have hpow : (2 : Int) ^ (IScalarTy.I64.numBits - 1) = 9223372036854775808 := by
    change (2 : Int) ^ (64 - 1) = 9223372036854775808; norm_num
  omega

lemma i32_bounds (x : Std.I32) :
    -(2147483648 : Int) ≤ x.val ∧ x.val ≤ 2147483647 := by
  have h1 := x.hBounds
  have hpow : (2 : Int) ^ (IScalarTy.I32.numBits - 1) = 2147483648 := by
    change (2 : Int) ^ (32 - 1) = 2147483648; norm_num
  omega

lemma i32_to_int64_val (x : Std.I32) :
    (Pion.I32.to_int64 x).val = x.val := by
  unfold Pion.I32.to_int64
  have hb := i32_bounds x
  change (BitVec.ofInt 64 x.val).toInt = x.val
  exact i64_val_of_int x.val (by omega) (by omega)

lemma i32_add_val (a b : Std.I32)
    (hlo : -(2147483648 : Int) ≤ a.val + b.val)
    (hhi : a.val + b.val ≤ 2147483647) :
    (Pion.I32.add a b).val = a.val + b.val := by
  unfold Pion.I32.add
  change (a.bv + b.bv).toInt = a.val + b.val
  rw [BitVec.toInt_add]
  change (a.val + b.val).bmod (2 ^ 32) = a.val + b.val
  rw [Int.bmod_eq_of_le] <;> norm_num <;> omega

lemma i32_sub_val (a b : Std.I32)
    (hlo : -(2147483648 : Int) ≤ a.val - b.val)
    (hhi : a.val - b.val ≤ 2147483647) :
    (Pion.I32.sub a b).val = a.val - b.val := by
  unfold Pion.I32.sub
  change (a.bv - b.bv).toInt = a.val - b.val
  rw [BitVec.toInt_sub]
  change (a.val - b.val).bmod (2 ^ 32) = a.val - b.val
  rw [Int.bmod_eq_of_le] <;> norm_num <;> omega

lemma i32_mul_val (a b : Std.I32)
    (hlo : -(2147483648 : Int) ≤ a.val * b.val)
    (hhi : a.val * b.val ≤ 2147483647) :
    (Pion.I32.mul a b).val = a.val * b.val := by
  unfold Pion.I32.mul
  change (a.bv * b.bv).toInt = a.val * b.val
  rw [BitVec.toInt_mul]
  change (a.val * b.val).bmod (2 ^ 32) = a.val * b.val
  rw [Int.bmod_eq_of_le] <;> norm_num <;> omega

lemma i64_add_val (a b : Std.I64)
    (hlo : -(9223372036854775808 : Int) ≤ a.val + b.val)
    (hhi : a.val + b.val ≤ 9223372036854775807) :
    (Pion.I64.add a b).val = a.val + b.val := by
  unfold Pion.I64.add
  change (a.bv + b.bv).toInt = a.val + b.val
  rw [BitVec.toInt_add]
  change (a.val + b.val).bmod (2 ^ 64) = a.val + b.val
  have hpow : (2 : Int) ^ 64 = 18446744073709551616 := by norm_num
  rw [Int.bmod_eq_of_le] <;> omega

lemma i64_to_int_val (x : Std.I64)
    (hlo : -(2147483648 : Int) ≤ x.val)
    (hhi : x.val ≤ 2147483647) :
    (Pion.I64.to_int x).val = x.val := by
  unfold Pion.I64.to_int
  change (BitVec.ofInt 32 x.val).toInt = x.val
  rw [BitVec.toInt_ofInt, Int.bmod_eq_of_le] <;> norm_num <;> omega

lemma i32_max_i64_val : (2147483647#i64).val = 2147483647 := by
  change (BitVec.ofInt 64 2147483647).toInt = 2147483647
  rw [BitVec.toInt_ofInt]; norm_num

lemma u16_max_plus_1_i64_val : (65536#i64).val = 65536 := by
  change (BitVec.ofInt 64 65536).toInt = 65536
  rw [BitVec.toInt_ofInt]; norm_num

end WebsocketProofs
