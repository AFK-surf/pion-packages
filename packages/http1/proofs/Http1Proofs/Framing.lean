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
    when `Transfer-Encoding` is already present is rejected with `AmbiguousFraming`. -/
theorem framing_on_cl_rejects_after_te (st : FramingState) (v : Std.I64)
    (hte : st.has_te = true) :
    framing_on_content_length st v = ok (Res.Err HttpError.AmbiguousFraming) := by
  unfold framing_on_content_length
  simp only [hte, ↓reduceIte]

/-- RFC 9112 §6.3: duplicate `Content-Length` headers are rejected with `InvalidContentLength`. -/
theorem framing_on_cl_rejects_duplicate (st : FramingState) (v : Std.I64)
    (hte : st.has_te = false) (hcl : st.has_cl = true) :
    framing_on_content_length st v = ok (Res.Err HttpError.InvalidContentLength) := by
  unfold framing_on_content_length
  simp only [hte, hcl, Bool.false_eq_true, ↓reduceIte]

/-- Negative `Content-Length` values are rejected with `InvalidContentLength`. -/
theorem framing_on_cl_rejects_negative (st : FramingState) (v : Std.I64)
    (hte : st.has_te = false) (hcl : st.has_cl = false) (hneg : v.val < 0) :
    framing_on_content_length st v = ok (Res.Err HttpError.InvalidContentLength) := by
  unfold framing_on_content_length
  have hlt : v < 0#i64 := (iscalar_lt_iff v 0#i64).mpr hneg
  simp only [hte, hcl, hlt, Bool.false_eq_true, ↓reduceIte]

/-- RFC 9112 §6.3 request-smuggling defense (CL + TE): adding `Transfer-Encoding`
    when `Content-Length` is already present is rejected with `AmbiguousFraming`. -/
theorem framing_on_te_rejects_after_cl (st : FramingState) (ver : Version) (nt : Std.I32)
    (hcl : st.has_cl = true) :
    framing_on_transfer_encoding st ver nt = ok (Res.Err HttpError.AmbiguousFraming) := by
  unfold framing_on_transfer_encoding
  simp only [hcl, ↓reduceIte]

/-- RFC 9112 §6.1: `Transfer-Encoding` in HTTP/1.0 is rejected with `InvalidTransferEncoding`. -/
theorem framing_on_te_rejects_http10 (st : FramingState) (nt : Std.I32)
    (hcl : st.has_cl = false) :
    framing_on_transfer_encoding st Version.Http10 nt = ok (Res.Err HttpError.InvalidTransferEncoding) := by
  unfold framing_on_transfer_encoding version_eq
  simp only [hcl, Bool.false_eq_true, ↓reduceIte, result_bind_ok]

/-- Invalid (negative) `Transfer-Encoding` state transitions are rejected. -/
theorem framing_on_te_rejects_neg_state (st : FramingState) (nt : Std.I32)
    (hcl : st.has_cl = false) (hneg : nt.val < 0) :
    framing_on_transfer_encoding st Version.Http11 nt = ok (Res.Err HttpError.InvalidTransferEncoding) := by
  unfold framing_on_transfer_encoding version_eq
  have hlt : nt < 0#i32 := (iscalar_lt_iff nt 0#i32).mpr hneg
  simp only [hcl, Bool.false_eq_true, ↓reduceIte, result_bind_ok, hlt]

/-- Duplicate `Host` headers are rejected with `InvalidHost`. -/
theorem framing_on_host_rejects_duplicate (st : FramingState) (valid : Bool)
    (hdup : 1 ≤ st.host_count.val) :
    framing_on_host st valid = ok (Res.Err HttpError.InvalidHost) := by
  unfold framing_on_host
  have hge : st.host_count ≥ 1#i32 := (iscalar_le_iff 1#i32 st.host_count).mpr hdup
  simp only [hge, ↓reduceIte]

/-- Invalid `Host` header values are rejected with `InvalidHost`. -/
theorem framing_on_host_rejects_invalid (st : FramingState) :
    framing_on_host st false = ok (Res.Err HttpError.InvalidHost) := by
  unfold framing_on_host
  by_cases hge : st.host_count ≥ 1#i32
  · simp only [hge, ↓reduceIte]
  · simp only [hge, ↓reduceIte, Bool.not_false]

/-- Core anti-smuggling invariant of `FramingState`:
    1. `Content-Length` and `Transfer-Encoding` are mutually exclusive.
    2. Whenever `has_cl` is set, `cl_val >= 0`.
    3. `host_count` is always `0` or `1`. -/
def FramingInv (st : FramingState) : Prop :=
  ¬(st.has_cl = true ∧ st.has_te = true) ∧
  (st.has_cl = true → 0 ≤ st.cl_val.val) ∧
  0 ≤ st.host_count.val ∧ st.host_count.val ≤ 1

/-- Initial `FramingState.new` satisfies `FramingInv`. -/
theorem framing_new_inv :
    ∃ st : FramingState, FramingState.new = ok st ∧ FramingInv st := by
  refine ⟨FramingState.mk false 0#i64 false 0#i32 0#i32, rfl, ?_⟩
  refine ⟨by simp, by simp, by norm_num, by norm_num⟩

/-- `framing_on_content_length` preserves `FramingInv` on every accepted transition. -/
theorem framing_on_cl_preserves_inv (st st' : FramingState) (v : Std.I64)
    (hinv : FramingInv st)
    (hok : framing_on_content_length st v = ok (Res.Ok st')) :
    FramingInv st' := by
  rcases hinv with ⟨hmex, hcl0, hhc0, hhc1⟩
  unfold framing_on_content_length at hok
  by_cases hte : st.has_te = true
  · simp only [hte, ↓reduceIte] at hok; cases result_ok_inj hok
  · have htef : st.has_te = false := Bool.eq_false_iff.mpr hte
    by_cases hcl : st.has_cl = true
    · simp only [htef, hcl, Bool.false_eq_true, ↓reduceIte] at hok; cases result_ok_inj hok
    · have hclf : st.has_cl = false := Bool.eq_false_iff.mpr hcl
      by_cases hneg : v < 0#i64
      · simp only [htef, hclf, hneg, Bool.false_eq_true, ↓reduceIte] at hok; cases result_ok_inj hok
      · simp only [htef, hclf, hneg, Bool.false_eq_true, ↓reduceIte] at hok
        have heq := Res.Ok.inj (result_ok_inj hok)
        subst heq
        have hv0 : 0 ≤ v.val := by
          have : ¬(v.val < 0) := fun h => hneg ((iscalar_lt_iff v 0#i64).mpr h)
          omega
        refine ⟨by simp, fun _ => hv0, hhc0, hhc1⟩

/-- `framing_on_transfer_encoding` preserves `FramingInv` on every accepted transition. -/
theorem framing_on_te_preserves_inv (st st' : FramingState) (ver : Version) (nt : Std.I32)
    (hinv : FramingInv st)
    (hok : framing_on_transfer_encoding st ver nt = ok (Res.Ok st')) :
    FramingInv st' := by
  rcases hinv with ⟨hmex, hcl0, hhc0, hhc1⟩
  unfold framing_on_transfer_encoding at hok
  by_cases hcl : st.has_cl = true
  · simp only [hcl, ↓reduceIte] at hok; cases result_ok_inj hok
  · have hclf : st.has_cl = false := Bool.eq_false_iff.mpr hcl
    cases ver with
    | Http10 =>
      unfold version_eq at hok
      simp only [hclf, Bool.false_eq_true, ↓reduceIte, result_bind_ok] at hok
      cases result_ok_inj hok
    | Http11 =>
      unfold version_eq at hok
      simp only [hclf, Bool.false_eq_true, ↓reduceIte, result_bind_ok] at hok
      by_cases hneg : nt < 0#i32
      · simp only [hneg, ↓reduceIte] at hok; cases result_ok_inj hok
      · simp only [hneg, ↓reduceIte] at hok
        have heq := Res.Ok.inj (result_ok_inj hok)
        subst heq
        refine ⟨by simp, by simp, hhc0, hhc1⟩

/-- `framing_on_host` preserves `FramingInv` on every accepted transition. -/
theorem framing_on_host_preserves_inv (st st' : FramingState) (valid : Bool)
    (hinv : FramingInv st)
    (hok : framing_on_host st valid = ok (Res.Ok st')) :
    FramingInv st' := by
  rcases hinv with ⟨hmex, hcl0, hhc0, hhc1⟩
  unfold framing_on_host at hok
  by_cases hge : st.host_count ≥ 1#i32
  · simp only [hge, ↓reduceIte] at hok; cases result_ok_inj hok
  · cases valid with
    | false =>
      simp only [hge, ↓reduceIte, Bool.not_false] at hok; cases result_ok_inj hok
    | true =>
      simp only [hge, ↓reduceIte, Bool.not_true, Bool.false_eq_true] at hok
      have heq := Res.Ok.inj (result_ok_inj hok)
      subst heq
      have hhc_lt : st.host_count.val < 1 := by
        have : ¬(1 ≤ st.host_count.val) := fun h => hge ((iscalar_le_iff 1#i32 st.host_count).mpr h)
        omega
      have h1v : (1#i32).val = 1 := by norm_num
      have hadd : (Pion.I32.add st.host_count 1#i32).val = st.host_count.val + 1 := by
        rw [i32_add_val st.host_count 1#i32 (by rw [h1v]; omega) (by rw [h1v]; omega), h1v]
      refine ⟨hmex, hcl0, by dsimp only; omega, by dsimp only; omega⟩

/-- RFC 9112 §3.2: HTTP/1.1 requests without a `Host` header are rejected with `InvalidHost`. -/
theorem framing_finalize_http11_requires_host (st : FramingState)
    (h0 : st.host_count = 0#i32) :
    framing_finalize st true Version.Http11 = ok (Res.Err HttpError.InvalidHost) := by
  unfold framing_finalize version_eq
  simp only [↓reduceIte, result_bind_ok, h0, beq_self_eq_true, Bool.and_self]

/-- RFC 9112 §6.3: Requests with `Transfer-Encoding` whose final coding is not `chunked`
    are rejected with `InvalidTransferEncoding`. -/
theorem framing_finalize_request_te_requires_chunked (st : FramingState) (ver : Version)
    (hhost : st.host_count ≠ 0#i32)
    (hte : st.has_te = true)
    (hnotchunked : st.te_state ≠ 1#i32) :
    framing_finalize st true ver = ok (Res.Err HttpError.InvalidTransferEncoding) := by
  unfold framing_finalize version_eq
  have hhb : (st.host_count == 0#i32) = false := beq_false_of_ne hhost
  have htb : (st.te_state != 1#i32) = true := bne_iff_ne.mpr hnotchunked
  cases ver <;> simp only [↓reduceIte, result_bind_ok, hhb, Bool.and_false,
    Bool.false_eq_true, hte, htb, Bool.true_and]

/-- Under `FramingInv`, if `framing_finalize` yields `ContentLength n`, then `n >= 0`
    and `has_te = false` (never ambiguous with chunked framing). -/
theorem framing_finalize_cl_nonneg (st : FramingState) (is_req : Bool) (ver : Version)
    (n : Std.I64) (hinv : FramingInv st)
    (hok : framing_finalize st is_req ver = ok (Res.Ok (Framing.ContentLength n))) :
    0 ≤ n.val ∧ st.has_te = false := by
  rcases hinv with ⟨hmex, hcl0, _, _⟩
  unfold framing_finalize version_eq at hok
  cases is_req <;> cases ver <;> simp only [↓reduceIte, result_bind_ok, Bool.false_and,
    Bool.true_and, Bool.false_eq_true] at hok
  all_goals (
    split_ifs at hok
    all_goals (try cases result_ok_inj hok)
    all_goals (try cases Res.Ok.inj (result_ok_inj hok))
  )
  all_goals (
    rename_i hcl
    have htef : st.has_te = false := Bool.eq_false_iff.mpr (by assumption)
    exact ⟨hcl0 hcl, htef⟩
  )

end Http1Proofs
