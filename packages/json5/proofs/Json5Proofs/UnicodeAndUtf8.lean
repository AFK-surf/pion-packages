import Aeneas
import PionLean
import Json5.Types
import Json5.Funs

open Aeneas Aeneas.Std Result Error Pion
open json5

namespace Json5Proofs

private lemma result_bind_ok {α β : Type} (a : α) (f : α → Result β) :
    (do let x ← ok a; f x) = f a := by
  simp

private lemma i32_beq_iff (x y : Std.I32) : (x == y) = true ↔ x.val = y.val := by
  cases x; cases y
  simp [BEq.beq, IScalar.val, BitVec.toInt_inj]

private lemma i32_eq_of_val {x y : Std.I32} (h : x.val = y.val) : x = y := by
  cases x; cases y
  simp [IScalar.val, BitVec.toInt_inj] at h
  congr

private lemma i32_add_val (x y : Std.I32)
    (hlo : -(2 ^ 31 : Int) ≤ x.val + y.val) (hhi : x.val + y.val < 2 ^ 31) :
    (Pion.I32.add x y).val = x.val + y.val := by
  change -(2 ^ 31 : Int) ≤ x.bv.toInt + y.bv.toInt at hlo
  change x.bv.toInt + y.bv.toInt < 2 ^ 31 at hhi
  change (x.bv + y.bv).toInt = x.bv.toInt + y.bv.toInt
  rw [BitVec.toInt_add]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_sub_val (x y : Std.I32)
    (hlo : -(2 ^ 31 : Int) ≤ x.val - y.val) (hhi : x.val - y.val < 2 ^ 31) :
    (Pion.I32.sub x y).val = x.val - y.val := by
  change -(2 ^ 31 : Int) ≤ x.bv.toInt - y.bv.toInt at hlo
  change x.bv.toInt - y.bv.toInt < 2 ^ 31 at hhi
  change (x.bv - y.bv).toInt = x.bv.toInt - y.bv.toInt
  rw [BitVec.toInt_sub]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_toNat_of_nonneg (x : Std.I32) (h0 : 0 ≤ x.val) :
    x.bv.toNat = x.val.toNat := by
  have hb := x.hBounds
  simp at hb
  have hlt : 2 * x.bv.toNat < 2 ^ 32 := by
    have hbv := BitVec.toInt_eq_toNat_cond x.bv
    split_ifs at hbv with hc
    · omega
    · change 0 ≤ x.bv.toInt at h0
      omega
  have hti : x.bv.toInt = (x.bv.toNat : Int) := BitVec.toInt_eq_toNat_of_lt hlt
  change x.bv.toNat = x.bv.toInt.toNat
  rw [hti]; omega

private lemma i32_shl_nonneg (x : Std.I32) (k : Std.I32)
    (hk0 : 0 ≤ k.val) (hk32 : k.val < 32)
    (hx0 : 0 ≤ x.val) (hfit : x.val.toNat * 2 ^ k.val.toNat < 2 ^ 31) :
    ∃ r : Std.I32,
      Pion.I32.shl x k = ok r ∧ r.val = x.val * (2 ^ k.val.toNat : Nat) := by
  have hk : 0 ≤ k.val ∧ k.val < 32 := ⟨hk0, hk32⟩
  have hs : Pion.I32.shl x k = ok ⟨x.bv <<< k.val.toNat⟩ := by
    simp only [Pion.I32.shl, hk, and_self, ↓reduceIte]
  refine ⟨⟨x.bv <<< k.val.toNat⟩, hs, ?_⟩
  have hxn := i32_toNat_of_nonneg x hx0
  have hnat : (x.bv <<< k.val.toNat).toNat = x.val.toNat * 2 ^ k.val.toNat := by
    rw [BitVec.toNat_shiftLeft, hxn, Nat.shiftLeft_eq]
    exact Nat.mod_eq_of_lt (by omega)
  change (x.bv <<< k.val.toNat).toInt = _
  rw [BitVec.toInt_eq_toNat_of_lt (by omega), hnat]
  have hxz : (x.val.toNat : Int) = x.val := Int.toNat_of_nonneg hx0
  rw [Nat.cast_mul, hxz]

/-- 1. High (`0xD800..0xDBFF`) and low (`0xDC00..0xDFFF`) UTF-16 surrogates are strictly disjoint. -/
theorem surrogate_ranges_disjoint (cp : Std.I32) :
    is_high_surrogate cp = ok true → is_low_surrogate cp = ok false := by
  unfold is_high_surrogate is_low_surrogate
  have h1 : (55296#i32).val = 55296 := by decide
  have h2 : (56319#i32).val = 56319 := by decide
  have h3 : (56320#i32).val = 56320 := by decide
  have h4 : (57343#i32).val = 57343 := by decide
  simp only [Result.ok.injEq, Bool.and_eq_true, Bool.and_eq_false_iff,
    decide_eq_true_eq, decide_eq_false_iff_not, ge_iff_le, IScalar.le_equiv, h1, h2, h3, h4]
  omega

/-- 2. `decode_surrogate_pair` maps every valid `(hi, lo)` pair to a valid supplementary
    Unicode scalar value in `[0x10000, 0x10FFFF]`. -/
theorem decode_surrogate_pair_bounds (hi lo : Std.I32)
    (hhi : is_high_surrogate hi = ok true) (hlo : is_low_surrogate lo = ok true) :
    ∃ cp : Std.I32,
      decode_surrogate_pair hi lo = ok cp ∧
      cp.val = 65536 + (hi.val - 55296) * 1024 + (lo.val - 56320) ∧
      65536 ≤ cp.val ∧ cp.val ≤ 1114111 := by
  have h1 : (55296#i32).val = 55296 := by decide
  have h2 : (56319#i32).val = 56319 := by decide
  have h3 : (56320#i32).val = 56320 := by decide
  have h4 : (57343#i32).val = 57343 := by decide
  have h65 : (65536#i32).val = 65536 := by decide
  have h10 : (10#i32).val = 10 := by decide
  unfold is_high_surrogate at hhi
  unfold is_low_surrogate at hlo
  simp only [Result.ok.injEq, Bool.and_eq_true, decide_eq_true_eq,
    ge_iff_le, IScalar.le_equiv, h1, h2, h3, h4] at hhi hlo
  unfold decode_surrogate_pair
  have hshi : (Pion.I32.sub hi 55296#i32).val = hi.val - 55296 := by
    rw [i32_sub_val hi 55296#i32 (by omega) (by omega), h1]
  have hslo : (Pion.I32.sub lo 56320#i32).val = lo.val - 56320 := by
    rw [i32_sub_val lo 56320#i32 (by omega) (by omega), h3]
  obtain ⟨sh, hsh, hshv⟩ := i32_shl_nonneg (Pion.I32.sub hi 55296#i32) 10#i32
    (by omega) (by omega) (by omega) (by rw [h10]; change _ * 1024 < _; omega)
  rw [hsh, result_bind_ok]
  rw [h10] at hshv
  have hshv' : sh.val = (hi.val - 55296) * 1024 := by
    change sh.val = (Pion.I32.sub hi 55296#i32).val * (1024 : Nat) at hshv
    omega
  have ha1 : (Pion.I32.add 65536#i32 sh).val = 65536 + sh.val := by
    rw [i32_add_val 65536#i32 sh (by omega) (by omega), h65]
  have ha2 : (Pion.I32.add (Pion.I32.add 65536#i32 sh) (Pion.I32.sub lo 56320#i32)).val =
      65536 + (hi.val - 55296) * 1024 + (lo.val - 56320) := by
    rw [i32_add_val _ _ (by omega) (by omega), ha1, hslo]; omega
  exact ⟨_, rfl, ha2, by omega, by omega⟩

/-- 3. `decode_surrogate_pair` is injective on valid UTF-16 surrogate pairs. -/
theorem decode_surrogate_pair_injective (h1 l1 h2 l2 : Std.I32)
    (hh1 : is_high_surrogate h1 = ok true) (hl1 : is_low_surrogate l1 = ok true)
    (hh2 : is_high_surrogate h2 = ok true) (hl2 : is_low_surrogate l2 = ok true)
    (heq : decode_surrogate_pair h1 l1 = decode_surrogate_pair h2 l2) :
    h1 = h2 ∧ l1 = l2 := by
  obtain ⟨c1, hc1, hcv1, _, _⟩ := decode_surrogate_pair_bounds h1 l1 hh1 hl1
  obtain ⟨c2, hc2, hcv2, _, _⟩ := decode_surrogate_pair_bounds h2 l2 hh2 hl2
  rw [hc1, hc2, Result.ok.injEq] at heq
  subst heq
  have ha : (55296#i32).val = 55296 := by decide
  have hb : (56319#i32).val = 56319 := by decide
  have hc : (56320#i32).val = 56320 := by decide
  have hd : (57343#i32).val = 57343 := by decide
  unfold is_high_surrogate at hh1 hh2
  unfold is_low_surrogate at hl1 hl2
  simp only [Result.ok.injEq, Bool.and_eq_true, decide_eq_true_eq,
    ge_iff_le, IScalar.le_equiv, ha, hb, hc, hd] at hh1 hh2 hl1 hl2
  exact ⟨i32_eq_of_val (by omega), i32_eq_of_val (by omega)⟩

/-- 4. `pack_hex2` packs two hex nibbles (`0..15`) into a byte in `[0, 255]`. -/
theorem pack_hex2_bounds (h0 h1 : Std.I32)
    (h0b : 0 ≤ h0.val ∧ h0.val ≤ 15) (h1b : 0 ≤ h1.val ∧ h1.val ≤ 15) :
    ∃ v : Std.I32, pack_hex2 h0 h1 = ok v ∧ 0 ≤ v.val ∧ v.val ≤ 255 := by
  unfold pack_hex2
  have h4 : (4#i32).val = 4 := by decide
  obtain ⟨sh, hsh, hshv⟩ := i32_shl_nonneg h0 4#i32 (by omega) (by omega) h0b.1
    (by rw [h4]; change _ * 16 < _; omega)
  rw [hsh, result_bind_ok]
  rw [h4] at hshv
  have hshv' : sh.val = h0.val * (16 : Nat) := hshv
  have hsh_lt : sh.bv.toNat < 2 ^ 8 := by
    have := i32_toNat_of_nonneg sh (by omega)
    omega
  have hh1_lt : h1.bv.toNat < 2 ^ 8 := by
    have := i32_toNat_of_nonneg h1 h1b.1
    omega
  have hor_lt : (Pion.I32.bor sh h1).bv.toNat < 2 ^ 8 := by
    change (sh.bv ||| h1.bv).toNat < 2 ^ 8
    rw [BitVec.toNat_or]
    exact Nat.or_lt_two_pow hsh_lt hh1_lt
  have hval : (Pion.I32.bor sh h1).val = ((Pion.I32.bor sh h1).bv.toNat : Int) := by
    change (Pion.I32.bor sh h1).bv.toInt = _
    exact BitVec.toInt_eq_toNat_of_lt (by omega)
  exact ⟨Pion.I32.bor sh h1, rfl, by omega, by omega⟩

/-- 5. `pack_hex4` packs four hex nibbles (`0..15`) into a 16-bit code unit in `[0, 65535]`. -/
theorem pack_hex4_bounds (d0 d1 d2 d3 : Std.I32)
    (b0 : 0 ≤ d0.val ∧ d0.val ≤ 15) (b1 : 0 ≤ d1.val ∧ d1.val ≤ 15)
    (b2 : 0 ≤ d2.val ∧ d2.val ≤ 15) (b3 : 0 ≤ d3.val ∧ d3.val ≤ 15) :
    ∃ v : Std.I32, pack_hex4 d0 d1 d2 d3 = ok v ∧ 0 ≤ v.val ∧ v.val ≤ 65535 := by
  unfold pack_hex4
  have h12 : (12#i32).val = 12 := by decide
  have h8 : (8#i32).val = 8 := by decide
  have h4 : (4#i32).val = 4 := by decide
  obtain ⟨s0, hs0, hs0v⟩ := i32_shl_nonneg d0 12#i32 (by omega) (by omega) b0.1
    (by rw [h12]; change _ * 4096 < _; omega)
  obtain ⟨s1, hs1, hs1v⟩ := i32_shl_nonneg d1 8#i32 (by omega) (by omega) b1.1
    (by rw [h8]; change _ * 256 < _; omega)
  obtain ⟨s2, hs2, hs2v⟩ := i32_shl_nonneg d2 4#i32 (by omega) (by omega) b2.1
    (by rw [h4]; change _ * 16 < _; omega)
  rw [hs0, result_bind_ok, hs1, result_bind_ok, hs2, result_bind_ok]
  rw [h12] at hs0v; rw [h8] at hs1v; rw [h4] at hs2v
  have hs0v' : s0.val = d0.val * (4096 : Nat) := hs0v
  have hs1v' : s1.val = d1.val * (256 : Nat) := hs1v
  have hs2v' : s2.val = d2.val * (16 : Nat) := hs2v
  have l0 : s0.bv.toNat < 2 ^ 16 := by have := i32_toNat_of_nonneg s0 (by omega); omega
  have l1 : s1.bv.toNat < 2 ^ 16 := by have := i32_toNat_of_nonneg s1 (by omega); omega
  have l2 : s2.bv.toNat < 2 ^ 16 := by have := i32_toNat_of_nonneg s2 (by omega); omega
  have l3 : d3.bv.toNat < 2 ^ 16 := by have := i32_toNat_of_nonneg d3 b3.1; omega
  have r01 : (Pion.I32.bor s0 s1).bv.toNat < 2 ^ 16 := by
    change (s0.bv ||| s1.bv).toNat < 2 ^ 16; rw [BitVec.toNat_or]; exact Nat.or_lt_two_pow l0 l1
  have r012 : (Pion.I32.bor (Pion.I32.bor s0 s1) s2).bv.toNat < 2 ^ 16 := by
    change ((Pion.I32.bor s0 s1).bv ||| s2.bv).toNat < 2 ^ 16
    rw [BitVec.toNat_or]; exact Nat.or_lt_two_pow r01 l2
  have r0123 : (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor s0 s1) s2) d3).bv.toNat < 2 ^ 16 := by
    change ((Pion.I32.bor (Pion.I32.bor s0 s1) s2).bv ||| d3.bv).toNat < 2 ^ 16
    rw [BitVec.toNat_or]; exact Nat.or_lt_two_pow r012 l3
  have hval : (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor s0 s1) s2) d3).val =
      ((Pion.I32.bor (Pion.I32.bor (Pion.I32.bor s0 s1) s2) d3).bv.toNat : Int) := by
    change (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor s0 s1) s2) d3).bv.toInt = _
    exact BitVec.toInt_eq_toNat_of_lt (by omega)
  exact ⟨_, rfl, by omega, by omega⟩

private lemma i32_beq_false_of_ne {x y : Std.I32} (h : x.val ≠ y.val) : (x == y) = false := by
  cases hb : (x == y)
  · rfl
  · rw [i32_beq_iff] at hb; exact absurd hb h

/-- 6. `is_unicode_j5_ws` returns `false` for all ASCII code points (`cp < 128`). -/
theorem is_unicode_j5_ws_non_ascii (cp : Std.I32) (h : cp.val < 128) :
    is_unicode_j5_ws cp = ok false := by
  unfold is_unicode_j5_ws
  have h1 : (160#i32).val = 160 := by decide
  have h2 : (65279#i32).val = 65279 := by decide
  have h3 : (8232#i32).val = 8232 := by decide
  have h4 : (8233#i32).val = 8233 := by decide
  have h5 : (5760#i32).val = 5760 := by decide
  have h6 : (8192#i32).val = 8192 := by decide
  have h7 : (8239#i32).val = 8239 := by decide
  have h8 : (8287#i32).val = 8287 := by decide
  have h9 : (12288#i32).val = 12288 := by decide
  have c1 : (cp == 160#i32) = false := i32_beq_false_of_ne (by omega)
  have c2 : (cp == 65279#i32) = false := i32_beq_false_of_ne (by omega)
  have c3 : (cp == 8232#i32) = false := i32_beq_false_of_ne (by omega)
  have c4 : (cp == 8233#i32) = false := i32_beq_false_of_ne (by omega)
  have c5 : (cp == 5760#i32) = false := i32_beq_false_of_ne (by omega)
  have c6 : decide (cp >= 8192#i32) = false := by
    simp only [decide_eq_false_iff_not, ge_iff_le, IScalar.le_equiv, h6]; omega
  have c7 : (cp == 8239#i32) = false := i32_beq_false_of_ne (by omega)
  have c8 : (cp == 8287#i32) = false := i32_beq_false_of_ne (by omega)
  have c9 : (cp == 12288#i32) = false := i32_beq_false_of_ne (by omega)
  simp only [c1, c2, c3, c4, c5, c6, c7, c8, c9, Bool.false_and, Bool.false_or]

/-- 7. JSON5 recognizes `U+2028` (LS), `U+2029` (PS), and `U+FEFF` (BOM) as whitespace. -/
theorem is_unicode_j5_ws_line_seps (cp : Std.I32)
    (h : cp.val = 8232 ∨ cp.val = 8233 ∨ cp.val = 65279) :
    is_unicode_j5_ws cp = ok true := by
  unfold is_unicode_j5_ws
  have h2 : (65279#i32).val = 65279 := by decide
  have h3 : (8232#i32).val = 8232 := by decide
  have h4 : (8233#i32).val = 8233 := by decide
  simp only [Result.ok.injEq, Bool.or_eq_true, i32_beq_iff, h2, h3, h4]
  omega

/-- 8. RFC 3629: `utf8_valid_3byte` always rejects overlong `0xE0` sequences (`b1 < 0xA0`). -/
theorem utf8_valid_3byte_rejects_overlong (b1 b2 : Std.I32) (h : b1.val < 160) :
    utf8_valid_3byte 224#i32 b1 b2 = ok false := by
  unfold utf8_valid_3byte
  have hcond : ((decide (224#i32 >= 224#i32)) && (decide (224#i32 <= 239#i32))) = true := by decide
  simp only [hcond, ↓reduceIte, is_utf8_cont, result_bind_ok]
  split_ifs <;> simp
  omega

/-- 9. RFC 3629: `utf8_valid_3byte` always rejects UTF-16 surrogates (`0xED` with `b1 ≥ 0xA0`). -/
theorem utf8_valid_3byte_rejects_surrogate (b1 b2 : Std.I32) (h : 160 ≤ b1.val) :
    utf8_valid_3byte 237#i32 b1 b2 = ok false := by
  unfold utf8_valid_3byte
  have hcond : ((decide (237#i32 >= 224#i32)) && (decide (237#i32 <= 239#i32))) = true := by decide
  simp only [hcond, ↓reduceIte, is_utf8_cont, result_bind_ok]
  split_ifs <;> simp
  omega

/-- 10. RFC 3629: `utf8_valid_4byte` always rejects overlong `0xF0` sequences (`b1 < 0x90`). -/
theorem utf8_valid_4byte_rejects_overlong (b1 b2 b3 : Std.I32) (h : b1.val < 144) :
    utf8_valid_4byte 240#i32 b1 b2 b3 = ok false := by
  unfold utf8_valid_4byte
  have hcond : ((decide (240#i32 >= 240#i32)) && (decide (240#i32 <= 244#i32))) = true := by decide
  simp only [hcond, ↓reduceIte, is_utf8_cont, result_bind_ok]
  split_ifs <;> simp
  omega

/-- 11. RFC 3629: `utf8_valid_4byte` always rejects code points `> U+10FFFF` (`0xF4` with `b1 > 0x8F`). -/
theorem utf8_valid_4byte_rejects_above_max (b1 b2 b3 : Std.I32) (h : 143 < b1.val) :
    utf8_valid_4byte 244#i32 b1 b2 b3 = ok false := by
  unfold utf8_valid_4byte
  have hcond : ((decide (244#i32 >= 240#i32)) && (decide (244#i32 <= 244#i32))) = true := by decide
  simp only [hcond, ↓reduceIte, is_utf8_cont, result_bind_ok]
  split_ifs <;> simp
  omega

/-- 12. `utf8_valid_3byte` rejects any sequence whose second byte is not a continuation byte. -/
theorem utf8_valid_3byte_requires_cont (b0 b1 b2 : Std.I32) (h : is_utf8_cont b1 = ok false) :
    utf8_valid_3byte b0 b1 b2 = ok false := by
  unfold utf8_valid_3byte
  split_ifs
  · rw [h, result_bind_ok]
    simp
  · rw [result_bind_ok]
    simp

end Json5Proofs
