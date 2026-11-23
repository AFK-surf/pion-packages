import Semver.Funs

open Aeneas Aeneas.Std Result Pion semver

namespace SemverEvalDiff

private def u64 (n : Nat) : Std.U64 := ⟨BitVec.ofNat 64 n⟩
private def u64Max : Std.U64 := u64 18446744073709551615
private def u64MaxM1 : Std.U64 := u64 18446744073709551614

private def mkVer (M m p : Std.U64) (pre : String := "") (build : String := "") : Version :=
  ⟨M, m, p, ⟨pre⟩, ⟨build⟩⟩

private def mkCmp (op : Op) (M : Std.U64) (m p : Option Std.U64) (pre : String := "") : Comparator :=
  ⟨op, M, m, p, ⟨pre⟩⟩

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

private def fmtI32 (r : Result Std.I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtOptI32Val (r : Result (Option Std.I32)) : String :=
  match r.match with
  | .ok (some v) => toString v.val
  | .ok none => "None"
  | _ => "TRAP"

private def runAll : List String :=
  [ s!"cmp_core_eq={fmtI32 (cmp_core u64Max u64Max u64Max u64Max u64Max u64Max)}"
  , s!"cmp_core_lt={fmtI32 (cmp_core u64MaxM1 u64Max u64Max u64Max (u64 0) (u64 0))}"
  , s!"cmp_core_gt={fmtI32 (cmp_core u64Max (u64 0) (u64 0) u64MaxM1 u64Max u64Max)}"
  , s!"cmp_prec_rel={fmtOptI32Val (cmp_precedence_core (mkVer (u64 1) (u64 0) (u64 0) "" "b1") (mkVer (u64 1) (u64 0) (u64 0) "alpha" "b2"))}"
  , s!"cmp_prec_bld={fmtOptI32Val (cmp_precedence_core (mkVer (u64 1) (u64 0) (u64 0) "alpha.1" "b1") (mkVer (u64 1) (u64 0) (u64 0) "alpha.1" "b2"))}"
  , s!"caret_max_0={fmtBool (matches_release (mkCmp .Caret u64Max (some (u64 0)) (some (u64 0))) (mkVer (u64 0) (u64 0) (u64 0)))}"
  , s!"caret_max_self={fmtBool (matches_release (mkCmp .Caret u64Max (some (u64 0)) (some (u64 0))) (mkVer u64Max u64Max u64Max))}"
  , s!"tilde_max_wrap={fmtBool (matches_release (mkCmp .Tilde (u64 0) (some u64Max) (some (u64 0))) (mkVer (u64 1) (u64 0) (u64 0)))}"
  , s!"gt_max_false={fmtBool (matches_release (mkCmp .Greater u64Max none none) (mkVer u64Max u64Max u64Max))}"
  , s!"caret_00p={fmtBool (matches_release (mkCmp .Caret (u64 0) (some (u64 0)) (some (u64 3))) (mkVer (u64 0) (u64 0) (u64 4)))}"
  , s!"wild_12={fmtBool (matches_release (mkCmp .Wildcard (u64 1) (some (u64 2)) none) (mkVer (u64 1) (u64 2) u64Max))}"
  , s!"pre_compat_t={fmtBool (pre_is_compatible (mkCmp .GreaterEq (u64 1) (some (u64 2)) (some (u64 3)) "alpha.1") (mkVer (u64 1) (u64 2) (u64 3) "alpha.2"))}"
  , s!"pre_compat_f={fmtBool (pre_is_compatible (mkCmp .GreaterEq (u64 1) (some (u64 2)) (some (u64 3))) (mkVer (u64 1) (u64 2) (u64 3) "alpha.2"))}"
  ]

#eval IO.println (String.intercalate "\n" runAll)

end SemverEvalDiff
