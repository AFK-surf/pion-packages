#!/usr/bin/env python3
"""Generate the handshake differential corpus: `<name> <req|resp> <hex>`.
Responses may contain `{ACCEPT}`, which each runner replaces with the correct
Sec-WebSocket-Accept for the key it actually sent (coder/websocket picks its own key)."""
import sys

KEY = "dGhlIHNhbXBsZSBub25jZQ=="
def req(*hdrs, line="GET /ws HTTP/1.1", eol="\r\n"):
    return line + eol + eol.join(hdrs) + eol + eol
BASE = ["Host: example.com", "Upgrade: websocket", "Connection: Upgrade",
        f"Sec-WebSocket-Key: {KEY}", "Sec-WebSocket-Version: 13"]
def without(name): return [h for h in BASE if not h.lower().startswith(name.lower() + ":")]
def resp(*extra, status="HTTP/1.1 101 Switching Protocols", accept="{ACCEPT}"):
    hs = ["Upgrade: websocket", "Connection: Upgrade", f"Sec-WebSocket-Accept: {accept}", *extra]
    return status + "\r\n" + "\r\n".join(hs) + "\r\n\r\n"

cases = [
    ("req_valid", "req", req(*BASE)),
    ("req_conn_keepalive_upgrade", "req", req(*without("Connection"), "Connection: keep-alive, Upgrade")),
    ("req_lowercase_names_mixed_values", "req", req("host: example.com", "upgrade: WebSocket", "connection: upgrade",
                                                    f"sec-websocket-key: {KEY}", "sec-websocket-version: 13")),
    ("req_version_8", "req", req(*without("Sec-WebSocket-Version"), "Sec-WebSocket-Version: 8")),
    ("req_key_not_base64", "req", req(*without("Sec-WebSocket-Key"), "Sec-WebSocket-Key: not-base64!!")),
    ("req_key_15_bytes", "req", req(*without("Sec-WebSocket-Key"), "Sec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAA")),
    ("req_duplicate_key", "req", req(*BASE, "Sec-WebSocket-Key: AQIDBAUGBwgJCgsMDQ4PEA==")),
    ("req_duplicate_version_13_8", "req", req(*BASE, "Sec-WebSocket-Version: 8")),
    ("req_space_before_colon", "req", req("Host : example.com", *without("Host"))),
    ("req_obs_fold", "req", req(*BASE, "X-Folded: a", " b")),
    ("req_missing_host", "req", req(*without("Host"))),
    ("req_http10", "req", req(*BASE, line="GET /ws HTTP/1.0")),
    ("req_lowercase_method", "req", req(*BASE, line="get /ws HTTP/1.1")),
    ("req_lf_only", "req", req(*BASE, eol="\n")),
    ("req_ctl_in_value", "req", req(*BASE, "X-Evil: a\x01b")),
    ("resp_valid", "resp", resp()),
    ("resp_wrong_accept", "resp", resp(accept="dGhpcyBpcyBub3QgdGhlIGFjY2VwdA==")),
    ("resp_unoffered_extension", "resp", resp("Sec-WebSocket-Extensions: permessage-deflate")),
    ("resp_unoffered_protocol", "resp", resp("Sec-WebSocket-Protocol: chat")),
    ("resp_status_no_reason", "resp", resp(status="HTTP/1.1 101")),
    ("resp_status_200", "resp", resp(status="HTTP/1.1 200 OK")),
    ("resp_missing_upgrade", "resp", "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {ACCEPT}\r\n\r\n"),
    ("resp_duplicate_accept_bad_first", "resp", "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: AAAAAAAAAAAAAAAAAAAAAAAAAAA=\r\nSec-WebSocket-Accept: {ACCEPT}\r\n\r\n"),
]
with open(sys.argv[1], "w") as f:
    for n, k, raw in cases:
        f.write(f"{n} {k} {raw.encode('latin-1').hex()}\n")
print(f"wrote {len(cases)} handshake cases to {sys.argv[1]}", file=sys.stderr)
