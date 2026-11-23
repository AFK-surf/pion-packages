import Aeneas
import PionLean
import Regex.Types
import Regex.Funs

open Aeneas Aeneas.Std Result Error Pion
open regex

namespace RegexProofs

private lemma result_bind_ok_lo {α β : Type} (a : α) (f : α → Result β) :
    (do let x ← ok a; f x) = f a := by
  simp

private lemma i32_beq_iff_lo (x y : Std.I32) : (x == y) = true ↔ x.val = y.val := by
  cases x; cases y
  simp [BEq.beq, IScalar.val, BitVec.toInt_inj]

private lemma i32_eq_of_val_lo {x y : Std.I32} (h : x.val = y.val) : x = y := by
  cases x; cases y
  simp [IScalar.val, BitVec.toInt_inj] at h
  congr

private lemma i64_eq_of_bv_lo {x y : Std.I64} (h : x.bv = y.bv) : x = y := by
  cases x; cases y
  simp at h
  exact congrArg IScalar.mk h

private lemma i32_add_val_lo (x y : Std.I32)
    (hlo : -(2 ^ 31 : Int) ≤ x.val + y.val) (hhi : x.val + y.val < 2 ^ 31) :
    (Pion.I32.add x y).val = x.val + y.val := by
  change -(2 ^ 31 : Int) ≤ x.bv.toInt + y.bv.toInt at hlo
  change x.bv.toInt + y.bv.toInt < 2 ^ 31 at hhi
  change (x.bv + y.bv).toInt = x.bv.toInt + y.bv.toInt
  rw [BitVec.toInt_add]
  exact Int.bmod_eq_of_le (by omega) (by omega)

/-! ==========================================================================
    1. PikeVM ↔ Lazy DFA Look-Around Exact Semantic Equivalence
    ========================================================================== -/

/-- **A-grade**: Exact semantic equivalence between PikeVM's `pike_look_holds` and
    Lazy DFA's `dfa_look_holds` across all 8 `LookKind` variants and all text/byte/word
    contexts at UTF-8 character boundaries, plus P0-2 non-char-boundary rejection and
    exact `\b` / `\B` complementarity. Any drift on either engine breaks this proof. -/
theorem pike_dfa_look_equiv
    (lk : LookKind)
    (pos text_len prev_byte next_byte : Std.I32)
    (prev_is_word next_is_word : Bool)
    (hposn : pos.val ≤ text_len.val) :
    let at_start_text : Bool := pos == 0#i32
    let at_start_line : Bool := (pos == 0#i32) || (prev_byte == 10#i32)
    let at_eoi : Bool := pos == text_len
    let next_is_nl : Bool := decide (pos < text_len) && (next_byte == 10#i32)
    pike_look_holds lk pos text_len prev_byte next_byte true prev_is_word next_is_word =
      dfa_look_holds lk at_start_text at_start_line prev_is_word next_is_nl next_is_word at_eoi ∧
    (pike_look_holds .WordBoundaryAscii pos text_len prev_byte next_byte false prev_is_word next_is_word = ok false ∧
     pike_look_holds .NotWordBoundaryAscii pos text_len prev_byte next_byte false prev_is_word next_is_word = ok false ∧
     pike_look_holds .WordBoundaryUnicode pos text_len prev_byte next_byte false prev_is_word next_is_word = ok false ∧
     pike_look_holds .NotWordBoundaryUnicode pos text_len prev_byte next_byte false prev_is_word next_is_word = ok false) ∧
    (∃ bw bnw : Bool,
      pike_look_holds .WordBoundaryAscii pos text_len prev_byte next_byte true prev_is_word next_is_word = ok bw ∧
      pike_look_holds .NotWordBoundaryAscii pos text_len prev_byte next_byte true prev_is_word next_is_word = ok bnw ∧
      bnw = !bw) := by
  dsimp only
  refine ⟨?_, ?_, ?_⟩
  · cases lk
    · -- StartText
      rfl
    · -- EndText
      rfl
    · -- StartLine
      rfl
    · -- EndLine
      unfold pike_look_holds dfa_look_holds
      by_cases heoi : (pos == text_len) = true
      · simp [heoi]
      · have hne : pos.val ≠ text_len.val := by
          intro h; exact heoi ((i32_beq_iff_lo pos text_len).mpr h)
        have hf : (pos == text_len) = false := Bool.eq_false_iff.mpr heoi
        simp only [hf, Bool.false_or]
        have hlt : decide (pos < text_len) = true := by
          simp only [decide_eq_true_eq, IScalar.lt_equiv]; omega
        rw [hlt, Bool.true_and]
    · -- WordBoundaryAscii
      unfold pike_look_holds dfa_look_holds
      simp
    · -- NotWordBoundaryAscii
      unfold pike_look_holds dfa_look_holds
      simp
    · -- WordBoundaryUnicode
      unfold pike_look_holds dfa_look_holds
      simp
    · -- NotWordBoundaryUnicode
      unfold pike_look_holds dfa_look_holds
      simp
  · unfold pike_look_holds
    simp
  · unfold pike_look_holds
    cases prev_is_word <;> cases next_is_word <;> simp

/-! ==========================================================================
    2. Reverse NFA Look-Around Duality & Involution
    ========================================================================== -/

/-- **A-grade**: Exact forward/reverse duality of `reverse_look_kind` under `dfa_look_holds`:
    for all 8 `LookKind`s and all boundary/word contexts, evaluating `reverse_look_kind lk`
    on the reversed text context (`start ↔ eoi`, `prev_nl ↔ next_nl`, `prev_word ↔ next_word`)
    is identical to evaluating `lk` on the forward text context, and `reverse_look_kind`
    is an exact involution. -/
theorem reverse_look_kind_duality
    (lk : LookKind)
    (at_start_text prev_is_nl prev_is_word next_is_nl next_is_word at_eoi : Bool) :
    ∃ rlk : LookKind,
      reverse_look_kind lk = ok rlk ∧
      reverse_look_kind rlk = ok lk ∧
      dfa_look_holds rlk at_eoi (at_eoi || next_is_nl) next_is_word prev_is_nl prev_is_word at_start_text =
        dfa_look_holds lk at_start_text (at_start_text || prev_is_nl) prev_is_word next_is_nl next_is_word at_eoi := by
  cases lk <;>
    refine ⟨_, rfl, rfl, ?_⟩ <;>
    unfold dfa_look_holds <;>
    cases at_start_text <;> cases prev_is_nl <;> cases prev_is_word <;>
    cases next_is_nl <;> cases next_is_word <;> cases at_eoi <;> rfl

/-! ==========================================================================
    3. CharRange Merge & Intersection Algebraic Invariants
    ========================================================================== -/

/-- **A-grade**: Exact soundness and completeness of `char_range_can_merge` and
    `char_range_merge` across the entire `I32` domain (including `INT32_MAX`, zero overflow):
    - `char_range_can_merge cur r = ok true ↔ r.lo ≤ cur.hi + 1`;
    - when mergeable, `char_range_merge cur r` is the exact integer set union of `cur` and `r`;
    - when not mergeable, there is a strict gap (`cur.hi + 1 < r.lo`). -/
theorem char_range_merge_union_iff (cur r : CharRange)
    (hord : cur.lo.val ≤ r.lo.val) :
    ∃ b : Bool, ∃ m : CharRange,
      char_range_can_merge cur r = ok b ∧
      char_range_merge cur r = ok m ∧
      (b = true ↔ r.lo.val ≤ cur.hi.val + 1) ∧
      (b = true →
        ∀ x : Int,
          (m.lo.val ≤ x ∧ x ≤ m.hi.val) ↔
            ((cur.lo.val ≤ x ∧ x ≤ cur.hi.val) ∨ (r.lo.val ≤ x ∧ x ≤ r.hi.val))) ∧
      (b = false → cur.hi.val + 1 < r.lo.val) := by
  have hmax : (2147483647#i32).val = 2147483647 := by decide
  have h1 : (1#i32).val = 1 := by decide
  have hcur_b := cur.hi.hBounds
  have hr_b := r.lo.hBounds
  simp at hcur_b hr_b
  unfold char_range_can_merge char_range_merge
  have hcm : ((decide (cur.hi >= 2147483647#i32)) || (decide (r.lo <= Pion.I32.add cur.hi 1#i32))) = true ↔
      r.lo.val ≤ cur.hi.val + 1 := by
    by_cases hge : cur.hi.val = 2147483647
    · simp only [Bool.or_eq_true, decide_eq_true_eq, ge_iff_le, IScalar.le_equiv, hmax]
      omega
    · have hadd : (Pion.I32.add cur.hi 1#i32).val = cur.hi.val + 1 := by
        rw [i32_add_val_lo cur.hi 1#i32 (by omega) (by omega), h1]
      simp only [Bool.or_eq_true, decide_eq_true_eq, ge_iff_le, IScalar.le_equiv, hmax, hadd]
      omega
  refine ⟨_, _, rfl, rfl, hcm, ?_, ?_⟩
  · intro hb x
    have hle : r.lo.val ≤ cur.hi.val + 1 := hcm.mp hb
    dsimp only
    split_ifs with hgt
    · simp only [gt_iff_lt, IScalar.lt_equiv] at hgt
      omega
    · simp only [gt_iff_lt, IScalar.lt_equiv] at hgt
      omega
  · intro hb
    have hnot : ¬ (r.lo.val ≤ cur.hi.val + 1) := by
      intro hle
      exact Bool.false_ne_true (hb.symm.trans (hcm.mpr hle))
    omega

/-- **A-grade**: Algebraic lattice laws for `char_range_intersect`:
    commutativity, idempotence, associativity, and exact emptiness characterization. -/
theorem char_range_intersect_alg_laws (a b c : CharRange) :
    char_range_intersect a b = char_range_intersect b a ∧
    char_range_intersect a a = ok a ∧
    (∃ ab bc abc : CharRange,
      char_range_intersect a b = ok ab ∧
      char_range_intersect b c = ok bc ∧
      char_range_intersect ab c = ok abc ∧
      char_range_intersect a bc = ok abc) ∧
    (∃ r : CharRange,
      char_range_intersect a b = ok r ∧
      (r.hi.val < r.lo.val ↔
        ∀ x : Int, ¬ ((a.lo.val ≤ x ∧ x ≤ a.hi.val) ∧ (b.lo.val ≤ x ∧ x ≤ b.hi.val)))) := by
  refine ⟨?_, ?_, ?_, ?_⟩
  · unfold char_range_intersect
    have hlo : (if a.lo > b.lo then a.lo else b.lo) = (if b.lo > a.lo then b.lo else a.lo) := by
      apply i32_eq_of_val_lo
      split_ifs with h1 h2 h2 <;> simp only [gt_iff_lt, IScalar.lt_equiv] at * <;> omega
    have hhi : (if a.hi < b.hi then a.hi else b.hi) = (if b.hi < a.hi then b.hi else a.hi) := by
      apply i32_eq_of_val_lo
      split_ifs with h1 h2 h2 <;> simp only [IScalar.lt_equiv] at * <;> omega
    rw [hlo, hhi]
  · unfold char_range_intersect
    simp
  · unfold char_range_intersect
    let ab : CharRange := ⟨if a.lo > b.lo then a.lo else b.lo, if a.hi < b.hi then a.hi else b.hi⟩
    let bc : CharRange := ⟨if b.lo > c.lo then b.lo else c.lo, if b.hi < c.hi then b.hi else c.hi⟩
    let abc : CharRange := ⟨if ab.lo > c.lo then ab.lo else c.lo, if ab.hi < c.hi then ab.hi else c.hi⟩
    refine ⟨ab, bc, abc, rfl, rfl, rfl, ?_⟩
    have hlo : (if a.lo > bc.lo then a.lo else bc.lo) = abc.lo := by
      apply i32_eq_of_val_lo
      dsimp only [ab, bc, abc]
      split_ifs <;> simp only [gt_iff_lt, IScalar.lt_equiv] at * <;> omega
    have hhi : (if a.hi < bc.hi then a.hi else bc.hi) = abc.hi := by
      apply i32_eq_of_val_lo
      dsimp only [ab, bc, abc]
      split_ifs <;> simp only [IScalar.lt_equiv] at * <;> omega
    exact congrArg ok (congrArg₂ CharRange.mk hlo hhi)
  · refine ⟨⟨if a.lo > b.lo then a.lo else b.lo, if a.hi < b.hi then a.hi else b.hi⟩, rfl, ?_⟩
    dsimp only
    constructor
    · intro hlt x hx
      split_ifs at hlt with h1 h2 h2 <;> simp only [gt_iff_lt, IScalar.lt_equiv] at * <;> omega
    · intro hnone
      by_contra hle
      have hge : (if a.lo > b.lo then a.lo else b.lo).val ≤
                 (if a.hi < b.hi then a.hi else b.hi).val := by omega
      apply hnone (if a.lo > b.lo then a.lo else b.lo).val
      split_ifs at hge ⊢ with h1 h2 h2 <;> simp only [gt_iff_lt, IScalar.lt_equiv] at * <;> omega

/-! ==========================================================================
    4. One-Pass DFA 64-bit Slot Bitmask & Structural Budget Invariants
    ========================================================================== -/

private lemma shl1_bit_spec (k : Nat) (hk : k < 63) (j : Nat) (hj : j < 64) :
    ((1#64) <<< k)[j] = decide (j = k) := by
  simp only [BitVec.getElem_shiftLeft]
  by_cases hlt : j < k
  · have hne : j ≠ k := by omega
    simp [hlt, hne]
  · simp only [hlt, decide_false, Bool.not_false, Bool.true_and]
    rw [BitVec.getElem_eq_testBit_toNat]
    have h1 : (1#64).toNat = 1 := by decide
    rw [h1]
    by_cases heq : j = k
    · subst heq; simp
    · have hpos : 0 < j - k := by omega
      have htb : Nat.testBit 1 (j - k) = false := by
        rw [Nat.testBit_eq_decide_div_mod_eq]
        have h2 : 2 ≤ 2 ^ (j - k) := by
          calc 2 = 2 ^ 1 := by decide
            _ ≤ 2 ^ (j - k) := Nat.pow_le_pow_right (by omega) hpos
        have hd : 1 / 2 ^ (j - k) = 0 := Nat.div_eq_of_lt (by omega)
        simp [hd]
      simp [heq, htb]

/-- **A-grade**: Full 64-bit per-bit semantics, sign-bit preservation, non-interference,
    and commutativity of `onepass_mask_add_slot` across all `I32` slot arguments. -/
theorem onepass_mask_add_slot_bit_spec
    (mask : Std.I64) (slot1 slot2 nslots : Std.I32) :
    (∃ m1 : Std.I64,
      onepass_mask_add_slot mask slot1 nslots = ok m1 ∧
      (∀ (j : Nat) (hj : j < 64),
        m1.bv[j] =
          if 0 ≤ slot1.val ∧ slot1.val < nslots.val ∧ slot1.val < 63 ∧ j = slot1.val.toNat
          then true else mask.bv[j]) ∧
      m1.bv[63] = mask.bv[63]) ∧
    (∃ m1 m2 m12 : Std.I64,
      onepass_mask_add_slot mask slot1 nslots = ok m1 ∧
      onepass_mask_add_slot mask slot2 nslots = ok m2 ∧
      onepass_mask_add_slot m1 slot2 nslots = ok m12 ∧
      onepass_mask_add_slot m2 slot1 nslots = ok m12) := by
  have h0 : (0#i32).val = 0 := by decide
  have h63 : (63#i32).val = 63 := by decide
  have hstep : ∀ (m : Std.I64) (s : Std.I32),
      ∃ m' : Std.I64,
        onepass_mask_add_slot m s nslots = ok m' ∧
        ∀ (j : Nat) (hj : j < 64),
          m'.bv[j] =
            if 0 ≤ s.val ∧ s.val < nslots.val ∧ s.val < 63 ∧ j = s.val.toNat
            then true else m.bv[j] := by
    intro m s
    unfold onepass_mask_add_slot
    by_cases hc : 0 ≤ s.val ∧ s.val < nslots.val ∧ s.val < 63
    · have hcond : ((((decide (s >= 0#i32)) && (decide (s < nslots))) &&
          (decide (s < 63#i32))) = true) := by
        simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le,
          IScalar.le_equiv, IScalar.lt_equiv, h0, h63]
        omega
      have hshl : Pion.I64.shl_i32 1#i64 s = ok ⟨(1#64) <<< s.val.toNat⟩ := by
        simp [Pion.I64.shl_i32]; omega
      simp only [hcond, ↓reduceIte, hshl, result_bind_ok_lo]
      refine ⟨Pion.I64.bor m ⟨(1#64) <<< s.val.toNat⟩, rfl, ?_⟩
      intro j hj
      change (m.bv ||| (1#64) <<< s.val.toNat)[j] = _
      rw [BitVec.getElem_or, shl1_bit_spec s.val.toNat (by omega) j hj]
      by_cases hjeq : j = s.val.toNat
      · simp [hc, hjeq]
      · simp [hc, hjeq]
    · have hcond : ((((decide (s >= 0#i32)) && (decide (s < nslots))) &&
          (decide (s < 63#i32))) = false) := by
        simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, ge_iff_le,
          IScalar.le_equiv, IScalar.lt_equiv, h0, h63]
        omega
      simp only [hcond, Bool.false_eq_true, ↓reduceIte]
      refine ⟨m, rfl, ?_⟩
      intro j hj
      have hnc : ¬ (0 ≤ s.val ∧ s.val < nslots.val ∧ s.val < 63 ∧ j = s.val.toNat) := by
        intro h; exact hc ⟨h.1, h.2.1, h.2.2.1⟩
      simp [hnc]
  refine ⟨?_, ?_⟩
  · obtain ⟨m1, hm1, hm1_bits⟩ := hstep mask slot1
    refine ⟨m1, hm1, hm1_bits, ?_⟩
    have h63bit := hm1_bits 63 (by omega)
    have hne : ¬ (0 ≤ slot1.val ∧ slot1.val < nslots.val ∧ slot1.val < 63 ∧ 63 = slot1.val.toNat) := by
      omega
    simp only [hne, ↓reduceIte] at h63bit
    exact h63bit
  · obtain ⟨m1, hm1, hm1_bits⟩ := hstep mask slot1
    obtain ⟨m12, hm12, hm12_bits⟩ := hstep m1 slot2
    obtain ⟨m2, hm2, hm2_bits⟩ := hstep mask slot2
    obtain ⟨m21, hm21, hm21_bits⟩ := hstep m2 slot1
    have heq : m12 = m21 := by
      apply i64_eq_of_bv_lo
      apply BitVec.eq_of_getElem_eq
      intro j hj
      rw [hm12_bits j hj, hm1_bits j hj, hm21_bits j hj, hm2_bits j hj]
      split_ifs <;> rfl
    rw [← heq] at hm21
    exact ⟨m1, m2, m12, hm1, hm2, hm12, hm21⟩

/-- **A-grade**: `onepass_can_compile` guarantees look-free NFA, bounded state budget
    (`≤ 512`), and capture slot budget `2 ≤ 2 * num_captures ≤ 62 < 63` so every capture
    slot fits strictly inside the 63 non-sign bits of `onepass_mask_add_slot`. -/
theorem onepass_can_compile_slot_budget
    (has_look : Bool) (num_captures num_nfa : Std.I32) :
    onepass_can_compile has_look num_captures num_nfa = ok true →
    has_look = false ∧
    2 ≤ num_captures.val * 2 ∧
    num_captures.val * 2 ≤ 62 ∧
    num_nfa.val ≤ 512 := by
  unfold onepass_can_compile
  have h1 : (1#i32).val = 1 := by decide
  have h31 : (31#i32).val = 31 := by decide
  have h512 : (512#i32).val = 512 := by decide
  simp only [Result.ok.injEq, Bool.and_eq_true, Bool.not_eq_true',
    decide_eq_true_eq, ge_iff_le, IScalar.le_equiv, h1, h31, h512]
  intro ⟨⟨⟨hlk, hlo⟩, hhi⟩, hnfa⟩
  exact ⟨hlk, by omega, by omega, hnfa⟩

end RegexProofs
