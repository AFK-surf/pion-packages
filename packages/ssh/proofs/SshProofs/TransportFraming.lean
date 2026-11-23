import Aeneas
import PionLean
import Ssh.Types
import Ssh.Funs

open Aeneas Aeneas.Std Result Pion ssh

namespace SshProofs

private lemma result_ok_inj {α : Type} {a b : α} (h : (ok a : Result α) = ok b) : a = b := by
  simpa using h

private lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by
  simp

private lemma i32_add_val_of_bounds (a b : I32)
    (hlo : -2147483648 ≤ a.val + b.val) (hhi : a.val + b.val ≤ 2147483647) :
    (Pion.I32.add a b).val = a.val + b.val := by
  have hwrap : (Pion.I32.add a b).val = Int.bmod (a.val + b.val) (2 ^ 32) := by
    change (I32.wrapping_add a b).val = Int.bmod (a.val + b.val) (2 ^ 32)
    simp only [I32.wrapping_add, IScalar.wrapping_add, IScalar.val, BitVec.toInt_add]
    rfl
  rw [hwrap]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_sub_val_of_bounds (a b : I32)
    (hlo : -2147483648 ≤ a.val - b.val) (hhi : a.val - b.val ≤ 2147483647) :
    (Pion.I32.sub a b).val = a.val - b.val := by
  have hwrap : (Pion.I32.sub a b).val = Int.bmod (a.val - b.val) (2 ^ 32) := by
    change (I32.wrapping_sub a b).val = Int.bmod (a.val - b.val) (2 ^ 32)
    simp only [I32.wrapping_sub, IScalar.wrapping_sub, IScalar.val, BitVec.toInt_sub]
    rfl
  rw [hwrap]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_mul_val_of_bounds (a b : I32)
    (hlo : -2147483648 ≤ a.val * b.val) (hhi : a.val * b.val ≤ 2147483647) :
    (Pion.I32.mul a b).val = a.val * b.val := by
  have hwrap : (Pion.I32.mul a b).val = Int.bmod (a.val * b.val) (2 ^ 32) := by
    change (I32.wrapping_mul a b).val = Int.bmod (a.val * b.val) (2 ^ 32)
    simp only [I32.wrapping_mul, IScalar.wrapping_mul, IScalar.val, BitVec.toInt_mul]
    rfl
  rw [hwrap]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_rem_nonneg_ok (x d : I32) (hx : 0 ≤ x.val) (hd : 0 < d.val) :
    ∃ r, Pion.I32.rem x d = ok r ∧ r.val = x.val % d.val := by
  have hspec := Pion.I32.rem_spec (x := x) (y := d) (by omega) (by omega)
  have hok : Pion.I32.rem x d = ok (⟨BitVec.srem x.bv d.bv⟩ : I32) := by
    unfold Pion.I32.rem
    have h1 : ¬(x.val = -2147483648 ∧ d.val = -1) := by omega
    simp only [h1, ↓reduceIte]
    change IScalar.rem x d = _
    unfold IScalar.rem
    have h2 : (d.val != 0) = true := bne_iff_ne.mpr (by omega)
    simp only [h2, ↓reduceIte]
  rw [hok] at hspec
  simp only [WP.spec_ok] at hspec
  rw [Int.tmod_eq_emod_of_nonneg hx] at hspec
  exact ⟨⟨BitVec.srem x.bv d.bv⟩, hok, hspec⟩

private lemma i32_div_nonneg_ok (x d : I32) (hx : 0 ≤ x.val) (hd : 0 < d.val) :
    ∃ q, Pion.I32.div x d = ok q ∧ q.val = x.val / d.val := by
  have hspec := Pion.I32.div_spec (x := x) (y := d) (by omega) (by omega)
  have hok : Pion.I32.div x d = ok (⟨BitVec.sdiv x.bv d.bv⟩ : I32) := by
    change IScalar.div x d = _
    unfold IScalar.div
    have h2 : (d.val != 0) = true := bne_iff_ne.mpr (by omega)
    have h3 : ¬(x.val = IScalar.min .I32 && d.val = -1) := by
      simp [show d.val ≠ -1 by omega]
    simp only [h2, h3, Bool.false_eq_true, not_false_eq_true, ↓reduceIte]
  rw [hok] at hspec
  simp only [WP.spec_ok] at hspec
  rw [Int.tdiv_eq_ediv_of_nonneg hx] at hspec
  exact ⟨⟨BitVec.sdiv x.bv d.bv⟩, hok, hspec⟩

private lemma i32_to_uint_val_of_nonneg (x : I32) (hx : 0 ≤ x.val) :
    ((Pion.I32.to_uint x).val : Int) = x.val := by
  have hbv : (Pion.I32.to_uint x).bv = x.bv := by
    change x.bv.signExtend 32 = x.bv
    exact BitVec.signExtend_eq x.bv
  have hval : (Pion.I32.to_uint x).val = x.bv.toNat := by
    change (Pion.I32.to_uint x).bv.toNat = x.bv.toNat
    rw [hbv]
  rw [hval]
  have htoInt : x.val = x.bv.toInt := rfl
  rw [BitVec.toInt_eq_toNat_cond] at htoInt
  split_ifs at htoInt with h
  · omega
  · have := x.bv.isLt; omega

private lemma u32_to_int_val_of_lt (u : U32) (hu : u.val < 2 ^ 31) :
    (Pion.U32.to_int u).val = (u.val : Int) := by
  have hbv : (Pion.U32.to_int u).bv = u.bv := by
    change BitVec.setWidth 32 u.bv = u.bv
    exact BitVec.setWidth_eq u.bv
  change (Pion.U32.to_int u).bv.toInt = (u.val : Int)
  rw [hbv, BitVec.toInt_eq_toNat_cond]
  have hlt : 2 * u.bv.toNat < 2 ^ 32 := by change 2 * u.val < 2 ^ 32; omega
  simp only [hlt, ↓reduceIte]
  rfl

/-- Theorem 3: `ssh_packet_padding_len` computes minimal RFC 4253 §6 padding satisfying `pad ≥ max(4, min_padding)`, `(5 + plen + pad) % max(8, block_size) = 0`, and `pad < max(4, min_padding) + max(8, block_size)`. -/
theorem ssh_packet_padding_len_spec (plen block_size min_padding : I32)
    (hplen0 : 0 ≤ plen.val) (hplen_hi : plen.val ≤ 1000000000)
    (hbs_hi : block_size.val ≤ 128) (hmp_hi : min_padding.val ≤ 128) :
    let eff_bs : Int := if block_size.val < 8 then 8 else block_size.val
    let eff_mp : Int := if min_padding.val < 4 then 4 else min_padding.val
    ∃ pad, ssh_packet_padding_len plen block_size min_padding = ok pad ∧
      eff_mp ≤ pad.val ∧
      pad.val < eff_mp + eff_bs ∧
      (5 + plen.val + pad.val) % eff_bs = 0 := by
  dsimp only
  unfold ssh_packet_padding_len
  dsimp only
  set bs : I32 := if block_size < 8#i32 then 8#i32 else block_size
  set min_pad : I32 := if min_padding < 4#i32 then 4#i32 else min_padding
  have hbs_val : bs.val = if block_size.val < 8 then 8 else block_size.val := by
    by_cases h : block_size < 8#i32
    · have h' : block_size.val < 8 := h
      simp [bs, h, h']
    · have h' : ¬(block_size.val < 8) := h
      simp [bs, h, h']
  have hmp_val : min_pad.val = if min_padding.val < 4 then 4 else min_padding.val := by
    by_cases h : min_padding < 4#i32
    · have h' : min_padding.val < 4 := h
      simp [min_pad, h, h']
    · have h' : ¬(min_padding.val < 4) := h
      simp [min_pad, h, h']
  have hbs_lo : 8 ≤ bs.val := by rw [hbs_val]; split_ifs <;> omega
  have hbs_ub : bs.val ≤ 128 := by rw [hbs_val]; split_ifs <;> omega
  have hmp_lo : 4 ≤ min_pad.val := by rw [hmp_val]; split_ifs <;> omega
  have hmp_ub : min_pad.val ≤ 128 := by rw [hmp_val]; split_ifs <;> omega
  have c5 : (5#i32 : I32).val = 5 := rfl
  have c1 : (1#i32 : I32).val = 1 := rfl
  have hbase := i32_add_val_of_bounds 5#i32 plen (by omega) (by omega)
  rcases i32_rem_nonneg_ok (Pion.I32.add 5#i32 plen) bs (by omega) (by omega) with ⟨rem, hrem, hremv⟩
  rw [hrem, result_bind_ok]
  rw [hbase, c5] at hremv
  have hrem_lo : 0 ≤ rem.val := by rw [hremv]; exact Int.emod_nonneg _ (by omega)
  have hrem_hi : rem.val < bs.val := by rw [hremv]; exact Int.emod_lt_of_pos _ (by omega)
  have hpad0 := i32_sub_val_of_bounds bs rem (by omega) (by omega)
  have hmod0 : (5 + plen.val + (Pion.I32.sub bs rem).val) % bs.val = 0 := by
    rw [hpad0, hremv]
    have hdm := Int.mul_ediv_add_emod (5 + plen.val) bs.val
    have hsum : 5 + plen.val + (bs.val - (5 + plen.val) % bs.val) = ((5 + plen.val) / bs.val + 1) * bs.val := by
      have : ((5 + plen.val) / bs.val + 1) * bs.val = bs.val * ((5 + plen.val) / bs.val) + bs.val := by
        rw [Int.add_mul, Int.one_mul, Int.mul_comm]
      omega
    rw [hsum, Int.mul_emod_left]
  by_cases hlt : Pion.I32.sub bs rem < min_pad
  · simp only [hlt, ↓reduceIte]
    have hltv : (Pion.I32.sub bs rem).val < min_pad.val := hlt
    have hdef := i32_sub_val_of_bounds min_pad (Pion.I32.sub bs rem) (by omega) (by omega)
    have hnum1 := i32_add_val_of_bounds (Pion.I32.sub min_pad (Pion.I32.sub bs rem)) bs (by omega) (by omega)
    have hnum2 := i32_sub_val_of_bounds (Pion.I32.add (Pion.I32.sub min_pad (Pion.I32.sub bs rem)) bs) 1#i32 (by omega) (by omega)
    rcases i32_div_nonneg_ok (Pion.I32.sub (Pion.I32.add (Pion.I32.sub min_pad (Pion.I32.sub bs rem)) bs) 1#i32) bs (by omega) (by omega) with ⟨eb, heb, hebv⟩
    rw [heb, result_bind_ok]
    rw [hnum2, hnum1, hdef, c1] at hebv
    have hdm := Int.mul_ediv_add_emod (min_pad.val - (Pion.I32.sub bs rem).val + bs.val - 1) bs.val
    rw [← hebv] at hdm
    have hrm_lo : 0 ≤ (min_pad.val - (Pion.I32.sub bs rem).val + bs.val - 1) % bs.val := Int.emod_nonneg _ (by omega)
    have hrm_hi : (min_pad.val - (Pion.I32.sub bs rem).val + bs.val - 1) % bs.val < bs.val := Int.emod_lt_of_pos _ (by omega)
    have hmc : eb.val * bs.val = bs.val * eb.val := Int.mul_comm _ _
    have hmul := i32_mul_val_of_bounds eb bs (by omega) (by omega)
    have hpad1 := i32_add_val_of_bounds (Pion.I32.sub bs rem) (Pion.I32.mul eb bs) (by omega) (by omega)
    refine ⟨Pion.I32.add (Pion.I32.sub bs rem) (Pion.I32.mul eb bs), rfl, ?_, ?_, ?_⟩
    · rw [← hmp_val]; omega
    · rw [← hmp_val, ← hbs_val]; omega
    · rw [← hbs_val, hpad1, hmul]
      have hre : 5 + plen.val + ((Pion.I32.sub bs rem).val + eb.val * bs.val) =
          (5 + plen.val + (Pion.I32.sub bs rem).val) + eb.val * bs.val := by omega
      rw [hre, Int.add_emod, hmod0, Int.mul_emod_left]
      simp
  · simp only [hlt, ↓reduceIte]
    have hgev : min_pad.val ≤ (Pion.I32.sub bs rem).val := by
      change ¬((Pion.I32.sub bs rem).val < min_pad.val) at hlt; omega
    refine ⟨Pion.I32.sub bs rem, rfl, ?_, ?_, ?_⟩
    · rw [← hmp_val]; exact hgev
    · rw [← hmp_val, ← hbs_val]; omega
    · rw [← hbs_val]; exact hmod0

/-- Theorem 4: For standard SSH block sizes `8 ≤ bs ≤ 64` and `min_padding = 4`, `ssh_packet_padding_len` fits in a single byte (`4 ≤ pad ≤ 255`). -/
theorem ssh_packet_padding_len_u8_bound (plen block_size : I32)
    (hplen0 : 0 ≤ plen.val) (hplen_hi : plen.val ≤ 1000000000)
    (hbs_lo : 8 ≤ block_size.val) (hbs_hi : block_size.val ≤ 64) :
    ∃ pad, ssh_packet_padding_len plen block_size 4#i32 = ok pad ∧
      4 ≤ pad.val ∧ pad.val ≤ 255 := by
  have c4 : (4#i32 : I32).val = 4 := rfl
  rcases ssh_packet_padding_len_spec plen block_size 4#i32 hplen0 hplen_hi (by omega) (by omega) with
    ⟨pad, hpad, hlo, hhi, _⟩
  simp only [show ¬(block_size.val < 8) by omega, show ¬((4#i32 : I32).val < 4) by omega, ↓reduceIte] at hlo hhi
  exact ⟨pad, hpad, by omega, by omega⟩

/-- Theorem 6: `ssh_packet_header_err_code` returns `0` iff all RFC 4253 §6 length, alignment, and padding invariants hold. -/
theorem ssh_packet_header_err_code_valid_iff (n : I32) (pkt_len_u : U32) (pad_len max_packet_len : I32)
    (hmax0 : 0 ≤ max_packet_len.val) (hmax_hi : max_packet_len.val ≤ 1000000000) :
    ssh_packet_header_err_code n pkt_len_u pad_len max_packet_len = ok 0#i32 ↔
      ((pkt_len_u.val : Int) ≤ max_packet_len.val ∧
       5 ≤ (pkt_len_u.val : Int) ∧
       4 + (pkt_len_u.val : Int) ≤ n.val ∧
       (4 + (pkt_len_u.val : Int)) % 8 = 0 ∧
       4 ≤ pad_len.val ∧
       pad_len.val < (pkt_len_u.val : Int)) := by
  unfold ssh_packet_header_err_code
  have hmaxu := i32_to_uint_val_of_nonneg max_packet_len hmax0
  by_cases h1 : pkt_len_u > Pion.I32.to_uint max_packet_len
  · simp only [h1, ↓reduceIte]
    have hgt : (Pion.I32.to_uint max_packet_len).val < pkt_len_u.val := h1
    constructor
    · intro h; exact absurd (result_ok_inj h) (by decide)
    · intro ⟨hle, _⟩; omega
  · simp only [h1, ↓reduceIte]
    have hle_max : (pkt_len_u.val : Int) ≤ max_packet_len.val := by
      have : ¬((Pion.I32.to_uint max_packet_len).val < pkt_len_u.val) := h1; omega
    have hpkt := u32_to_int_val_of_lt pkt_len_u (by omega)
    by_cases h2 : Pion.U32.to_int pkt_len_u < 5#i32
    · simp only [h2, ↓reduceIte]
      have hlt5 : (Pion.U32.to_int pkt_len_u).val < 5 := h2
      constructor
      · intro h; exact absurd (result_ok_inj h) (by decide)
      · intro ⟨_, h5, _⟩; omega
    · simp only [h2, ↓reduceIte]
      have hge5 : 5 ≤ (pkt_len_u.val : Int) := by
        have : ¬((Pion.U32.to_int pkt_len_u).val < 5) := h2; omega
      have c4 : (4#i32 : I32).val = 4 := rfl
      have c8 : (8#i32 : I32).val = 8 := rfl
      have htot := i32_add_val_of_bounds 4#i32 (Pion.U32.to_int pkt_len_u) (by omega) (by omega)
      by_cases h3 : n < Pion.I32.add 4#i32 (Pion.U32.to_int pkt_len_u)
      · simp only [h3, ↓reduceIte]
        have hnlt : n.val < (Pion.I32.add 4#i32 (Pion.U32.to_int pkt_len_u)).val := h3
        constructor
        · intro h; exact absurd (result_ok_inj h) (by decide)
        · intro ⟨_, _, hnle, _⟩; omega
      · simp only [h3, ↓reduceIte]
        have hnle : 4 + (pkt_len_u.val : Int) ≤ n.val := by
          have : ¬(n.val < (Pion.I32.add 4#i32 (Pion.U32.to_int pkt_len_u)).val) := h3; omega
        rcases i32_rem_nonneg_ok (Pion.I32.add 4#i32 (Pion.U32.to_int pkt_len_u)) 8#i32 (by omega) (by omega) with ⟨rem, hrem, hremv⟩
        rw [hrem, result_bind_ok]
        rw [htot, hpkt, c4, c8] at hremv
        split_ifs with h4 h5 h6
        · have hne0 : rem.val ≠ 0 := fun hv => h4 (IScalar.eq_of_val_eq hv)
          constructor
          · intro h; exact absurd (result_ok_inj h) (by decide)
          · intro ⟨_, _, _, hmod8, _⟩; omega
        · have hp4 : pad_len.val < 4 := h5
          constructor
          · intro h; exact absurd (result_ok_inj h) (by decide)
          · intro ⟨_, _, _, _, hge4, _⟩; omega
        · have hpge : (Pion.U32.to_int pkt_len_u).val ≤ pad_len.val := h6
          constructor
          · intro h; exact absurd (result_ok_inj h) (by decide)
          · intro ⟨_, _, _, _, _, hplt⟩; omega
        · have heq0 : rem.val = 0 := by
            have : rem = 0#i32 := Classical.byContradiction h4
            rw [this]; rfl
          have hge4 : 4 ≤ pad_len.val := by
            have : ¬(pad_len.val < 4) := h5; omega
          have hplt : pad_len.val < (pkt_len_u.val : Int) := by
            have : ¬((Pion.U32.to_int pkt_len_u).val ≤ pad_len.val) := h6; omega
          exact ⟨fun _ => ⟨hle_max, hge5, hnle, by omega, hge4, hplt⟩, fun _ => rfl⟩

/-- Theorem 9: End-to-end RFC 4253 §6 framing round-trip: every packet padded by `ssh_packet_padding_len` (for `plen ≤ 34000`, `8 ∣ bs`, `8 ≤ bs ≤ 64`, `min_pad = 4`) is accepted by `ssh_packet_header_err_code` and recovers exact `plen`. -/
theorem ssh_packet_encode_decode_framing_roundtrip (plen block_size : I32)
    (hplen0 : 0 ≤ plen.val) (hplen_hi : plen.val ≤ 34000)
    (hbs_lo : 8 ≤ block_size.val) (hbs_hi : block_size.val ≤ 64)
    (hdvd8 : block_size.val % 8 = 0) :
    ∃ pad, ssh_packet_padding_len plen block_size 4#i32 = ok pad ∧
      let pkt_len : I32 := Pion.I32.add (Pion.I32.add 1#i32 plen) pad
      let total : I32 := Pion.I32.add 4#i32 pkt_len
      4 ≤ pad.val ∧ pad.val ≤ 255 ∧
      ssh_packet_header_err_code total (Pion.I32.to_uint pkt_len) pad 35000#i32 = ok 0#i32 ∧
      pkt_len.val - 1 - pad.val = plen.val := by
  have c1 : (1#i32 : I32).val = 1 := rfl
  have c4 : (4#i32 : I32).val = 4 := rfl
  have c35000 : (35000#i32 : I32).val = 35000 := rfl
  rcases ssh_packet_padding_len_spec plen block_size 4#i32 hplen0 (by omega) (by omega) (by omega) with
    ⟨pad, hpad, hlo, hhi, hmod⟩
  simp only [show ¬(block_size.val < 8) by omega, show ¬((4#i32 : I32).val < 4) by omega, ↓reduceIte] at hlo hhi hmod
  have halign8 : (5 + plen.val + pad.val) % 8 = 0 := by
    have h1 : block_size.val ∣ (5 + plen.val + pad.val) := Int.dvd_of_emod_eq_zero hmod
    have h2 : (8 : Int) ∣ block_size.val := Int.dvd_of_emod_eq_zero hdvd8
    exact Int.emod_eq_zero_of_dvd (Int.dvd_trans h2 h1)
  have h1p := i32_add_val_of_bounds 1#i32 plen (by omega) (by omega)
  have hpkt := i32_add_val_of_bounds (Pion.I32.add 1#i32 plen) pad (by omega) (by omega)
  have htot := i32_add_val_of_bounds 4#i32 (Pion.I32.add (Pion.I32.add 1#i32 plen) pad) (by omega) (by omega)
  have hu := i32_to_uint_val_of_nonneg (Pion.I32.add (Pion.I32.add 1#i32 plen) pad) (by omega)
  refine ⟨pad, hpad, by omega, by omega, ?_, by omega⟩
  rw [ssh_packet_header_err_code_valid_iff _ _ _ _ (by decide) (by decide)]
  refine ⟨by omega, by omega, by omega, ?_, by omega, by omega⟩
  have heq : 4 + ((Pion.I32.to_uint (Pion.I32.add (Pion.I32.add 1#i32 plen) pad)).val : Int) = 5 + plen.val + pad.val := by omega
  rw [heq]
  exact halign8

end SshProofs
