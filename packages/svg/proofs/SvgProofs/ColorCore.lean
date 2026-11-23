import Aeneas
import PionLean
import Svg.Types
import Svg.Funs

open Aeneas Aeneas.Std Result ControlFlow Error Pion svg

namespace SvgProofs

private lemma result_bind_ok {α β : Type} (a : α) (f : α → Result β) :
    (do let x ← ok a; f x) = f a := by simp
private lemma i32_le_iff (x y : Std.I32) : (x <= y) ↔ (x.val <= y.val) := Iff.rfl
private lemma i32_lt_iff (x y : Std.I32) : (x < y) ↔ (x.val < y.val) := Iff.rfl
private lemma i32_beq_iff (x y : Std.I32) : ((x == y) = true) ↔ (x.val = y.val) := by
  cases x; cases y; simp [BEq.beq, IScalar.val, BitVec.toInt_inj]

private lemma i32_add_val (x y : Std.I32)
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

private lemma i32_sub_val (x y : Std.I32)
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

private lemma i32_mul_val (x y : Std.I32)
    (hlo : -2147483648 ≤ x.val * y.val) (hhi : x.val * y.val ≤ 2147483647) :
    (Pion.I32.mul x y).val = x.val * y.val := by
  unfold Pion.I32.mul
  have hv : (x.bv * y.bv).toInt = x.val * y.val := by
    rw [BitVec.toInt_mul]
    have hx : x.bv.toInt = x.val := rfl
    have hy : y.bv.toInt = y.val := rfl
    rw [hx, hy]
    exact Int.bmod_eq_of_le (by omega) (by omega)
  exact hv

private lemma i32_shl4 (x : Std.I32) :
    Pion.I32.shl x 4#i32 = ok ⟨x.bv <<< 4⟩ := by
  unfold Pion.I32.shl; rfl

private lemma fin16_shl4_or :
    ∀ a b : Fin 16, (a.val <<< 4 ||| b.val) = a.val * 16 + b.val := by
  decide

private lemma bv32_toInt_of_nonneg (v : BitVec 32) (h : v.toNat < 2147483648) :
    v.toInt = (v.toNat : Int) := by
  rw [BitVec.toInt_eq_toNat_cond]
  have h2 : 2 * v.toNat < 2 ^ 32 := by omega
  simp only [h2, ↓reduceIte]

private lemma i32_toNat_eq_of_nonneg (x : Std.I32) (h0 : 0 ≤ x.val) :
    (x.bv.toNat : Int) = x.val ∧ x.bv.toNat < 2147483648 := by
  have hdef : x.val = x.bv.toInt := rfl
  rw [BitVec.toInt_eq_toNat_cond] at hdef
  by_cases hlt : 2 * x.bv.toNat < 2 ^ 32
  · simp only [hlt, ↓reduceIte] at hdef
    exact ⟨hdef.symm, by omega⟩
  · simp only [hlt, ↓reduceIte] at hdef
    have hlt2 := x.bv.isLt
    omega

/-- Theorem 1: `SvgLimits::default` has exact strictly positive limits with monotone resource hierarchy. -/
theorem svg_limits_default_positive :
    ∃ l : SvgLimits, SvgLimits.default = ok l ∧
      l.max_depth.val = 128 ∧ l.max_elements.val = 100000 ∧
      l.max_path_segments.val = 200000 ∧ l.max_flatten_points.val = 500000 ∧
      l.max_input_bytes.val = 16777216 ∧
      0 < l.max_depth.val ∧ l.max_elements.val < l.max_path_segments.val ∧
      l.max_path_segments.val < l.max_flatten_points.val ∧
      l.max_flatten_points.val < l.max_input_bytes.val := by
  refine ⟨SvgLimits.mk 128#i32 100000#i32 200000#i32 500000#i32 16777216#i32, rfl, ?_⟩
  refine ⟨rfl, rfl, rfl, rfl, rfl, by decide, by decide, by decide, by decide⟩

/-- Theorem 2: `SvgColor::rgb` constructs an opaque color (`a = 255`) preserving `(r, g, b)`. -/
theorem svg_color_rgb_opaque (r g b : Std.I32) :
    ∃ c : SvgColor, SvgColor.rgb r g b = ok c ∧
      c.r = r ∧ c.g = g ∧ c.b = b ∧ c.a.val = 255 := by
  exact ⟨SvgColor.mk r g b 255#i32, rfl, rfl, rfl, rfl, rfl⟩

/-- Theorem 3: `SvgColor::rgba` preserves all four RGBA channels exactly. -/
theorem svg_color_rgba_preserves (r g b a : Std.I32) :
    ∃ c : SvgColor, SvgColor.rgba r g b a = ok c ∧
      c.r = r ∧ c.g = g ∧ c.b = b ∧ c.a = a := by
  exact ⟨SvgColor.mk r g b a, rfl, rfl, rfl, rfl, rfl⟩

/-- Theorem 4: `clamp_u8_int` always lands in `[0, 255]` with exact piecewise clamping. -/
theorem clamp_u8_int_bounds (r : Std.I32) :
    ∃ out : Std.I32, clamp_u8_int r = ok out ∧
      0 ≤ out.val ∧ out.val ≤ 255 ∧
      (r.val < 0 → out.val = 0) ∧
      (255 < r.val → out.val = 255) ∧
      (0 ≤ r.val ∧ r.val ≤ 255 → out.val = r.val) := by
  unfold clamp_u8_int
  by_cases h0 : r < 0#i32
  · simp only [h0, ↓reduceIte]
    have hv := (i32_lt_iff r 0#i32).mp h0; change r.val < 0 at hv
    refine ⟨0#i32, rfl, by decide, by decide, fun _ => rfl, fun hgt => by omega, fun hb => by omega⟩
  · simp only [h0, ↓reduceIte]
    have hv0 : ¬ (r.val < 0) := fun hlt => h0 ((i32_lt_iff r 0#i32).mpr hlt)
    by_cases h255 : r > 255#i32
    · simp only [h255, ↓reduceIte]
      have hv2 := (i32_lt_iff 255#i32 r).mp h255; change 255 < r.val at hv2
      refine ⟨255#i32, rfl, by decide, by decide, fun hlt => by omega, fun _ => rfl, fun hb => by omega⟩
    · simp only [h255, ↓reduceIte]
      have hv2 : ¬ (255 < r.val) := fun hgt => h255 ((i32_lt_iff 255#i32 r).mpr hgt)
      refine ⟨r, rfl, by omega, by omega, fun hlt => by omega, fun hgt => by omega, fun _ => rfl⟩

/-- Theorem 5: `clamp_u8_int` is monotone (`a ≤ b → clamp_u8_int a ≤ clamp_u8_int b`). -/
theorem clamp_u8_int_mono (a b : Std.I32) (hab : a.val ≤ b.val) :
    ∃ ra rb : Std.I32, clamp_u8_int a = ok ra ∧ clamp_u8_int b = ok rb ∧ ra.val ≤ rb.val := by
  rcases clamp_u8_int_bounds a with ⟨ra, hra, hra0, hra2, ha1, ha2, ha3⟩
  rcases clamp_u8_int_bounds b with ⟨rb, hrb, hrb0, hrb2, hb1, hb2, hb3⟩
  refine ⟨ra, rb, hra, hrb, ?_⟩
  by_cases ha_neg : a.val < 0
  · rw [ha1 ha_neg]; exact hrb0
  · by_cases ha_hi : 255 < a.val
    · rw [ha2 ha_hi, hb2 (by omega)]
    · rw [ha3 ⟨by omega, by omega⟩]
      by_cases hb_hi : 255 < b.val
      · rw [hb2 hb_hi]; omega
      · rw [hb3 ⟨by omega, by omega⟩]; omega

/-- Theorem 6: `clamp_u8_int` is idempotent across all 32-bit inputs. -/
theorem clamp_u8_int_idempotent (r : Std.I32) :
    (do let c ← clamp_u8_int r; clamp_u8_int c) = clamp_u8_int r := by
  rcases clamp_u8_int_bounds r with ⟨c, hc, hc0, hc2, _, _, _⟩
  rw [hc, result_bind_ok]
  rcases clamp_u8_int_bounds c with ⟨c2, hc2eq, _, _, _, _, hc2val⟩
  rw [hc2eq]
  apply congrArg ok
  exact IScalar.eq_of_val_eq (hc2val ⟨hc0, hc2⟩)

/-- Theorem 7: `is_valid_hex_color_len` accepts exclusively `{3, 4, 6, 8}` (`#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`). -/
theorem is_valid_hex_color_len_exact (n : Std.I32) :
    is_valid_hex_color_len n = ok true ↔ (n.val = 3 ∨ n.val = 4 ∨ n.val = 6 ∨ n.val = 8) := by
  unfold is_valid_hex_color_len
  simp only [ok.injEq, Bool.or_eq_true, i32_beq_iff]
  change ((n.val = 3 ∨ n.val = 4) ∨ n.val = 6) ∨ n.val = 8 ↔ _
  omega

/-- Theorem 8: `hex_nibble_code` emits lowercase ASCII hex digits (`'0'..'9'` for `0..9`, `'a'..'f'` for `10..15`). -/
theorem hex_nibble_code_lowercase_ascii (n : Std.I32) (h0 : 0 ≤ n.val) (h15 : n.val ≤ 15) :
    ∃ c : Std.I32, hex_nibble_code n = ok c ∧
      (n.val < 10 → c.val = 48 + n.val) ∧
      (10 ≤ n.val → c.val = 87 + n.val) := by
  unfold hex_nibble_code
  by_cases h10 : n < 10#i32
  · simp only [h10, ↓reduceIte]
    have hv := (i32_lt_iff n 10#i32).mp h10; change n.val < 10 at hv
    have ha := i32_add_val 48#i32 n (by change -2147483648 ≤ 48 + n.val; omega) (by change 48 + n.val ≤ 2147483647; omega)
    change (Pion.I32.add 48#i32 n).val = 48 + n.val at ha
    exact ⟨Pion.I32.add 48#i32 n, rfl, fun _ => ha, fun hge => by omega⟩
  · simp only [h10, ↓reduceIte]
    have hv : ¬ (n.val < 10) := fun hlt => h10 ((i32_lt_iff n 10#i32).mpr hlt)
    set t := Pion.I32.add 97#i32 n
    have ht : t.val = 97 + n.val :=
      i32_add_val 97#i32 n (by change -2147483648 ≤ 97 + n.val; omega) (by change 97 + n.val ≤ 2147483647; omega)
    have hs := i32_sub_val t 10#i32 (by change -2147483648 ≤ t.val - 10; omega) (by change t.val - 10 ≤ 2147483647; omega)
    change (Pion.I32.sub t 10#i32).val = t.val - 10 at hs
    exact ⟨Pion.I32.sub t 10#i32, rfl, fun hlt => by omega, fun _ => by omega⟩

/-- Theorem 9: Exact nibble encode/decode roundtrip: `hex_val (hex_nibble_code n) = ok n` for all `n ∈ [0, 15]`. -/
theorem hex_nibble_code_roundtrip (n : Std.I32) (h0 : 0 ≤ n.val) (h15 : n.val ≤ 15) :
    (do let c ← hex_nibble_code n; hex_val c) = ok n := by
  rcases hex_nibble_code_lowercase_ascii n h0 h15 with ⟨c, hc, hlt, hge⟩
  rw [hc, result_bind_ok]
  unfold hex_val
  by_cases h10 : n.val < 10
  · have hcv := hlt h10
    have hd : ((decide (c >= 48#i32)) && (decide (c <= 57#i32))) = true := by
      simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff]
      change 48 ≤ c.val ∧ c.val ≤ 57; omega
    simp only [hd, ↓reduceIte]
    apply congrArg ok; apply IScalar.eq_of_val_eq
    have hs := i32_sub_val c 48#i32 (by change -2147483648 ≤ c.val - 48; omega) (by change c.val - 48 ≤ 2147483647; omega)
    change (Pion.I32.sub c 48#i32).val = c.val - 48 at hs; omega
  · have hcv := hge (by omega)
    have hd : ((decide (c >= 48#i32)) && (decide (c <= 57#i32))) = false := by
      rw [Bool.eq_false_iff]; intro h; simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff] at h; change 48 ≤ c.val ∧ c.val ≤ 57 at h; omega
    have hu : ((decide (c >= 65#i32)) && (decide (c <= 70#i32))) = false := by
      rw [Bool.eq_false_iff]; intro h; simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff] at h; change 65 ≤ c.val ∧ c.val ≤ 70 at h; omega
    have hl : ((decide (c >= 97#i32)) && (decide (c <= 102#i32))) = true := by
      simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff]
      change 97 ≤ c.val ∧ c.val ≤ 102; omega
    simp only [hd, hu, hl, Bool.false_eq_true, ↓reduceIte]
    apply congrArg ok; apply IScalar.eq_of_val_eq
    set t := Pion.I32.sub c 97#i32
    have ht : t.val = c.val - 97 :=
      i32_sub_val c 97#i32 (by change -2147483648 ≤ c.val - 97; omega) (by change c.val - 97 ≤ 2147483647; omega)
    have ha := i32_add_val t 10#i32 (by change -2147483648 ≤ t.val + 10; omega) (by change t.val + 10 ≤ 2147483647; omega)
    change (Pion.I32.add t 10#i32).val = t.val + 10 at ha; omega

/-- Theorem 10: `#rgb`/`#rgba` shorthand expansion `hex3_channel_expand nib` equals `nib * 16 + nib ∈ [0, 255]`. -/
theorem hex3_channel_expand_bounds (nib : Std.I32) (h0 : 0 ≤ nib.val) (h15 : nib.val ≤ 15) :
    ∃ r : Std.I32, hex3_channel_expand nib = ok r ∧
      r.val = nib.val * 16 + nib.val ∧ 0 ≤ r.val ∧ r.val ≤ 255 := by
  unfold hex3_channel_expand
  have hm := i32_mul_val nib 17#i32 (by change -2147483648 ≤ nib.val * 17; omega) (by change nib.val * 17 ≤ 2147483647; omega)
  change (Pion.I32.mul nib 17#i32).val = nib.val * 17 at hm
  exact ⟨Pion.I32.mul nib 17#i32, rfl, by omega, by omega, by omega⟩

/-- Theorem 11: `hex_pair_to_byte hi lo` equals `hi * 16 + lo ∈ [0, 255]` for all nibbles `hi, lo ∈ [0, 15]`. -/
theorem hex_pair_to_byte_exact (hi lo : Std.I32)
    (hi0 : 0 ≤ hi.val) (hi15 : hi.val ≤ 15) (lo0 : 0 ≤ lo.val) (lo15 : lo.val ≤ 15) :
    ∃ r : Std.I32, hex_pair_to_byte hi lo = ok r ∧
      r.val = hi.val * 16 + lo.val ∧ 0 ≤ r.val ∧ r.val ≤ 255 := by
  unfold hex_pair_to_byte
  rw [i32_shl4, result_bind_ok]
  set r : Std.I32 := Pion.I32.bor ⟨hi.bv <<< 4⟩ lo
  have ⟨hhi_nat, _⟩ := i32_toNat_eq_of_nonneg hi hi0
  have ⟨hlo_nat, _⟩ := i32_toNat_eq_of_nonneg lo lo0
  have hhi_lt : hi.bv.toNat < 16 := by omega
  have hlo_lt : lo.bv.toNat < 16 := by omega
  have hr_nat : r.bv.toNat = hi.bv.toNat * 16 + lo.bv.toNat := by
    change ((hi.bv <<< 4) ||| lo.bv).toNat = hi.bv.toNat * 16 + lo.bv.toNat
    rw [BitVec.toNat_or, BitVec.toNat_shiftLeft]
    have hmod : (hi.bv.toNat <<< 4) % 2 ^ 32 = hi.bv.toNat <<< 4 := by
      rw [Nat.shiftLeft_eq]; omega
    rw [hmod]
    exact fin16_shl4_or ⟨hi.bv.toNat, hhi_lt⟩ ⟨lo.bv.toNat, hlo_lt⟩
  have hr_val : r.val = hi.val * 16 + lo.val := by
    have hv := bv32_toInt_of_nonneg r.bv (by omega)
    change r.val = (r.bv.toNat : Int) at hv
    omega
  exact ⟨r, rfl, hr_val, by omega, by omega⟩

/-- Theorem 12: Shorthand `#rgb` expansion is identically equal to `#rrggbb` with duplicate nibbles (`hex3_channel_expand nib = hex_pair_to_byte nib nib`). -/
theorem hex3_expand_eq_hex_pair_dup (nib : Std.I32) (h0 : 0 ≤ nib.val) (h15 : nib.val ≤ 15) :
    hex3_channel_expand nib = hex_pair_to_byte nib nib := by
  rcases hex3_channel_expand_bounds nib h0 h15 with ⟨r1, hr1, hr1v, _, _⟩
  rcases hex_pair_to_byte_exact nib nib h0 h15 h0 h15 with ⟨r2, hr2, hr2v, _, _⟩
  rw [hr1, hr2]
  apply congrArg ok
  exact IScalar.eq_of_val_eq (by omega)

end SvgProofs
