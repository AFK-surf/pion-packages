import Aeneas
import PionLean
import Mqtt.Types
import Mqtt.Funs

open Aeneas Aeneas.Std Result Pion mqtt

namespace MqttProofs

private lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by simp

private lemma i32_bv_toNat_of_nonneg (x : Std.I32) (h0 : 0 ≤ x.val) :
    (x.bv.toNat : Int) = x.val := by
  have h := x.bv.toInt_eq_toNat_cond
  change 0 ≤ x.bv.toInt at h0
  split_ifs at h with hcond
  · exact h.symm
  · have := x.bv.isLt; omega

private lemma i32_val_of_bv_toNat_lt (x : Std.I32) (hlt : x.bv.toNat < 2 ^ 31) :
    x.val = (x.bv.toNat : Int) := by
  have h := x.bv.toInt_eq_toNat_cond
  have h2 : 2 * x.bv.toNat < 2 ^ 32 := by omega
  simp only [h2, ↓reduceIte] at h
  exact h

private lemma i32_band_127_nonneg (x : Std.I32) (hx : 0 ≤ x.val) :
    (Pion.I32.band x 127#i32).val = x.val % 128 ∧
    (Pion.I32.band x 127#i32).bv.toNat = x.bv.toNat % 128 := by
  have hxnat : (x.bv.toNat : Int) = x.val := i32_bv_toNat_of_nonneg x hx
  set r := Pion.I32.band x 127#i32
  have hrnat : r.bv.toNat = x.bv.toNat % 128 := by
    change (x.bv &&& (127#32 : BitVec 32)).toNat = x.bv.toNat % 128
    rw [BitVec.toNat_and]
    have h127 : (127#32 : BitVec 32).toNat = 2 ^ 7 - 1 := rfl
    rw [h127, Nat.and_two_pow_sub_one_eq_mod]
  have hrval : r.val = (r.bv.toNat : Int) := i32_val_of_bv_toNat_lt r (by rw [hrnat]; omega)
  exact ⟨by omega, hrnat⟩

private lemma i32_shl_nonneg (x : Std.I32) (k : Std.I32)
    (hk0 : 0 ≤ k.val) (hk31 : k.val < 32)
    (hfit : x.bv.toNat * 2 ^ k.bv.toNat < 2 ^ 31) :
    ∃ r : Std.I32, Pion.I32.shl x k = ok r ∧
      r.bv.toNat = x.bv.toNat * 2 ^ k.bv.toNat := by
  have hk_nat : (k.bv.toNat : Int) = k.val := i32_bv_toNat_of_nonneg k hk0
  have hknat_eq : k.val.toNat = k.bv.toNat := by omega
  have hshl : Pion.I32.shl x k = ok ⟨x.bv <<< k.bv.toNat⟩ := by
    unfold Pion.I32.shl
    simp only [hk0, hk31, and_self, ↓reduceIte, hknat_eq]
  refine ⟨⟨x.bv <<< k.bv.toNat⟩, hshl, ?_⟩
  rw [BitVec.toNat_shiftLeft, Nat.shiftLeft_eq]
  exact Nat.mod_eq_of_lt (by omega)

private lemma nat_or_low_high (a m k : Nat) (ha : a < 2 ^ k) :
    a ||| (m * 2 ^ k) = a + m * 2 ^ k := by
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
  · simp only [hi, ↓reduceIte, Bool.or_false]
    rw [Nat.testBit_eq_decide_div_mod_eq, Nat.testBit_eq_decide_div_mod_eq]
    have hpow : 2 ^ k = 2 ^ (k - i) * 2 ^ i := by rw [← Nat.pow_add]; congr 1; omega
    have hpos : 0 < 2 ^ i := Nat.two_pow_pos i
    have hdiv : (a + m * 2 ^ k) / 2 ^ i = a / 2 ^ i + m * 2 ^ (k - i) := by
      rw [hpow, ← Nat.mul_assoc, Nat.add_mul_div_right _ _ hpos]
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
    rw [hlt, Bool.false_or, Nat.testBit_eq_decide_div_mod_eq, Nat.testBit_eq_decide_div_mod_eq]
    have hpow : 2 ^ i = 2 ^ k * 2 ^ (i - k) := by rw [← Nat.pow_add]; congr 1; omega
    have hposk : 0 < 2 ^ k := Nat.two_pow_pos k
    have hdiv1 : (a + m * 2 ^ k) / 2 ^ k = m := by
      rw [Nat.add_mul_div_right _ _ hposk, Nat.div_eq_of_lt ha, Nat.zero_add]
    rw [hpow, ← Nat.div_div_eq_div_mul, hdiv1]

/-- Theorem 1: `MqttLimits.default` has strictly positive defensive resource limits. -/
theorem mqtt_limits_default_positive :
    ∃ l : MqttLimits, MqttLimits.default = ok l ∧
      0 < l.max_packet_size.val ∧ 0 < l.max_topic_len.val ∧
      0 < l.max_properties.val ∧ 0 < l.max_subscriptions.val ∧ 0 < l.max_inflight.val := by
  refine ⟨_, rfl, by decide, by decide, by decide, by decide, by decide⟩

/-- Theorem 2: `qos_to_int` and `qos_from_int_opt` form a roundtrip on all 3 QoS levels. -/
theorem qos_roundtrip (q : QoS) :
    (do let n ← qos_to_int q; qos_from_int_opt n) = ok (some q) := by
  cases q <;> simp [qos_to_int, qos_from_int_opt]

/-- Theorem 3: `qos_from_int_opt` accepts exactly `{0, 1, 2}` and `qos_to_int` is injective. -/
theorem qos_from_int_opt_valid_iff :
    (∀ raw : Std.I32, (∃ q : QoS, qos_from_int_opt raw = ok (some q)) ↔ (0 ≤ raw.val ∧ raw.val ≤ 2)) ∧
    (∀ a b : QoS, qos_to_int a = qos_to_int b → a = b) := by
  constructor
  · intro raw
    unfold qos_from_int_opt
    constructor
    · rintro ⟨q, hq⟩
      split_ifs at hq with h0 h1 h2
      · subst h0; decide
      · subst h1; decide
      · subst h2; decide
      · simp at hq
    · intro ⟨hlo, hhi⟩
      have hcases : raw.val = 0 ∨ raw.val = 1 ∨ raw.val = 2 := by omega
      rcases hcases with h | h | h
      · have heq : raw = 0#i32 := IScalar.eq_of_val_eq h; subst heq; exact ⟨.AtMostOnce, rfl⟩
      · have heq : raw = 1#i32 := IScalar.eq_of_val_eq h; subst heq; exact ⟨.AtLeastOnce, rfl⟩
      · have heq : raw = 2#i32 := IScalar.eq_of_val_eq h; subst heq; exact ⟨.ExactlyOnce, rfl⟩
  · intro a b h; cases a <;> cases b <;> first | rfl | (simp [qos_to_int] at h)

/-- Theorem 4: `packet_type_to_int` and `packet_type_from_int_opt` form an exact roundtrip on all 15 MQTT packet types. -/
theorem packet_type_roundtrip (pt : PacketType) :
    (do let n ← packet_type_to_int pt; packet_type_from_int_opt n) = ok (some pt) := by
  cases pt <;> simp [packet_type_to_int, packet_type_from_int_opt]

/-- Theorem 5: `packet_type_from_int_opt` accepts exactly `1..15` (rejecting reserved 0 and ≥ 16). -/
theorem packet_type_from_int_opt_valid_iff (raw : Std.I32) :
    (∃ pt : PacketType, packet_type_from_int_opt raw = ok (some pt)) ↔ (1 ≤ raw.val ∧ raw.val ≤ 15) := by
  unfold packet_type_from_int_opt
  constructor
  · rintro ⟨pt, hpt⟩
    by_cases h1 : raw = 1#i32; · subst h1; decide
    simp only [h1, ↓reduceIte] at hpt
    by_cases h2 : raw = 2#i32; · subst h2; decide
    simp only [h2, ↓reduceIte] at hpt
    by_cases h3 : raw = 3#i32; · subst h3; decide
    simp only [h3, ↓reduceIte] at hpt
    by_cases h4 : raw = 4#i32; · subst h4; decide
    simp only [h4, ↓reduceIte] at hpt
    by_cases h5 : raw = 5#i32; · subst h5; decide
    simp only [h5, ↓reduceIte] at hpt
    by_cases h6 : raw = 6#i32; · subst h6; decide
    simp only [h6, ↓reduceIte] at hpt
    by_cases h7 : raw = 7#i32; · subst h7; decide
    simp only [h7, ↓reduceIte] at hpt
    by_cases h8 : raw = 8#i32; · subst h8; decide
    simp only [h8, ↓reduceIte] at hpt
    by_cases h9 : raw = 9#i32; · subst h9; decide
    simp only [h9, ↓reduceIte] at hpt
    by_cases h10 : raw = 10#i32; · subst h10; decide
    simp only [h10, ↓reduceIte] at hpt
    by_cases h11 : raw = 11#i32; · subst h11; decide
    simp only [h11, ↓reduceIte] at hpt
    by_cases h12 : raw = 12#i32; · subst h12; decide
    simp only [h12, ↓reduceIte] at hpt
    by_cases h13 : raw = 13#i32; · subst h13; decide
    simp only [h13, ↓reduceIte] at hpt
    by_cases h14 : raw = 14#i32; · subst h14; decide
    simp only [h14, ↓reduceIte] at hpt
    by_cases h15 : raw = 15#i32; · subst h15; decide
    simp only [h15, ↓reduceIte] at hpt
    simp only [ok.injEq, reduceCtorEq] at hpt
  · intro ⟨hlo, hhi⟩
    have hc : raw.val = 1 ∨ raw.val = 2 ∨ raw.val = 3 ∨ raw.val = 4 ∨ raw.val = 5 ∨
              raw.val = 6 ∨ raw.val = 7 ∨ raw.val = 8 ∨ raw.val = 9 ∨ raw.val = 10 ∨
              raw.val = 11 ∨ raw.val = 12 ∨ raw.val = 13 ∨ raw.val = 14 ∨ raw.val = 15 := by omega
    rcases hc with h|h|h|h|h|h|h|h|h|h|h|h|h|h|h
    · have heq : raw = 1#i32 := IScalar.eq_of_val_eq h; subst heq; exact ⟨.Connect, rfl⟩
    · have heq : raw = 2#i32 := IScalar.eq_of_val_eq h; subst heq; exact ⟨.ConnAck, rfl⟩
    · have heq : raw = 3#i32 := IScalar.eq_of_val_eq h; subst heq; exact ⟨.Publish, rfl⟩
    · have heq : raw = 4#i32 := IScalar.eq_of_val_eq h; subst heq; exact ⟨.PubAck, rfl⟩
    · have heq : raw = 5#i32 := IScalar.eq_of_val_eq h; subst heq; exact ⟨.PubRec, rfl⟩
    · have heq : raw = 6#i32 := IScalar.eq_of_val_eq h; subst heq; exact ⟨.PubRel, rfl⟩
    · have heq : raw = 7#i32 := IScalar.eq_of_val_eq h; subst heq; exact ⟨.PubComp, rfl⟩
    · have heq : raw = 8#i32 := IScalar.eq_of_val_eq h; subst heq; exact ⟨.Subscribe, rfl⟩
    · have heq : raw = 9#i32 := IScalar.eq_of_val_eq h; subst heq; exact ⟨.SubAck, rfl⟩
    · have heq : raw = 10#i32 := IScalar.eq_of_val_eq h; subst heq; exact ⟨.Unsubscribe, rfl⟩
    · have heq : raw = 11#i32 := IScalar.eq_of_val_eq h; subst heq; exact ⟨.UnsubAck, rfl⟩
    · have heq : raw = 12#i32 := IScalar.eq_of_val_eq h; subst heq; exact ⟨.PingReq, rfl⟩
    · have heq : raw = 13#i32 := IScalar.eq_of_val_eq h; subst heq; exact ⟨.PingResp, rfl⟩
    · have heq : raw = 14#i32 := IScalar.eq_of_val_eq h; subst heq; exact ⟨.Disconnect, rfl⟩
    · have heq : raw = 15#i32 := IScalar.eq_of_val_eq h; subst heq; exact ⟨.Auth, rfl⟩

/-- Theorem 6: `vbi_encoded_len` exactly partitions all 32-bit values into the 4 OASIS §1.5.5 VBI byte-length tiers (or 0 if out of range). -/
theorem vbi_encoded_len_spec (v : Std.I32) :
    ∃ n : Std.I32, vbi_encoded_len v = ok n ∧
      ((n.val = 0 ↔ v.val < 0 ∨ v.val > 268435455) ∧
       (n.val = 1 ↔ 0 ≤ v.val ∧ v.val ≤ 127) ∧
       (n.val = 2 ↔ 128 ≤ v.val ∧ v.val ≤ 16383) ∧
       (n.val = 3 ↔ 16384 ≤ v.val ∧ v.val ≤ 2097151) ∧
       (n.val = 4 ↔ 2097152 ≤ v.val ∧ v.val ≤ 268435455)) := by
  unfold vbi_encoded_len
  have c0 : (0#i32 : Std.I32).val = 0 := rfl
  have c1 : (1#i32 : Std.I32).val = 1 := rfl
  have c2 : (2#i32 : Std.I32).val = 2 := rfl
  have c3 : (3#i32 : Std.I32).val = 3 := rfl
  have c4 : (4#i32 : Std.I32).val = 4 := rfl
  by_cases hout : ((decide (v < 0#i32)) || (decide (v > 268435455#i32))) = true
  · simp only [hout, ↓reduceIte]
    simp only [Bool.or_eq_true, decide_eq_true_eq] at hout
    have h' : v.val < 0 ∨ v.val > 268435455 := hout
    exact ⟨0#i32, rfl, ⟨fun _ => h', fun _ => c0⟩,
           ⟨fun h => by omega, fun h => by omega⟩,
           ⟨fun h => by omega, fun h => by omega⟩,
           ⟨fun h => by omega, fun h => by omega⟩,
           ⟨fun h => by omega, fun h => by omega⟩⟩
  · simp only [hout]
    simp only [Bool.or_eq_true, decide_eq_true_eq, not_or] at hout
    have hlo : 0 ≤ v.val := by have : ¬ (v.val < 0) := hout.1; omega
    have hhi : v.val ≤ 268435455 := by have : ¬ (v.val > 268435455) := hout.2; omega
    refine ⟨_, rfl, ?_⟩
    split_ifs with h1 h2 h3
    · have hv : v.val < 128 := h1
      exact ⟨⟨fun h => by omega, fun h => by omega⟩, ⟨fun _ => by omega, fun _ => c1⟩,
             ⟨fun h => by omega, fun h => by omega⟩, ⟨fun h => by omega, fun h => by omega⟩,
             ⟨fun h => by omega, fun h => by omega⟩⟩
    · have hv1 : ¬ (v.val < 128) := h1; have hv2 : v.val < 16384 := h2
      exact ⟨⟨fun h => by omega, fun h => by omega⟩, ⟨fun h => by omega, fun h => by omega⟩,
             ⟨fun _ => by omega, fun _ => c2⟩, ⟨fun h => by omega, fun h => by omega⟩,
             ⟨fun h => by omega, fun h => by omega⟩⟩
    · have hv1 : ¬ (v.val < 128) := h1; have hv2 : ¬ (v.val < 16384) := h2; have hv3 : v.val < 2097152 := h3
      exact ⟨⟨fun h => by omega, fun h => by omega⟩, ⟨fun h => by omega, fun h => by omega⟩,
             ⟨fun h => by omega, fun h => by omega⟩, ⟨fun _ => by omega, fun _ => c3⟩,
             ⟨fun h => by omega, fun h => by omega⟩⟩
    · have hv1 : ¬ (v.val < 128) := h1; have hv2 : ¬ (v.val < 16384) := h2; have hv3 : ¬ (v.val < 2097152) := h3
      exact ⟨⟨fun h => by omega, fun h => by omega⟩, ⟨fun h => by omega, fun h => by omega⟩,
             ⟨fun h => by omega, fun h => by omega⟩, ⟨fun h => by omega, fun h => by omega⟩,
             ⟨fun _ => by omega, fun _ => c4⟩⟩

/-- Theorem 7: `vbi_encoded_len` is monotonic on valid VBI values `[0, 268435455]`. -/
theorem vbi_encoded_len_mono (a b : Std.I32)
    (ha : 0 ≤ a.val) (hb : b.val ≤ 268435455) (hab : a.val ≤ b.val) :
    ∃ na nb : Std.I32, vbi_encoded_len a = ok na ∧ vbi_encoded_len b = ok nb ∧ na.val ≤ nb.val := by
  obtain ⟨na, hna, ha0, ha1, ha2, ha3, ha4⟩ := vbi_encoded_len_spec a
  obtain ⟨nb, hnb, hb0, hb1, hb2, hb3, hb4⟩ := vbi_encoded_len_spec b
  exact ⟨na, nb, hna, hnb, by
    by_cases h1 : a.val ≤ 127
    · have : na.val = 1 := ha1.mpr ⟨ha, h1⟩
      have : nb.val ≠ 0 := fun h => by have := hb0.mp h; omega
      by_cases h1' : b.val ≤ 127
      · have := hb1.mpr ⟨by omega, h1'⟩; omega
      · by_cases h2' : b.val ≤ 16383
        · have := hb2.mpr ⟨by omega, h2'⟩; omega
        · by_cases h3' : b.val ≤ 2097151
          · have := hb3.mpr ⟨by omega, h3'⟩; omega
          · have := hb4.mpr ⟨by omega, hb⟩; omega
    · by_cases h2 : a.val ≤ 16383
      · have : na.val = 2 := ha2.mpr ⟨by omega, h2⟩
        by_cases h2' : b.val ≤ 16383
        · have := hb2.mpr ⟨by omega, h2'⟩; omega
        · by_cases h3' : b.val ≤ 2097151
          · have := hb3.mpr ⟨by omega, h3'⟩; omega
          · have := hb4.mpr ⟨by omega, hb⟩; omega
      · by_cases h3 : a.val ≤ 2097151
        · have : na.val = 3 := ha3.mpr ⟨by omega, h3⟩
          by_cases h3' : b.val ≤ 2097151
          · have := hb3.mpr ⟨by omega, h3'⟩; omega
          · have := hb4.mpr ⟨by omega, hb⟩; omega
        · have : na.val = 4 := ha4.mpr ⟨by omega, by omega⟩
          have := hb4.mpr ⟨by omega, hb⟩; omega⟩

/-- Theorem 8: `vbi_decode_2` computes the exact 14-bit value `(b0 % 128) + b1 * 128`. -/
theorem vbi_decode_2_exact (b0 b1 : Std.I32)
    (h0 : 0 ≤ b0.val ∧ b0.val ≤ 255) (h1 : 0 ≤ b1.val ∧ b1.val ≤ 127) :
    ∃ r : Std.I32, vbi_decode_2 b0 b1 = ok r ∧ r.val = b0.val % 128 + b1.val * 128 := by
  have hb0n : (b0.bv.toNat : Int) = b0.val := i32_bv_toNat_of_nonneg b0 h0.1
  have hb1n : (b1.bv.toNat : Int) = b1.val := i32_bv_toNat_of_nonneg b1 h1.1
  have ⟨_, hm0n⟩ := i32_band_127_nonneg b0 h0.1
  obtain ⟨s1, hs1, hs1n⟩ := i32_shl_nonneg b1 7#i32 (by decide) (by decide) (by
    change b1.bv.toNat * 2 ^ 7 < 2 ^ 31; omega)
  change s1.bv.toNat = b1.bv.toNat * 2 ^ 7 at hs1n
  unfold vbi_decode_2
  rw [hs1, result_bind_ok]
  set r := Pion.I32.bor (Pion.I32.band b0 127#i32) s1
  have hrn : r.bv.toNat = b0.bv.toNat % 128 + b1.bv.toNat * 128 := by
    change ((Pion.I32.band b0 127#i32).bv ||| s1.bv).toNat = _
    rw [BitVec.toNat_or, hm0n, hs1n]
    exact nat_or_low_high (b0.bv.toNat % 128) b1.bv.toNat 7 (by omega)
  have hrv : r.val = (r.bv.toNat : Int) := i32_val_of_bv_toNat_lt r (by rw [hrn]; omega)
  exact ⟨r, rfl, by omega⟩

/-- Theorem 9: Canonical 2-byte VBI (`b1 ∈ [1, 127]`) decodes into `[128, 16383]` with `vbi_encoded_len = 2`. -/
theorem vbi_decode_2_canonical_range (b0 b1 : Std.I32)
    (h0 : 128 ≤ b0.val ∧ b0.val ≤ 255) (h1 : 1 ≤ b1.val ∧ b1.val ≤ 127) :
    ∃ r : Std.I32, vbi_decode_2 b0 b1 = ok r ∧
      128 ≤ r.val ∧ r.val ≤ 16383 ∧ vbi_encoded_len r = ok 2#i32 := by
  obtain ⟨r, hr, hrv⟩ := vbi_decode_2_exact b0 b1 (by omega) (by omega)
  obtain ⟨n, hn, _, _, h2, _, _⟩ := vbi_encoded_len_spec r
  have hn2 : n = 2#i32 := IScalar.eq_of_val_eq (h2.mpr ⟨by omega, by omega⟩)
  rw [hn2] at hn
  exact ⟨r, hr, by omega, by omega, hn⟩

/-- Theorem 10: `vbi_decode_3` computes the exact 21-bit value `(b0 % 128) + (b1 % 128) * 128 + b2 * 16384`. -/
theorem vbi_decode_3_exact (b0 b1 b2 : Std.I32)
    (h0 : 0 ≤ b0.val ∧ b0.val ≤ 255) (h1 : 0 ≤ b1.val ∧ b1.val ≤ 255)
    (h2 : 0 ≤ b2.val ∧ b2.val ≤ 127) :
    ∃ r : Std.I32, vbi_decode_3 b0 b1 b2 = ok r ∧
      r.val = b0.val % 128 + (b1.val % 128) * 128 + b2.val * 16384 := by
  have hb0n : (b0.bv.toNat : Int) = b0.val := i32_bv_toNat_of_nonneg b0 h0.1
  have hb1n : (b1.bv.toNat : Int) = b1.val := i32_bv_toNat_of_nonneg b1 h1.1
  have hb2n : (b2.bv.toNat : Int) = b2.val := i32_bv_toNat_of_nonneg b2 h2.1
  have ⟨_, hm0n⟩ := i32_band_127_nonneg b0 h0.1
  have ⟨_, hm1n⟩ := i32_band_127_nonneg b1 h1.1
  obtain ⟨s1, hs1, hs1n⟩ := i32_shl_nonneg (Pion.I32.band b1 127#i32) 7#i32 (by decide) (by decide) (by
    change (Pion.I32.band b1 127#i32).bv.toNat * 2 ^ 7 < 2 ^ 31; omega)
  obtain ⟨s2, hs2, hs2n⟩ := i32_shl_nonneg b2 14#i32 (by decide) (by decide) (by
    change b2.bv.toNat * 2 ^ 14 < 2 ^ 31; omega)
  change s1.bv.toNat = (Pion.I32.band b1 127#i32).bv.toNat * 2 ^ 7 at hs1n
  change s2.bv.toNat = b2.bv.toNat * 2 ^ 14 at hs2n
  unfold vbi_decode_3
  rw [hs1, result_bind_ok, hs2, result_bind_ok]
  set r1 := Pion.I32.bor (Pion.I32.band b0 127#i32) s1
  have hr1n : r1.bv.toNat = b0.bv.toNat % 128 + (b1.bv.toNat % 128) * 128 := by
    change ((Pion.I32.band b0 127#i32).bv ||| s1.bv).toNat = _
    rw [BitVec.toNat_or, hm0n, hs1n, hm1n]
    exact nat_or_low_high (b0.bv.toNat % 128) (b1.bv.toNat % 128) 7 (by omega)
  set r := Pion.I32.bor r1 s2
  have hrn : r.bv.toNat = b0.bv.toNat % 128 + (b1.bv.toNat % 128) * 128 + b2.bv.toNat * 16384 := by
    change (r1.bv ||| s2.bv).toNat = _
    rw [BitVec.toNat_or, hr1n, hs2n]
    exact nat_or_low_high (b0.bv.toNat % 128 + (b1.bv.toNat % 128) * 128) b2.bv.toNat 14 (by omega)
  have hrv : r.val = (r.bv.toNat : Int) := i32_val_of_bv_toNat_lt r (by rw [hrn]; omega)
  exact ⟨r, rfl, by omega⟩

/-- Theorem 11: Canonical 3-byte VBI (`b2 ∈ [1, 127]`) decodes into `[16384, 2097151]` with `vbi_encoded_len = 3`. -/
theorem vbi_decode_3_canonical_range (b0 b1 b2 : Std.I32)
    (h0 : 128 ≤ b0.val ∧ b0.val ≤ 255) (h1 : 128 ≤ b1.val ∧ b1.val ≤ 255)
    (h2 : 1 ≤ b2.val ∧ b2.val ≤ 127) :
    ∃ r : Std.I32, vbi_decode_3 b0 b1 b2 = ok r ∧
      16384 ≤ r.val ∧ r.val ≤ 2097151 ∧ vbi_encoded_len r = ok 3#i32 := by
  obtain ⟨r, hr, hrv⟩ := vbi_decode_3_exact b0 b1 b2 (by omega) (by omega) (by omega)
  obtain ⟨n, hn, _, _, _, h3, _⟩ := vbi_encoded_len_spec r
  have hn3 : n = 3#i32 := IScalar.eq_of_val_eq (h3.mpr ⟨by omega, by omega⟩)
  rw [hn3] at hn
  exact ⟨r, hr, by omega, by omega, hn⟩

/-- Theorem 12: `vbi_decode_4` computes the exact 28-bit value `(b0 % 128) + (b1 % 128) * 128 + (b2 % 128) * 16384 + b3 * 2097152`. -/
theorem vbi_decode_4_exact (b0 b1 b2 b3 : Std.I32)
    (h0 : 0 ≤ b0.val ∧ b0.val ≤ 255) (h1 : 0 ≤ b1.val ∧ b1.val ≤ 255)
    (h2 : 0 ≤ b2.val ∧ b2.val ≤ 255) (h3 : 0 ≤ b3.val ∧ b3.val ≤ 127) :
    ∃ r : Std.I32, vbi_decode_4 b0 b1 b2 b3 = ok r ∧
      r.val = b0.val % 128 + (b1.val % 128) * 128 + (b2.val % 128) * 16384 + b3.val * 2097152 := by
  have hb0n : (b0.bv.toNat : Int) = b0.val := i32_bv_toNat_of_nonneg b0 h0.1
  have hb1n : (b1.bv.toNat : Int) = b1.val := i32_bv_toNat_of_nonneg b1 h1.1
  have hb2n : (b2.bv.toNat : Int) = b2.val := i32_bv_toNat_of_nonneg b2 h2.1
  have hb3n : (b3.bv.toNat : Int) = b3.val := i32_bv_toNat_of_nonneg b3 h3.1
  have ⟨_, hm0n⟩ := i32_band_127_nonneg b0 h0.1
  have ⟨_, hm1n⟩ := i32_band_127_nonneg b1 h1.1
  have ⟨_, hm2n⟩ := i32_band_127_nonneg b2 h2.1
  obtain ⟨s1, hs1, hs1n⟩ := i32_shl_nonneg (Pion.I32.band b1 127#i32) 7#i32 (by decide) (by decide) (by
    change (Pion.I32.band b1 127#i32).bv.toNat * 2 ^ 7 < 2 ^ 31; omega)
  obtain ⟨s2, hs2, hs2n⟩ := i32_shl_nonneg (Pion.I32.band b2 127#i32) 14#i32 (by decide) (by decide) (by
    change (Pion.I32.band b2 127#i32).bv.toNat * 2 ^ 14 < 2 ^ 31; omega)
  obtain ⟨s3, hs3, hs3n⟩ := i32_shl_nonneg b3 21#i32 (by decide) (by decide) (by
    change b3.bv.toNat * 2 ^ 21 < 2 ^ 31; omega)
  change s1.bv.toNat = (Pion.I32.band b1 127#i32).bv.toNat * 2 ^ 7 at hs1n
  change s2.bv.toNat = (Pion.I32.band b2 127#i32).bv.toNat * 2 ^ 14 at hs2n
  change s3.bv.toNat = b3.bv.toNat * 2 ^ 21 at hs3n
  unfold vbi_decode_4
  rw [hs1, result_bind_ok, hs2, result_bind_ok, hs3, result_bind_ok]
  set r1 := Pion.I32.bor (Pion.I32.band b0 127#i32) s1
  have hr1n : r1.bv.toNat = b0.bv.toNat % 128 + (b1.bv.toNat % 128) * 128 := by
    change ((Pion.I32.band b0 127#i32).bv ||| s1.bv).toNat = _
    rw [BitVec.toNat_or, hm0n, hs1n, hm1n]
    exact nat_or_low_high (b0.bv.toNat % 128) (b1.bv.toNat % 128) 7 (by omega)
  set r2 := Pion.I32.bor r1 s2
  have hr2n : r2.bv.toNat = b0.bv.toNat % 128 + (b1.bv.toNat % 128) * 128 + (b2.bv.toNat % 128) * 16384 := by
    change (r1.bv ||| s2.bv).toNat = _
    rw [BitVec.toNat_or, hr1n, hs2n, hm2n]
    exact nat_or_low_high (b0.bv.toNat % 128 + (b1.bv.toNat % 128) * 128) (b2.bv.toNat % 128) 14 (by omega)
  set r := Pion.I32.bor r2 s3
  have hrn : r.bv.toNat = b0.bv.toNat % 128 + (b1.bv.toNat % 128) * 128 + (b2.bv.toNat % 128) * 16384 + b3.bv.toNat * 2097152 := by
    change (r2.bv ||| s3.bv).toNat = _
    rw [BitVec.toNat_or, hr2n, hs3n]
    exact nat_or_low_high (b0.bv.toNat % 128 + (b1.bv.toNat % 128) * 128 + (b2.bv.toNat % 128) * 16384) b3.bv.toNat 21 (by omega)
  have hrv : r.val = (r.bv.toNat : Int) := i32_val_of_bv_toNat_lt r (by rw [hrn]; omega)
  exact ⟨r, rfl, by omega⟩

/-- Theorem 13: Canonical 4-byte VBI (`b3 ∈ [1, 127]`) decodes into `[2097152, 268435455]` with `vbi_encoded_len = 4`. -/
theorem vbi_decode_4_canonical_range (b0 b1 b2 b3 : Std.I32)
    (h0 : 128 ≤ b0.val ∧ b0.val ≤ 255) (h1 : 128 ≤ b1.val ∧ b1.val ≤ 255)
    (h2 : 128 ≤ b2.val ∧ b2.val ≤ 255) (h3 : 1 ≤ b3.val ∧ b3.val ≤ 127) :
    ∃ r : Std.I32, vbi_decode_4 b0 b1 b2 b3 = ok r ∧
      2097152 ≤ r.val ∧ r.val ≤ 268435455 ∧ vbi_encoded_len r = ok 4#i32 := by
  obtain ⟨r, hr, hrv⟩ := vbi_decode_4_exact b0 b1 b2 b3 (by omega) (by omega) (by omega) (by omega)
  obtain ⟨n, hn, _, _, _, _, h4⟩ := vbi_encoded_len_spec r
  have hn4 : n = 4#i32 := IScalar.eq_of_val_eq (h4.mpr ⟨by omega, by omega⟩)
  rw [hn4] at hn
  exact ⟨r, hr, by omega, by omega, hn⟩

/-- Theorem 14: Canonical 1-byte, 2-byte, 3-byte, and 4-byte MQTT VBI value ranges are strictly ordered and pairwise disjoint. -/
theorem vbi_canonical_tiers_disjoint
    (v1 : Std.I32) (hv1 : 0 ≤ v1.val ∧ v1.val ≤ 127)
    (a0 a1 b0 b1 b2 c0 c1 c2 c3 : Std.I32)
    (ha0 : 128 ≤ a0.val ∧ a0.val ≤ 255) (ha1 : 1 ≤ a1.val ∧ a1.val ≤ 127)
    (hb0 : 128 ≤ b0.val ∧ b0.val ≤ 255) (hb1 : 128 ≤ b1.val ∧ b1.val ≤ 255) (hb2 : 1 ≤ b2.val ∧ b2.val ≤ 127)
    (hc0 : 128 ≤ c0.val ∧ c0.val ≤ 255) (hc1 : 128 ≤ c1.val ∧ c1.val ≤ 255)
    (hc2 : 128 ≤ c2.val ∧ c2.val ≤ 255) (hc3 : 1 ≤ c3.val ∧ c3.val ≤ 127) :
    ∃ v2 v3 v4 : Std.I32,
      vbi_decode_2 a0 a1 = ok v2 ∧
      vbi_decode_3 b0 b1 b2 = ok v3 ∧
      vbi_decode_4 c0 c1 c2 c3 = ok v4 ∧
      v1.val < v2.val ∧ v2.val < v3.val ∧ v3.val < v4.val := by
  obtain ⟨v2, hv2, h2lo, h2hi, _⟩ := vbi_decode_2_canonical_range a0 a1 ha0 ha1
  obtain ⟨v3, hv3, h3lo, h3hi, _⟩ := vbi_decode_3_canonical_range b0 b1 b2 hb0 hb1 hb2
  obtain ⟨v4, hv4, h4lo, _, _⟩ := vbi_decode_4_canonical_range c0 c1 c2 c3 hc0 hc1 hc2 hc3
  exact ⟨v2, v3, v4, hv2, hv3, hv4, by omega, by omega, by omega⟩

end MqttProofs
