import Aeneas
import PionLean
import Wasm.Types
import Wasm.Funs

open Aeneas Aeneas.Std Result Pion wasm

namespace WasmProofs

private lemma result_ok_inj {α : Type} {a b : α} (h : (ok a : Result α) = ok b) : a = b := by
  simpa using h

/-- Theorem 1: `val_type_from_code ∘ val_type_code = some` for all 7 WebAssembly 2.0 value types. -/
theorem val_type_code_roundtrip (vt : ValType) :
    (do let c ← val_type_code vt; val_type_from_code c) = ok (some vt) := by
  cases vt <;> simp [val_type_code, val_type_from_code]

/-- Theorem 2: Any byte accepted by `val_type_from_code` re-encodes to the exact same byte. -/
theorem val_type_from_code_roundtrip (b : I32) (vt : ValType)
    (h : val_type_from_code b = ok (some vt)) :
    val_type_code vt = ok b := by
  unfold val_type_from_code at h
  dsimp only at h
  split_ifs at h with h1 h2 h3 h4 h5 h6 h7
  · have hvt := Option.some.inj (result_ok_inj h); subst hvt; rw [h1]; rfl
  · have hvt := Option.some.inj (result_ok_inj h); subst hvt; rw [h2]; rfl
  · have hvt := Option.some.inj (result_ok_inj h); subst hvt; rw [h3]; rfl
  · have hvt := Option.some.inj (result_ok_inj h); subst hvt; rw [h4]; rfl
  · have hvt := Option.some.inj (result_ok_inj h); subst hvt; rw [h5]; rfl
  · have hvt := Option.some.inj (result_ok_inj h); subst hvt; rw [h6]; rfl
  · have hvt := Option.some.inj (result_ok_inj h); subst hvt; rw [h7]; rfl
  · exact absurd (result_ok_inj h) (by simp)

/-- Theorem 3: `val_type_code` is injective across all 7 WebAssembly 2.0 value types. -/
theorem val_type_code_injective (a b : ValType) (h : val_type_code a = val_type_code b) :
    a = b := by
  cases a <;> cases b <;> first | rfl | (unfold val_type_code at h; exact absurd (result_ok_inj h) (by decide))

/-- Theorem 4: `val_type_equals` is exact decidable equality on `ValType`. -/
theorem val_type_equals_iff (a b : ValType) :
    val_type_equals a b = ok true ↔ a = b := by
  cases a <;> cases b <;> simp [val_type_equals, val_type_code]

/-- Theorem 5: `ref_type_from_code ∘ ref_type_code = some` for both reference types. -/
theorem ref_type_code_roundtrip (rt : RefType) :
    (do let c ← ref_type_code rt; ref_type_from_code c) = ok (some rt) := by
  cases rt <;> simp [ref_type_code, ref_type_from_code]

/-- Theorem 6: Embedding `RefType` into `ValType` preserves its binary encoding byte. -/
theorem ref_type_embed_code_compat (rt : RefType) :
    (do let vt ← ref_type_to_val_type rt; val_type_code vt) = ref_type_code rt := by
  cases rt <;> simp [ref_type_to_val_type, val_type_code, ref_type_code]

/-- Theorem 7: `export_kind_code` is injective across `{Func, Table, Memory, Global}`. -/
theorem export_kind_code_injective (a b : ExportKind) (h : export_kind_code a = export_kind_code b) :
    a = b := by
  cases a <;> cases b <;> first | rfl | (unfold export_kind_code at h; exact absurd (result_ok_inj h) (by decide))

/-- Theorem 8: `val_type_to_id` is injective and maps every `ValType` into `[0, 6]`. -/
theorem val_type_to_id_injective_and_range (a b : ValType) :
    (val_type_to_id a = val_type_to_id b → a = b) ∧
    (∃ id, val_type_to_id a = ok id ∧ 0 ≤ id.val ∧ id.val ≤ 6) := by
  constructor
  · intro h
    cases a <;> cases b <;> first | rfl | (unfold val_type_to_id at h; exact absurd (result_ok_inj h) (by decide))
  · cases a <;> exact ⟨_, rfl, by decide, by decide⟩

/-- Theorem 9: `ref_type_to_id` agrees with `val_type_to_id ∘ ref_type_to_val_type` and always satisfies `is_ref_id`. -/
theorem ref_type_id_compat_and_is_ref (rt : RefType) :
    (do let vt ← ref_type_to_val_type rt; val_type_to_id vt) = ref_type_to_id rt ∧
    (do let id ← ref_type_to_id rt; is_ref_id id) = ok true := by
  cases rt <;> simp [ref_type_to_val_type, val_type_to_id, ref_type_to_id, is_ref_id]

/-- Theorem 10: `is_ref_id (val_type_to_id vt)` holds iff `vt` is `FuncRef` or `ExternRef`. -/
theorem is_ref_id_iff_val_type_ref (vt : ValType) :
    (do let id ← val_type_to_id vt; is_ref_id id) = ok true ↔
      (vt = .FuncRef ∨ vt = .ExternRef) := by
  cases vt <;> simp [val_type_to_id, is_ref_id]

private lemma section_order_rank_spec (id : I32) :
    (id = 1#i32 ∧ section_order_rank id = ok 1#i32) ∨
    (id = 2#i32 ∧ section_order_rank id = ok 2#i32) ∨
    (id = 3#i32 ∧ section_order_rank id = ok 3#i32) ∨
    (id = 4#i32 ∧ section_order_rank id = ok 4#i32) ∨
    (id = 5#i32 ∧ section_order_rank id = ok 5#i32) ∨
    (id = 6#i32 ∧ section_order_rank id = ok 6#i32) ∨
    (id = 7#i32 ∧ section_order_rank id = ok 7#i32) ∨
    (id = 8#i32 ∧ section_order_rank id = ok 8#i32) ∨
    (id = 9#i32 ∧ section_order_rank id = ok 9#i32) ∨
    (id = 12#i32 ∧ section_order_rank id = ok 10#i32) ∨
    (id = 10#i32 ∧ section_order_rank id = ok 11#i32) ∨
    (id = 11#i32 ∧ section_order_rank id = ok 12#i32) ∨
    (section_order_rank id = ok (-1)#i32) := by
  unfold section_order_rank
  dsimp only
  by_cases h1 : id = 1#i32
  · simp only [h1, ↓reduceIte]; exact Or.inl ⟨trivial, trivial⟩
  simp only [h1, ↓reduceIte]
  by_cases h2 : id = 2#i32
  · simp only [h2, ↓reduceIte]; exact Or.inr (Or.inl ⟨trivial, trivial⟩)
  simp only [h2, ↓reduceIte]
  by_cases h3 : id = 3#i32
  · simp only [h3, ↓reduceIte]; exact Or.inr (Or.inr (Or.inl ⟨trivial, trivial⟩))
  simp only [h3, ↓reduceIte]
  by_cases h4 : id = 4#i32
  · simp only [h4, ↓reduceIte]; exact Or.inr (Or.inr (Or.inr (Or.inl ⟨trivial, trivial⟩)))
  simp only [h4, ↓reduceIte]
  by_cases h5 : id = 5#i32
  · simp only [h5, ↓reduceIte]; exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inl ⟨trivial, trivial⟩))))
  simp only [h5, ↓reduceIte]
  by_cases h6 : id = 6#i32
  · simp only [h6, ↓reduceIte]; exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inl ⟨trivial, trivial⟩)))))
  simp only [h6, ↓reduceIte]
  by_cases h7 : id = 7#i32
  · simp only [h7, ↓reduceIte]; exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inl ⟨trivial, trivial⟩))))))
  simp only [h7, ↓reduceIte]
  by_cases h8 : id = 8#i32
  · simp only [h8, ↓reduceIte]; exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inl ⟨trivial, trivial⟩)))))))
  simp only [h8, ↓reduceIte]
  by_cases h9 : id = 9#i32
  · simp only [h9, ↓reduceIte]; exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inl ⟨trivial, trivial⟩))))))))
  simp only [h9, ↓reduceIte]
  by_cases h12 : id = 12#i32
  · simp only [h12, ↓reduceIte]; exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inl ⟨trivial, trivial⟩)))))))))
  simp only [h12, ↓reduceIte]
  by_cases h10 : id = 10#i32
  · simp only [h10, ↓reduceIte]; exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inl ⟨trivial, trivial⟩))))))))))
  simp only [h10, ↓reduceIte]
  by_cases h11 : id = 11#i32
  · simp only [h11, ↓reduceIte]; exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inl ⟨trivial, trivial⟩)))))))))))
  simp only [h11, ↓reduceIte]
  exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr trivial)))))))))))

/-- Theorem 11: `section_order_rank` returns `-1` or `[1, 12]`, placing Wasm 2.0 `DataCount (12)` strictly between `Element (9)` and `Code (10)` / `Data (11)`. -/
theorem section_order_rank_canonical_order (id : I32) :
    (∃ r, section_order_rank id = ok r ∧ (r = (-1)#i32 ∨ (1 ≤ r.val ∧ r.val ≤ 12))) ∧
    (section_order_rank 9#i32 = ok 9#i32 ∧
     section_order_rank 12#i32 = ok 10#i32 ∧
     section_order_rank 10#i32 = ok 11#i32 ∧
     section_order_rank 11#i32 = ok 12#i32) := by
  constructor
  · rcases section_order_rank_spec id with
      ⟨_, h⟩ | ⟨_, h⟩ | ⟨_, h⟩ | ⟨_, h⟩ | ⟨_, h⟩ | ⟨_, h⟩ |
      ⟨_, h⟩ | ⟨_, h⟩ | ⟨_, h⟩ | ⟨_, h⟩ | ⟨_, h⟩ | ⟨_, h⟩ | h
    all_goals first
      | exact ⟨_, h, Or.inr ⟨by decide, by decide⟩⟩
      | exact ⟨_, h, Or.inl rfl⟩
  · refine ⟨?_, ?_, ?_, ?_⟩
    · unfold section_order_rank; dsimp only
      simp only [show (9#i32 : I32) ≠ 1#i32 by decide, show (9#i32 : I32) ≠ 2#i32 by decide,
                 show (9#i32 : I32) ≠ 3#i32 by decide, show (9#i32 : I32) ≠ 4#i32 by decide,
                 show (9#i32 : I32) ≠ 5#i32 by decide, show (9#i32 : I32) ≠ 6#i32 by decide,
                 show (9#i32 : I32) ≠ 7#i32 by decide, show (9#i32 : I32) ≠ 8#i32 by decide, ↓reduceIte]
    · unfold section_order_rank; dsimp only
      simp only [show (12#i32 : I32) ≠ 1#i32 by decide, show (12#i32 : I32) ≠ 2#i32 by decide,
                 show (12#i32 : I32) ≠ 3#i32 by decide, show (12#i32 : I32) ≠ 4#i32 by decide,
                 show (12#i32 : I32) ≠ 5#i32 by decide, show (12#i32 : I32) ≠ 6#i32 by decide,
                 show (12#i32 : I32) ≠ 7#i32 by decide, show (12#i32 : I32) ≠ 8#i32 by decide,
                 show (12#i32 : I32) ≠ 9#i32 by decide, ↓reduceIte]
    · unfold section_order_rank; dsimp only
      simp only [show (10#i32 : I32) ≠ 1#i32 by decide, show (10#i32 : I32) ≠ 2#i32 by decide,
                 show (10#i32 : I32) ≠ 3#i32 by decide, show (10#i32 : I32) ≠ 4#i32 by decide,
                 show (10#i32 : I32) ≠ 5#i32 by decide, show (10#i32 : I32) ≠ 6#i32 by decide,
                 show (10#i32 : I32) ≠ 7#i32 by decide, show (10#i32 : I32) ≠ 8#i32 by decide,
                 show (10#i32 : I32) ≠ 9#i32 by decide, show (10#i32 : I32) ≠ 12#i32 by decide, ↓reduceIte]
    · unfold section_order_rank; dsimp only
      simp only [show (11#i32 : I32) ≠ 1#i32 by decide, show (11#i32 : I32) ≠ 2#i32 by decide,
                 show (11#i32 : I32) ≠ 3#i32 by decide, show (11#i32 : I32) ≠ 4#i32 by decide,
                 show (11#i32 : I32) ≠ 5#i32 by decide, show (11#i32 : I32) ≠ 6#i32 by decide,
                 show (11#i32 : I32) ≠ 7#i32 by decide, show (11#i32 : I32) ≠ 8#i32 by decide,
                 show (11#i32 : I32) ≠ 9#i32 by decide, show (11#i32 : I32) ≠ 12#i32 by decide,
                 show (11#i32 : I32) ≠ 10#i32 by decide, ↓reduceIte]

private lemma section_order_rank_inv (a r : I32) (h : section_order_rank a = ok r) (hr : r ≠ (-1)#i32) :
    a = if r = 10#i32 then 12#i32 else if r = 11#i32 then 10#i32 else if r = 12#i32 then 11#i32 else r := by
  rcases section_order_rank_spec a with
    ⟨rfl, heq⟩ | ⟨rfl, heq⟩ | ⟨rfl, heq⟩ | ⟨rfl, heq⟩ | ⟨rfl, heq⟩ | ⟨rfl, heq⟩ |
    ⟨rfl, heq⟩ | ⟨rfl, heq⟩ | ⟨rfl, heq⟩ | ⟨rfl, heq⟩ | ⟨rfl, heq⟩ | ⟨rfl, heq⟩ | heq
  all_goals
    rw [heq] at h
    have hr' := (result_ok_inj h).symm
    subst hr'
    first | exact absurd rfl hr | decide

/-- Theorem 12: `section_order_rank` is injective on all known non-custom section IDs (`rank ≠ -1`). -/
theorem section_order_rank_injective_on_known (a b r : I32)
    (ha : section_order_rank a = ok r) (hb : section_order_rank b = ok r)
    (hr : r ≠ (-1)#i32) :
    a = b := by
  rw [section_order_rank_inv a r ha hr, section_order_rank_inv b r hb hr]

end WasmProofs
