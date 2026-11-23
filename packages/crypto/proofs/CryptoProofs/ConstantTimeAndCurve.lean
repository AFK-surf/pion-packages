import Aeneas
import PionLean
import Crypto.Types
import Crypto.Funs

open Aeneas Aeneas.Std Result ControlFlow Error Pion crypto

namespace CryptoProofs

private lemma result_bind_ok {α β : Type} (a : α) (f : α → Result β) :
    (do let x ← ok a; f x) = f a := by simp

private lemma iscalar_eq_of_bv {ty} {x y : IScalar ty} (h : x.bv = y.bv) : x = y := by
  cases x; cases y; congr

private lemma i64_xor_zero_and (a b : Std.I64) :
    Pion.I64.bxor a (Pion.I64.band (Pion.I64.sub 0#i64 0#i64) (Pion.I64.bxor a b)) = a := by
  apply iscalar_eq_of_bv
  change a.bv ^^^ ((0#64 - 0#64) &&& (a.bv ^^^ b.bv)) = a.bv
  have h0 : (0#64 - 0#64 : BitVec 64) = 0#64 := rfl
  rw [h0, BitVec.zero_and, BitVec.xor_zero]

private lemma i64_xor_allones_and_left (a b : Std.I64) :
    Pion.I64.bxor a (Pion.I64.band (Pion.I64.sub 0#i64 1#i64) (Pion.I64.bxor a b)) = b := by
  apply iscalar_eq_of_bv
  change a.bv ^^^ ((0#64 - 1#64) &&& (a.bv ^^^ b.bv)) = b.bv
  have hm : (0#64 - 1#64 : BitVec 64) = BitVec.allOnes 64 := rfl
  rw [hm, BitVec.allOnes_and, ← BitVec.xor_assoc, BitVec.xor_self, BitVec.zero_xor]

private lemma i64_xor_allones_and_right (a b : Std.I64) :
    Pion.I64.bxor b (Pion.I64.band (Pion.I64.sub 0#i64 1#i64) (Pion.I64.bxor a b)) = a := by
  apply iscalar_eq_of_bv
  change b.bv ^^^ ((0#64 - 1#64) &&& (a.bv ^^^ b.bv)) = a.bv
  have hm : (0#64 - 1#64 : BitVec 64) = BitVec.allOnes 64 := rfl
  rw [hm, BitVec.allOnes_and, BitVec.xor_comm a.bv b.bv, ← BitVec.xor_assoc, BitVec.xor_self, BitVec.zero_xor]

private lemma i64_xor_self_mask (a : Std.I64) (m : Std.I64) :
    Pion.I64.bxor a (Pion.I64.band m (Pion.I64.bxor a a)) = a := by
  apply iscalar_eq_of_bv
  change a.bv ^^^ (m.bv &&& (a.bv ^^^ a.bv)) = a.bv
  rw [BitVec.xor_self, BitVec.and_zero, BitVec.xor_zero]

private lemma bv32_toInt_of_nonneg (v : BitVec 32) (h : v.toNat < 2147483648) :
    v.toInt = (v.toNat : Int) := by
  rw [BitVec.toInt_eq_toNat_cond]
  have h2 : 2 * v.toNat < 2 ^ 32 := by omega
  simp only [h2, ↓reduceIte]

private lemma i64_add_comm (a b : Std.I64) : Pion.I64.add a b = Pion.I64.add b a := by
  apply iscalar_eq_of_bv
  change a.bv + b.bv = b.bv + a.bv
  exact BitVec.add_comm a.bv b.bv

private lemma bv32_or_eq_zero_iff (x y : BitVec 32) : (x ||| y = 0#32) ↔ (x = 0#32 ∧ y = 0#32) := by
  constructor
  · intro h
    constructor
    · apply BitVec.eq_of_getLsbD_eq; intro i hi
      have hb := congrArg (fun v => v.getLsbD i) h
      simp only [BitVec.getLsbD_or, BitVec.getLsbD_zero, Bool.or_eq_false_iff] at hb
      rw [BitVec.getLsbD_zero]; exact hb.1
    · apply BitVec.eq_of_getLsbD_eq; intro i hi
      have hb := congrArg (fun v => v.getLsbD i) h
      simp only [BitVec.getLsbD_or, BitVec.getLsbD_zero, Bool.or_eq_false_iff] at hb
      rw [BitVec.getLsbD_zero]; exact hb.2
  · rintro ⟨rfl, rfl⟩; rfl

private lemma bv32_xor_eq_zero_iff (x y : BitVec 32) : (x ^^^ y = 0#32) ↔ x = y := by
  constructor
  · intro h
    have := congrArg (fun v => x ^^^ v) h
    simp only [← BitVec.xor_assoc, BitVec.xor_self, BitVec.zero_xor, BitVec.xor_zero] at this
    exact this.symm
  · intro h; subst h; exact BitVec.xor_self

/-- Theorem 1: Constant-time byte difference step `ct_diff_acc 0 a b = 0` iff `a = b`. -/
theorem ct_diff_acc_zero_iff (a b : Std.I32) :
    ct_diff_acc 0#i32 a b = ok 0#i32 ↔ a = b := by
  unfold ct_diff_acc
  simp only [ok.injEq]
  constructor
  · intro h
    have hbv : (0#32 ||| (a.bv ^^^ b.bv)) = 0#32 := congrArg IScalar.bv h
    rw [BitVec.zero_or] at hbv
    exact iscalar_eq_of_bv ((bv32_xor_eq_zero_iff a.bv b.bv).mp hbv)
  · intro h; subst h
    apply iscalar_eq_of_bv
    change (0#32 ||| (a.bv ^^^ a.bv)) = 0#32
    rw [BitVec.xor_self, BitVec.zero_or]

/-- Theorem 2: Monotone non-zero latch: once `diff ≠ 0` or `a ≠ b`, `ct_diff_acc diff a b` can never return `0`. -/
theorem ct_diff_acc_monotone_nonzero (diff a b : Std.I32) :
    (diff ≠ 0#i32 → ct_diff_acc diff a b ≠ ok 0#i32) ∧
    (a ≠ b → ct_diff_acc diff a b ≠ ok 0#i32) := by
  constructor
  · intro hne heq
    unfold ct_diff_acc at heq
    simp only [ok.injEq] at heq
    have hbv : (diff.bv ||| (a.bv ^^^ b.bv)) = 0#32 := congrArg IScalar.bv heq
    exact hne (iscalar_eq_of_bv ((bv32_or_eq_zero_iff diff.bv (a.bv ^^^ b.bv)).mp hbv).1)
  · intro hne heq
    unfold ct_diff_acc at heq
    simp only [ok.injEq] at heq
    have hbv : (diff.bv ||| (a.bv ^^^ b.bv)) = 0#32 := congrArg IScalar.bv heq
    have hxor := ((bv32_or_eq_zero_iff diff.bv (a.bv ^^^ b.bv)).mp hbv).2
    exact hne (iscalar_eq_of_bv ((bv32_xor_eq_zero_iff a.bv b.bv).mp hxor))

/-- Theorem 3: Branch-free Ed25519 `fe_cmov a b 0 = ok a` across all `2^1280` field-element pairs. -/
theorem fe_cmov_flag_zero (a b : Fe) :
    fe_cmov a b 0#i64 = ok a := by
  unfold fe_cmov
  cases a; cases b
  simp only [i64_xor_zero_and]

/-- Theorem 4: Branch-free Ed25519 `fe_cmov a b 1 = ok b` across all `2^1280` field-element pairs. -/
theorem fe_cmov_flag_one (a b : Fe) :
    fe_cmov a b 1#i64 = ok b := by
  unfold fe_cmov
  cases a; cases b
  simp only [i64_xor_allones_and_left]

/-- Theorem 5: `fe_cmov a a flag = ok a` for every `Fe` and every 64-bit `flag`. -/
theorem fe_cmov_same_invariant (a : Fe) (flag : Std.I64) :
    fe_cmov a a flag = ok a := by
  unfold fe_cmov
  cases a
  simp only [i64_xor_self_mask]

/-- Theorem 6: Branch-free X25519 Montgomery ladder `fe_cswap_pair a b 0 = ok (a, b)`. -/
theorem fe_cswap_pair_zero (a b : Fe) :
    fe_cswap_pair a b 0#i64 = ok (a, b) := by
  unfold fe_cswap_pair
  cases a; cases b
  simp only [i64_xor_zero_and]
  have hr : ∀ x y : Std.I64, Pion.I64.bxor y (Pion.I64.band (Pion.I64.sub 0#i64 0#i64) (Pion.I64.bxor x y)) = y := by
    intro x y; apply iscalar_eq_of_bv
    change y.bv ^^^ ((0#64 - 0#64) &&& (x.bv ^^^ y.bv)) = y.bv
    have h0 : (0#64 - 0#64 : BitVec 64) = 0#64 := rfl
    rw [h0, BitVec.zero_and, BitVec.xor_zero]
  simp only [hr]

/-- Theorem 7: Branch-free X25519 Montgomery ladder `fe_cswap_pair a b 1 = ok (b, a)`. -/
theorem fe_cswap_pair_one (a b : Fe) :
    fe_cswap_pair a b 1#i64 = ok (b, a) := by
  unfold fe_cswap_pair
  cases a; cases b
  simp only [i64_xor_allones_and_left, i64_xor_allones_and_right]

/-- Theorem 8: `fe_cswap_pair` is an involution for `swap ∈ {0, 1}`. -/
theorem fe_cswap_pair_involutive (a b : Fe) (s : Std.I64) (hs : s = 0#i64 ∨ s = 1#i64) :
    (do let p ← fe_cswap_pair a b s; fe_cswap_pair p.1 p.2 s) = ok (a, b) := by
  rcases hs with rfl | rfl
  · rw [fe_cswap_pair_zero, result_bind_ok, fe_cswap_pair_zero]
  · rw [fe_cswap_pair_one, result_bind_ok, fe_cswap_pair_one]

/-- Theorem 9: Ed25519 / X25519 10-limb field addition `fe_add` is commutative across all `2^1280` `Fe` pairs. -/
theorem fe_add_comm (a b : Fe) :
    fe_add a b = fe_add b a := by
  unfold fe_add
  cases a; cases b
  simp only [Result.ok.injEq, Fe.mk.injEq]
  exact ⟨i64_add_comm _ _, i64_add_comm _ _, i64_add_comm _ _, i64_add_comm _ _, i64_add_comm _ _,
         i64_add_comm _ _, i64_add_comm _ _, i64_add_comm _ _, i64_add_comm _ _, i64_add_comm _ _⟩

/-- Theorem 10: RFC 7748 §5 X25519 low-byte clamping clears bits `0..2` (`r % 8 = 0`, cofactor-8) and lands in `[0, 248]`. -/
theorem x25519_clamp_low_byte_cofactor8 (b : Std.I32) :
    ∃ r : Std.I32, x25519_clamp_low_byte b = ok r ∧
      0 ≤ r.val ∧ r.val ≤ 248 ∧ r.val % 8 = 0 := by
  unfold x25519_clamp_low_byte
  set r := Pion.I32.band b 248#i32
  have hr_nat : r.bv.toNat = b.bv.toNat &&& 248 := by
    change (b.bv &&& 248#32).toNat = b.bv.toNat &&& 248
    rw [BitVec.toNat_and]; rfl
  have hr_le : r.bv.toNat ≤ 248 := by
    rw [hr_nat]; exact Nat.and_le_right
  have hr_mod : r.bv.toNat % 8 = 0 := by
    have h1 : r.bv.toNat % 2 ^ 3 = r.bv.toNat &&& (2 ^ 3 - 1) := (Nat.and_two_pow_sub_one_eq_mod r.bv.toNat 3).symm
    change r.bv.toNat % 8 = r.bv.toNat &&& 7 at h1
    rw [h1, hr_nat, Nat.and_assoc]
    have h2 : (248 &&& 7 : Nat) = 0 := by decide
    rw [h2, Nat.and_zero]
  have hr_val : r.val = (r.bv.toNat : Int) := bv32_toInt_of_nonneg r.bv (by omega)
  exact ⟨r, rfl, by omega, by omega, by omega⟩

/-- Theorem 11: RFC 7748 §5 X25519 high-byte clamping clears bit 7 and sets bit 6, landing strictly in `[64, 127]`. -/
theorem x25519_clamp_high_byte_range (b : Std.I32) :
    ∃ r : Std.I32, x25519_clamp_high_byte b = ok r ∧
      64 ≤ r.val ∧ r.val ≤ 127 := by
  unfold x25519_clamp_high_byte
  set r := Pion.I32.bor (Pion.I32.band b 127#i32) 64#i32
  have hr_nat : r.bv.toNat = ((b.bv.toNat &&& 127) ||| 64) := by
    change ((b.bv &&& 127#32) ||| 64#32).toNat = ((b.bv.toNat &&& 127) ||| 64)
    rw [BitVec.toNat_or, BitVec.toNat_and]; rfl
  have h127 : (b.bv.toNat &&& 127) < 2 ^ 7 := by
    have : b.bv.toNat &&& 127 ≤ 127 := Nat.and_le_right
    omega
  have hr_lt : r.bv.toNat < 128 := by
    rw [hr_nat]
    exact Nat.or_lt_two_pow h127 (by decide)
  have hr_ge : 64 ≤ r.bv.toNat := by
    rw [hr_nat]
    exact Nat.right_le_or
  have hr_val : r.val = (r.bv.toNat : Int) := bv32_toInt_of_nonneg r.bv (by omega)
  exact ⟨r, rfl, by omega, by omega⟩

/-- Theorem 12: Both RFC 7748 X25519 byte clamps are idempotent across all `2^32` 32-bit inputs. -/
theorem x25519_clamp_idempotent_all (b : Std.I32) :
    (do let r ← x25519_clamp_low_byte b; x25519_clamp_low_byte r) = x25519_clamp_low_byte b ∧
    (do let r ← x25519_clamp_high_byte b; x25519_clamp_high_byte r) = x25519_clamp_high_byte b := by
  constructor
  · unfold x25519_clamp_low_byte; rw [result_bind_ok]
    apply congrArg ok; apply iscalar_eq_of_bv
    change (b.bv &&& 248#32) &&& 248#32 = b.bv &&& 248#32
    rw [BitVec.and_assoc]; rfl
  · unfold x25519_clamp_high_byte; rw [result_bind_ok]
    apply congrArg ok; apply iscalar_eq_of_bv
    change (((b.bv &&& 127#32) ||| 64#32) &&& 127#32) ||| 64#32 =
           (b.bv &&& 127#32) ||| 64#32
    have h64 : ((64#32 : BitVec 32) &&& 127#32) = 64#32 := by decide
    ext i hi
    have h64i := congrArg (fun v : BitVec 32 => v[i]) h64
    simp only [BitVec.getElem_or, BitVec.getElem_and] at h64i ⊢
    cases b.bv[i] <;> cases (127#32 : BitVec 32)[i] <;> cases (64#32 : BitVec 32)[i] <;> simp_all

end CryptoProofs
