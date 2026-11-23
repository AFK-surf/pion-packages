import Aeneas
import PionLean
import Effect.Types
import Effect.Funs

open Aeneas Aeneas.Std Result Error Pion
open effect

namespace EffectProofs

private lemma result_bind_ok_ci {α β : Type} (a : α) (f : α → Result β) :
    (do let x ← ok a; f x) = f a := by
  simp

private lemma result_bind_ok_triple {α β γ δ : Type} (a : α) (b : β) (c : γ)
    (f : α → β → γ → Result δ) :
    (do let (x, y, z) ← ok (a, b, c); f x y z) = f a b c := by
  simp

private lemma i32_eq_of_val_ci {x y : Std.I32} (h : x.val = y.val) : x = y := by
  cases x; cases y
  simp [IScalar.val, BitVec.toInt_inj] at h
  congr

private lemma i64_eq_of_bv_ci {x y : Std.I64} (h : x.bv = y.bv) : x = y := by
  cases x; cases y
  simp at h
  exact congrArg IScalar.mk h

private lemma i64_beq_iff_ci (x y : Std.I64) : (x == y) = true ↔ x.val = y.val := by
  cases x; cases y
  simp [BEq.beq, IScalar.val, BitVec.toInt_inj]

private lemma i32_add_val_ci (x y : Std.I32)
    (hlo : -(2 ^ 31 : Int) ≤ x.val + y.val) (hhi : x.val + y.val < 2 ^ 31) :
    (Pion.I32.add x y).val = x.val + y.val := by
  change -(2 ^ 31 : Int) ≤ x.bv.toInt + y.bv.toInt at hlo
  change x.bv.toInt + y.bv.toInt < 2 ^ 31 at hhi
  change (x.bv + y.bv).toInt = x.bv.toInt + y.bv.toInt
  rw [BitVec.toInt_add]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_sub_val_ci (x y : Std.I32)
    (hlo : -(2 ^ 31 : Int) ≤ x.val - y.val) (hhi : x.val - y.val < 2 ^ 31) :
    (Pion.I32.sub x y).val = x.val - y.val := by
  change -(2 ^ 31 : Int) ≤ x.bv.toInt - y.bv.toInt at hlo
  change x.bv.toInt - y.bv.toInt < 2 ^ 31 at hhi
  change (x.bv - y.bv).toInt = x.bv.toInt - y.bv.toInt
  rw [BitVec.toInt_sub]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_mul_val_ci (x y : Std.I32)
    (hlo : -(2 ^ 31 : Int) ≤ x.val * y.val) (hhi : x.val * y.val < 2 ^ 31) :
    (Pion.I32.mul x y).val = x.val * y.val := by
  change -(2 ^ 31 : Int) ≤ x.bv.toInt * y.bv.toInt at hlo
  change x.bv.toInt * y.bv.toInt < 2 ^ 31 at hhi
  change (x.bv * y.bv).toInt = x.bv.toInt * y.bv.toInt
  rw [BitVec.toInt_mul]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_div_two_nonneg_ci (x : Std.I32) (hx : 0 ≤ x.val) :
    ∃ q : Std.I32,
      Pion.I32.div x 2#i32 = ok q ∧ q.val = x.val / 2 := by
  have hnz : (2#i32).val ≠ 0 := by decide
  have hno : ¬ (x.val = IScalar.min .I32 ∧ (2#i32).val = -1) := by
    intro h
    have h2 : (2#i32).val = 2 := by decide
    omega
  obtain ⟨q, hq, hqv⟩ := IScalar.div_spec (x := x) (y := 2#i32) hnz hno
  refine ⟨q, ?_, ?_⟩
  · simpa [Pion.I32.div] using hq
  · have h2 : (2#i32).val = 2 := by decide
    rw [h2] at hqv
    rw [hqv, Int.tdiv_eq_ediv_of_nonneg hx]

private lemma i32_rem_nonneg_ci (x y : Std.I32) (hx : 0 ≤ x.val) (hy : 0 < y.val) :
    ∃ r : Std.I32,
      Pion.I32.rem x y = ok r ∧
      r.val = x.val % y.val ∧ 0 ≤ r.val ∧ r.val < y.val := by
  have hnz : y.val ≠ 0 := by omega
  have hrem : Pion.I32.rem x y = ok ⟨x.bv.srem y.bv⟩ := by
    simp [Pion.I32.rem, HMod.hMod, IScalar.rem, hnz]
    omega
  refine ⟨⟨x.bv.srem y.bv⟩, hrem, ?_, ?_, ?_⟩
  · change (x.bv.srem y.bv).toInt = x.bv.toInt % y.bv.toInt
    rw [BitVec.toInt_srem]
    change Int.tmod x.val y.val = x.val % y.val
    exact Int.tmod_eq_emod_of_nonneg hx
  · change 0 ≤ (x.bv.srem y.bv).toInt
    rw [BitVec.toInt_srem]
    change 0 ≤ Int.tmod x.val y.val
    rw [Int.tmod_eq_emod_of_nonneg hx]
    exact Int.emod_nonneg x.val (by omega)
  · change (x.bv.srem y.bv).toInt < y.val
    rw [BitVec.toInt_srem]
    change Int.tmod x.val y.val < y.val
    rw [Int.tmod_eq_emod_of_nonneg hx]
    exact Int.emod_lt_of_pos x.val hy

/-! ==========================================================================
    1. TimerHeap Min-Heap Core Invariants
    ========================================================================== -/

/-- Mathematical strict lexicographic order `(at1, seq1) < (at2, seq2)`. -/
def timerLt (at1 : Std.I64) (seq1 : Std.I32) (at2 : Std.I64) (seq2 : Std.I32) : Prop :=
  at1.val < at2.val ∨ (at1.val = at2.val ∧ seq1.val < seq2.val)

private lemma timer_before_eq_decide (at1 : Std.I64) (seq1 : Std.I32)
    (at2 : Std.I64) (seq2 : Std.I32) :
    ∃ b : Bool, timer_before at1 seq1 at2 seq2 = ok b ∧
      (b = true ↔ timerLt at1 seq1 at2 seq2) := by
  unfold timer_before
  refine ⟨(decide (at1 < at2)) || ((at1 == at2) && (decide (seq1 < seq2))), rfl, ?_⟩
  simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq,
    IScalar.lt_equiv, i64_beq_iff_ci, timerLt]

/-- **A-grade**: `TimerHeap::pop` sift-down child selection (`heap_sift_down_pick`)
    always returns an exact minimum among `{parent (0), left (1), optional right (2)}`:
    - returns `0` iff neither existing child is strictly smaller than parent (no early stop);
    - returns `1` iff left is strictly smaller than parent and not beaten by an existing right;
    - returns `2` iff right exists and is strictly smaller than both parent and left. -/
theorem heap_sift_down_pick_is_min
    (cur_at : Std.I64) (cur_seq : Std.I32)
    (l_at : Std.I64) (l_seq : Std.I32)
    (has_right : Bool)
    (r_at : Std.I64) (r_seq : Std.I32) :
    ∃ pick : Std.I32,
      heap_sift_down_pick cur_at cur_seq l_at l_seq has_right r_at r_seq = ok pick ∧
      (pick = 0#i32 ∨ pick = 1#i32 ∨ pick = 2#i32) ∧
      (pick = 0#i32 ↔
        ¬ timerLt l_at l_seq cur_at cur_seq ∧
        (has_right = true → ¬ timerLt r_at r_seq cur_at cur_seq)) ∧
      (pick = 1#i32 →
        timerLt l_at l_seq cur_at cur_seq ∧
        (has_right = true → ¬ timerLt r_at r_seq l_at l_seq)) ∧
      (pick = 2#i32 →
        has_right = true ∧
        timerLt r_at r_seq cur_at cur_seq ∧
        timerLt r_at r_seq l_at l_seq) := by
  unfold heap_sift_down_pick
  dsimp only
  obtain ⟨bl, hbl_eq, hbl_iff⟩ := timer_before_eq_decide l_at l_seq cur_at cur_seq
  rw [hbl_eq, result_bind_ok_ci]
  cases bl
  · have hnl : ¬ timerLt l_at l_seq cur_at cur_seq := by
      intro h; exact Bool.false_ne_true (hbl_iff.mpr h)
    simp only [Bool.false_eq_true, ↓reduceIte]
    rw [result_bind_ok_triple]
    cases has_right
    · simp only [Bool.false_eq_true, ↓reduceIte]
      rw [result_bind_ok_ci]
      simp only [Bool.false_eq_true, ↓reduceIte]
      refine ⟨0#i32, rfl, Or.inl rfl, ?_, ?_, ?_⟩
      · constructor
        · intro _; exact ⟨hnl, fun h => False.elim h⟩
        · intro _; rfl
      · intro h; exact absurd h (by decide)
      · intro h; exact absurd h (by decide)
    · simp only [↓reduceIte]
      obtain ⟨br, hbr_eq, hbr_iff⟩ := timer_before_eq_decide r_at r_seq cur_at cur_seq
      rw [hbr_eq, result_bind_ok_ci, result_bind_ok_ci]
      cases br
      · have hnr : ¬ timerLt r_at r_seq cur_at cur_seq := by
          intro h; exact Bool.false_ne_true (hbr_iff.mpr h)
        simp only [Bool.false_eq_true, ↓reduceIte]
        refine ⟨0#i32, rfl, Or.inl rfl, ?_, ?_, ?_⟩
        · constructor
          · intro _; exact ⟨hnl, fun _ => hnr⟩
          · intro _; rfl
        · intro h; exact absurd h (by decide)
        · intro h; exact absurd h (by decide)
      · have hr : timerLt r_at r_seq cur_at cur_seq := hbr_iff.mp rfl
        simp only [↓reduceIte]
        refine ⟨2#i32, rfl, Or.inr (Or.inr rfl), ?_, ?_, ?_⟩
        · constructor
          · intro h; exact absurd h (by decide)
          · intro ⟨_, hnr⟩; exact absurd hr (hnr trivial)
        · intro h; exact absurd h (by decide)
        · intro _
          refine ⟨trivial, hr, ?_⟩
          unfold timerLt at hr hnl ⊢
          omega
  · have hl : timerLt l_at l_seq cur_at cur_seq := hbl_iff.mp rfl
    simp only [↓reduceIte]
    rw [result_bind_ok_triple]
    cases has_right
    · simp only [Bool.false_eq_true, ↓reduceIte]
      rw [result_bind_ok_ci]
      simp only [Bool.false_eq_true, ↓reduceIte]
      refine ⟨1#i32, rfl, Or.inr (Or.inl rfl), ?_, ?_, ?_⟩
      · constructor
        · intro h; exact absurd h (by decide)
        · intro ⟨hnl, _⟩; exact absurd hl hnl
      · intro _; exact ⟨hl, fun h => False.elim h⟩
      · intro h; exact absurd h (by decide)
    · simp only [↓reduceIte]
      obtain ⟨br, hbr_eq, hbr_iff⟩ := timer_before_eq_decide r_at r_seq l_at l_seq
      rw [hbr_eq, result_bind_ok_ci, result_bind_ok_ci]
      cases br
      · have hnr : ¬ timerLt r_at r_seq l_at l_seq := by
          intro h; exact Bool.false_ne_true (hbr_iff.mpr h)
        simp only [Bool.false_eq_true, ↓reduceIte]
        refine ⟨1#i32, rfl, Or.inr (Or.inl rfl), ?_, ?_, ?_⟩
        · constructor
          · intro h; exact absurd h (by decide)
          · intro ⟨hnl, _⟩; exact absurd hl hnl
        · intro _; exact ⟨hl, fun _ => hnr⟩
        · intro h; exact absurd h (by decide)
      · have hrl : timerLt r_at r_seq l_at l_seq := hbr_iff.mp rfl
        simp only [↓reduceIte]
        refine ⟨2#i32, rfl, Or.inr (Or.inr rfl), ?_, ?_, ?_⟩
        · constructor
          · intro h; exact absurd h (by decide)
          · intro ⟨hnl, _⟩; exact absurd hl hnl
        · intro h; exact absurd h (by decide)
        · intro _
          refine ⟨trivial, ?_, hrl⟩
          unfold timerLt at hl hrl ⊢
          omega

/-- **A-grade**: `TimerHeap::push` sift-up swap decision (`heap_sift_up_should_swap`)
    is exact and preserves the min-heap parent ≤ child invariant after conditional swap. -/
theorem heap_sift_up_preserves_min_order
    (cur_at : Std.I64) (cur_seq : Std.I32)
    (par_at : Std.I64) (par_seq : Std.I32) :
    ∃ swap : Bool,
      heap_sift_up_should_swap cur_at cur_seq par_at par_seq = ok swap ∧
      (swap = true ↔ timerLt cur_at cur_seq par_at par_seq) ∧
      (swap = true → ¬ timerLt par_at par_seq cur_at cur_seq) ∧
      (swap = false → ¬ timerLt cur_at cur_seq par_at par_seq) := by
  unfold heap_sift_up_should_swap
  obtain ⟨b, hb_eq, hb_iff⟩ := timer_before_eq_decide cur_at cur_seq par_at par_seq
  rw [hb_eq, result_bind_ok_ci]
  refine ⟨b, rfl, hb_iff, ?_, ?_⟩
  · intro hbt
    have hlt := hb_iff.mp hbt
    unfold timerLt at hlt ⊢
    omega
  · intro hbf hlt
    exact Bool.false_ne_true (hbf.symm.trans (hb_iff.mpr hlt))

/-- **A-grade**: `heap_parent (heap_right i) = i` and `heap_left i < heap_right i`
    for all valid heap indices `0 ≤ i < 2^30 - 1`. -/
theorem heap_right_parent_inv (i : Std.I32)
    (hlo : 0 ≤ i.val) (hhi : i.val < 2 ^ 30 - 1) :
    ∃ l r : Std.I32,
      heap_left i = ok l ∧
      heap_right i = ok r ∧
      heap_parent r = ok i ∧
      r.val = 2 * i.val + 2 ∧
      l.val + 1 = r.val := by
  unfold heap_left heap_right heap_parent
  have h1 : (1#i32).val = 1 := by decide
  have h2 : (2#i32).val = 2 := by decide
  have hm : (Pion.I32.mul 2#i32 i).val = 2 * i.val := by
    rw [i32_mul_val_ci 2#i32 i (by rw [h2]; omega) (by rw [h2]; omega), h2]
  have hal : (Pion.I32.add (Pion.I32.mul 2#i32 i) 1#i32).val = 2 * i.val + 1 := by
    rw [i32_add_val_ci _ 1#i32 (by omega) (by omega), hm, h1]
  have har : (Pion.I32.add (Pion.I32.mul 2#i32 i) 2#i32).val = 2 * i.val + 2 := by
    rw [i32_add_val_ci _ 2#i32 (by omega) (by omega), hm, h2]
  set l := Pion.I32.add (Pion.I32.mul 2#i32 i) 1#i32
  set r := Pion.I32.add (Pion.I32.mul 2#i32 i) 2#i32
  have hs : (Pion.I32.sub r 1#i32).val = 2 * i.val + 1 := by
    rw [i32_sub_val_ci r 1#i32 (by omega) (by omega), har, h1]; omega
  obtain ⟨q, hq, hqv⟩ := i32_div_two_nonneg_ci (Pion.I32.sub r 1#i32) (by omega)
  refine ⟨l, r, rfl, rfl, ?_, har, by omega⟩
  rw [hq, result_bind_ok_ci]
  congr 1
  exact i32_eq_of_val_ci (by omega)

/-! ==========================================================================
    2. xorshift32 Full-Domain Bijection & Non-Zero Orbit Closure
    ========================================================================== -/

private def xs1 (x : BitVec 32) : BitVec 32 := x ^^^ (x <<< 13)
private def xs2 (x : BitVec 32) : BitVec 32 := x ^^^ (x >>> 17)
private def xs3 (x : BitVec 32) : BitVec 32 := x ^^^ (x <<< 5)
private def xorshift32Bv (x : BitVec 32) : BitVec 32 := xs3 (xs2 (xs1 x))

private def xs1Inv (y : BitVec 32) : BitVec 32 := y ^^^ (y <<< 13) ^^^ (y <<< 26)
private def xs2Inv (y : BitVec 32) : BitVec 32 := xs2 y
private def xs3Inv (y : BitVec 32) : BitVec 32 :=
  let a := y ^^^ (y <<< 5)
  let b := a ^^^ (a <<< 10)
  b ^^^ (b <<< 20)
private def xorshift32Inv (y : BitVec 32) : BitVec 32 := xs1Inv (xs2Inv (xs3Inv y))

private lemma xs1_left_inv (x : BitVec 32) : xs1Inv (xs1 x) = x := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  simp only [xs1Inv, xs1, BitVec.getLsbD_xor, BitVec.getLsbD_shiftLeft]
  by_cases h1 : i < 13
  · have h2 : i < 26 := by omega
    simp [hi, h1, h2]
  · by_cases h2 : i < 26
    · have h13 : i - 13 < 13 := by omega
      simp [hi, h1, h2, h13]
    · have h13 : ¬ (i - 13 < 13) := by omega
      have h26 : i - 26 < 13 := by omega
      have hi13 : i - 13 < 32 := by omega
      have heq : i - 13 - 13 = i - 26 := by omega
      simp [hi, hi13, h1, h2, h13, h26, heq]

private lemma xs1_right_inv (y : BitVec 32) : xs1 (xs1Inv y) = y := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  simp only [xs1, xs1Inv, BitVec.getLsbD_xor, BitVec.getLsbD_shiftLeft]
  by_cases h1 : i < 13
  · have h2 : i < 26 := by omega
    simp [hi, h1, h2]
  · by_cases h2 : i < 26
    · have h13 : i - 13 < 13 := by omega
      have h26 : i - 13 < 26 := by omega
      simp [hi, h1, h2, h13, h26]
    · have h13 : ¬ (i - 13 < 13) := by omega
      have h26 : i - 13 < 26 := by omega
      have hi13 : i - 13 < 32 := by omega
      have heq : i - 13 - 13 = i - 26 := by omega
      simp [hi, hi13, h1, h2, h13, h26, heq]

private lemma xs2_involution (x : BitVec 32) : xs2 (xs2 x) = x := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  simp only [xs2, BitVec.getLsbD_xor, BitVec.getLsbD_ushiftRight]
  by_cases h1 : 17 + i < 32
  · have hlt : BitVec.getLsbD x (17 + (17 + i)) = false :=
      BitVec.getLsbD_of_ge x (17 + (17 + i)) (by omega)
    simp [hlt]
  · have hgt1 : BitVec.getLsbD x (17 + i) = false :=
      BitVec.getLsbD_of_ge x (17 + i) (by omega)
    have hgt2 : BitVec.getLsbD x (17 + (17 + i)) = false :=
      BitVec.getLsbD_of_ge x (17 + (17 + i)) (by omega)
    simp [hgt1, hgt2]

private lemma shl_add_bv32 (x : BitVec 32) (a b : Nat) :
    (x <<< a) <<< b = x <<< (a + b) := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  simp only [BitVec.getLsbD_shiftLeft]
  by_cases h : i < a + b
  · by_cases hb : i < b
    · simp [hi, h, hb]
    · have ha : i - b < a := by omega
      simp [hi, h, hb, ha]
  · have hb : ¬ (i < b) := by omega
    have ha : ¬ (i - b < a) := by omega
    have hib : i - b < 32 := by omega
    have heq : i - b - a = i - (a + b) := by omega
    simp [hi, hib, h, hb, ha, heq]

private lemma shl_xor_bv32 (x y : BitVec 32) (n : Nat) :
    (x ^^^ y) <<< n = (x <<< n) ^^^ (y <<< n) := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  simp only [BitVec.getLsbD_shiftLeft, BitVec.getLsbD_xor]
  by_cases h : i < n <;> simp [hi, h]

private lemma shl_ge32_zero (x : BitVec 32) (n : Nat) (hn : 32 ≤ n) :
    x <<< n = 0#32 := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  simp only [BitVec.getLsbD_shiftLeft, BitVec.getLsbD_zero]
  have : i < n := by omega
  simp [this]

private lemma bv32_xor_zero (x : BitVec 32) : x ^^^ 0#32 = x := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi; simp

private lemma bv32_xor_step_double (x : BitVec 32) (k : Nat) :
    (x ^^^ (x <<< k)) ^^^ ((x ^^^ (x <<< k)) <<< k) = x ^^^ (x <<< (k + k)) := by
  rw [shl_xor_bv32, shl_add_bv32]
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  simp only [BitVec.getLsbD_xor]
  cases x.getLsbD i <;> cases (x <<< k).getLsbD i <;> cases (x <<< (k + k)).getLsbD i <;> rfl

private lemma xs3_left_inv (x : BitVec 32) : xs3Inv (xs3 x) = x := by
  unfold xs3Inv xs3
  dsimp only
  have h1 : (x ^^^ (x <<< 5)) ^^^ ((x ^^^ (x <<< 5)) <<< 5) = x ^^^ (x <<< 10) :=
    bv32_xor_step_double x 5
  rw [h1]
  have h2 : (x ^^^ (x <<< 10)) ^^^ ((x ^^^ (x <<< 10)) <<< 10) = x ^^^ (x <<< 20) :=
    bv32_xor_step_double x 10
  rw [h2]
  have h3 : (x ^^^ (x <<< 20)) ^^^ ((x ^^^ (x <<< 20)) <<< 20) = x ^^^ (x <<< 40) :=
    bv32_xor_step_double x 20
  rw [h3, shl_ge32_zero x 40 (by omega), bv32_xor_zero]

private lemma xs3_right_inv (y : BitVec 32) : xs3 (xs3Inv y) = y := by
  have hcomm : ∀ (z : BitVec 32) (k : Nat),
      (z ^^^ (z <<< k)) ^^^ ((z ^^^ (z <<< k)) <<< 5) =
      (z ^^^ (z <<< 5)) ^^^ ((z ^^^ (z <<< 5)) <<< k) := by
    intro z k
    rw [shl_xor_bv32, shl_xor_bv32, shl_add_bv32, shl_add_bv32, Nat.add_comm k 5]
    apply BitVec.eq_of_getLsbD_eq
    intro i hi
    simp only [BitVec.getLsbD_xor]
    cases z.getLsbD i <;> cases (z <<< k).getLsbD i <;>
      cases (z <<< 5).getLsbD i <;> cases (z <<< (5 + k)).getLsbD i <;> rfl
  unfold xs3 xs3Inv
  dsimp only
  set a := y ^^^ (y <<< 5)
  set b := a ^^^ (a <<< 10)
  rw [hcomm b 20, hcomm a 10]
  have h1 : a ^^^ (a <<< 5) = y ^^^ (y <<< 10) := bv32_xor_step_double y 5
  rw [h1]
  have h2 : (y ^^^ (y <<< 10)) ^^^ ((y ^^^ (y <<< 10)) <<< 10) = y ^^^ (y <<< 20) :=
    bv32_xor_step_double y 10
  rw [h2]
  have h3 : (y ^^^ (y <<< 20)) ^^^ ((y ^^^ (y <<< 20)) <<< 20) = y ^^^ (y <<< 40) :=
    bv32_xor_step_double y 20
  rw [h3, shl_ge32_zero y 40 (by omega), bv32_xor_zero]

private lemma xorshift32_left_inv (x : BitVec 32) :
    xorshift32Inv (xorshift32Bv x) = x := by
  unfold xorshift32Inv xorshift32Bv xs2Inv
  rw [xs3_left_inv, xs2_involution, xs1_left_inv]

private lemma xorshift32_right_inv (y : BitVec 32) :
    xorshift32Bv (xorshift32Inv y) = y := by
  unfold xorshift32Inv xorshift32Bv xs2Inv
  rw [xs1_right_inv, xs2_involution, xs3_right_inv]

private lemma mask32_bv_getElem (i : Nat) (hi : i < 64) :
    (4294967295#64)[i] = decide (i < 32) := by
  have hnat : (4294967295#64) = BitVec.ofNat 64 (2 ^ 32 - 1) := by decide
  rw [hnat, BitVec.getElem_eq_testBit_toNat, BitVec.toNat_ofNat]
  have hmod : (2 ^ 32 - 1) % 2 ^ 64 = 2 ^ 32 - 1 := by decide
  rw [hmod, Nat.testBit_two_pow_sub_one]

private lemma mask32_i64_bv : (4294967295#i64).bv = 4294967295#64 := by
  decide

private lemma i64_u32_high_zero (s : Std.I64) (hlo : 0 ≤ s.val) (hhi : s.val ≤ 4294967295) :
    ∀ (i : Nat) (hi : i < 64), 32 ≤ i → s.bv[i] = false := by
  intro i hi h32
  change 0 ≤ s.bv.toInt at hlo
  change s.bv.toInt ≤ 4294967295 at hhi
  have hlt2 : 2 * s.bv.toNat < 2 ^ 64 := by
    rw [BitVec.toInt_eq_toNat_cond] at hlo hhi
    split_ifs at hlo hhi with hlt
    · exact hlt
    · omega
  have hnat : (s.bv.toNat : Int) = s.bv.toInt := (BitVec.toInt_eq_toNat_of_lt hlt2).symm
  have hlt : s.bv.toNat < 2 ^ 32 := by omega
  rw [BitVec.getElem_eq_testBit_toNat]
  exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le hlt (Nat.pow_le_pow_right (by omega) h32))

private lemma i64_from_u32_bounds (b : BitVec 32) :
    let x : Std.I64 := ⟨b.setWidth 64⟩
    0 ≤ x.val ∧ x.val ≤ 4294967295 ∧ x.bv.setWidth 32 = b := by
  dsimp only
  have hnat : (b.setWidth 64).toNat = b.toNat := by
    rw [BitVec.toNat_setWidth]
    exact Nat.mod_eq_of_lt (Nat.lt_trans b.isLt (by decide))
  have hlt32 : b.toNat < 2 ^ 32 := b.isLt
  have hval : (⟨b.setWidth 64⟩ : Std.I64).val = (b.toNat : Int) := by
    change (b.setWidth 64).toInt = (b.toNat : Int)
    rw [BitVec.toInt_eq_toNat_of_lt (by omega), hnat]
  refine ⟨by omega, by omega, ?_⟩
  apply BitVec.eq_of_getElem_eq
  intro i hi
  simp

private lemma bv64_mask32_eq (x : BitVec 64) :
    x &&& 4294967295#64 = (x.setWidth 32).setWidth 64 := by
  apply BitVec.eq_of_getElem_eq
  intro i hi
  simp only [BitVec.getElem_and, mask32_bv_getElem i hi]
  by_cases h32 : i < 32
  · simp [BitVec.getElem_setWidth, h32, BitVec.getLsbD_eq_getElem hi]
  · simp [BitVec.getElem_setWidth, h32]

private lemma bv64_shl_setWidth32 (x : BitVec 64) (k : Nat) :
    (x <<< k).setWidth 32 = (x.setWidth 32) <<< k := by
  apply BitVec.eq_of_getElem_eq
  intro i hi
  have h64 : i < 64 := by omega
  simp only [BitVec.getElem_setWidth, BitVec.getElem_shiftLeft]
  by_cases hk : i < k
  · simp [hk]
  · have h64' : i - k < 64 := by omega
    simp [hk, h64, BitVec.getLsbD_eq_getElem h64']

private lemma bv64_zext_sshiftRight_setWidth32 (b : BitVec 32) (k : Nat) :
    ((b.setWidth 64).sshiftRight k).setWidth 32 = b >>> k := by
  have hmsb : (b.setWidth 64).msb = false := by
    rw [BitVec.msb_eq_getLsbD_last, BitVec.getLsbD_setWidth]
    simp
  apply BitVec.eq_of_getElem_eq
  intro i hi
  have h64 : i < 64 := by omega
  simp only [BitVec.getElem_setWidth, BitVec.getElem_sshiftRight, BitVec.getElem_ushiftRight,
    hmsb, BitVec.getLsbD_eq_getElem h64]
  by_cases hki32 : k + i < 32
  · have hki64 : k + i < 64 := by omega
    simp [hki32, hki64]
  · have hge : b.getLsbD (k + i) = false := BitVec.getLsbD_of_ge b (k + i) (by omega)
    by_cases hki64 : k + i < 64
    · simp [hki64, hge]
    · simp [hki64, hge]

private lemma bv32_setWidth64_setWidth32 (b : BitVec 32) :
    (b.setWidth 64).setWidth 32 = b := by
  apply BitVec.eq_of_getElem_eq; intro i hi; simp

private lemma rng_step_u32_spec_bv (s : Std.I64)
    (_hlo : 0 ≤ s.val) (_hhi : s.val ≤ 4294967295) :
    rng_step_u32 s = ok ⟨(xorshift32Bv (s.bv.setWidth 32)).setWidth 64⟩ := by
  unfold rng_step_u32
  have hshl13 : Pion.I64.shl_i32 s 13#i32 = ok ⟨s.bv <<< 13⟩ := by
    simp [Pion.I64.shl_i32]
  rw [hshl13, result_bind_ok_ci]
  dsimp only
  set x1 : Std.I64 :=
    Pion.I64.band (Pion.I64.bxor s (Pion.I64.band ⟨s.bv <<< 13⟩ 4294967295#i64)) 4294967295#i64
  have hx1_bv : x1.bv = (xs1 (s.bv.setWidth 32)).setWidth 64 := by
    change (s.bv ^^^ ((s.bv <<< 13) &&& 4294967295#64)) &&& 4294967295#64 = _
    rw [bv64_mask32_eq, bv64_mask32_eq, BitVec.setWidth_xor,
        bv32_setWidth64_setWidth32, bv64_shl_setWidth32]
    rfl
  have hshr17 : Pion.I64.shr_i32 x1 17#i32 = ok ⟨x1.bv.sshiftRight 17⟩ := by
    simp [Pion.I64.shr_i32]
  rw [hshr17, result_bind_ok_ci]
  set x2 : Std.I64 :=
    Pion.I64.band (Pion.I64.bxor x1 (Pion.I64.band ⟨x1.bv.sshiftRight 17⟩ 4294967295#i64)) 4294967295#i64
  have hx2_bv : x2.bv = (xs2 (xs1 (s.bv.setWidth 32))).setWidth 64 := by
    change (x1.bv ^^^ ((x1.bv.sshiftRight 17) &&& 4294967295#64)) &&& 4294967295#64 = _
    rw [bv64_mask32_eq, bv64_mask32_eq, BitVec.setWidth_xor,
        bv32_setWidth64_setWidth32, hx1_bv,
        bv32_setWidth64_setWidth32, bv64_zext_sshiftRight_setWidth32]
    rfl
  have hshl5 : Pion.I64.shl_i32 x2 5#i32 = ok ⟨x2.bv <<< 5⟩ := by
    simp [Pion.I64.shl_i32]
  rw [hshl5, result_bind_ok_ci]
  congr 1
  apply i64_eq_of_bv_ci
  change (x2.bv ^^^ ((x2.bv <<< 5) &&& 4294967295#64)) &&& 4294967295#64 = _
  rw [bv64_mask32_eq, bv64_mask32_eq, BitVec.setWidth_xor,
      bv32_setWidth64_setWidth32, hx2_bv,
      bv32_setWidth64_setWidth32, bv64_shl_setWidth32,
      bv32_setWidth64_setWidth32]
  rfl

/-- **A-grade**: `rng_step_u32` is an exact bijection (injective + surjective) on the
    entire 32-bit unsigned state space `[0, 2^32 - 1]`, matching Marsaglia's `(13, 17, 5)`
    xorshift32 permutation (`rng_step_u32 1 = 270369`). Any mutation to shifts `13/17/5`
    or the `0xFFFFFFFF` mask breaks this theorem. -/
theorem rng_step_u32_bijection :
    (∀ s : Std.I64, 0 ≤ s.val → s.val ≤ 4294967295 →
      ∃ y : Std.I64, rng_step_u32 s = ok y ∧ 0 ≤ y.val ∧ y.val ≤ 4294967295) ∧
    (∀ s1 s2 : Std.I64,
      0 ≤ s1.val → s1.val ≤ 4294967295 →
      0 ≤ s2.val → s2.val ≤ 4294967295 →
      rng_step_u32 s1 = rng_step_u32 s2 → s1 = s2) ∧
    (∀ y : Std.I64, 0 ≤ y.val → y.val ≤ 4294967295 →
      ∃ s : Std.I64, 0 ≤ s.val ∧ s.val ≤ 4294967295 ∧ rng_step_u32 s = ok y) ∧
    rng_step_u32 1#i64 = ok 270369#i64 := by
  refine ⟨?_, ?_, ?_, ?_⟩
  · intro s hlo hhi
    rw [rng_step_u32_spec_bv s hlo hhi]
    obtain ⟨hy0, hyhi, _⟩ := i64_from_u32_bounds (xorshift32Bv (s.bv.setWidth 32))
    exact ⟨_, rfl, hy0, hyhi⟩
  · intro s1 s2 h1lo h1hi h2lo h2hi heq
    rw [rng_step_u32_spec_bv s1 h1lo h1hi, rng_step_u32_spec_bv s2 h2lo h2hi] at heq
    simp only [Result.ok.injEq] at heq
    have hbv : (xorshift32Bv (s1.bv.setWidth 32)).setWidth 64 =
               (xorshift32Bv (s2.bv.setWidth 32)).setWidth 64 :=
      congrArg IScalar.bv heq
    have htr : xorshift32Bv (s1.bv.setWidth 32) = xorshift32Bv (s2.bv.setWidth 32) := by
      have h1 := (i64_from_u32_bounds (xorshift32Bv (s1.bv.setWidth 32))).2.2
      have h2 := (i64_from_u32_bounds (xorshift32Bv (s2.bv.setWidth 32))).2.2
      rw [← h1, ← h2, hbv]
    have htr_eq : s1.bv.setWidth 32 = s2.bv.setWidth 32 := by
      rw [← xorshift32_left_inv (s1.bv.setWidth 32), ← xorshift32_left_inv (s2.bv.setWidth 32), htr]
    apply i64_eq_of_bv_ci
    apply BitVec.eq_of_getElem_eq
    intro i hi
    by_cases h32 : i < 32
    · have := congrArg (fun (v : BitVec 32) => v[i]) htr_eq
      simpa [h32, BitVec.getLsbD_eq_getElem hi] using this
    · rw [i64_u32_high_zero s1 h1lo h1hi i hi (by omega),
          i64_u32_high_zero s2 h2lo h2hi i hi (by omega)]
  · intro y hlo hhi
    set s : Std.I64 := ⟨(xorshift32Inv (y.bv.setWidth 32)).setWidth 64⟩
    obtain ⟨hs0, hshi, hstr⟩ := i64_from_u32_bounds (xorshift32Inv (y.bv.setWidth 32))
    refine ⟨s, hs0, hshi, ?_⟩
    rw [rng_step_u32_spec_bv s hs0 hshi]
    congr 1
    apply i64_eq_of_bv_ci
    have hs_tr : s.bv.setWidth 32 = xorshift32Inv (y.bv.setWidth 32) := hstr
    rw [hs_tr, xorshift32_right_inv]
    apply BitVec.eq_of_getElem_eq
    intro i hi
    by_cases h32 : i < 32
    · simp [hi, h32]
    · simp [hi, h32, i64_u32_high_zero y hlo hhi i hi (by omega)]
  · rw [rng_step_u32_spec_bv 1#i64 (by decide) (by decide)]
    rfl

/-- **A-grade**: Non-zero orbit closure of `rng_step_u32` — for EVERY non-zero
    unsigned 32-bit state `s ∈ [1, 2^32 - 1]`, `rng_step_u32 s` stays strictly in
    `[1, 2^32 - 1]` and never enters the `0` deadlock fixed point. -/
theorem rng_step_u32_nonzero_orbit (s : Std.I64)
    (hlo : 1 ≤ s.val) (hhi : s.val ≤ 4294967295) :
    ∃ y : Std.I64,
      rng_step_u32 s = ok y ∧ 1 ≤ y.val ∧ y.val ≤ 4294967295 := by
  obtain ⟨hclosed, hinj, _, _⟩ := rng_step_u32_bijection
  obtain ⟨y, hy_eq, hy0, hyhi⟩ := hclosed s (by omega) hhi
  have hzero : rng_step_u32 0#i64 = ok 0#i64 := by
    rw [rng_step_u32_spec_bv 0#i64 (by decide) (by decide)]
    rfl
  have hynz : y.val ≠ 0 := by
    intro hyz
    have hy_is_0 : y = 0#i64 := by
      apply i64_eq_of_bv_ci
      rw [← BitVec.toInt_inj]
      change y.val = (0#i64).val
      have h0 : (0#i64).val = 0 := by decide
      omega
    rw [hy_is_0] at hy_eq
    have hs_is_0 : s = 0#i64 :=
      hinj s 0#i64 (by omega) hhi (by decide) (by decide) (hy_eq.trans hzero.symm)
    have h0 : (0#i64).val = 0 := by decide
    rw [hs_is_0] at hlo
    omega
  exact ⟨y, hy_eq, by omega, hyhi⟩

/-! ==========================================================================
    3. RingDeque Circular Buffer Logical-Order & Grow Bijection Invariants
    ========================================================================== -/

private lemma ring_slot_add_val (head offset cap : Std.I32)
    (hh : 0 ≤ head.val) (ho : 0 ≤ offset.val) (hc : 0 < cap.val)
    (hsum : head.val + offset.val < 2 ^ 31) :
    ∃ slot : Std.I32,
      ring_slot_add head offset cap = ok slot ∧
      slot.val = (head.val + offset.val) % cap.val ∧
      0 ≤ slot.val ∧ slot.val < cap.val := by
  unfold ring_slot_add
  have ha : (Pion.I32.add head offset).val = head.val + offset.val :=
    i32_add_val_ci head offset (by omega) (by omega)
  obtain ⟨r, hr, hreq, hr0, hrlt⟩ := i32_rem_nonneg_ci (Pion.I32.add head offset) cap (by omega) hc
  rw [hr, result_bind_ok_ci]
  exact ⟨r, rfl, by rw [hreq, ha], hr0, hrlt⟩

private lemma ring_slot_prev_val (head cap : Std.I32)
    (hh0 : 0 ≤ head.val) (hhc : head.val < cap.val) (hc : cap.val < 2 ^ 30) :
    ∃ prev : Std.I32,
      ring_slot_prev head cap = ok prev ∧
      prev.val = (head.val - 1 + cap.val) % cap.val ∧
      0 ≤ prev.val ∧ prev.val < cap.val := by
  unfold ring_slot_prev
  have h1 : (1#i32).val = 1 := by decide
  have hs : (Pion.I32.sub head 1#i32).val = head.val - 1 := by
    rw [i32_sub_val_ci head 1#i32 (by omega) (by omega), h1]
  have ha : (Pion.I32.add (Pion.I32.sub head 1#i32) cap).val = head.val - 1 + cap.val := by
    rw [i32_add_val_ci _ cap (by omega) (by omega), hs]
  obtain ⟨r, hr, hreq, hr0, hrlt⟩ :=
    i32_rem_nonneg_ci (Pion.I32.add (Pion.I32.sub head 1#i32) cap) cap (by omega) (by omega)
  rw [hr, result_bind_ok_ci]
  exact ⟨r, rfl, by rw [hreq, ha], hr0, hrlt⟩

/-- **A-grade**: Logical-to-physical slot mapping `i ↦ ring_slot_add head i cap` is
    strictly injective on `0 ≤ i < cap` — no two live elements in `[0, len)` ever alias
    or overwrite each other, and `RingDeque::grow` copies `len` distinct slots in order. -/
theorem ring_slot_add_injective_window (head i j cap : Std.I32)
    (hh0 : 0 ≤ head.val) (hhc : head.val < cap.val) (hc : cap.val < 2 ^ 30)
    (hi0 : 0 ≤ i.val) (hic : i.val < cap.val)
    (hj0 : 0 ≤ j.val) (hjc : j.val < cap.val)
    (heq : ring_slot_add head i cap = ring_slot_add head j cap) :
    i = j := by
  obtain ⟨si, hsi, hsi_val, _, _⟩ := ring_slot_add_val head i cap hh0 hi0 (by omega) (by omega)
  obtain ⟨sj, hsj, hsj_val, _, _⟩ := ring_slot_add_val head j cap hh0 hj0 (by omega) (by omega)
  rw [hsi, hsj] at heq
  simp only [Result.ok.injEq] at heq
  have hval : si.val = sj.val := congrArg IScalar.val heq
  rw [hsi_val, hsj_val] at hval
  apply i32_eq_of_val_ci
  have hmod : ∀ a : Int, 0 ≤ a → a < 2 * cap.val →
      a % cap.val = if a < cap.val then a else a - cap.val := by
    intro a ha0 ha2
    split_ifs with hlt
    · exact Int.emod_eq_of_lt ha0 hlt
    · calc a % cap.val
          = ((a - cap.val) + cap.val * 1) % cap.val := by congr 1; omega
        _ = (a - cap.val) % cap.val := Int.add_mul_emod_self_left (a - cap.val) cap.val 1
        _ = a - cap.val := Int.emod_eq_of_lt (by omega) (by omega)
  have hmi := hmod (head.val + i.val) (by omega) (by omega)
  have hmj := hmod (head.val + j.val) (by omega) (by omega)
  rw [hmi, hmj] at hval
  split_ifs at hval <;> omega

/-- **A-grade**: `i ↦ ring_slot_add head i cap` is a bijection from logical offsets
    `[0, cap)` onto physical buffer slots `[0, cap)`. -/
theorem ring_slot_add_bijective_mod_cap (head p cap : Std.I32)
    (hh0 : 0 ≤ head.val) (hhc : head.val < cap.val) (hc : cap.val < 2 ^ 30)
    (hp0 : 0 ≤ p.val) (hpc : p.val < cap.val) :
    ∃ i : Std.I32,
      0 ≤ i.val ∧ i.val < cap.val ∧
      ring_slot_add head i cap = ok p ∧
      (∀ j : Std.I32, 0 ≤ j.val → j.val < cap.val →
        ring_slot_add head j cap = ok p → j = i) := by
  let iv : Int := if head.val ≤ p.val then p.val - head.val else p.val + cap.val - head.val
  let i : Std.I32 := ⟨BitVec.ofInt 32 iv⟩
  have hiv_bounds : 0 ≤ iv ∧ iv < cap.val := by
    dsimp [iv]; split_ifs <;> omega
  have hi_val : i.val = iv := by
    change (BitVec.ofInt 32 iv).toInt = iv
    rw [BitVec.toInt_ofInt]
    exact Int.bmod_eq_of_le (by omega) (by omega)
  obtain ⟨s, hs, hs_val, _, _⟩ :=
    ring_slot_add_val head i cap hh0 (by omega) (by omega) (by omega)
  have hsp : s = p := by
    apply i32_eq_of_val_ci
    rw [hs_val, hi_val]
    dsimp [iv]
    split_ifs with hle
    · have : head.val + (p.val - head.val) = p.val := by omega
      rw [this]
      exact Int.emod_eq_of_lt hp0 hpc
    · have : head.val + (p.val + cap.val - head.val) = p.val + cap.val * 1 := by omega
      rw [this, Int.add_mul_emod_self_left]
      exact Int.emod_eq_of_lt hp0 hpc
  rw [hsp] at hs
  refine ⟨i, by omega, by omega, hs, ?_⟩
  intro j hj0 hjc hjeq
  exact ring_slot_add_injective_window head j i cap hh0 hhc hc hj0 hjc (by omega) (by omega)
    (hjeq.trans hs.symm)

/-- **A-grade**: Full 4-way `RingDeque` circular index consistency:
    1. `pop_front` followed by `push_front` restores `head` (`ring_slot_prev (ring_slot_add head 1 cap) cap = ok head`);
    2. `push_front` preserves every existing logical element's physical slot
       (`ring_slot_add (ring_slot_prev head cap) (i + 1) cap = ring_slot_add head i cap`);
    3. `push_front`'s new slot `ring_slot_prev head cap` never aliases any existing live slot `0 ≤ i < len` when `len < cap`;
    4. `push_back`'s new slot `ring_slot_add head len cap` never aliases any existing live slot `0 ≤ i < len` when `len < cap`. -/
theorem ring_push_pop_full_consistency (head len i cap : Std.I32)
    (hh0 : 0 ≤ head.val) (hhc : head.val < cap.val) (hc : cap.val < 2 ^ 30)
    (hlen0 : 0 ≤ len.val) (hlenc : len.val < cap.val)
    (hi0 : 0 ≤ i.val) (hil : i.val < len.val) :
    ∃ next_head prev_head slot_i slot_tail : Std.I32,
      ring_slot_add head 1#i32 cap = ok next_head ∧
      ring_slot_prev next_head cap = ok head ∧
      ring_slot_prev head cap = ok prev_head ∧
      ring_slot_add head i cap = ok slot_i ∧
      ring_slot_add prev_head (Pion.I32.add i 1#i32) cap = ok slot_i ∧
      prev_head ≠ slot_i ∧
      ring_slot_add head len cap = ok slot_tail ∧
      slot_tail ≠ slot_i := by
  have h1 : (1#i32).val = 1 := by decide
  have h0v : (0#i32).val = 0 := by decide
  obtain ⟨nh, hnh, hnh_val, hnh0, hnhc⟩ :=
    ring_slot_add_val head 1#i32 cap hh0 (by omega) (by omega) (by omega)
  obtain ⟨nh_prev, hnh_prev, hnh_prev_val, _, _⟩ :=
    ring_slot_prev_val nh cap hnh0 hnhc hc
  obtain ⟨ph, hph, hph_val, hph0, hphc⟩ :=
    ring_slot_prev_val head cap hh0 hhc hc
  obtain ⟨si, hsi, hsi_val, _, _⟩ :=
    ring_slot_add_val head i cap hh0 hi0 (by omega) (by omega)
  have hi1_val : (Pion.I32.add i 1#i32).val = i.val + 1 := by
    rw [i32_add_val_ci i 1#i32 (by omega) (by omega), h1]
  obtain ⟨si', hsi', hsi'_val, _, _⟩ :=
    ring_slot_add_val ph (Pion.I32.add i 1#i32) cap hph0 (by omega) (by omega) (by omega)
  obtain ⟨st, hst, hst_val, _, _⟩ :=
    ring_slot_add_val head len cap hh0 hlen0 (by omega) (by omega)
  have hnh_prev_eq : nh_prev = head := by
    apply i32_eq_of_val_ci
    rw [hnh_prev_val, hnh_val, h1]
    by_cases hlast : head.val + 1 = cap.val
    · have hm : (head.val + 1) % cap.val = 0 := by rw [hlast, Int.emod_self]
      rw [hm]
      have : (0 - 1 + cap.val) = cap.val - 1 := by omega
      rw [this, Int.emod_eq_of_lt (by omega) (by omega)]
      omega
    · have hm : (head.val + 1) % cap.val = head.val + 1 :=
        Int.emod_eq_of_lt (by omega) (by omega)
      rw [hm]
      have : (head.val + 1 - 1 + cap.val) = head.val + cap.val * 1 := by omega
      rw [this, Int.add_mul_emod_self_left, Int.emod_eq_of_lt hh0 hhc]
  have hsi'_eq : si' = si := by
    apply i32_eq_of_val_ci
    rw [hsi'_val, hi1_val, hph_val, hsi_val]
    have hph_mod : (head.val - 1 + cap.val) % cap.val =
        if head.val = 0 then cap.val - 1 else head.val - 1 := by
      split_ifs with hz
      · have : head.val - 1 + cap.val = cap.val - 1 := by omega
        rw [this]; exact Int.emod_eq_of_lt (by omega) (by omega)
      · have : head.val - 1 + cap.val = (head.val - 1) + cap.val * 1 := by omega
        rw [this, Int.add_mul_emod_self_left]
        exact Int.emod_eq_of_lt (by omega) (by omega)
    rw [hph_mod]
    split_ifs with hz
    · have heq1 : cap.val - 1 + (i.val + 1) = i.val + cap.val * 1 := by omega
      have heq2 : head.val + i.val = i.val := by omega
      rw [heq1, heq2, Int.add_mul_emod_self_left]
    · have heq1 : head.val - 1 + (i.val + 1) = head.val + i.val := by omega
      rw [heq1]
  have hph_ne_si : ph ≠ si := by
    intro hpeq
    obtain ⟨s0, hs0, hs0_val, _, _⟩ :=
      ring_slot_add_val ph 0#i32 cap hph0 (by omega) (by omega) (by omega)
    have hs0_eq : s0 = ph := by
      apply i32_eq_of_val_ci
      rw [hs0_val, h0v]
      have : ph.val + 0 = ph.val := by omega
      rw [this, Int.emod_eq_of_lt hph0 hphc]
    rw [hs0_eq] at hs0
    rw [hsi'_eq] at hsi'
    have h0_eq_i1 : 0#i32 = Pion.I32.add i 1#i32 :=
      ring_slot_add_injective_window ph 0#i32 (Pion.I32.add i 1#i32) cap
        hph0 hphc hc (by omega) (by omega) (by omega) (by omega)
        (hs0.trans (hpeq.symm ▸ hsi'.symm))
    have := congrArg IScalar.val h0_eq_i1
    rw [h0v, hi1_val] at this
    omega
  have hst_ne_si : st ≠ si := by
    intro hteq
    have hlen_eq_i : len = i :=
      ring_slot_add_injective_window head len i cap hh0 hhc hc hlen0 hlenc hi0 (by omega)
        (hst.trans (hteq.symm ▸ hsi.symm))
    have := congrArg IScalar.val hlen_eq_i
    omega
  rw [hnh_prev_eq] at hnh_prev
  rw [hsi'_eq] at hsi'
  exact ⟨nh, ph, si, st, hnh, hnh_prev, hph, hsi, hsi', hph_ne_si, hst, hst_ne_si⟩

end EffectProofs
