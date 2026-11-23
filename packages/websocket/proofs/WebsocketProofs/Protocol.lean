import WebsocketProofs.Core

open Aeneas Aeneas.Std Result Pion websocket

namespace WebsocketProofs

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

end WebsocketProofs
