import Aeneas
import PionLean
import Url.Types
import Url.Funs

open Aeneas Aeneas.Std Result Pion url

namespace UrlProofs

private lemma result_bind_ok' {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by simp

private lemma u32_shl24_ok (x : Std.U32) : Pion.U32.shl x 24#u32 = ok ⟨x.bv <<< 24⟩ := by
  unfold Pion.U32.shl
  have h : (24#u32 : Std.U32).val < 32 := by decide
  simp only [h, ↓reduceIte]; rfl

private lemma u32_shl16_ok (x : Std.U32) : Pion.U32.shl x 16#u32 = ok ⟨x.bv <<< 16⟩ := by
  unfold Pion.U32.shl
  have h : (16#u32 : Std.U32).val < 32 := by decide
  simp only [h, ↓reduceIte]; rfl

private lemma u32_shl8_ok (x : Std.U32) : Pion.U32.shl x 8#u32 = ok ⟨x.bv <<< 8⟩ := by
  unfold Pion.U32.shl
  have h : (8#u32 : Std.U32).val < 32 := by decide
  simp only [h, ↓reduceIte]; rfl

private lemma u32_shr24_ok (x : Std.U32) : Pion.U32.shr x 24#u32 = ok ⟨x.bv >>> 24⟩ := by
  unfold Pion.U32.shr
  have h : (24#u32 : Std.U32).val < 32 := by decide
  simp only [h, ↓reduceIte]; rfl

private lemma u32_shr16_ok (x : Std.U32) : Pion.U32.shr x 16#u32 = ok ⟨x.bv >>> 16⟩ := by
  unfold Pion.U32.shr
  have h : (16#u32 : Std.U32).val < 32 := by decide
  simp only [h, ↓reduceIte]; rfl

private lemma u32_shr8_ok (x : Std.U32) : Pion.U32.shr x 8#u32 = ok ⟨x.bv >>> 8⟩ := by
  unfold Pion.U32.shr
  have h : (8#u32 : Std.U32).val < 32 := by decide
  simp only [h, ↓reduceIte]; rfl

private lemma bv32_signExtend_self (v : BitVec 32) : v.signExtend 32 = v := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  rw [BitVec.getLsbD_signExtend]
  simp [hi]

private lemma i32_band_255_to_u32_val (x : Std.I32) (hlo : 0 ≤ x.val) (hhi : x.val ≤ 255) :
    (Pion.I32.to_uint (Pion.I32.band x 255#i32)).val = x.val.toNat := by
  have hcond : (x.bv.toNat : Int) = x.val ∧ 2 * x.bv.toNat < 2 ^ 32 := by
    have h := x.bv.toInt_eq_toNat_cond
    change 0 ≤ x.bv.toInt at hlo
    split_ifs at h with hc
    · exact ⟨h.symm, hc⟩
    · have := x.bv.isLt; omega
  have hbv : (Pion.I32.to_uint (Pion.I32.band x 255#i32)).bv = (x.bv &&& 255#32).signExtend 32 := rfl
  change (Pion.I32.to_uint (Pion.I32.band x 255#i32)).bv.toNat = x.val.toNat
  rw [hbv, bv32_signExtend_self, BitVec.toNat_and]
  have h255 : (255#32 : BitVec 32).toNat = 2 ^ 8 - 1 := rfl
  rw [h255, Nat.and_two_pow_sub_one_eq_mod, Nat.mod_eq_of_lt (by omega)]
  omega

private lemma u32_band_255_to_i32_val (x : Std.U32) :
    (Pion.U32.to_int (Pion.U32.band x 255#u32)).val = ((x.val % 256 : Nat) : Int) := by
  set m := Pion.U32.band x 255#u32
  have hm_nat : m.bv.toNat = x.val % 256 := by
    change (x.bv &&& (255#32 : BitVec 32)).toNat = x.bv.toNat % 256
    rw [BitVec.toNat_and]
    have h255 : (255#32 : BitVec 32).toNat = 2 ^ 8 - 1 := rfl
    rw [h255, Nat.and_two_pow_sub_one_eq_mod]
  have hbv : (Pion.U32.to_int m).bv = m.bv.setWidth 32 := rfl
  have hnat : (Pion.U32.to_int m).bv.toNat = x.val % 256 := by
    rw [hbv, BitVec.setWidth_eq, hm_nat]
  have h := (Pion.U32.to_int m).bv.toInt_eq_toNat_cond
  change (Pion.U32.to_int m).bv.toInt = ((x.val % 256 : Nat) : Int)
  split_ifs at h with hc
  · rw [h, hnat]
  · change ¬ 2 * (Pion.U32.to_int m).bv.toNat < 2 ^ 32 at hc; omega

private lemma nat_or_low_high_u32 (a m k : Nat) (ha : a < 2 ^ k) :
    (m * 2 ^ k) ||| a = m * 2 ^ k + a := by
  apply Nat.eq_of_testBit_eq
  intro i
  rw [Nat.testBit_or]
  have hmul : (m * 2 ^ k).testBit i = if i < k then false else m.testBit (i - k) := by
    rw [← Nat.shiftLeft_eq, Nat.testBit_shiftLeft]
    by_cases hi : i < k
    · have hnot : ¬ (k ≤ i) := by omega
      simp [hi, hnot]
    · have hge : k ≤ i := by omega
      simp [hi, hge]
  rw [hmul]
  by_cases hi : i < k
  · simp only [hi, ↓reduceIte, Bool.false_or]
    rw [Nat.testBit_eq_decide_div_mod_eq, Nat.testBit_eq_decide_div_mod_eq]
    have hpow : 2 ^ k = 2 ^ (k - i) * 2 ^ i := by rw [← Nat.pow_add]; congr 1; omega
    have hpos : 0 < 2 ^ i := Nat.two_pow_pos i
    have hdiv : (m * 2 ^ k + a) / 2 ^ i = a / 2 ^ i + m * 2 ^ (k - i) := by
      rw [Nat.add_comm, hpow, ← Nat.mul_assoc, Nat.add_mul_div_right _ _ hpos]
    have heven : 2 ∣ 2 ^ (k - i) := by
      refine ⟨2 ^ (k - i - 1), ?_⟩
      conv => lhs; rw [show k - i = (k - i - 1) + 1 by omega, Nat.pow_succ, Nat.mul_comm]
    rcases heven with ⟨q, hq⟩
    rw [hdiv, hq]
    have hre : m * (2 * q) = 2 * (m * q) := by
      rw [← Nat.mul_assoc, Nat.mul_comm m 2, Nat.mul_assoc]
    rw [hre, Nat.add_mul_mod_self_left]
  · simp only [hi, ↓reduceIte]
    have hlt : a.testBit i = false := by
      apply Nat.testBit_lt_two_pow
      have hle : 2 ^ k ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) (by omega)
      omega
    rw [hlt, Bool.or_false, Nat.testBit_eq_decide_div_mod_eq, Nat.testBit_eq_decide_div_mod_eq]
    have hpow : 2 ^ i = 2 ^ k * 2 ^ (i - k) := by rw [← Nat.pow_add]; congr 1; omega
    have hposk : 0 < 2 ^ k := Nat.two_pow_pos k
    have hdiv1 : (m * 2 ^ k + a) / 2 ^ k = m := by
      rw [Nat.add_comm, Nat.add_mul_div_right _ _ hposk, Nat.div_eq_of_lt ha, Nat.zero_add]
    rw [hpow, ← Nat.div_div_eq_div_mul, hdiv1]

/-- Theorem 13: `Ipv4Addr.from_u32` and `Ipv4Addr.to_u32` form an exact identity roundtrip. -/
theorem ipv4_u32_roundtrip (u : Std.U32) :
    (do let ip ← Ipv4Addr.from_u32 u; Ipv4Addr.to_u32 ip) = ok u := by
  simp [Ipv4Addr.from_u32, Ipv4Addr.to_u32]

/-- Theorem 14: `Ipv4Addr.new` packs 4 octets in `[0, 255]` into the exact big-endian 32-bit value `a*2^24 + b*2^16 + c*2^8 + d`. -/
theorem ipv4_new_exact_u32 (a b c d : Std.I32)
    (ha : 0 ≤ a.val ∧ a.val ≤ 255) (hb : 0 ≤ b.val ∧ b.val ≤ 255)
    (hc : 0 ≤ c.val ∧ c.val ≤ 255) (hd : 0 ≤ d.val ∧ d.val ≤ 255) :
    ∃ ip : Ipv4Addr, Ipv4Addr.new a b c d = ok ip ∧
      ip.bits.val = a.val.toNat * 16777216 + b.val.toNat * 65536 + c.val.toNat * 256 + d.val.toNat := by
  unfold Ipv4Addr.new
  rw [u32_shl24_ok, result_bind_ok']
  rw [u32_shl16_ok, result_bind_ok']
  rw [u32_shl8_ok, result_bind_ok']
  set au := Pion.I32.to_uint (Pion.I32.band a 255#i32)
  set bu := Pion.I32.to_uint (Pion.I32.band b 255#i32)
  set cu := Pion.I32.to_uint (Pion.I32.band c 255#i32)
  set du := Pion.I32.to_uint (Pion.I32.band d 255#i32)
  have hau : au.val = a.val.toNat := i32_band_255_to_u32_val a ha.1 ha.2
  have hbu : bu.val = b.val.toNat := i32_band_255_to_u32_val b hb.1 hb.2
  have hcu : cu.val = c.val.toNat := i32_band_255_to_u32_val c hc.1 hc.2
  have hdu : du.val = d.val.toNat := i32_band_255_to_u32_val d hd.1 hd.2
  refine ⟨_, rfl, ?_⟩
  change (((((au.bv <<< 24) ||| (bu.bv <<< 16)) ||| (cu.bv <<< 8)) ||| du.bv).toNat) = _
  rw [BitVec.toNat_or, BitVec.toNat_or, BitVec.toNat_or,
      BitVec.toNat_shiftLeft, BitVec.toNat_shiftLeft, BitVec.toNat_shiftLeft,
      Nat.shiftLeft_eq, Nat.shiftLeft_eq, Nat.shiftLeft_eq]
  have hm1 : (au.bv.toNat * 2 ^ 24) % 2 ^ 32 = a.val.toNat * 16777216 := by
    change (au.val * 16777216) % 2 ^ 32 = _; rw [hau]; exact Nat.mod_eq_of_lt (by omega)
  have hm2 : (bu.bv.toNat * 2 ^ 16) % 2 ^ 32 = b.val.toNat * 65536 := by
    change (bu.val * 65536) % 2 ^ 32 = _; rw [hbu]; exact Nat.mod_eq_of_lt (by omega)
  have hm3 : (cu.bv.toNat * 2 ^ 8) % 2 ^ 32 = c.val.toNat * 256 := by
    change (cu.val * 256) % 2 ^ 32 = _; rw [hcu]; exact Nat.mod_eq_of_lt (by omega)
  have hdu' : du.bv.toNat = d.val.toNat := hdu
  rw [hm1, hm2, hm3, hdu']
  have s1 : (a.val.toNat * 16777216) ||| (b.val.toNat * 65536) = a.val.toNat * 16777216 + b.val.toNat * 65536 := by
    exact nat_or_low_high_u32 (b.val.toNat * 65536) a.val.toNat 24 (by omega)
  rw [s1]
  have s2 : (a.val.toNat * 16777216 + b.val.toNat * 65536) ||| (c.val.toNat * 256) =
            a.val.toNat * 16777216 + b.val.toNat * 65536 + c.val.toNat * 256 := by
    have hre : a.val.toNat * 16777216 + b.val.toNat * 65536 = (a.val.toNat * 256 + b.val.toNat) * 2 ^ 16 := by omega
    rw [hre]
    have := nat_or_low_high_u32 (c.val.toNat * 256) (a.val.toNat * 256 + b.val.toNat) 16 (by omega)
    omega
  rw [s2]
  have hre2 : a.val.toNat * 16777216 + b.val.toNat * 65536 + c.val.toNat * 256 =
              (a.val.toNat * 65536 + b.val.toNat * 256 + c.val.toNat) * 2 ^ 8 := by omega
  rw [hre2]
  have := nat_or_low_high_u32 d.val.toNat (a.val.toNat * 65536 + b.val.toNat * 256 + c.val.toNat) 8 (by omega)
  omega

/-- Theorem 15: `Ipv4Addr.new` followed by `Ipv4Addr.octets` is the exact identity on all `[0, 255]^4` tuples. -/
theorem ipv4_new_octets_roundtrip (a b c d : Std.I32)
    (ha : 0 ≤ a.val ∧ a.val ≤ 255) (hb : 0 ≤ b.val ∧ b.val ≤ 255)
    (hc : 0 ≤ c.val ∧ c.val ≤ 255) (hd : 0 ≤ d.val ∧ d.val ≤ 255) :
    (do let ip ← Ipv4Addr.new a b c d; Ipv4Addr.octets ip) = ok (a, b, c, d) := by
  obtain ⟨ip, hip, hbits⟩ := ipv4_new_exact_u32 a b c d ha hb hc hd
  rw [hip, result_bind_ok']
  unfold Ipv4Addr.octets
  rw [u32_shr24_ok, result_bind_ok']
  rw [u32_shr16_ok, result_bind_ok']
  rw [u32_shr8_ok, result_bind_ok']
  apply congrArg ok
  have hsh24 : (⟨ip.bits.bv >>> 24⟩ : Std.U32).val = ip.bits.val / 16777216 := by
    change (ip.bits.bv >>> 24).toNat = ip.bits.bv.toNat / 16777216
    rw [BitVec.toNat_ushiftRight, Nat.shiftRight_eq_div_pow]
  have hsh16 : (⟨ip.bits.bv >>> 16⟩ : Std.U32).val = ip.bits.val / 65536 := by
    change (ip.bits.bv >>> 16).toNat = ip.bits.bv.toNat / 65536
    rw [BitVec.toNat_ushiftRight, Nat.shiftRight_eq_div_pow]
  have hsh8 : (⟨ip.bits.bv >>> 8⟩ : Std.U32).val = ip.bits.val / 256 := by
    change (ip.bits.bv >>> 8).toNat = ip.bits.bv.toNat / 256
    rw [BitVec.toNat_ushiftRight, Nat.shiftRight_eq_div_pow]
  have ha' : Pion.U32.to_int (Pion.U32.band ⟨ip.bits.bv >>> 24⟩ 255#u32) = a := by
    apply IScalar.eq_of_val_eq
    rw [u32_band_255_to_i32_val, hsh24, hbits]; omega
  have hb' : Pion.U32.to_int (Pion.U32.band ⟨ip.bits.bv >>> 16⟩ 255#u32) = b := by
    apply IScalar.eq_of_val_eq
    rw [u32_band_255_to_i32_val, hsh16, hbits]; omega
  have hc' : Pion.U32.to_int (Pion.U32.band ⟨ip.bits.bv >>> 8⟩ 255#u32) = c := by
    apply IScalar.eq_of_val_eq
    rw [u32_band_255_to_i32_val, hsh8, hbits]; omega
  have hd' : Pion.U32.to_int (Pion.U32.band ip.bits 255#u32) = d := by
    apply IScalar.eq_of_val_eq
    rw [u32_band_255_to_i32_val, hbits]; omega
  rw [ha', hb', hc', hd']

/-- Theorem 16: `Ipv4Addr.octets` always returns four octets in `[0, 255]`. -/
theorem ipv4_octets_in_byte_range (ip : Ipv4Addr) :
    ∃ a b c d : Std.I32, Ipv4Addr.octets ip = ok (a, b, c, d) ∧
      0 ≤ a.val ∧ a.val ≤ 255 ∧ 0 ≤ b.val ∧ b.val ≤ 255 ∧
      0 ≤ c.val ∧ c.val ≤ 255 ∧ 0 ≤ d.val ∧ d.val ≤ 255 := by
  unfold Ipv4Addr.octets
  rw [u32_shr24_ok, result_bind_ok']
  rw [u32_shr16_ok, result_bind_ok']
  rw [u32_shr8_ok, result_bind_ok']
  refine ⟨_, _, _, _, rfl, ?_⟩
  have h1 := u32_band_255_to_i32_val ⟨ip.bits.bv >>> 24⟩
  have h2 := u32_band_255_to_i32_val ⟨ip.bits.bv >>> 16⟩
  have h3 := u32_band_255_to_i32_val ⟨ip.bits.bv >>> 8⟩
  have h4 := u32_band_255_to_i32_val ip.bits
  omega

/-- Theorem 17: `Ipv4Addr.octets` followed by `Ipv4Addr.new` is the exact identity on all `2^32` IPv4 addresses. -/
theorem ipv4_octets_new_roundtrip (ip : Ipv4Addr) :
    (do let (a, b, c, d) ← Ipv4Addr.octets ip; Ipv4Addr.new a b c d) = ok ip := by
  unfold Ipv4Addr.octets
  rw [u32_shr24_ok, result_bind_ok']
  rw [u32_shr16_ok, result_bind_ok']
  rw [u32_shr8_ok, result_bind_ok']
  rw [result_bind_ok']
  set a := Pion.U32.to_int (Pion.U32.band ⟨ip.bits.bv >>> 24⟩ 255#u32)
  set b := Pion.U32.to_int (Pion.U32.band ⟨ip.bits.bv >>> 16⟩ 255#u32)
  set c := Pion.U32.to_int (Pion.U32.band ⟨ip.bits.bv >>> 8⟩ 255#u32)
  set d := Pion.U32.to_int (Pion.U32.band ip.bits 255#u32)
  change Ipv4Addr.new a b c d = ok ip
  have ha : a.val = (((ip.bits.val / 16777216) % 256 : Nat) : Int) := by
    rw [u32_band_255_to_i32_val]
    have : (⟨ip.bits.bv >>> 24⟩ : Std.U32).val = ip.bits.val / 16777216 := by
      change (ip.bits.bv >>> 24).toNat = ip.bits.bv.toNat / 16777216
      rw [BitVec.toNat_ushiftRight, Nat.shiftRight_eq_div_pow]
    rw [this]
  have hb : b.val = (((ip.bits.val / 65536) % 256 : Nat) : Int) := by
    rw [u32_band_255_to_i32_val]
    have : (⟨ip.bits.bv >>> 16⟩ : Std.U32).val = ip.bits.val / 65536 := by
      change (ip.bits.bv >>> 16).toNat = ip.bits.bv.toNat / 65536
      rw [BitVec.toNat_ushiftRight, Nat.shiftRight_eq_div_pow]
    rw [this]
  have hc : c.val = (((ip.bits.val / 256) % 256 : Nat) : Int) := by
    rw [u32_band_255_to_i32_val]
    have : (⟨ip.bits.bv >>> 8⟩ : Std.U32).val = ip.bits.val / 256 := by
      change (ip.bits.bv >>> 8).toNat = ip.bits.bv.toNat / 256
      rw [BitVec.toNat_ushiftRight, Nat.shiftRight_eq_div_pow]
    rw [this]
  have hd : d.val = ((ip.bits.val % 256 : Nat) : Int) := u32_band_255_to_i32_val ip.bits
  obtain ⟨ip', hip', hbits'⟩ := ipv4_new_exact_u32 a b c d (by omega) (by omega) (by omega) (by omega)
  rw [hip']
  apply congrArg ok
  have hlt : ip.bits.val < 2 ^ 32 := ip.bits.bv.isLt
  have hbe : ip'.bits.val = ip.bits.val := by omega
  cases ip with | mk u1 =>
  cases ip' with | mk u2 =>
  congr 1
  exact UScalar.eq_of_val_eq hbe

/-- Theorem 18: `Ipv4Addr.eq` decides exact structural equality on `Ipv4Addr`. -/
theorem ipv4_eq_iff (x y : Ipv4Addr) :
    Ipv4Addr.eq x y = ok true ↔ x = y := by
  unfold Ipv4Addr.eq
  simp only [ok.injEq, beq_iff_eq]
  cases x; cases y; simp

private lemma i32_band_65535_bounds (x : Std.I32) :
    0 ≤ (Pion.I32.band x 65535#i32).val ∧ (Pion.I32.band x 65535#i32).val ≤ 65535 := by
  set r := Pion.I32.band x 65535#i32
  have hnat : r.bv.toNat ≤ 65535 := by
    change (x.bv &&& (65535#32 : BitVec 32)).toNat ≤ 65535
    rw [BitVec.toNat_and]
    have h65535 : (65535#32 : BitVec 32).toNat = 65535 := rfl
    rw [h65535]
    exact Nat.and_le_right
  have h := r.bv.toInt_eq_toNat_cond
  change 0 ≤ r.bv.toInt ∧ r.bv.toInt ≤ 65535
  split_ifs at h with hc
  · omega
  · change ¬ 2 * r.bv.toNat < 2 ^ 32 at hc; omega

private lemma i32_band_65535_id (x : Std.I32) (hlo : 0 ≤ x.val) (hhi : x.val ≤ 65535) :
    Pion.I32.band x 65535#i32 = x := by
  have hcond : (x.bv.toNat : Int) = x.val ∧ 2 * x.bv.toNat < 2 ^ 32 := by
    have h := x.bv.toInt_eq_toNat_cond
    change 0 ≤ x.bv.toInt at hlo
    split_ifs at h with hc
    · exact ⟨h.symm, hc⟩
    · have := x.bv.isLt; omega
  set r := Pion.I32.band x 65535#i32
  have hnat : r.bv.toNat = x.bv.toNat := by
    change (x.bv &&& (65535#32 : BitVec 32)).toNat = x.bv.toNat
    rw [BitVec.toNat_and]
    have h65535 : (65535#32 : BitVec 32).toNat = 2 ^ 16 - 1 := rfl
    rw [h65535, Nat.and_two_pow_sub_one_eq_mod, Nat.mod_eq_of_lt (by omega)]
  apply IScalar.eq_of_val_eq
  have h := r.bv.toInt_eq_toNat_cond
  change r.bv.toInt = x.val
  split_ifs at h with hc
  · rw [h, hnat]; omega
  · change ¬ 2 * r.bv.toNat < 2 ^ 32 at hc; omega

/-- Theorem 19: `Ipv6Addr.new` masks every segment into the exact 16-bit range `[0, 65535]`. -/
theorem ipv6_new_segments_in_u16_range (s0 s1 s2 s3 s4 s5 s6 s7 : Std.I32) :
    ∃ ip : Ipv6Addr, Ipv6Addr.new s0 s1 s2 s3 s4 s5 s6 s7 = ok ip ∧
      (0 ≤ ip.s0.val ∧ ip.s0.val ≤ 65535) ∧ (0 ≤ ip.s1.val ∧ ip.s1.val ≤ 65535) ∧
      (0 ≤ ip.s2.val ∧ ip.s2.val ≤ 65535) ∧ (0 ≤ ip.s3.val ∧ ip.s3.val ≤ 65535) ∧
      (0 ≤ ip.s4.val ∧ ip.s4.val ≤ 65535) ∧ (0 ≤ ip.s5.val ∧ ip.s5.val ≤ 65535) ∧
      (0 ≤ ip.s6.val ∧ ip.s6.val ≤ 65535) ∧ (0 ≤ ip.s7.val ∧ ip.s7.val ≤ 65535) := by
  unfold Ipv6Addr.new
  exact ⟨_, rfl, i32_band_65535_bounds s0, i32_band_65535_bounds s1,
         i32_band_65535_bounds s2, i32_band_65535_bounds s3,
         i32_band_65535_bounds s4, i32_band_65535_bounds s5,
         i32_band_65535_bounds s6, i32_band_65535_bounds s7⟩

/-- Theorem 20: `Ipv6Addr.new` preserves all eight segments unchanged when already in `[0, 65535]`. -/
theorem ipv6_new_idempotent_on_u16 (s0 s1 s2 s3 s4 s5 s6 s7 : Std.I32)
    (h0 : 0 ≤ s0.val ∧ s0.val ≤ 65535) (h1 : 0 ≤ s1.val ∧ s1.val ≤ 65535)
    (h2 : 0 ≤ s2.val ∧ s2.val ≤ 65535) (h3 : 0 ≤ s3.val ∧ s3.val ≤ 65535)
    (h4 : 0 ≤ s4.val ∧ s4.val ≤ 65535) (h5 : 0 ≤ s5.val ∧ s5.val ≤ 65535)
    (h6 : 0 ≤ s6.val ∧ s6.val ≤ 65535) (h7 : 0 ≤ s7.val ∧ s7.val ≤ 65535) :
    Ipv6Addr.new s0 s1 s2 s3 s4 s5 s6 s7 = ok (Ipv6Addr.mk s0 s1 s2 s3 s4 s5 s6 s7) := by
  unfold Ipv6Addr.new
  rw [i32_band_65535_id s0 h0.1 h0.2, i32_band_65535_id s1 h1.1 h1.2,
      i32_band_65535_id s2 h2.1 h2.2, i32_band_65535_id s3 h3.1 h3.2,
      i32_band_65535_id s4 h4.1 h4.2, i32_band_65535_id s5 h5.1 h5.2,
      i32_band_65535_id s6 h6.1 h6.2, i32_band_65535_id s7 h7.1 h7.2]

/-- Theorem 21: `ipv6_seg` extracts each of the 8 segments `0..7` exactly. -/
theorem ipv6_seg_exact (ip : Ipv6Addr) :
    ipv6_seg ip 0#i32 = ok ip.s0 ∧ ipv6_seg ip 1#i32 = ok ip.s1 ∧
    ipv6_seg ip 2#i32 = ok ip.s2 ∧ ipv6_seg ip 3#i32 = ok ip.s3 ∧
    ipv6_seg ip 4#i32 = ok ip.s4 ∧ ipv6_seg ip 5#i32 = ok ip.s5 ∧
    ipv6_seg ip 6#i32 = ok ip.s6 ∧ ipv6_seg ip 7#i32 = ok ip.s7 := by
  refine ⟨rfl, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> simp [ipv6_seg]

/-- Theorem 22: Indexing any segment of a constructed `Ipv6Addr` always succeeds with a 16-bit value `[0, 65535]`. -/
theorem ipv6_seg_new_bounds (s0 s1 s2 s3 s4 s5 s6 s7 idx : Std.I32) :
    ∃ v : Std.I32, (do let ip ← Ipv6Addr.new s0 s1 s2 s3 s4 s5 s6 s7; ipv6_seg ip idx) = ok v ∧
      0 ≤ v.val ∧ v.val ≤ 65535 := by
  obtain ⟨ip, hip, h0, h1, h2, h3, h4, h5, h6, h7⟩ := ipv6_new_segments_in_u16_range s0 s1 s2 s3 s4 s5 s6 s7
  rw [hip, result_bind_ok']
  unfold ipv6_seg
  split_ifs
  · exact ⟨ip.s0, rfl, h0⟩
  · exact ⟨ip.s1, rfl, h1⟩
  · exact ⟨ip.s2, rfl, h2⟩
  · exact ⟨ip.s3, rfl, h3⟩
  · exact ⟨ip.s4, rfl, h4⟩
  · exact ⟨ip.s5, rfl, h5⟩
  · exact ⟨ip.s6, rfl, h6⟩
  · exact ⟨ip.s7, rfl, h7⟩

/-- Theorem 23: `Ipv6Addr.eq` decides exact structural equality on `Ipv6Addr`. -/
theorem ipv6_eq_iff (x y : Ipv6Addr) :
    Ipv6Addr.eq x y = ok true ↔ x = y := by
  unfold Ipv6Addr.eq
  simp only [ok.injEq, Bool.and_eq_true, beq_iff_eq]
  cases x; cases y
  constructor
  · intro ⟨⟨⟨⟨⟨⟨⟨h0, h1⟩, h2⟩, h3⟩, h4⟩, h5⟩, h6⟩, h7⟩
    subst h0 h1 h2 h3 h4 h5 h6 h7; rfl
  · intro h; injection h with h0 h1 h2 h3 h4 h5 h6 h7
    exact ⟨⟨⟨⟨⟨⟨⟨h0, h1⟩, h2⟩, h3⟩, h4⟩, h5⟩, h6⟩, h7⟩

private lemma i32_beq_comm (a b : Std.I32) : (a == b) = (b == a) := by
  cases h : (a == b)
  · have hne : a ≠ b := beq_eq_false_iff_ne.mp h
    exact (beq_false_of_ne hne.symm).symm
  · have heq : a = b := beq_iff_eq.mp h
    subst heq; simp

/-- Theorem 24: `Ipv6Addr.eq` is reflexive and symmetric. -/
theorem ipv6_eq_refl_symm (x y : Ipv6Addr) :
    Ipv6Addr.eq x x = ok true ∧ Ipv6Addr.eq x y = Ipv6Addr.eq y x := by
  constructor
  · exact (ipv6_eq_iff x x).mpr rfl
  · unfold Ipv6Addr.eq
    apply congrArg ok
    rw [i32_beq_comm x.s0 y.s0, i32_beq_comm x.s1 y.s1, i32_beq_comm x.s2 y.s2, i32_beq_comm x.s3 y.s3,
        i32_beq_comm x.s4 y.s4, i32_beq_comm x.s5 y.s5, i32_beq_comm x.s6 y.s6, i32_beq_comm x.s7 y.s7]

end UrlProofs
