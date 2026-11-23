import Aeneas
import PionLean
import Crypto.Types
import Crypto.Funs

open Aeneas Aeneas.Std Result ControlFlow Error Pion crypto

namespace CryptoProofs

private lemma result_bind_ok' {α β : Type} (a : α) (f : α → Result β) :
    (do let x ← ok a; f x) = f a := by simp
private lemma uscalar_eq_of_bv {ty} {x y : UScalar ty} (h : x.bv = y.bv) : x = y := by
  cases x; cases y; congr
private lemma i32_le_iff' (x y : Std.I32) : (x <= y) ↔ (x.val <= y.val) := Iff.rfl
private lemma i32_beq_iff' (x y : Std.I32) : ((x == y) = true) ↔ (x.val = y.val) := by
  cases x; cases y; simp [BEq.beq, IScalar.val, BitVec.toInt_inj]

private lemma i32_add_val' (x y : Std.I32)
    (hlo : -2147483648 ≤ x.val + y.val) (hhi : x.val + y.val ≤ 2147483647) :
    (Pion.I32.add x y).val = x.val + y.val := by
  unfold Pion.I32.add
  have hv : (x.bv + y.bv).toInt = x.val + y.val := by
    rw [BitVec.toInt_add]
    have hx : x.bv.toInt = x.val := rfl
    have hy : y.bv.toInt = y.val := rfl
    rw [hx, hy]
    exact Int.bmod_eq_of_le (by omega) (by omega)
  exact hv

private lemma i32_sub_val' (x y : Std.I32)
    (hlo : -2147483648 ≤ x.val - y.val) (hhi : x.val - y.val ≤ 2147483647) :
    (Pion.I32.sub x y).val = x.val - y.val := by
  unfold Pion.I32.sub
  have hv : (x.bv - y.bv).toInt = x.val - y.val := by
    rw [BitVec.toInt_sub]
    have hx : x.bv.toInt = x.val := rfl
    have hy : y.bv.toInt = y.val := rfl
    rw [hx, hy]
    exact Int.bmod_eq_of_le (by omega) (by omega)
  exact hv

private lemma i32_div_pos (x y : Std.I32) (hy : 0 < y.val) :
    ∃ q : Std.I32, Pion.I32.div x y = ok q ∧ q.val = x.val.tdiv y.val := by
  unfold Pion.I32.div
  have hne : y.val ≠ 0 := by omega
  have hnoovf : ¬ (x.val = IScalar.min .I32 ∧ y.val = -1) := fun h => by omega
  rcases IScalar.div_spec (x := x) (y := y) hne hnoovf with ⟨q, hq, hqv⟩
  exact ⟨q, hq, hqv⟩

private lemma u32_rotl_eval (x : Std.U32) (n : Std.U32) (hn0 : 0 < n.val) (hn32 : n.val < 32) :
    cc_rotl32 x n = ok ⟨(x.bv <<< n.val) ||| (x.bv >>> (32 - n.val))⟩ := by
  unfold cc_rotl32 Pion.U32.shl Pion.U32.shr
  have hsub : (Pion.U32.sub 32#u32 n).val = 32 - n.val := by
    unfold Pion.U32.sub
    change ((32#32 : BitVec 32) - n.bv).toNat = 32 - n.bv.toNat
    rw [BitVec.toNat_sub_of_le]
    · rfl
    · exact BitVec.le_def.mpr (by change n.val ≤ 32; omega)
  have hsub_lt : (Pion.U32.sub 32#u32 n).val < 32 := by omega
  simp only [hn32, hsub_lt, ↓reduceIte, result_bind_ok']
  apply congrArg ok; apply uscalar_eq_of_bv
  change (((x.bv <<< n.val) ||| (x.bv >>> (Pion.U32.sub 32#u32 n).val)) &&& 4294967295#32) =
         ((x.bv <<< n.val) ||| (x.bv >>> (32 - n.val)))
  rw [hsub]
  have hm : (4294967295#32 : BitVec 32) = BitVec.allOnes 32 := rfl
  rw [hm, BitVec.and_allOnes]

private lemma bv32_rotl_inv (x : BitVec 32) (k : Nat) (hk0 : 0 < k) (hk32 : k < 32) :
    (((x <<< k) ||| (x >>> (32 - k))) <<< (32 - k)) ||| (((x <<< k) ||| (x >>> (32 - k))) >>> k) = x := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  simp only [BitVec.getLsbD_or, BitVec.getLsbD_shiftLeft, BitVec.getLsbD_ushiftRight, hi, decide_true, Bool.true_and]
  by_cases h1 : 32 - k ≤ i
  · have ha : ¬ (i < 32 - k) := by omega
    have hb : i - (32 - k) < k := by omega
    have hc : 32 - k + (i - (32 - k)) = i := by omega
    have hd : ¬ (k + i < 32) := by omega
    have he : x.getLsbD (32 - k + (k + i)) = false := BitVec.getLsbD_of_ge x _ (by omega)
    simp only [ha, hb, hc, hd, he, decide_false, decide_true, Bool.not_false, Bool.not_true, Bool.true_and, Bool.false_and, Bool.and_false, Bool.false_or, Bool.or_false]
  · have ha : i < 32 - k := by omega
    have hb : k + i < 32 := by omega
    have hc : ¬ (k + i < k) := by omega
    have hd : k + i - k = i := by omega
    have he : x.getLsbD (32 - k + (k + i)) = false := BitVec.getLsbD_of_ge x _ (by omega)
    simp only [ha, hb, hc, hd, he, decide_false, decide_true, Bool.not_false, Bool.not_true, Bool.true_and, Bool.false_and, Bool.false_or, Bool.or_false]

/-- Theorem 13: Rotating `0` by any ChaCha20 shift `0 < n < 32` yields `0`. -/
theorem cc_rotl32_zero (n : Std.U32) (hn0 : 0 < n.val) (hn32 : n.val < 32) :
    cc_rotl32 0#u32 n = ok 0#u32 := by
  rw [u32_rotl_eval 0#u32 n hn0 hn32]
  apply congrArg ok; apply uscalar_eq_of_bv
  ext i hi; simp

/-- Theorem 14: ChaCha20 16-bit rotation (`cc_rotl32 · 16`) is an involution across all `2^32` words. -/
theorem cc_rotl32_16_involutive (x : Std.U32) :
    (do let y ← cc_rotl32 x 16#u32; cc_rotl32 y 16#u32) = ok x := by
  rw [u32_rotl_eval x 16#u32 (by decide) (by decide), result_bind_ok']
  rw [u32_rotl_eval _ 16#u32 (by decide) (by decide)]
  apply congrArg ok; apply uscalar_eq_of_bv
  exact bv32_rotl_inv x.bv 16 (by decide) (by decide)

/-- Theorem 15: ChaCha20 12-bit rotation is inverted by 20-bit rotation across all `2^32` words. -/
theorem cc_rotl32_12_inverse (x : Std.U32) :
    (do let y ← cc_rotl32 x 12#u32; cc_rotl32 y 20#u32) = ok x := by
  rw [u32_rotl_eval x 12#u32 (by decide) (by decide), result_bind_ok']
  rw [u32_rotl_eval _ 20#u32 (by decide) (by decide)]
  apply congrArg ok; apply uscalar_eq_of_bv
  exact bv32_rotl_inv x.bv 12 (by decide) (by decide)

/-- Theorem 16: ChaCha20 8-bit rotation is inverted by 24-bit rotation across all `2^32` words. -/
theorem cc_rotl32_8_inverse (x : Std.U32) :
    (do let y ← cc_rotl32 x 8#u32; cc_rotl32 y 24#u32) = ok x := by
  rw [u32_rotl_eval x 8#u32 (by decide) (by decide), result_bind_ok']
  rw [u32_rotl_eval _ 24#u32 (by decide) (by decide)]
  apply congrArg ok; apply uscalar_eq_of_bv
  exact bv32_rotl_inv x.bv 8 (by decide) (by decide)

/-- Theorem 17: ChaCha20 7-bit rotation is inverted by 25-bit rotation across all `2^32` words. -/
theorem cc_rotl32_7_inverse (x : Std.U32) :
    (do let y ← cc_rotl32 x 7#u32; cc_rotl32 y 25#u32) = ok x := by
  rw [u32_rotl_eval x 7#u32 (by decide) (by decide), result_bind_ok']
  rw [u32_rotl_eval _ 25#u32 (by decide) (by decide)]
  apply congrArg ok; apply uscalar_eq_of_bv
  exact bv32_rotl_inv x.bv 7 (by decide) (by decide)

/-- Theorem 18: RFC 8439 ChaCha20-Poly1305 AEAD key (32B), nonce (12B), and ciphertext+tag (`≥ 16B`) length guards. -/
theorem chacha20_aead_lengths_exact (n : Std.I32) :
    (chacha20_is_valid_key_len n = ok true ↔ n.val = 32) ∧
    (chacha20_is_valid_nonce_len n = ok true ↔ n.val = 12) ∧
    (chacha20_is_valid_ct_len n = ok true ↔ 16 ≤ n.val) := by
  refine ⟨?_, ?_, ?_⟩
  · unfold chacha20_is_valid_key_len; simp only [ok.injEq, i32_beq_iff']; exact Iff.rfl
  · unfold chacha20_is_valid_nonce_len; simp only [ok.injEq, i32_beq_iff']; exact Iff.rfl
  · unfold chacha20_is_valid_ct_len; simp only [ok.injEq, decide_eq_true_eq, ge_iff_le, i32_le_iff']; exact Iff.rfl

/-- Theorem 19: RFC 5869 §2.3 HKDF-SHA256 output length validity exact range (`0 ≤ len ≤ 8160 = 255 * 32`). -/
theorem hkdf_sha256_valid_len_exact (len : Std.I32) :
    hkdf_sha256_valid_len len = ok true ↔ (0 ≤ len.val ∧ len.val ≤ 8160) := by
  unfold hkdf_sha256_valid_len
  simp only [ok.injEq, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']
  have hm : (Pion.I32.mul 255#i32 32#i32).val = 8160 := by decide
  rw [hm]
  change (0 ≤ len.val ∧ len.val ≤ 8160) ↔ _
  exact Iff.rfl

/-- Theorem 20: RFC 5869 §2.3 HKDF-SHA256 block count for `1 ≤ len ≤ 8160` lands strictly in `[1, 255]` (counter byte never wraps) and satisfies exact ceiling division. -/
theorem hkdf_sha256_blocks_counter_safe (len : Std.I32) (h1 : 1 ≤ len.val) (hmax : len.val ≤ 8160) :
    ∃ b : Std.I32, hkdf_sha256_blocks len = ok b ∧
      1 ≤ b.val ∧ b.val ≤ 255 ∧
      (b.val - 1) * 32 < len.val ∧ len.val ≤ b.val * 32 := by
  unfold hkdf_sha256_blocks
  set num := Pion.I32.add len 31#i32
  have hnum : num.val = len.val + 31 :=
    i32_add_val' len 31#i32 (by change -2147483648 ≤ len.val + 31; omega) (by change len.val + 31 ≤ 2147483647; omega)
  rcases i32_div_pos num 32#i32 (by decide) with ⟨b, hb, hbv⟩
  rw [hb, result_bind_ok']
  have hb_ediv : b.val = (len.val + 31) / 32 := by
    rw [hbv, hnum]
    exact Int.tdiv_eq_ediv_of_nonneg (by omega)
  exact ⟨b, rfl, by omega, by omega, by omega, by omega⟩

/-- Theorem 21: RFC 5869 §2.3 HKDF-SHA512 output length validity exact range (`0 ≤ len ≤ 16320 = 255 * 64`). -/
theorem hkdf_sha512_valid_len_exact (len : Std.I32) :
    hkdf_sha512_valid_len len = ok true ↔ (0 ≤ len.val ∧ len.val ≤ 16320) := by
  unfold hkdf_sha512_valid_len
  simp only [ok.injEq, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']
  have hm : (Pion.I32.mul 255#i32 64#i32).val = 16320 := by decide
  rw [hm]
  change (0 ≤ len.val ∧ len.val ≤ 16320) ↔ _
  exact Iff.rfl

/-- Theorem 22: RFC 5869 §2.3 HKDF-SHA512 block count for `1 ≤ len ≤ 16320` lands strictly in `[1, 255]` (counter byte never wraps) and satisfies exact ceiling division. -/
theorem hkdf_sha512_blocks_counter_safe (len : Std.I32) (h1 : 1 ≤ len.val) (hmax : len.val ≤ 16320) :
    ∃ b : Std.I32, hkdf_sha512_blocks len = ok b ∧
      1 ≤ b.val ∧ b.val ≤ 255 ∧
      (b.val - 1) * 64 < len.val ∧ len.val ≤ b.val * 64 := by
  unfold hkdf_sha512_blocks
  set num := Pion.I32.add len 63#i32
  have hnum : num.val = len.val + 63 :=
    i32_add_val' len 63#i32 (by change -2147483648 ≤ len.val + 63; omega) (by change len.val + 63 ≤ 2147483647; omega)
  rcases i32_div_pos num 64#i32 (by decide) with ⟨b, hb, hbv⟩
  rw [hb, result_bind_ok']
  have hb_ediv : b.val = (len.val + 63) / 64 := by
    rw [hbv, hnum]
    exact Int.tdiv_eq_ediv_of_nonneg (by omega)
  exact ⟨b, rfl, by omega, by omega, by omega, by omega⟩

/-- Theorem 23: `hex_nibble_val` always lands in `[-1, 15]`, returning `≥ 0` iff `c` is an ASCII hex digit. -/
theorem hex_nibble_val_bounds (c : Std.I32) :
    ∃ r : Std.I32, hex_nibble_val c = ok r ∧
      -1 ≤ r.val ∧ r.val ≤ 15 ∧
      (0 ≤ r.val ↔ ((48 ≤ c.val ∧ c.val ≤ 57) ∨ (97 ≤ c.val ∧ c.val ≤ 102) ∨ (65 ≤ c.val ∧ c.val ≤ 70))) := by
  unfold hex_nibble_val
  by_cases hd : ((decide (c >= 48#i32)) && (decide (c <= 57#i32))) = true
  · simp only [hd, ↓reduceIte]
    simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at hd
    change 48 ≤ c.val ∧ c.val ≤ 57 at hd
    have hs := i32_sub_val' c 48#i32 (by change -2147483648 ≤ c.val - 48; omega) (by change c.val - 48 ≤ 2147483647; omega)
    change (Pion.I32.sub c 48#i32).val = c.val - 48 at hs
    exact ⟨Pion.I32.sub c 48#i32, rfl, by omega, by omega, ⟨fun _ => by omega, fun _ => by omega⟩⟩
  · have hdf := Bool.eq_false_iff.mpr hd
    simp only [hdf, Bool.false_eq_true, ↓reduceIte]
    have hdn : ¬ (48 ≤ c.val ∧ c.val ≤ 57) := fun h => hd (by
      simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']; change 48 ≤ c.val ∧ c.val ≤ 57; exact h)
    by_cases hl : ((decide (c >= 97#i32)) && (decide (c <= 102#i32))) = true
    · simp only [hl, ↓reduceIte]
      simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at hl
      change 97 ≤ c.val ∧ c.val ≤ 102 at hl
      set t := Pion.I32.sub c 97#i32
      have ht : t.val = c.val - 97 := i32_sub_val' c 97#i32 (by change -2147483648 ≤ c.val - 97; omega) (by change c.val - 97 ≤ 2147483647; omega)
      have ha := i32_add_val' t 10#i32 (by change -2147483648 ≤ t.val + 10; omega) (by change t.val + 10 ≤ 2147483647; omega)
      change (Pion.I32.add t 10#i32).val = t.val + 10 at ha
      exact ⟨Pion.I32.add t 10#i32, rfl, by omega, by omega, ⟨fun _ => by omega, fun _ => by omega⟩⟩
    · have hlf := Bool.eq_false_iff.mpr hl
      simp only [hlf, Bool.false_eq_true, ↓reduceIte]
      have hln : ¬ (97 ≤ c.val ∧ c.val ≤ 102) := fun h => hl (by
        simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']; change 97 ≤ c.val ∧ c.val ≤ 102; exact h)
      by_cases hu : ((decide (c >= 65#i32)) && (decide (c <= 70#i32))) = true
      · simp only [hu, ↓reduceIte]
        simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at hu
        change 65 ≤ c.val ∧ c.val ≤ 70 at hu
        set t := Pion.I32.sub c 65#i32
        have ht : t.val = c.val - 65 := i32_sub_val' c 65#i32 (by change -2147483648 ≤ c.val - 65; omega) (by change c.val - 65 ≤ 2147483647; omega)
        have ha := i32_add_val' t 10#i32 (by change -2147483648 ≤ t.val + 10; omega) (by change t.val + 10 ≤ 2147483647; omega)
        change (Pion.I32.add t 10#i32).val = t.val + 10 at ha
        exact ⟨Pion.I32.add t 10#i32, rfl, by omega, by omega, ⟨fun _ => by omega, fun _ => by omega⟩⟩
      · have huf := Bool.eq_false_iff.mpr hu
        simp only [huf, Bool.false_eq_true, ↓reduceIte]
        have hun : ¬ (65 ≤ c.val ∧ c.val ≤ 70) := fun h => hu (by
          simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']; change 65 ≤ c.val ∧ c.val ≤ 70; exact h)
        exact ⟨(-1)#i32, rfl, by decide, by decide, ⟨fun h => by change 0 ≤ (-1 : Int) at h; omega, fun h => by omega⟩⟩

/-- Theorem 24: `hex_nibble_val` is case-insensitive on `'A'..'F'` vs `'a'..'f'`. -/
theorem hex_nibble_val_case_insensitive (c : Std.I32) (hlo : 65 ≤ c.val) (hhi : c.val ≤ 70) :
    hex_nibble_val (Pion.I32.add c 32#i32) = hex_nibble_val c := by
  set cl := Pion.I32.add c 32#i32
  have hcl : cl.val = c.val + 32 :=
    i32_add_val' c 32#i32 (by change -2147483648 ≤ c.val + 32; omega) (by change c.val + 32 ≤ 2147483647; omega)
  unfold hex_nibble_val
  have d1 : ((decide (cl >= 48#i32)) && (decide (cl <= 57#i32))) = false := by
    rw [Bool.eq_false_iff]; intro h; simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h; change 48 ≤ cl.val ∧ cl.val ≤ 57 at h; omega
  have l1 : ((decide (cl >= 97#i32)) && (decide (cl <= 102#i32))) = true := by
    simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']; change 97 ≤ cl.val ∧ cl.val ≤ 102; omega
  have d2 : ((decide (c >= 48#i32)) && (decide (c <= 57#i32))) = false := by
    rw [Bool.eq_false_iff]; intro h; simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h; change 48 ≤ c.val ∧ c.val ≤ 57 at h; omega
  have l2 : ((decide (c >= 97#i32)) && (decide (c <= 102#i32))) = false := by
    rw [Bool.eq_false_iff]; intro h; simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h; change 97 ≤ c.val ∧ c.val ≤ 102 at h; omega
  have u2 : ((decide (c >= 65#i32)) && (decide (c <= 70#i32))) = true := by
    simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']; change 65 ≤ c.val ∧ c.val ≤ 70; omega
  simp only [d1, l1, d2, l2, u2, Bool.false_eq_true, ↓reduceIte]
  apply congrArg ok; apply IScalar.eq_of_val_eq
  set s1 := Pion.I32.sub cl 97#i32
  set s2 := Pion.I32.sub c 65#i32
  have hs1 : s1.val = cl.val - 97 := i32_sub_val' cl 97#i32 (by change -2147483648 ≤ cl.val - 97; omega) (by change cl.val - 97 ≤ 2147483647; omega)
  have hs2 : s2.val = c.val - 65 := i32_sub_val' c 65#i32 (by change -2147483648 ≤ c.val - 65; omega) (by change c.val - 65 ≤ 2147483647; omega)
  have ha1 := i32_add_val' s1 10#i32 (by change -2147483648 ≤ s1.val + 10; omega) (by change s1.val + 10 ≤ 2147483647; omega)
  have ha2 := i32_add_val' s2 10#i32 (by change -2147483648 ≤ s2.val + 10; omega) (by change s2.val + 10 ≤ 2147483647; omega)
  change (Pion.I32.add s1 10#i32).val = s1.val + 10 at ha1
  change (Pion.I32.add s2 10#i32).val = s2.val + 10 at ha2
  omega

end CryptoProofs
