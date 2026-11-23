import WebsocketProofs.Core

open Aeneas Aeneas.Std Result Pion websocket

namespace WebsocketProofs

/-- RFC 6455 §5.2: `opcode_from_int (opcode_to_int op) = some op` for every `Opcode`. -/
theorem opcode_roundtrip (op : Opcode) :
    (do let n ← opcode_to_int op; opcode_from_int n) = ok (some op) := by
  cases op <;> simp [opcode_to_int, opcode_from_int]

/-- Whenever `opcode_from_int raw` succeeds with `some op`, `opcode_to_int op = raw`. -/
theorem opcode_from_int_sound (raw : Std.I32) (op : Opcode)
    (h : opcode_from_int raw = ok (some op)) :
    opcode_to_int op = ok raw := by
  unfold opcode_from_int at h
  dsimp only at h
  split_ifs at h
  all_goals (
    have hs := result_ok_inj h
    try cases hs
  )
  all_goals (subst_vars; rfl)

/-- RFC 6455 §5.2: all reserved opcodes (`3..7`, `11..15`) and out-of-range values are rejected. -/
theorem opcode_from_int_rejects_reserved (raw : Std.I32)
    (h : raw.val ≠ 0 ∧ raw.val ≠ 1 ∧ raw.val ≠ 2 ∧ raw.val ≠ 8 ∧ raw.val ≠ 9 ∧ raw.val ≠ 10) :
    opcode_from_int raw = ok none := by
  unfold opcode_from_int
  have h0 : raw ≠ 0#i32 := fun e => by have := (iscalar_eq_iff _ _).mp e; norm_num at this; omega
  have h1 : raw ≠ 1#i32 := fun e => by have := (iscalar_eq_iff _ _).mp e; norm_num at this; omega
  have h2 : raw ≠ 2#i32 := fun e => by have := (iscalar_eq_iff _ _).mp e; norm_num at this; omega
  have h8 : raw ≠ 8#i32 := fun e => by have := (iscalar_eq_iff _ _).mp e; norm_num at this; omega
  have h9 : raw ≠ 9#i32 := fun e => by have := (iscalar_eq_iff _ _).mp e; norm_num at this; omega
  have h10 : raw ≠ 10#i32 := fun e => by have := (iscalar_eq_iff _ _).mp e; norm_num at this; omega
  simp only [h0, h1, h2, h8, h9, h10, ↓reduceIte]

/-- RFC 6455 §5.5: an opcode is a control opcode iff its wire code is `>= 8`. -/
theorem is_control_opcode_iff_ge8 (op : Opcode) :
    (do let n ← opcode_to_int op; ok (decide (8 ≤ n.val))) = is_control_opcode op := by
  cases op <;> simp [opcode_to_int, is_control_opcode]

/-- RFC 6455 §5.1: role-based masking direction table. -/
theorem check_role_mask_spec :
    check_role_mask Role.Server false = ok 1#i32 ∧
    check_role_mask Role.Server true = ok 0#i32 ∧
    check_role_mask Role.Client true = ok 2#i32 ∧
    check_role_mask Role.Client false = ok 0#i32 := by
  refine ⟨rfl, rfl, rfl, rfl⟩

/-- RFC 6455 §5.5: control frames must not be fragmented and must have payload `<= 125`. -/
theorem check_control_frame_spec (is_control fin : Bool) (len7 : Std.I32) :
    (is_control = false → check_control_frame is_control fin len7 = ok 0#i32) ∧
    (is_control = true ∧ fin = false → check_control_frame is_control fin len7 = ok 1#i32) ∧
    (is_control = true ∧ fin = true ∧ 125 < len7.val → check_control_frame is_control fin len7 = ok 2#i32) ∧
    (is_control = true ∧ fin = true ∧ len7.val ≤ 125 → check_control_frame is_control fin len7 = ok 0#i32) := by
  have h125 : (125#i32).val = 125 := by norm_num
  refine ⟨?_, ?_, ?_, ?_⟩
  · intro h; subst h; rfl
  · rintro ⟨h1, h2⟩; subst h1; subst h2; rfl
  · rintro ⟨h1, h2, h3⟩; subst h1; subst h2
    unfold check_control_frame
    have hgt : len7 > 125#i32 := (iscalar_lt_iff 125#i32 len7).mpr (by omega)
    simp only [Bool.not_true, Bool.false_eq_true, hgt, ↓reduceIte]
  · rintro ⟨h1, h2, h3⟩; subst h1; subst h2
    unfold check_control_frame
    have hgt : ¬(len7 > 125#i32) := fun hc => by have := (iscalar_lt_iff 125#i32 len7).mp hc; omega
    simp only [Bool.not_true, Bool.false_eq_true, hgt, ↓reduceIte]

/-- RFC 6455 §7.4.1 & IANA: exact specification of `is_valid_close_code`. -/
theorem is_valid_close_code_spec (code : Std.I32) :
    is_valid_close_code code =
      ok (decide ((1000 ≤ code.val ∧ code.val ≤ 1003) ∨
        (1007 ≤ code.val ∧ code.val ≤ 1014) ∨
        (3000 ≤ code.val ∧ code.val ≤ 4999))) := by
  unfold is_valid_close_code
  congr 1
  by_cases h : (1000 ≤ code.val ∧ code.val ≤ 1003) ∨
      (1007 ≤ code.val ∧ code.val ≤ 1014) ∨
      (3000 ≤ code.val ∧ code.val ≤ 4999)
  · rw [decide_eq_true h]
    simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, iscalar_le_iff]
    norm_num
    omega
  · rw [decide_eq_false h]
    simp only [Bool.or_eq_false_iff, Bool.and_eq_false_iff, decide_eq_false_iff_not, iscalar_le_iff]
    norm_num
    omega

/-- RFC 6455 §7.4.1: forbidden wire close codes (`0..999`, `1004`, `1005`, `1006`, `1015`, `1016..2999`, `>= 5000`) are rejected. -/
theorem is_valid_close_code_rejects_forbidden (code : Std.I32)
    (h : code.val < 1000 ∨ code.val = 1004 ∨ code.val = 1005 ∨ code.val = 1006 ∨
      code.val = 1015 ∨ (1016 ≤ code.val ∧ code.val ≤ 2999) ∨ 5000 ≤ code.val) :
    is_valid_close_code code = ok false := by
  rw [is_valid_close_code_spec]
  congr 1
  exact decide_eq_false (by omega)

end WebsocketProofs
