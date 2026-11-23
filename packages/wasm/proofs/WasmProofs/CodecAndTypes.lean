import Aeneas
import PionLean
import Wasm.Types
import Wasm.Funs

open Aeneas Aeneas.Std Result Pion wasm

namespace WasmProofs

private lemma result_ok_inj {α : Type} {a b : α} (h : (ok a : Result α) = ok b) : a = b := by
  simpa using h

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
