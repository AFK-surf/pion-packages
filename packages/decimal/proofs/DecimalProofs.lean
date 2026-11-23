/-
Formal verification of `packages/decimal` (`Decimal.Funs`, extracted via
`pionc extract-lean` from `packages/decimal/src/*.pion`).

Modularized into 5 Lean modules for fast, bounded-memory builds:
- `DecimalProofs.Core`: scalar, BitVec & mathematical model helpers
- `DecimalProofs.Arith96`: 96-bit & 128-bit multi-precision arithmetic kernels
- `DecimalProofs.Flags`: flags, sign, scale (`0..=28`) & `neg`/`abs`/`is_zero` invariants
- `DecimalProofs.Wire`: 16-byte binary wire format `serialize` <-> `deserialize` & F-5 mask
- `DecimalProofs.Ops`: aligned 96-bit add/sub, cross-scale comparison & truncation

All proofs are complete and kernel-checked, depending only on the three
standard Lean axioms: `propext`, `Classical.choice`, `Quot.sound`.
-/
import DecimalProofs.Core
import DecimalProofs.Arith96
import DecimalProofs.Flags
import DecimalProofs.Wire
import DecimalProofs.Ops
