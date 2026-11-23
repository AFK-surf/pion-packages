import Aeneas
import PionLean
import Mime.Types
import Mime.Funs
import MimeProofs.Codec

open Aeneas Aeneas.Std Result Pion mime

namespace MimeProofs

/-- Theorem 12: RFC 5987 §3.2.1 `attr-char` is strictly a subset of RFC 9110 §5.6.2 `tchar`. -/
theorem attr_char_subset_of_tchar (c : I32) :
    is_attr_char_byte c = ok true → is_tchar_byte c = ok true := by
  unfold is_attr_char_byte is_tchar_byte
  intro h
  have ht := result_ok_inj h
  congr 1
  simp only [Bool.or_eq_true] at ht ⊢
  tauto

/-- Theorem 13: RFC 5987 delimiters `'`, `*`, `%` are valid `tchar`s but strictly excluded from `attr-char`. -/
theorem attr_char_excludes_rfc5987_delimiters (c : I32)
    (h : c = 39#i32 ∨ c = 42#i32 ∨ c = 37#i32) :
    is_attr_char_byte c = ok false ∧ is_tchar_byte c = ok true := by
  rcases h with rfl | rfl | rfl <;>
    (unfold is_attr_char_byte is_tchar_byte; constructor <;> congr 1)

/-- Theorem 14: RFC 9110 §5.6.2 `tchar` forbids CTLs, SP, non-ASCII, and header delimiters (`/`, `;`, `=`, `"`). -/
theorem tchar_forbids_ctl_space_and_separators (c : I32)
    (h : c.val ≤ 32 ∨ c.val ≥ 127 ∨ c = 47#i32 ∨ c = 59#i32 ∨ c = 61#i32 ∨ c = 34#i32) :
    is_tchar_byte c = ok false := by
  unfold is_tchar_byte
  rcases h with hle | hge | rfl | rfl | rfl | rfl
  · have hne : ∀ k : I32, 33 ≤ k.val → (c == k) = false := fun k hk =>
      beq_false_of_ne (by intro heq; subst heq; omega)
    have h1 : ¬((48#i32 : I32) ≤ c) := by change ¬(48 ≤ c.val); omega
    have h2 : ¬((65#i32 : I32) ≤ c) := by change ¬(65 ≤ c.val); omega
    have h3 : ¬((97#i32 : I32) ≤ c) := by change ¬(97 ≤ c.val); omega
    simp [h1, h2, h3, hne 33#i32 (by decide), hne 35#i32 (by decide), hne 36#i32 (by decide),
          hne 37#i32 (by decide), hne 38#i32 (by decide), hne 39#i32 (by decide),
          hne 42#i32 (by decide), hne 43#i32 (by decide), hne 45#i32 (by decide),
          hne 46#i32 (by decide), hne 94#i32 (by decide), hne 95#i32 (by decide),
          hne 96#i32 (by decide), hne 124#i32 (by decide), hne 126#i32 (by decide)]
  · have hne : ∀ k : I32, k.val ≤ 126 → (c == k) = false := fun k hk =>
      beq_false_of_ne (by intro heq; subst heq; omega)
    have h1 : ¬(c ≤ (57#i32 : I32)) := by change ¬(c.val ≤ 57); omega
    have h2 : ¬(c ≤ (90#i32 : I32)) := by change ¬(c.val ≤ 90); omega
    have h3 : ¬(c ≤ (122#i32 : I32)) := by change ¬(c.val ≤ 122); omega
    simp [h1, h2, h3, hne 33#i32 (by decide), hne 35#i32 (by decide), hne 36#i32 (by decide),
          hne 37#i32 (by decide), hne 38#i32 (by decide), hne 39#i32 (by decide),
          hne 42#i32 (by decide), hne 43#i32 (by decide), hne 45#i32 (by decide),
          hne 46#i32 (by decide), hne 94#i32 (by decide), hne 95#i32 (by decide),
          hne 96#i32 (by decide), hne 124#i32 (by decide), hne 126#i32 (by decide)]
  · congr 1
  · congr 1
  · congr 1
  · congr 1

/-- Theorem 15: RFC 2046 §5.1.1 multipart `bcharsnospace` forbids CTLs (incl. CR/LF), SP, non-ASCII, `"`, and `\`. -/
theorem bchar_nospace_forbids_ctl_space_and_quotes (c : I32)
    (h : c.val ≤ 32 ∨ c.val ≥ 127 ∨ c = 34#i32 ∨ c = 92#i32) :
    is_bchar_nospace_byte c = ok false := by
  unfold is_bchar_nospace_byte
  rcases h with hle | hge | rfl | rfl
  · have hne : ∀ k : I32, 33 ≤ k.val → (c == k) = false := fun k hk =>
      beq_false_of_ne (by intro heq; subst heq; omega)
    have h1 : ¬((48#i32 : I32) ≤ c) := by change ¬(48 ≤ c.val); omega
    have h2 : ¬((65#i32 : I32) ≤ c) := by change ¬(65 ≤ c.val); omega
    have h3 : ¬((97#i32 : I32) ≤ c) := by change ¬(97 ≤ c.val); omega
    simp [h1, h2, h3, hne 39#i32 (by decide), hne 40#i32 (by decide), hne 41#i32 (by decide),
          hne 43#i32 (by decide), hne 44#i32 (by decide), hne 45#i32 (by decide),
          hne 46#i32 (by decide), hne 47#i32 (by decide), hne 58#i32 (by decide),
          hne 61#i32 (by decide), hne 63#i32 (by decide), hne 95#i32 (by decide)]
  · have hne : ∀ k : I32, k.val ≤ 126 → (c == k) = false := fun k hk =>
      beq_false_of_ne (by intro heq; subst heq; omega)
    have h1 : ¬(c ≤ (57#i32 : I32)) := by change ¬(c.val ≤ 57); omega
    have h2 : ¬(c ≤ (90#i32 : I32)) := by change ¬(c.val ≤ 90); omega
    have h3 : ¬(c ≤ (122#i32 : I32)) := by change ¬(c.val ≤ 122); omega
    simp [h1, h2, h3, hne 39#i32 (by decide), hne 40#i32 (by decide), hne 41#i32 (by decide),
          hne 43#i32 (by decide), hne 44#i32 (by decide), hne 45#i32 (by decide),
          hne 46#i32 (by decide), hne 47#i32 (by decide), hne 58#i32 (by decide),
          hne 61#i32 (by decide), hne 63#i32 (by decide), hne 95#i32 (by decide)]
  · congr 1
  · congr 1

/-- Theorem 16: All ASCII alphanumerics (`0..9`, `A..Z`, `a..z`) are simultaneously valid `tchar`, `attr-char`, and `bcharsnospace`. -/
theorem tchar_and_bchar_allow_alnum (c : I32)
    (h : (48 ≤ c.val ∧ c.val ≤ 57) ∨ (65 ≤ c.val ∧ c.val ≤ 90) ∨ (97 ≤ c.val ∧ c.val ≤ 122)) :
    is_tchar_byte c = ok true ∧ is_attr_char_byte c = ok true ∧ is_bchar_nospace_byte c = ok true := by
  unfold is_tchar_byte is_attr_char_byte is_bchar_nospace_byte
  rcases h with ⟨h1, h2⟩ | ⟨h1, h2⟩ | ⟨h1, h2⟩
  · have ha : (48#i32 : I32) ≤ c := h1
    have hb : c ≤ (57#i32 : I32) := h2
    simp [ha, hb]
  · have ha : (65#i32 : I32) ≤ c := h1
    have hb : c ≤ (90#i32 : I32) := h2
    simp [ha, hb]
  · have ha : (97#i32 : I32) ≤ c := h1
    have hb : c ≤ (122#i32 : I32) := h2
    simp [ha, hb]

/-- Theorem 17: `is_path_sep_byte` characterizes Unix `/` (47) and Windows `\` (92) separators. -/
theorem path_sep_byte_iff (c : I32) :
    is_path_sep_byte c = ok true ↔ c = 47#i32 ∨ c = 92#i32 := by
  unfold is_path_sep_byte
  constructor
  · intro h
    have ht := result_ok_inj h
    simp only [Bool.or_eq_true, beq_iff_eq] at ht
    exact ht
  · intro h; rcases h with rfl | rfl <;> simp

/-- Theorem 18: `is_filename_c0_or_del` characterizes ASCII C0 controls (`< 32`) and DEL (`127`). -/
theorem filename_c0_or_del_iff (c : I32) :
    is_filename_c0_or_del c = ok true ↔ c.val < 32 ∨ c.val = 127 := by
  unfold is_filename_c0_or_del
  constructor
  · intro h
    have ht := result_ok_inj h
    simp only [Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq] at ht
    rcases ht with hlt | rfl
    · exact Or.inl hlt
    · exact Or.inr rfl
  · intro h
    rcases h with hlt | h127
    · have h1 : c < (32#i32 : I32) := hlt
      simp [h1]
    · have h2 : c = 127#i32 := iscalar_eq_of_val_eq h127
      subst h2; simp

/-- Theorem 19: Printable ASCII (`32..126`) is never stripped by `is_filename_c0_or_del`. -/
theorem filename_printable_ascii_preserved (c : I32) (hlo : 32 ≤ c.val) (hhi : c.val ≤ 126) :
    is_filename_c0_or_del c = ok false := by
  unfold is_filename_c0_or_del
  have h1 : ¬(c < (32#i32 : I32)) := by change ¬(c.val < 32); omega
  have h2 : (c == 127#i32) = false := beq_false_of_ne (by intro h; subst h; have : (127#i32 : I32).val = 127 := rfl; omega)
  simp [h1, h2]

/-- Theorem 20: `is_utf8_c1_pair` characterizes UTF-8 C1 control sequences `U+0080..U+009F` (`C2 80..9F`). -/
theorem utf8_c1_pair_iff (b0 b1 : I32) :
    is_utf8_c1_pair b0 b1 = ok true ↔ b0.val = 194 ∧ 128 ≤ b1.val ∧ b1.val ≤ 159 := by
  unfold is_utf8_c1_pair
  constructor
  · intro h
    have ht := result_ok_inj h
    simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at ht
    rcases ht with ⟨⟨rfl, hlo⟩, hhi⟩
    exact ⟨rfl, hlo, hhi⟩
  · intro ⟨h0, hlo, hhi⟩
    have hb0 : b0 = 194#i32 := iscalar_eq_of_val_eq h0
    subst hb0
    have h1 : (128#i32 : I32) ≤ b1 := hlo
    have h2 : b1 ≤ (159#i32 : I32) := hhi
    simp [h1, h2]

/-- Theorem 21: `is_utf8_bidi_3byte` catches Trojan-Source / RLO filename spoofing controls (U+202E, U+202D, U+2066, U+2069). -/
theorem utf8_bidi_3byte_catches_trojan_rlo :
    is_utf8_bidi_3byte 226#i32 128#i32 174#i32 = ok true ∧
    is_utf8_bidi_3byte 226#i32 128#i32 173#i32 = ok true ∧
    is_utf8_bidi_3byte 226#i32 129#i32 166#i32 = ok true ∧
    is_utf8_bidi_3byte 226#i32 129#i32 169#i32 = ok true := by
  refine ⟨?_, ?_, ?_, ?_⟩ <;> (unfold is_utf8_bidi_3byte; congr 1)

/-- Theorem 22: `is_utf8_bidi_3byte` returns `false` whenever the lead byte is not `0xE2` (226). -/
theorem utf8_bidi_3byte_requires_e2_lead (b0 b1 b2 : I32) (hne : b0 ≠ 226#i32) :
    is_utf8_bidi_3byte b0 b1 b2 = ok false := by
  unfold is_utf8_bidi_3byte
  have hf : (b0 == 226#i32) = false := beq_false_of_ne hne
  simp [hf]

end MimeProofs
