import CrdtProofs.Core

open Aeneas Aeneas.Std Result Pion crdt

namespace CrdtProofs

/-- Full-domain `u64_sat_add` specification over ALL `UInt64` inputs:
    never traps and equals `min (a + b) (2^64 - 1)` without 64-bit wraparound. -/
theorem u64_sat_add_spec (a b : Std.U64) :
    ∃ r : Std.U64, u64_sat_add a b = ok r ∧
      r.val = min (a.val + b.val) 18446744073709551615 := by
  have ha := u64_lt_pow64 a
  have hb := u64_lt_pow64 b
  have hm := u64_max_val
  unfold u64_sat_add
  have hsub := u64_sub_val 18446744073709551615#u64 a (by omega)
  by_cases hov : b.val > 18446744073709551615 - a.val
  · have hov' : b > Pion.U64.sub 18446744073709551615#u64 a := by
      rw [uscalar_gt_iff, hsub, hm]; omega
    simp only [hov', ↓reduceIte]
    exact ⟨18446744073709551615#u64, rfl, by omega⟩
  · have hov' : ¬(b > Pion.U64.sub 18446744073709551615#u64 a) := by
      rw [uscalar_gt_iff, hsub, hm]; omega
    simp only [hov', ↓reduceIte]
    have hadd := u64_add_val a b (by omega)
    exact ⟨Pion.U64.add a b, rfl, by omega⟩

/-- Full-domain `item_last_id` specification over ALL `(id : Id, len : UInt64)` (ZERO overflow hypothesis):
    preserves `client`, saturates at `UInt64::MAX`, and is always monotonic (`id.clock ≤ r.clock`). -/
theorem item_last_id_full_domain (id : Id) (len : Std.U64) :
    ∃ r : Id, item_last_id id len = ok r ∧
      r.client = id.client ∧
      id.clock.val ≤ r.clock.val ∧
      r.clock.val = (if len.val ≤ 1 then id.clock.val
                     else min (id.clock.val + (len.val - 1)) 18446744073709551615) := by
  have hc := u64_lt_pow64 id.clock
  have h1v : (1#u64).val = 1 := rfl
  unfold item_last_id
  by_cases hle : len.val ≤ 1
  · have hle' : len ≤ 1#u64 := by rw [uscalar_le_iff, h1v]; exact hle
    simp only [hle', hle, ↓reduceIte]
    exact ⟨id, rfl, rfl, le_refl _, rfl⟩
  · have hle' : ¬(len ≤ 1#u64) := by rw [uscalar_le_iff, h1v]; exact hle
    simp only [hle', hle, ↓reduceIte]
    have hsub := u64_sub_val len 1#u64 (by omega)
    obtain ⟨sat, hsat, hsatv⟩ := u64_sat_add_spec id.clock (Pion.U64.sub len 1#u64)
    rw [hsat, result_bind_ok]
    unfold Id.new
    rw [result_bind_ok]
    exact ⟨Id.mk id.client sat, rfl, rfl, by dsimp only; omega, by dsimp only; omega⟩

/-- Full-domain `delete_item_contains` specification over ALL `(item : DeleteItem, c : UInt64)`
    (ZERO `clock + len < 2^64` hypothesis): exact mathematical half-open interval `[clock, clock + len)` in `ℕ`. -/
theorem delete_item_contains_full_domain (item : DeleteItem) (c : Std.U64) :
    delete_item_contains item c = ok true ↔
      item.clock.val ≤ c.val ∧ c.val < item.clock.val + item.len.val := by
  have h0v : (0#u64).val = 0 := rfl
  unfold delete_item_contains
  simp only [ok.injEq, Bool.and_eq_true, decide_eq_true_eq, uscalar_gt_iff, uscalar_le_iff]
  constructor
  · rintro ⟨⟨hpos, hge⟩, hlt⟩
    rw [u64_sub_val c item.clock hge] at hlt
    omega
  · rintro ⟨hge, hlt⟩
    refine ⟨⟨by omega, hge⟩, ?_⟩
    rw [u64_sub_val c item.clock hge]
    omega

/-- Full-domain `delete_item_can_merge` specification over ALL `(cur nxt : DeleteItem)`
    (ZERO `clock + len < 2^64` hypothesis): exact interval overlap/adjacency in `ℕ`. -/
theorem delete_item_can_merge_full_domain (cur nxt : DeleteItem) :
    delete_item_can_merge cur nxt = ok true ↔
      cur.clock.val ≤ nxt.clock.val ∧ nxt.clock.val ≤ cur.clock.val + cur.len.val := by
  unfold delete_item_can_merge
  simp only [ok.injEq, Bool.and_eq_true, decide_eq_true_eq, uscalar_le_iff]
  constructor
  · rintro ⟨hle, hdiff⟩
    rw [u64_sub_val nxt.clock cur.clock hle] at hdiff
    omega
  · rintro ⟨hle, hsum⟩
    refine ⟨hle, ?_⟩
    rw [u64_sub_val nxt.clock cur.clock hle]
    omega

/-- Full-domain `delete_item_merge` specification over ALL `(cur nxt : DeleteItem)` (sorted or unsorted,
    wrapping or non-wrapping): sets `clock = min(cur.clock, nxt.clock)`, saturates span without 64-bit
    wraparound, and is unconditionally commutative (`delete_item_merge cur nxt = delete_item_merge nxt cur`). -/
theorem delete_item_merge_full_domain (cur nxt : DeleteItem) :
    ∃ m : DeleteItem, delete_item_merge cur nxt = ok m ∧
      delete_item_merge nxt cur = ok m ∧
      m.clock.val = min cur.clock.val nxt.clock.val ∧
      m.len.val = (if cur.clock.val ≤ nxt.clock.val then
                     max cur.len.val (min ((nxt.clock.val - cur.clock.val) + nxt.len.val) 18446744073709551615)
                   else
                     max nxt.len.val (min ((cur.clock.val - nxt.clock.val) + cur.len.val) 18446744073709551615)) := by
  have hcl := u64_lt_pow64 cur.len
  have hnl := u64_lt_pow64 nxt.len
  unfold delete_item_merge
  by_cases hle : cur.clock.val ≤ nxt.clock.val
  · have hle' : cur.clock ≤ nxt.clock := hle
    simp only [hle', hle, ↓reduceIte]
    have hsub := u64_sub_val nxt.clock cur.clock hle
    obtain ⟨sp, hsp, hspv⟩ := u64_sat_add_spec (Pion.U64.sub nxt.clock cur.clock) nxt.len
    rw [hsp, result_bind_ok]
    set new_len := if sp > cur.len then sp else cur.len
    have hnewv : new_len.val = max cur.len.val (min ((nxt.clock.val - cur.clock.val) + nxt.len.val) 18446744073709551615) := by
      simp only [new_len]
      split_ifs with hgt
      · rw [uscalar_gt_iff] at hgt; omega
      · rw [uscalar_gt_iff] at hgt; omega
    refine ⟨DeleteItem.mk cur.clock new_len, rfl, ?_, by dsimp only; omega, hnewv⟩
    by_cases heq : cur.clock.val = nxt.clock.val
    · have hceq : cur.clock = nxt.clock := (uscalar_eq_iff _ _).mpr heq
      have hle2 : nxt.clock ≤ cur.clock := by rw [uscalar_le_iff]; omega
      simp only [hle2, ↓reduceIte]
      have hsub2 := u64_sub_val cur.clock nxt.clock (by omega)
      obtain ⟨sp2, hsp2, hsp2v⟩ := u64_sat_add_spec (Pion.U64.sub cur.clock nxt.clock) cur.len
      rw [hsp2, result_bind_ok]
      congr 1
      cases cur with | mk cc cl =>
      cases nxt with | mk nc nl =>
      simp only at heq hceq hsub hspv hnewv hsub2 hsp2v hcl hnl ⊢
      subst hceq
      congr 1
      apply (uscalar_eq_iff _ _).mpr
      split_ifs with hgt2
      · rw [uscalar_gt_iff] at hgt2; omega
      · rw [uscalar_gt_iff] at hgt2; omega
    · have hnotle2 : ¬(nxt.clock ≤ cur.clock) := by rw [uscalar_le_iff]; omega
      simp only [hnotle2, ↓reduceIte]
  · have hle' : ¬(cur.clock ≤ nxt.clock) := hle
    have hle2 : nxt.clock ≤ cur.clock := by rw [uscalar_le_iff]; omega
    simp only [hle', hle, hle2, ↓reduceIte]
    have hsub := u64_sub_val cur.clock nxt.clock (by omega)
    obtain ⟨sp, hsp, hspv⟩ := u64_sat_add_spec (Pion.U64.sub cur.clock nxt.clock) cur.len
    rw [hsp, result_bind_ok]
    set new_len := if sp > nxt.len then sp else nxt.len
    have hnewv : new_len.val = max nxt.len.val (min ((cur.clock.val - nxt.clock.val) + cur.len.val) 18446744073709551615) := by
      simp only [new_len]
      split_ifs with hgt
      · rw [uscalar_gt_iff] at hgt; omega
      · rw [uscalar_gt_iff] at hgt; omega
    exact ⟨DeleteItem.mk nxt.clock new_len, rfl, rfl, by dsimp only; omega, hnewv⟩

/-- Full-domain interval-union soundness for `delete_item_merge` (ZERO `clock + len < 2^64` C5 hypothesis!):
    when `delete_item_can_merge cur nxt = ok true`:
    1. Soundness (no fabricated deletions across ALL `c : UInt64`): every clock in `m` lies in `cur` or `nxt`;
    2. Exact union completeness over all representable clocks `c < cur.clock + (2^64 - 1)`
       (i.e. EVERY `c : UInt64` when `cur.clock > 0`, and every `c < UInt64::MAX` when `cur.clock = 0`). -/
theorem delete_item_merge_covers_both_full (cur nxt : DeleteItem)
    (hmerge : delete_item_can_merge cur nxt = ok true) :
    ∃ m : DeleteItem, delete_item_merge cur nxt = ok m ∧
      (∀ c : Std.U64, delete_item_contains m c = ok true →
        delete_item_contains cur c = ok true ∨ delete_item_contains nxt c = ok true) ∧
      (∀ c : Std.U64, c.val < cur.clock.val + 18446744073709551615 →
        (delete_item_contains m c = ok true ↔
          delete_item_contains cur c = ok true ∨ delete_item_contains nxt c = ok true)) := by
  have ⟨hle, htouch⟩ := (delete_item_can_merge_full_domain cur nxt).mp hmerge
  obtain ⟨m, hm, _, hmc, hml⟩ := delete_item_merge_full_domain cur nxt
  simp only [hle, ↓reduceIte] at hml
  refine ⟨m, hm, ?_, ?_⟩
  · intro c hmc_in
    rw [delete_item_contains_full_domain] at hmc_in
    rw [delete_item_contains_full_domain, delete_item_contains_full_domain]
    omega
  · intro c hcrep
    rw [delete_item_contains_full_domain, delete_item_contains_full_domain, delete_item_contains_full_domain]
    omega

end CrdtProofs
