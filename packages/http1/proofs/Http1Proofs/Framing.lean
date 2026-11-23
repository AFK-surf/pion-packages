import Http1Proofs.Core

open Aeneas Aeneas.Std Result Pion http1

namespace Http1Proofs

/-- `version_eq` decides structural equality on `Version`. -/
theorem version_eq_iff (a b : Version) :
    version_eq a b = ok true ↔ a = b := by
  cases a <;> cases b <;> simp [version_eq]

/-- RFC 9112 §6.3 rule 1: exact specification of `is_bodyless_status`. -/
theorem is_bodyless_status_spec (status : Std.I32) :
    is_bodyless_status status =
      ok (decide (status.val < 200 ∨ status.val = 204 ∨ status.val = 304)) := by
  unfold is_bodyless_status
  congr 1
  by_cases h : status.val < 200 ∨ status.val = 204 ∨ status.val = 304
  · rw [decide_eq_true h]
    simp only [Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq, iscalar_eq_iff, iscalar_lt_iff]
    norm_num
    omega
  · rw [decide_eq_false h]
    simp only [Bool.or_eq_false_iff, decide_eq_false_iff_not, beq_eq_false_iff_ne,
      ne_eq, iscalar_eq_iff, iscalar_lt_iff]
    norm_num
    omega

/-- RFC 9112 §6.3 rule 1: 1xx, 204, and 304 responses always have `Framing.None`,
    even if Content-Length or Transfer-Encoding headers were present. -/
theorem effective_response_framing_bodyless (status : Std.I32) (f : Framing)
    (h : status.val < 200 ∨ status.val = 204 ∨ status.val = 304) :
    effective_response_framing status f = ok Framing.None := by
  unfold effective_response_framing
  rw [is_bodyless_status_spec, decide_eq_true h]
  simp only [result_bind_ok, ↓reduceIte]

/-- Responses with status `>= 200` other than 204 and 304 preserve their negotiated framing. -/
theorem effective_response_framing_body_allowed (status : Std.I32) (f : Framing)
    (h : 200 ≤ status.val ∧ status.val ≠ 204 ∧ status.val ≠ 304) :
    effective_response_framing status f = ok f := by
  unfold effective_response_framing
  rw [is_bodyless_status_spec, decide_eq_false (by omega)]
  simp only [result_bind_ok, Bool.false_eq_true, ↓reduceIte]

/-- RFC 9112 §6.3: Once `chunked` has been seen (`prev_state = 1`), no coding may follow it. -/
theorem te_coding_step_rejects_after_chunked (is_chunked is_known : Bool) :
    te_coding_step 1#i32 is_chunked is_known = ok (-1)#i32 := by
  unfold te_coding_step
  simp only [↓reduceIte]

/-- Unknown Transfer-Encoding codings are always rejected (`-1`). -/
theorem te_coding_step_rejects_unknown (prev : Std.I32) :
    te_coding_step prev false false = ok (-1)#i32 := by
  unfold te_coding_step
  by_cases h : prev = 1#i32
  · simp only [h, ↓reduceIte]
  · simp only [h, ↓reduceIte, Bool.false_eq_true]

/-- RFC 9112 §6.3 request-smuggling defense (TE + CL): adding `Content-Length`
    when `Transfer-Encoding` is already present is rejected with `1` (`AmbiguousFraming`). -/
theorem check_framing_cl_rejects_after_te (has_cl : Bool) (v : Std.I64) :
    check_framing_cl true has_cl v = ok 1#i32 := by
  rfl

/-- RFC 9112 §6.3: duplicate `Content-Length` headers are rejected with `2` (`InvalidContentLength`). -/
theorem check_framing_cl_rejects_duplicate (v : Std.I64) :
    check_framing_cl false true v = ok 2#i32 := by
  rfl

/-- Negative `Content-Length` values are rejected with `2` (`InvalidContentLength`). -/
theorem check_framing_cl_rejects_negative (v : Std.I64) (hneg : v.val < 0) :
    check_framing_cl false false v = ok 2#i32 := by
  unfold check_framing_cl
  have hlt : v < 0#i64 := (iscalar_lt_iff v 0#i64).mpr (by norm_num; omega)
  simp only [Bool.false_eq_true, Bool.false_or, decide_eq_true hlt, ↓reduceIte]

/-- Valid non-negative first `Content-Length` without `Transfer-Encoding` is accepted (`0`). -/
theorem check_framing_cl_accepts_valid (v : Std.I64) (hnn : 0 ≤ v.val) :
    check_framing_cl false false v = ok 0#i32 := by
  unfold check_framing_cl
  have hlt : ¬(v < 0#i64) := fun hc => by have := (iscalar_lt_iff v 0#i64).mp hc; norm_num at this; omega
  simp only [Bool.false_eq_true, Bool.false_or, decide_eq_false hlt, ↓reduceIte]

/-- RFC 9112 §6.3 request-smuggling defense (CL + TE): adding `Transfer-Encoding`
    when `Content-Length` is already present is rejected with `1` (`AmbiguousFraming`). -/
theorem check_framing_te_rejects_after_cl (ver : Version) (nt : Std.I32) :
    check_framing_te true ver nt = ok 1#i32 := by
  rfl

/-- RFC 9112 §6.1: `Transfer-Encoding` in HTTP/1.0 is rejected with `2` (`InvalidTransferEncoding`). -/
theorem check_framing_te_rejects_http10 (nt : Std.I32) :
    check_framing_te false Version.Http10 nt = ok 2#i32 := by
  unfold check_framing_te version_eq
  simp only [Bool.false_eq_true, result_bind_ok, Bool.true_or, ↓reduceIte]

/-- Invalid (negative) `Transfer-Encoding` state transitions are rejected (`2`). -/
theorem check_framing_te_rejects_neg_state (nt : Std.I32) (hneg : nt.val < 0) :
    check_framing_te false Version.Http11 nt = ok 2#i32 := by
  unfold check_framing_te version_eq
  have hlt : nt < 0#i32 := (iscalar_lt_iff nt 0#i32).mpr (by norm_num; omega)
  simp only [Bool.false_eq_true, result_bind_ok, Bool.false_or, decide_eq_true hlt, ↓reduceIte]

/-- Valid HTTP/1.1 `Transfer-Encoding` transition without `Content-Length` is accepted (`0`). -/
theorem check_framing_te_accepts_valid (nt : Std.I32) (hnn : 0 ≤ nt.val) :
    check_framing_te false Version.Http11 nt = ok 0#i32 := by
  unfold check_framing_te version_eq
  have hlt : ¬(nt < 0#i32) := fun hc => by have := (iscalar_lt_iff nt 0#i32).mp hc; norm_num at this; omega
  simp only [Bool.false_eq_true, result_bind_ok, Bool.false_or, decide_eq_false hlt, ↓reduceIte]

/-- Duplicate `Host` headers are rejected with `1` (`InvalidHost`). -/
theorem check_framing_host_rejects_duplicate (hc : Std.I32) (valid : Bool)
    (hdup : 1 ≤ hc.val) :
    check_framing_host hc valid = ok 1#i32 := by
  unfold check_framing_host
  have hge : hc ≥ 1#i32 := (iscalar_le_iff 1#i32 hc).mpr (by norm_num; omega)
  simp only [decide_eq_true hge, Bool.true_or, ↓reduceIte]

/-- Invalid `Host` header values are rejected with `1` (`InvalidHost`). -/
theorem check_framing_host_rejects_invalid (hc : Std.I32) :
    check_framing_host hc false = ok 1#i32 := by
  unfold check_framing_host
  simp only [Bool.not_false, Bool.or_true, ↓reduceIte]

/-- First valid `Host` header (`host_count = 0`) is accepted (`0`). -/
theorem check_framing_host_accepts_first :
    check_framing_host 0#i32 true = ok 0#i32 := by
  rfl

/-- Core anti-smuggling invariant predicate for framing scalar state. -/
def FramingInv (has_cl : Bool) (cl_val : Std.I64) (has_te : Bool) (host_count : Std.I32) : Prop :=
  ¬(has_cl = true ∧ has_te = true) ∧
  (has_cl = true → 0 ≤ cl_val.val) ∧
  0 ≤ host_count.val ∧ host_count.val ≤ 1

/-- Initial framing state satisfies `FramingInv`. -/
theorem framing_init_inv : FramingInv false 0#i64 false 0#i32 := by
  refine ⟨by simp, by simp, by norm_num, by norm_num⟩

/-- Every accepted `check_framing_cl` transition preserves `FramingInv`. -/
theorem check_framing_cl_preserves_inv (has_cl : Bool) (cl_val v : Std.I64) (has_te : Bool) (hc : Std.I32)
    (hinv : FramingInv has_cl cl_val has_te hc)
    (hok : check_framing_cl has_te has_cl v = ok 0#i32) :
    FramingInv true v has_te hc := by
  rcases hinv with ⟨_, _, hhc0, hhc1⟩
  unfold check_framing_cl at hok
  cases has_te with
  | true => simp at hok
  | false =>
    cases has_cl with
    | true => simp at hok
    | false =>
      have hv0 : 0 ≤ v.val := by
        by_contra hlt
        have hlt' : v < 0#i64 := (iscalar_lt_iff v 0#i64).mpr (by norm_num; omega)
        simp only [Bool.false_eq_true, Bool.false_or, decide_eq_true hlt', ↓reduceIte] at hok
        have := result_ok_inj hok; revert this; decide
      exact ⟨by simp, fun _ => hv0, hhc0, hhc1⟩

/-- Every accepted `check_framing_te` transition preserves `FramingInv`. -/
theorem check_framing_te_preserves_inv (has_cl : Bool) (cl_val : Std.I64) (has_te : Bool)
    (hc : Std.I32) (ver : Version) (nt : Std.I32)
    (hinv : FramingInv has_cl cl_val has_te hc)
    (hok : check_framing_te has_cl ver nt = ok 0#i32) :
    FramingInv has_cl cl_val true hc := by
  rcases hinv with ⟨_, _, hhc0, hhc1⟩
  unfold check_framing_te at hok
  cases has_cl with
  | true => simp at hok
  | false => exact ⟨by simp, by simp, hhc0, hhc1⟩

/-- Every accepted `check_framing_host` transition preserves `FramingInv`. -/
theorem check_framing_host_preserves_inv (has_cl : Bool) (cl_val : Std.I64) (has_te : Bool)
    (hc : Std.I32) (valid : Bool)
    (hinv : FramingInv has_cl cl_val has_te hc)
    (hok : check_framing_host hc valid = ok 0#i32) :
    FramingInv has_cl cl_val has_te (Pion.I32.add hc 1#i32) := by
  rcases hinv with ⟨hmex, hcl0, hhc0, hhc1⟩
  unfold check_framing_host at hok
  have hlt : hc.val < 1 := by
    by_contra hge
    have hge' : hc ≥ 1#i32 := (iscalar_le_iff 1#i32 hc).mpr (by norm_num; omega)
    simp only [decide_eq_true hge', Bool.true_or, ↓reduceIte] at hok
    have := result_ok_inj hok; revert this; decide
  have h1v : (1#i32).val = 1 := by norm_num
  have hadd : (Pion.I32.add hc 1#i32).val = hc.val + 1 := by
    rw [i32_add_val hc 1#i32 (by rw [h1v]; omega) (by rw [h1v]; omega), h1v]
  exact ⟨hmex, hcl0, by omega, by omega⟩

/-- RFC 9112 §3.2: HTTP/1.1 requests without a `Host` header are rejected with `-1` (`InvalidHost`). -/
theorem check_framing_finalize_http11_requires_host
    (has_cl has_te : Bool) (te_state : Std.I32) :
    check_framing_finalize has_cl has_te te_state 0#i32 true Version.Http11 = ok (-1)#i32 := by
  unfold check_framing_finalize version_eq
  simp only [↓reduceIte, result_bind_ok, beq_self_eq_true, Bool.and_self]

/-- RFC 9112 §6.3: Requests with `Transfer-Encoding` whose final coding is not `chunked`
    are rejected with `-2` (`InvalidTransferEncoding`). -/
theorem check_framing_finalize_request_te_requires_chunked
    (has_cl : Bool) (te_state hc : Std.I32) (ver : Version)
    (hhost : hc ≠ 0#i32) (hnotchunked : te_state ≠ 1#i32) :
    check_framing_finalize has_cl true te_state hc true ver = ok (-2)#i32 := by
  unfold check_framing_finalize version_eq
  have hhb : (hc == 0#i32) = false := beq_false_of_ne hhost
  have htb : (te_state != 1#i32) = true := bne_iff_ne.mpr hnotchunked
  cases ver <;> simp only [↓reduceIte, result_bind_ok, hhb, Bool.and_false,
    Bool.false_eq_true, htb, Bool.true_and]

/-- Under `FramingInv`, if `check_framing_finalize` yields `1` (`ContentLength`), then `cl_val >= 0`
    and `has_te = false` (never ambiguous with chunked framing). -/
theorem check_framing_finalize_cl_nonneg
    (has_cl : Bool) (cl_val : Std.I64) (has_te : Bool) (te_state hc : Std.I32)
    (is_req : Bool) (ver : Version)
    (hinv : FramingInv has_cl cl_val has_te hc)
    (hok : check_framing_finalize has_cl has_te te_state hc is_req ver = ok 1#i32) :
    0 ≤ cl_val.val ∧ has_te = false := by
  rcases hinv with ⟨_, hcl0, _, _⟩
  unfold check_framing_finalize version_eq at hok
  cases is_req <;> cases ver <;> simp only [↓reduceIte, result_bind_ok, Bool.false_and,
    Bool.true_and, Bool.false_eq_true] at hok
  all_goals (
    split_ifs at hok
    all_goals (try (exfalso; have h := (iscalar_eq_iff _ _).mp (result_ok_inj hok); norm_num at h; done))
  )
  all_goals (
    rename_i hcl
    have htef : has_te = false := Bool.eq_false_iff.mpr (by assumption)
    exact ⟨hcl0 hcl, htef⟩
  )

end Http1Proofs
