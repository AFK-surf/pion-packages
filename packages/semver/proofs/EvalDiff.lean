/-
Executable `#eval` / `#guard` differential checks on the extracted `Semver.Funs`
including `UInt64::MAX` (`18446744073709551615`), Cargo `Caret`/`Tilde`/`Exact`/
`Wildcard`/`Greater`/`GreaterEq`/`Less`/`LessEq`, SemVer 2.0.0 prerelease & build
precedence, and `pre_is_compatible`.
-/
import Semver.Funs

open Aeneas Aeneas.Std Result Pion semver

namespace SemverEvalDiff

def okIs {α : Type} [BEq α] (r : Result α) (expected : α) : Bool :=
  r.reducesTo expected

def u64 (n : Nat) : Std.U64 := ⟨BitVec.ofNat 64 n⟩
def i32 (x : Int) : Std.I32 := ⟨BitVec.ofInt 32 x⟩

def u64Max : Std.U64 := u64 18446744073709551615
def u64MaxMinus1 : Std.U64 := u64 18446744073709551614

def mkVer (M m p : Std.U64) (pre : String := "") (build : String := "") : Version :=
  ⟨M, m, p, ⟨pre⟩, ⟨build⟩⟩

def mkCmp (op : Op) (M : Std.U64) (m p : Option Std.U64) (pre : String := "") : Comparator :=
  ⟨op, M, m, p, ⟨pre⟩⟩

-- 1. cmp_core boundary cases (including UInt64::MAX)
#guard okIs (cmp_core (u64 0) (u64 0) (u64 0) (u64 0) (u64 0) (u64 0)) (i32 0)
#guard okIs (cmp_core u64Max u64Max u64Max u64Max u64Max u64Max) (i32 0)
#guard okIs (cmp_core u64MaxMinus1 u64Max u64Max u64Max (u64 0) (u64 0)) (i32 (-1))
#guard okIs (cmp_core u64Max (u64 0) (u64 0) u64MaxMinus1 u64Max u64Max) (i32 1)
#guard okIs (cmp_core (u64 1) (u64 2) (u64 3) (u64 1) (u64 2) (u64 4)) (i32 (-1))
#guard okIs (cmp_core (u64 1) (u64 3) (u64 0) (u64 1) (u64 2) u64Max) (i32 1)

-- 2. SemVer 2.0.0 prerelease & build precedence
#guard okIs (cmp_precedence_core (mkVer (u64 1) (u64 0) (u64 0) "" "b1")
                                 (mkVer (u64 1) (u64 0) (u64 0) "alpha" "b2")) (some (i32 1))
#guard okIs (cmp_precedence_core (mkVer (u64 1) (u64 0) (u64 0) "alpha" "b1")
                                 (mkVer (u64 1) (u64 0) (u64 0) "" "b2")) (some (i32 (-1)))
#guard okIs (cmp_precedence_core (mkVer (u64 1) (u64 0) (u64 0) "alpha.1" "build.1")
                                 (mkVer (u64 1) (u64 0) (u64 0) "alpha.1" "build.999")) (some (i32 0))
#guard okIs (cmp_precedence_core (mkVer u64Max (u64 0) (u64 0) "" "aaa")
                                 (mkVer u64Max (u64 0) (u64 0) "" "zzz")) (some (i32 0))

-- 3. Caret three regimes + UInt64::MAX overflow immunity
#guard okIs (matches_release (mkCmp .Caret (u64 1) (some (u64 2)) (some (u64 3))) (mkVer (u64 1) (u64 2) (u64 3))) true
#guard okIs (matches_release (mkCmp .Caret (u64 1) (some (u64 2)) (some (u64 3))) (mkVer (u64 1) (u64 9) (u64 0))) true
#guard okIs (matches_release (mkCmp .Caret (u64 1) (some (u64 2)) (some (u64 3))) (mkVer (u64 2) (u64 0) (u64 0))) false
#guard okIs (matches_release (mkCmp .Caret (u64 0) (some (u64 2)) (some (u64 3))) (mkVer (u64 0) (u64 2) (u64 9))) true
#guard okIs (matches_release (mkCmp .Caret (u64 0) (some (u64 2)) (some (u64 3))) (mkVer (u64 0) (u64 3) (u64 0))) false
#guard okIs (matches_release (mkCmp .Caret (u64 0) (some (u64 0)) (some (u64 3))) (mkVer (u64 0) (u64 0) (u64 3))) true
#guard okIs (matches_release (mkCmp .Caret (u64 0) (some (u64 0)) (some (u64 3))) (mkVer (u64 0) (u64 0) (u64 4))) false
-- UInt64::MAX caret must NOT wrap major+1 to 0
#guard okIs (matches_release (mkCmp .Caret u64Max (some (u64 0)) (some (u64 0))) (mkVer u64Max u64Max u64Max)) true
#guard okIs (matches_release (mkCmp .Caret u64Max (some (u64 0)) (some (u64 0))) (mkVer (u64 0) (u64 0) (u64 0))) false
-- UInt64::MAX tilde must NOT wrap minor+1 to 0
#guard okIs (matches_release (mkCmp .Tilde (u64 0) (some u64Max) (some (u64 0))) (mkVer (u64 0) u64Max u64Max)) true
#guard okIs (matches_release (mkCmp .Tilde (u64 0) (some u64Max) (some (u64 0))) (mkVer (u64 0) (u64 0) (u64 0))) false
#guard okIs (matches_release (mkCmp .Tilde (u64 0) (some u64Max) (some (u64 0))) (mkVer (u64 1) (u64 0) (u64 0))) false
-- UInt64::MAX greater must never match anything
#guard okIs (matches_release (mkCmp .Greater u64Max none none) (mkVer u64Max u64Max u64Max)) false
#guard okIs (matches_release (mkCmp .Greater u64Max none none) (mkVer (u64 0) (u64 0) (u64 0))) false

-- 4. Exact / Wildcard / Less / GreaterEq / LessEq / pre_is_compatible
#guard okIs (matches_release (mkCmp .Exact (u64 1) (some (u64 2)) (some (u64 3))) (mkVer (u64 1) (u64 2) (u64 3))) true
#guard okIs (matches_release (mkCmp .Exact (u64 1) (some (u64 2)) (some (u64 3)) "alpha") (mkVer (u64 1) (u64 2) (u64 3))) false
#guard okIs (matches_release (mkCmp .Wildcard (u64 1) (some (u64 2)) none) (mkVer (u64 1) (u64 2) u64Max)) true
#guard okIs (matches_release (mkCmp .Less u64Max (some u64Max) (some u64Max)) (mkVer u64Max u64Max u64MaxMinus1)) true
#guard okIs (matches_release (mkCmp .GreaterEq u64Max (some u64Max) (some u64Max)) (mkVer u64Max u64Max u64MaxMinus1)) false
#guard okIs (matches_release (mkCmp .LessEq (u64 1) (some (u64 2)) (some (u64 3)) "alpha") (mkVer (u64 1) (u64 2) (u64 3))) false
#guard okIs (matches_release (mkCmp .Greater (u64 1) (some (u64 2)) (some (u64 3)) "alpha") (mkVer (u64 1) (u64 2) (u64 3))) true
#guard okIs (pre_is_compatible (mkCmp .GreaterEq (u64 1) (some (u64 2)) (some (u64 3)) "alpha.1") (mkVer (u64 1) (u64 2) (u64 3) "alpha.2")) true
#guard okIs (pre_is_compatible (mkCmp .GreaterEq (u64 1) (some (u64 2)) (some (u64 3))) (mkVer (u64 1) (u64 2) (u64 3) "alpha.2")) false

-- Print structured output for cross-checking against Pion native execution
def fmtResult (label : String) (b : Bool) : String :=
  s!"{label}: {if b then "PASS" else "FAIL"}"

#eval do
  let checks : List (String × Bool) := [
    ("cmp_core_u64max_eq", okIs (cmp_core u64Max u64Max u64Max u64Max u64Max u64Max) (i32 0)),
    ("cmp_core_u64max_lt", okIs (cmp_core u64MaxMinus1 u64Max u64Max u64Max (u64 0) (u64 0)) (i32 (-1))),
    ("cmp_prec_rel_gt_pre", okIs (cmp_precedence_core (mkVer (u64 1) (u64 0) (u64 0) "" "b1") (mkVer (u64 1) (u64 0) (u64 0) "alpha" "b2")) (some (i32 1))),
    ("cmp_prec_build_eq", okIs (cmp_precedence_core (mkVer (u64 1) (u64 0) (u64 0) "alpha.1" "b1") (mkVer (u64 1) (u64 0) (u64 0) "alpha.1" "b2")) (some (i32 0))),
    ("caret_u64max_no_wrap", okIs (matches_release (mkCmp .Caret u64Max (some (u64 0)) (some (u64 0))) (mkVer (u64 0) (u64 0) (u64 0))) false),
    ("caret_u64max_self", okIs (matches_release (mkCmp .Caret u64Max (some (u64 0)) (some (u64 0))) (mkVer u64Max u64Max u64Max)) true),
    ("tilde_u64max_no_wrap", okIs (matches_release (mkCmp .Tilde (u64 0) (some u64Max) (some (u64 0))) (mkVer (u64 1) (u64 0) (u64 0))) false),
    ("greater_u64max_false", okIs (matches_release (mkCmp .Greater u64Max none none) (mkVer u64Max u64Max u64Max)) false),
    ("caret_0_0_p_exact", okIs (matches_release (mkCmp .Caret (u64 0) (some (u64 0)) (some (u64 3))) (mkVer (u64 0) (u64 0) (u64 4))) false)
  ]
  checks.forM (fun p => IO.println (fmtResult p.1 p.2))
  IO.println "SemverEvalDiff: all #guard and #eval checks passed"

end SemverEvalDiff
