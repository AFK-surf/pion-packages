import CrdtProofs.Core

open Aeneas Aeneas.Std Result Pion crdt

namespace CrdtProofs

/-- `TypeRef` wire enum roundtrip: `int_to_type_ref (type_ref_to_int tr) = ok tr`. -/
theorem type_ref_roundtrip (tr : TypeRef) :
    (do let v ← type_ref_to_int tr; int_to_type_ref v) = ok tr := by
  cases tr <;> simp [type_ref_to_int, int_to_type_ref]

/-- `type_ref_to_int` always yields `{0, 1, 2}`. -/
theorem type_ref_to_int_range (tr : TypeRef) :
    ∃ v : Std.I32, type_ref_to_int tr = ok v ∧ (v = 0#i32 ∨ v = 1#i32 ∨ v = 2#i32) := by
  cases tr <;> simp [type_ref_to_int]

/-- `int_to_type_ref` is injective on valid wire IDs `{0, 1, 2}`. -/
theorem int_to_type_ref_injective_on_valid (v1 v2 : Std.I32)
    (h1lo : 0 ≤ v1.val) (h1hi : v1.val ≤ 2)
    (h2lo : 0 ≤ v2.val) (h2hi : v2.val ≤ 2)
    (heq : int_to_type_ref v1 = int_to_type_ref v2) :
    v1 = v2 := by
  unfold int_to_type_ref at heq
  dsimp only at heq
  apply (iscalar_eq_iff v1 v2).mpr
  by_cases h10 : v1 = 0#i32
  · simp only [h10, ↓reduceIte] at heq
    by_cases h20 : v2 = 0#i32
    · rw [(iscalar_eq_iff _ _).mp h10, (iscalar_eq_iff _ _).mp h20]
    · simp only [h20, ↓reduceIte] at heq
      split_ifs at heq <;> simp only [ok.injEq, reduceCtorEq] at heq
  · simp only [h10, ↓reduceIte] at heq
    by_cases h11 : v1 = 1#i32
    · simp only [h11, ↓reduceIte] at heq
      by_cases h20 : v2 = 0#i32
      · simp only [h20, ↓reduceIte, ok.injEq, reduceCtorEq] at heq
      · simp only [h20, ↓reduceIte] at heq
        by_cases h21 : v2 = 1#i32
        · rw [(iscalar_eq_iff _ _).mp h11, (iscalar_eq_iff _ _).mp h21]
        · simp only [h21, ↓reduceIte, ok.injEq, reduceCtorEq] at heq
    · simp only [h11, ↓reduceIte] at heq
      by_cases h20 : v2 = 0#i32
      · simp only [h20, ↓reduceIte, ok.injEq, reduceCtorEq] at heq
      · simp only [h20, ↓reduceIte] at heq
        by_cases h21 : v2 = 1#i32
        · simp only [h21, ↓reduceIte, ok.injEq, reduceCtorEq] at heq
        · have n10 : v1.val ≠ 0 := fun h => h10 ((iscalar_eq_iff _ _).mpr h)
          have n11 : v1.val ≠ 1 := fun h => h11 ((iscalar_eq_iff _ _).mpr h)
          have n20 : v2.val ≠ 0 := fun h => h20 ((iscalar_eq_iff _ _).mpr h)
          have n21 : v2.val ≠ 1 := fun h => h21 ((iscalar_eq_iff _ _).mpr h)
          omega

/-- `item_last_id` preserves `client` and yields `clock + len - 1` without underflow for `len ≥ 1`. -/
theorem item_last_id_spec (id : Id) (len : Std.U64)
    (hlen : 1 ≤ len.val) (hnoov : id.clock.val + len.val < 2 ^ 64) :
    ∃ r : Id, item_last_id id len = ok r ∧
      r.client = id.client ∧ r.clock.val = id.clock.val + len.val - 1 := by
  unfold item_last_id
  split_ifs with h1
  · rw [uscalar_le_iff] at h1
    have h1v : (1#u64).val = 1 := rfl
    refine ⟨id, rfl, rfl, by omega⟩
  · unfold Id.new
    rw [result_bind_ok]
    refine ⟨_, rfl, rfl, ?_⟩
    have h1v : (1#u64).val = 1 := rfl
    have hadd := u64_add_val id.clock len hnoov
    have hsub := u64_sub_val (Pion.U64.add id.clock len) 1#u64 (by omega)
    change (Pion.U64.sub (Pion.U64.add id.clock len) 1#u64).val = id.clock.val + len.val - 1
    omega

/-- Singleton item (`len = 1`) has `item_last_id id 1 = ok id`. -/
theorem item_last_id_singleton (id : Id) :
    item_last_id id 1#u64 = ok id := by
  unfold item_last_id
  simp

/-- `delete_item_contains` matches the exact half-open interval `[clock, clock + len)` when non-overflowing. -/
theorem delete_item_contains_iff (item : DeleteItem) (c : Std.U64)
    (hnoov : item.clock.val + item.len.val < 2 ^ 64) :
    delete_item_contains item c = ok true ↔
      item.clock.val ≤ c.val ∧ c.val < item.clock.val + item.len.val := by
  unfold delete_item_contains
  simp only [ok.injEq, Bool.and_eq_true, decide_eq_true_eq, uscalar_le_iff, uscalar_lt_iff]
  rw [u64_add_val item.clock item.len hnoov]

/-- An empty delete range (`len = 0`) contains no clocks. -/
theorem delete_item_contains_empty (item : DeleteItem) (c : Std.U64) (h0 : item.len = 0#u64) :
    delete_item_contains item c = ok false := by
  unfold delete_item_contains
  have hadd : Pion.U64.add item.clock item.len = item.clock := by
    rw [h0]
    apply (uscalar_eq_iff _ _).mpr
    have hlt : item.clock.val + (0#u64).val < 2 ^ 64 := by
      have h0v : (0#u64).val = 0 := rfl
      have := item.clock.bv.isLt
      have hpow : (2 : Nat) ^ UScalarTy.U64.numBits = 2 ^ 64 := rfl
      change item.clock.bv.toNat + (0#u64).val < 2 ^ 64
      omega
    rw [u64_add_val _ _ hlt]
    rfl
  rw [hadd]
  simp only [ok.injEq, Bool.and_eq_false_iff, decide_eq_false_iff_not, uscalar_le_iff, uscalar_lt_iff]
  omega

/-- `delete_item_can_merge` holds iff `cur.clock ≤ nxt.clock ≤ cur.clock + cur.len` (when non-overflowing). -/
theorem delete_item_can_merge_iff (cur nxt : DeleteItem)
    (hnoov : cur.clock.val + cur.len.val < 2 ^ 64) :
    delete_item_can_merge cur nxt = ok true ↔
      cur.clock.val ≤ nxt.clock.val ∧ nxt.clock.val ≤ cur.clock.val + cur.len.val := by
  unfold delete_item_can_merge
  simp only [ok.injEq, Bool.and_eq_true, decide_eq_true_eq, uscalar_le_iff]
  rw [u64_add_val cur.clock cur.len hnoov]

/-- `delete_item_merge` preserves `cur.clock` and sets end to `max(end_cur, end_nxt)`. -/
theorem delete_item_merge_sound (cur nxt : DeleteItem)
    (hle : cur.clock.val ≤ nxt.clock.val)
    (hnoov_cur : cur.clock.val + cur.len.val < 2 ^ 64)
    (hnoov_nxt : nxt.clock.val + nxt.len.val < 2 ^ 64) :
    ∃ m : DeleteItem, delete_item_merge cur nxt = ok m ∧
      m.clock = cur.clock ∧
      m.clock.val + m.len.val = max (cur.clock.val + cur.len.val) (nxt.clock.val + nxt.len.val) := by
  unfold delete_item_merge
  refine ⟨_, rfl, rfl, ?_⟩
  have h1 := u64_add_val cur.clock cur.len hnoov_cur
  have h2 := u64_add_val nxt.clock nxt.len hnoov_nxt
  split_ifs with hgt
  · rw [uscalar_gt_iff] at hgt
    have hsub := u64_sub_val (Pion.U64.add nxt.clock nxt.len) cur.clock (by omega)
    change cur.clock.val + (Pion.U64.sub (Pion.U64.add nxt.clock nxt.len) cur.clock).val = _
    omega
  · rw [uscalar_gt_iff] at hgt
    have hsub := u64_sub_val (Pion.U64.add cur.clock cur.len) cur.clock (by omega)
    change cur.clock.val + (Pion.U64.sub (Pion.U64.add cur.clock cur.len) cur.clock).val = _
    omega

/-- Interval-union soundness: merging overlapping/adjacent `cur` and `nxt` covers a clock iff `cur` or `nxt` covers it. -/
theorem delete_item_merge_covers_both (cur nxt : DeleteItem)
    (hmerge : delete_item_can_merge cur nxt = ok true)
    (hnoov_cur : cur.clock.val + cur.len.val < 2 ^ 64)
    (hnoov_nxt : nxt.clock.val + nxt.len.val < 2 ^ 64) :
    ∃ m : DeleteItem, delete_item_merge cur nxt = ok m ∧
      ∀ c : Std.U64,
        delete_item_contains m c = ok true ↔
          (delete_item_contains cur c = ok true ∨ delete_item_contains nxt c = ok true) := by
  have ⟨hle, htouch⟩ := (delete_item_can_merge_iff cur nxt hnoov_cur).mp hmerge
  obtain ⟨m, hm, hmc, hmend⟩ := delete_item_merge_sound cur nxt hle hnoov_cur hnoov_nxt
  refine ⟨m, hm, fun c => ?_⟩
  have hnoov_m : m.clock.val + m.len.val < 2 ^ 64 := by omega
  rw [delete_item_contains_iff m c hnoov_m,
      delete_item_contains_iff cur c hnoov_cur,
      delete_item_contains_iff nxt c hnoov_nxt,
      hmend, hmc]
  omega

/-- `delete_item_merge` is idempotent: merging an item with itself yields the same item. -/
theorem delete_item_merge_idempotent (item : DeleteItem)
    (hnoov : item.clock.val + item.len.val < 2 ^ 64) :
    delete_item_merge item item = ok item := by
  obtain ⟨m, hm, hmc, hmend⟩ := delete_item_merge_sound item item (le_refl _) hnoov hnoov
  rw [hm]
  congr 1
  cases item with | mk ic il =>
  cases m with | mk mc ml =>
  simp only at hmc hmend
  subst hmc
  have hml : ml = il := (uscalar_eq_iff ml il).mpr (by omega)
  subst hml
  rfl

end CrdtProofs
