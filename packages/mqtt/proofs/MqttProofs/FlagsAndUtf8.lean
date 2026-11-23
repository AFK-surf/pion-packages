import Aeneas
import PionLean
import Mqtt.Types
import Mqtt.Funs

open Aeneas Aeneas.Std Result Pion mqtt

namespace MqttProofs

private lemma result_bind_ok' {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by simp

private lemma i32_bv_toNat_of_nonneg' (x : Std.I32) (h0 : 0 ≤ x.val) :
    (x.bv.toNat : Int) = x.val := by
  have h := x.bv.toInt_eq_toNat_cond
  change 0 ≤ x.bv.toInt at h0
  split_ifs at h with hcond
  · exact h.symm
  · have := x.bv.isLt; omega

private lemma i32_val_of_bv_toNat_lt' (x : Std.I32) (hlt : x.bv.toNat < 2 ^ 31) :
    x.val = (x.bv.toNat : Int) := by
  have h := x.bv.toInt_eq_toNat_cond
  have h2 : 2 * x.bv.toNat < 2 ^ 32 := by omega
  simp only [h2, ↓reduceIte] at h
  exact h

private lemma i32_shr1_val (x : Std.I32) :
    ∃ r : Std.I32, Pion.I32.shr x 1#i32 = ok r ∧ r.val = x.val / 2 := by
  have hshr : Pion.I32.shr x 1#i32 = ok ⟨BitVec.sshiftRight x.bv 1⟩ := by
    unfold Pion.I32.shr
    have hc0 : (0 : Int) ≤ (1#i32 : Std.I32).val := by decide
    have hc32 : (1#i32 : Std.I32).val < 32 := by decide
    have hc1 : ((1#i32 : Std.I32).val).toNat = 1 := by decide
    simp only [hc0, hc32, and_self, ↓reduceIte, hc1]
  refine ⟨⟨BitVec.sshiftRight x.bv 1⟩, hshr, ?_⟩
  change (BitVec.sshiftRight x.bv 1).toInt = x.bv.toInt / 2
  rw [BitVec.toInt_sshiftRight, Int.shiftRight_eq_div_pow]
  rfl

private lemma i32_band_3_nonneg (x : Std.I32) (hx : 0 ≤ x.val) :
    (Pion.I32.band x 3#i32).val = x.val % 4 := by
  have hxnat : (x.bv.toNat : Int) = x.val := i32_bv_toNat_of_nonneg' x hx
  set r := Pion.I32.band x 3#i32
  have hrnat : r.bv.toNat = x.bv.toNat % 4 := by
    change (x.bv &&& (3#32 : BitVec 32)).toNat = x.bv.toNat % 4
    rw [BitVec.toNat_and]
    have h3 : (3#32 : BitVec 32).toNat = 2 ^ 2 - 1 := rfl
    rw [h3, Nat.and_two_pow_sub_one_eq_mod]
  have hrval : r.val = (r.bv.toNat : Int) := i32_val_of_bv_toNat_lt' r (by rw [hrnat]; omega)
  rw [hrval, hrnat]; omega

private lemma nat_and_8_nibble (n : Nat) (hn : n ≤ 15) :
    (n &&& 8 == 0) = false ↔ 8 ≤ n := by
  have hdec : ∀ k : Fin 16, ((k.val &&& 8 == 0) == false) = decide (8 ≤ k.val) := by decide
  have hk := hdec ⟨n, by omega⟩
  constructor
  · intro h
    have h1 : ((n &&& 8 == 0) == false) = true := beq_iff_eq.mpr h
    rw [hk] at h1
    exact of_decide_eq_true h1
  · intro h
    have h1 : decide (8 ≤ n) = true := decide_eq_true h
    rw [← hk] at h1
    exact beq_iff_eq.mp h1

private lemma i32_band_8_nibble (flags : Std.I32) (hlo : 0 ≤ flags.val) (hhi : flags.val ≤ 15) :
    (Pion.I32.band flags 8#i32 == 0#i32) = false ↔ flags.val ≥ 8 := by
  have hfn : (flags.bv.toNat : Int) = flags.val := i32_bv_toNat_of_nonneg' flags hlo
  set r := Pion.I32.band flags 8#i32
  have hrn : r.bv.toNat = flags.bv.toNat &&& 8 := by
    change (flags.bv &&& (8#32 : BitVec 32)).toNat = flags.bv.toNat &&& 8
    rw [BitVec.toNat_and]; rfl
  have hrlt : r.bv.toNat < 2 ^ 31 := by
    rw [hrn]; have : flags.bv.toNat &&& 8 ≤ 8 := Nat.and_le_right; omega
  have hrv : r.val = (r.bv.toNat : Int) := i32_val_of_bv_toNat_lt' r hrlt
  have hbeq : (r == 0#i32) = (flags.bv.toNat &&& 8 == 0) := by
    cases hb : (flags.bv.toNat &&& 8 == 0)
    · have hne : flags.bv.toNat &&& 8 ≠ 0 := by simpa using hb
      have hrne : r ≠ 0#i32 := fun h => by
        have hv : r.val = 0 := congrArg IScalar.val h
        omega
      exact beq_false_of_ne hrne
    · have heq : flags.bv.toNat &&& 8 = 0 := by simpa using hb
      have hreq : r = 0#i32 := IScalar.eq_of_val_eq (by change r.val = 0; omega)
      exact beq_iff_eq.mpr hreq
  rw [hbeq, nat_and_8_nibble flags.bv.toNat (by omega)]
  omega

/-- Theorem 15: Packet types outside `1..15` always return error code 1 (`InvalidPacketType`). -/
theorem fixed_header_invalid_ptype (ptype flags : Std.I32)
    (hbad : ptype.val < 1 ∨ ptype.val > 15) :
    fixed_header_flags_err_code ptype flags = ok 1#i32 := by
  unfold fixed_header_flags_err_code
  have hc : ((decide (ptype < 1#i32)) || (decide (ptype > 15#i32))) = true := by
    simp only [Bool.or_eq_true, decide_eq_true_eq]
    exact hbad
  simp only [hc, ↓reduceIte]

/-- Theorem 16: `PUBLISH` (type 3) with QoS = 3 always returns error code 2 (`InvalidQoS(3)`). -/
theorem fixed_header_publish_qos3_rejected (flags : Std.I32)
    (hlo : 0 ≤ flags.val) (hhi : flags.val ≤ 15) (hqos : (flags.val / 2) % 4 = 3) :
    fixed_header_flags_err_code 3#i32 flags = ok 2#i32 := by
  unfold fixed_header_flags_err_code
  have c3 : (3#i32 : Std.I32).val = 3 := rfl
  have hcond1 : ((decide (3#i32 < 1#i32)) || (decide (3#i32 > 15#i32))) = false := by decide
  simp only [hcond1, Bool.false_eq_true, ↓reduceIte]
  obtain ⟨sh, hsh, hshv⟩ := i32_shr1_val flags
  rw [hsh, result_bind_ok']
  have hband := i32_band_3_nonneg sh (by omega)
  have hq3 : Pion.I32.band sh 3#i32 = 3#i32 := IScalar.eq_of_val_eq (by omega)
  simp only [hq3, ↓reduceIte]

/-- Theorem 17: `PUBLISH` (type 3) with QoS = 0 and DUP = 1 returns error code 3 (`InvalidFlags`). -/
theorem fixed_header_publish_qos0_dup_rejected (flags : Std.I32)
    (hlo : 0 ≤ flags.val) (hhi : flags.val ≤ 15)
    (hqos : (flags.val / 2) % 4 = 0) (hdup : flags.val ≥ 8) :
    fixed_header_flags_err_code 3#i32 flags = ok 3#i32 := by
  unfold fixed_header_flags_err_code
  have c0 : (0#i32 : Std.I32).val = 0 := rfl
  have hcond1 : ((decide (3#i32 < 1#i32)) || (decide (3#i32 > 15#i32))) = false := by decide
  simp only [hcond1, Bool.false_eq_true, ↓reduceIte]
  obtain ⟨sh, hsh, hshv⟩ := i32_shr1_val flags
  rw [hsh, result_bind_ok']
  have hband := i32_band_3_nonneg sh (by omega)
  have hq0 : Pion.I32.band sh 3#i32 = 0#i32 := IScalar.eq_of_val_eq (by omega)
  have h0ne3 : (0#i32 : Std.I32) ≠ 3#i32 := by decide
  have hdup' : (Pion.I32.band flags 8#i32 != 0#i32) = true := by
    unfold bne
    rw [(i32_band_8_nibble flags hlo hhi).mpr hdup]
    rfl
  simp only [hq0, h0ne3, beq_self_eq_true, hdup', Bool.and_self, ↓reduceIte]

/-- Theorem 18: Exact iff characterization of valid `PUBLISH` flags in `[0, 15]`. -/
theorem fixed_header_publish_valid_iff (flags : Std.I32)
    (hlo : 0 ≤ flags.val) (hhi : flags.val ≤ 15) :
    fixed_header_flags_err_code 3#i32 flags = ok 0#i32 ↔
      ((flags.val / 2) % 4 ≠ 3 ∧ ¬ ((flags.val / 2) % 4 = 0 ∧ flags.val ≥ 8)) := by
  unfold fixed_header_flags_err_code
  have c0 : (0#i32 : Std.I32).val = 0 := rfl
  have c3 : (3#i32 : Std.I32).val = 3 := rfl
  have hcond1 : ((decide (3#i32 < 1#i32)) || (decide (3#i32 > 15#i32))) = false := by decide
  simp only [hcond1, Bool.false_eq_true, ↓reduceIte]
  obtain ⟨sh, hsh, hshv⟩ := i32_shr1_val flags
  rw [hsh, result_bind_ok']
  have hband := i32_band_3_nonneg sh (by omega)
  by_cases hq3 : (flags.val / 2) % 4 = 3
  · have hq3' : Pion.I32.band sh 3#i32 = 3#i32 := IScalar.eq_of_val_eq (by omega)
    simp only [hq3', ↓reduceIte]
    constructor
    · intro h; simp at h
    · intro ⟨hne, _⟩; exact (hne hq3).elim
  · have hqne3 : Pion.I32.band sh 3#i32 ≠ 3#i32 := fun h => by
      have hv := congrArg IScalar.val h; omega
    simp only [hqne3, ↓reduceIte]
    by_cases hq0 : (flags.val / 2) % 4 = 0
    · have hq0' : Pion.I32.band sh 3#i32 = 0#i32 := IScalar.eq_of_val_eq (by omega)
      by_cases hd : flags.val ≥ 8
      · have hdup' : (Pion.I32.band flags 8#i32 != 0#i32) = true := by
          unfold bne; rw [(i32_band_8_nibble flags hlo hhi).mpr hd]; rfl
        simp only [hq0', beq_self_eq_true, hdup', Bool.and_self, ↓reduceIte]
        constructor
        · intro h; simp at h
        · intro ⟨_, hnot⟩; exact (hnot ⟨hq0, hd⟩).elim
      · have hndup : (Pion.I32.band flags 8#i32 != 0#i32) = false := by
          unfold bne
          cases hb : (Pion.I32.band flags 8#i32 == 0#i32)
          · exfalso; exact hd ((i32_band_8_nibble flags hlo hhi).mp hb)
          · rfl
        simp only [hq0', beq_self_eq_true, hndup, Bool.and_false, Bool.false_eq_true, ↓reduceIte]
        exact ⟨fun _ => ⟨hq3, fun ⟨_, h⟩ => hd h⟩, fun _ => trivial⟩
    · have hqne0 : (Pion.I32.band sh 3#i32 == 0#i32) = false := by
        apply beq_false_of_ne
        intro h; have hv := congrArg IScalar.val h; omega
      simp only [hqne0, Bool.false_and, Bool.false_eq_true, ↓reduceIte]
      exact ⟨fun _ => ⟨hq3, fun ⟨h, _⟩ => hq0 h⟩, fun _ => trivial⟩

/-- Theorem 19: `PUBREL` (6), `SUBSCRIBE` (8), and `UNSUBSCRIBE` (10) require exact flags `0x02`. -/
theorem fixed_header_flags_0x02_types (ptype flags : Std.I32)
    (hpt : ptype.val = 6 ∨ ptype.val = 8 ∨ ptype.val = 10) :
    fixed_header_flags_err_code ptype flags = ok 0#i32 ↔ flags.val = 2 := by
  have c2 : (2#i32 : Std.I32).val = 2 := rfl
  rcases hpt with h | h | h
  · have heq : ptype = 6#i32 := IScalar.eq_of_val_eq h; subst heq
    unfold fixed_header_flags_err_code
    have h1 : ((decide (6#i32 < 1#i32)) || (decide (6#i32 > 15#i32))) = false := by decide
    have h3 : (6#i32 : Std.I32) ≠ 3#i32 := by decide
    have hexp : (((6#i32 == 6#i32) || (6#i32 == 8#i32)) || (6#i32 == 10#i32)) = true := by decide
    simp only [h1, Bool.false_eq_true, h3, hexp, ↓reduceIte]
    split_ifs with hne
    · constructor
      · intro hok; simp at hok
      · intro hf2; exfalso; exact hne (IScalar.eq_of_val_eq (by omega))
    · constructor
      · intro _; have hf := Classical.not_not.mp hne; exact congrArg IScalar.val hf
      · intro _; rfl
  · have heq : ptype = 8#i32 := IScalar.eq_of_val_eq h; subst heq
    unfold fixed_header_flags_err_code
    have h1 : ((decide (8#i32 < 1#i32)) || (decide (8#i32 > 15#i32))) = false := by decide
    have h3 : (8#i32 : Std.I32) ≠ 3#i32 := by decide
    have hexp : (((8#i32 == 6#i32) || (8#i32 == 8#i32)) || (8#i32 == 10#i32)) = true := by decide
    simp only [h1, Bool.false_eq_true, h3, hexp, ↓reduceIte]
    split_ifs with hne
    · constructor
      · intro hok; simp at hok
      · intro hf2; exfalso; exact hne (IScalar.eq_of_val_eq (by omega))
    · constructor
      · intro _; have hf := Classical.not_not.mp hne; exact congrArg IScalar.val hf
      · intro _; rfl
  · have heq : ptype = 10#i32 := IScalar.eq_of_val_eq h; subst heq
    unfold fixed_header_flags_err_code
    have h1 : ((decide (10#i32 < 1#i32)) || (decide (10#i32 > 15#i32))) = false := by decide
    have h3 : (10#i32 : Std.I32) ≠ 3#i32 := by decide
    have hexp : (((10#i32 == 6#i32) || (10#i32 == 8#i32)) || (10#i32 == 10#i32)) = true := by decide
    simp only [h1, Bool.false_eq_true, h3, hexp, ↓reduceIte]
    split_ifs with hne
    · constructor
      · intro hok; simp at hok
      · intro hf2; exfalso; exact hne (IScalar.eq_of_val_eq (by omega))
    · constructor
      · intro _; have hf := Classical.not_not.mp hne; exact congrArg IScalar.val hf
      · intro _; rfl

/-- Theorem 20: All other 11 valid MQTT packet types require exact flags `0x00`. -/
theorem fixed_header_flags_0x00_types (ptype flags : Std.I32)
    (hpt : 1 ≤ ptype.val ∧ ptype.val ≤ 15 ∧
           ptype.val ≠ 3 ∧ ptype.val ≠ 6 ∧ ptype.val ≠ 8 ∧ ptype.val ≠ 10) :
    fixed_header_flags_err_code ptype flags = ok 0#i32 ↔ flags.val = 0 := by
  unfold fixed_header_flags_err_code
  have c0 : (0#i32 : Std.I32).val = 0 := rfl
  have h1 : ((decide (ptype < 1#i32)) || (decide (ptype > 15#i32))) = false := by
    cases hb : ((decide (ptype < 1#i32)) || (decide (ptype > 15#i32)))
    · rfl
    · simp only [Bool.or_eq_true, decide_eq_true_eq] at hb
      rcases hb with ha | hb'
      · change ptype.val < 1 at ha; omega
      · change ptype.val > 15 at hb'; omega
  have h3 : ptype ≠ 3#i32 := fun h => hpt.2.2.1 (congrArg IScalar.val h)
  have hexp : (((ptype == 6#i32) || (ptype == 8#i32)) || (ptype == 10#i32)) = false := by
    cases hb : (((ptype == 6#i32) || (ptype == 8#i32)) || (ptype == 10#i32))
    · rfl
    · simp only [Bool.or_eq_true, beq_iff_eq] at hb
      rcases hb with (h6 | h8) | h10
      · exact (hpt.2.2.2.1 (congrArg IScalar.val h6)).elim
      · exact (hpt.2.2.2.2.1 (congrArg IScalar.val h8)).elim
      · exact (hpt.2.2.2.2.2 (congrArg IScalar.val h10)).elim
  simp only [h1, Bool.false_eq_true, h3, hexp, ↓reduceIte]
  split_ifs with hne
  · constructor
    · intro hok; simp at hok
    · intro hf0; exfalso; exact hne (IScalar.eq_of_val_eq (by omega))
  · constructor
    · intro _; have hf := Classical.not_not.mp hne; exact congrArg IScalar.val hf
    · intro _; rfl

/-- Theorem 21: `fixed_header_flags_err_code` always succeeds and returns a code in `[0, 3]`. -/
theorem fixed_header_flags_error_range (ptype flags : Std.I32) :
    ∃ c : Std.I32, fixed_header_flags_err_code ptype flags = ok c ∧ 0 ≤ c.val ∧ c.val ≤ 3 := by
  unfold fixed_header_flags_err_code
  by_cases h1 : ((decide (ptype < 1#i32)) || (decide (ptype > 15#i32))) = true
  · simp only [h1, ↓reduceIte]; exact ⟨1#i32, rfl, by decide, by decide⟩
  · have h1f : ((decide (ptype < 1#i32)) || (decide (ptype > 15#i32))) = false :=
      Bool.eq_false_iff.mpr h1
    simp only [h1f, Bool.false_eq_true, ↓reduceIte]
    by_cases h3 : ptype = 3#i32
    · simp only [h3, ↓reduceIte]
      obtain ⟨sh, hsh, _⟩ := i32_shr1_val flags
      rw [hsh, result_bind_ok']
      split_ifs
      · exact ⟨2#i32, rfl, by decide, by decide⟩
      · exact ⟨3#i32, rfl, by decide, by decide⟩
      · exact ⟨0#i32, rfl, by decide, by decide⟩
    · simp only [h3, ↓reduceIte]
      split_ifs
      · exact ⟨3#i32, rfl, by decide, by decide⟩
      · exact ⟨0#i32, rfl, by decide, by decide⟩
      · exact ⟨3#i32, rfl, by decide, by decide⟩
      · exact ⟨0#i32, rfl, by decide, by decide⟩

/-- Theorem 22: Exact iff characterization of `is_mqtt_forbidden_ascii` (OASIS §1.5.4 C0 controls & DEL). -/
theorem is_mqtt_forbidden_ascii_spec (b : Std.I32) :
    is_mqtt_forbidden_ascii b = ok true ↔ (b.val < 32 ∨ b.val = 127) := by
  unfold is_mqtt_forbidden_ascii
  simp only [ok.injEq, Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq]
  constructor
  · intro h
    rcases h with h1 | h2
    · left; exact h1
    · right; exact congrArg IScalar.val h2
  · intro h
    rcases h with h1 | h2
    · left; exact h1
    · right; exact IScalar.eq_of_val_eq h2

/-- Theorem 23: Printable ASCII bytes `[32, 126]` are never forbidden by `is_mqtt_forbidden_ascii`. -/
theorem is_mqtt_forbidden_ascii_allows_printable (b : Std.I32)
    (hlo : 32 ≤ b.val) (hhi : b.val ≤ 126) :
    is_mqtt_forbidden_ascii b = ok false := by
  have hne : is_mqtt_forbidden_ascii b ≠ ok true := by
    intro ht; rw [is_mqtt_forbidden_ascii_spec] at ht; omega
  unfold is_mqtt_forbidden_ascii at hne ⊢
  cases hb : ((decide (b < 32#i32)) || (b == 127#i32))
  · rfl
  · exfalso; exact hne (congrArg ok hb)

private lemma nat_and_192_eq_128 (n : Nat) (hn : n ≤ 255) :
    n &&& 192 = 128 ↔ 128 ≤ n ∧ n ≤ 191 := by
  have hdec : ∀ hi lo : Fin 16,
      (((hi.val * 16 + lo.val) &&& 192) == 128) =
      decide (128 ≤ hi.val * 16 + lo.val ∧ hi.val * 16 + lo.val ≤ 191) := by
    decide
  have hk := hdec ⟨n / 16, by omega⟩ ⟨n % 16, by omega⟩
  have hre : (n / 16) * 16 + n % 16 = n := by omega
  simp only [hre] at hk
  constructor
  · intro h
    have h1 : (n &&& 192 == 128) = true := beq_iff_eq.mpr h
    rw [hk] at h1
    exact of_decide_eq_true h1
  · intro h
    have h1 : decide (128 ≤ n ∧ n ≤ 191) = true := decide_eq_true h
    rw [← hk] at h1
    exact beq_iff_eq.mp h1

/-- Theorem 24: `is_utf8_cont_byte` matches exactly `[0x80, 0xBF]` for all byte values `0..255`. -/
theorem is_utf8_cont_byte_spec (b : Std.I32) (hlo : 0 ≤ b.val) (hhi : b.val ≤ 255) :
    is_utf8_cont_byte b = ok true ↔ (128 ≤ b.val ∧ b.val ≤ 191) := by
  unfold is_utf8_cont_byte
  simp only [ok.injEq, beq_iff_eq]
  have c128 : (128#i32 : Std.I32).val = 128 := rfl
  have hbn : (b.bv.toNat : Int) = b.val := i32_bv_toNat_of_nonneg' b hlo
  set r := Pion.I32.band b 192#i32
  have hrn : r.bv.toNat = b.bv.toNat &&& 192 := by
    change (b.bv &&& (192#32 : BitVec 32)).toNat = b.bv.toNat &&& 192
    rw [BitVec.toNat_and]; rfl
  have hrlt : r.bv.toNat < 2 ^ 31 := by
    rw [hrn]
    have hle : b.bv.toNat &&& 192 ≤ 192 := Nat.and_le_right
    omega
  have hrv : r.val = (r.bv.toNat : Int) := i32_val_of_bv_toNat_lt' r hrlt
  constructor
  · intro h
    have hv : r.val = 128 := congrArg IScalar.val h
    have hn : b.bv.toNat &&& 192 = 128 := by omega
    have hrange := (nat_and_192_eq_128 b.bv.toNat (by omega)).mp hn
    omega
  · intro h
    have hn := (nat_and_192_eq_128 b.bv.toNat (by omega)).mpr ⟨by omega, by omega⟩
    exact IScalar.eq_of_val_eq (by omega)

/-- Theorem 25: No ASCII byte `[0, 127]` is a UTF-8 continuation byte. -/
theorem is_utf8_cont_byte_disjoint_ascii (b : Std.I32) (hlo : 0 ≤ b.val) (hhi : b.val ≤ 127) :
    is_utf8_cont_byte b = ok false := by
  have hne : is_utf8_cont_byte b ≠ ok true := by
    intro ht; rw [is_utf8_cont_byte_spec b hlo (by omega)] at ht; omega
  unfold is_utf8_cont_byte at hne ⊢
  cases hb : ((Pion.I32.band b 192#i32) == 128#i32)
  · rfl
  · exfalso; exact hne (congrArg ok hb)

/-- Theorem 26: Exact iff characterization of `is_mqtt_c1_control_2b` (U+0080..U+009F = `0xC2 0x80..0x9F`). -/
theorem is_mqtt_c1_control_2b_spec (b0 b1 : Std.I32) :
    is_mqtt_c1_control_2b b0 b1 = ok true ↔ (b0.val = 194 ∧ 128 ≤ b1.val ∧ b1.val ≤ 159) := by
  unfold is_mqtt_c1_control_2b
  simp only [ok.injEq, Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq]
  constructor
  · intro ⟨⟨h0, h1⟩, h2⟩
    exact ⟨congrArg IScalar.val h0, h1, h2⟩
  · intro ⟨h0, h1, h2⟩
    exact ⟨⟨IScalar.eq_of_val_eq h0, h1⟩, h2⟩

/-- Theorem 27: Every MQTT C1 control pair has a valid UTF-8 continuation second byte, and U+00A0 (`0xC2 0xA0`) is allowed. -/
theorem is_mqtt_c1_control_2b_sound :
    (∀ b0 b1 : Std.I32, is_mqtt_c1_control_2b b0 b1 = ok true → is_utf8_cont_byte b1 = ok true) ∧
    is_mqtt_c1_control_2b 194#i32 160#i32 = ok false := by
  constructor
  · intro b0 b1 h
    rw [is_mqtt_c1_control_2b_spec] at h
    rw [is_utf8_cont_byte_spec b1 (by omega) (by omega)]
    omega
  · rfl

end MqttProofs
