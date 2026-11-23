import Aeneas
import PionLean
import Http1.Types
import Http1.Funs

open Aeneas Aeneas.Std Result Pion http1

namespace Http1Proofs

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

lemma max_div10_val : (922337203685477580#i64).val = 922337203685477580 := by
  change (BitVec.ofInt 64 922337203685477580).toInt = 922337203685477580
  rw [BitVec.toInt_ofInt]; norm_num

lemma max_div16_val : (576460752303423487#i64).val = 576460752303423487 := by
  change (BitVec.ofInt 64 576460752303423487).toInt = 576460752303423487
  rw [BitVec.toInt_ofInt]; norm_num

lemma default_max_chunk_val : (4611686018427387903#i64).val = 4611686018427387903 := by
  change (BitVec.ofInt 64 4611686018427387903).toInt = 4611686018427387903
  rw [BitVec.toInt_ofInt]; norm_num

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

lemma i32_sub_val (a b : Std.I32)
    (hlo : -(2147483648 : Int) ≤ a.val - b.val)
    (hhi : a.val - b.val ≤ 2147483647) :
    (Pion.I32.sub a b).val = a.val - b.val := by
  unfold Pion.I32.sub
  change (a.bv - b.bv).toInt = a.val - b.val
  rw [BitVec.toInt_sub]
  change (a.val - b.val).bmod (2 ^ 32) = a.val - b.val
  rw [Int.bmod_eq_of_le] <;> norm_num <;> omega

lemma i32_add_val (a b : Std.I32)
    (hlo : -(2147483648 : Int) ≤ a.val + b.val)
    (hhi : a.val + b.val ≤ 2147483647) :
    (Pion.I32.add a b).val = a.val + b.val := by
  unfold Pion.I32.add
  change (a.bv + b.bv).toInt = a.val + b.val
  rw [BitVec.toInt_add]
  change (a.val + b.val).bmod (2 ^ 32) = a.val + b.val
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

lemma i64_mul_val (a b : Std.I64)
    (hlo : -(9223372036854775808 : Int) ≤ a.val * b.val)
    (hhi : a.val * b.val ≤ 9223372036854775807) :
    (Pion.I64.mul a b).val = a.val * b.val := by
  unfold Pion.I64.mul
  change (a.bv * b.bv).toInt = a.val * b.val
  rw [BitVec.toInt_mul]
  change (a.val * b.val).bmod (2 ^ 64) = a.val * b.val
  have hpow : (2 : Int) ^ 64 = 18446744073709551616 := by norm_num
  rw [Int.bmod_eq_of_le] <;> omega

/-- Default HTTP/1.1 limits are all strictly positive and safely bounded. -/
theorem limits_default_positive :
    ∃ l : Limits, Limits.default = ok l ∧
      0 < l.max_headers.val ∧
      0 < l.max_header_bytes.val ∧
      0 < l.max_uri_bytes.val ∧
      0 < l.max_chunk_size.val ∧
      0 < l.max_chunk_ext_bytes.val ∧
      0 < l.max_trailers.val ∧
      0 < l.max_sse_event_bytes.val ∧
      0 < l.max_sse_line_bytes.val := by
  refine ⟨Limits.mk 100#i32 65536#i64 8192#i64 4611686018427387903#i64 4096#i64 64#i32 1048576#i64 262144#i64, rfl, ?_⟩
  dsimp only
  have hmc := default_max_chunk_val
  refine ⟨by norm_num, by norm_num, by norm_num, by omega, by norm_num, by norm_num, by norm_num, by norm_num⟩

end Http1Proofs
