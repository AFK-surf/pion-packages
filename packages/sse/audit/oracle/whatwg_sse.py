#!/usr/bin/env python3
"""WHATWG HTML Living Standard §9.2.6 reference oracle + corpus generator + differential checker
for the packages/sse red-team audit.

  whatwg_sse.py gen <cases.hex> <n_random> <seed>     hand-written + random corpus (one hex stream per line)
  whatwg_sse.py diff <cases.hex> <pion.out> <rust.out>
                                                       gate: Pion == spec oracle under every chunking;
                                                       Rust eventsource-stream 0.2.3 == oracle-with-its-
                                                       known-quirks (anything else is UNEXPLAINED)

The oracle is a literal transcription of §9.2.6 "Interpreting an event stream" applied to the
byte stream: UTF-8 decode (BOM EF BB BF stripped once at stream start, ill-formed sequences ->
U+FFFD maximal subparts, WHATWG Encoding §4 / Python 'replace' is identical), lines split on
CRLF / LF / CR, an unterminated final line discarded, then the field rules.  Two documented
choices of packages/sse are modelled explicitly:
  * SseEvent.retry carries a valid retry: seen in the same event block (reset on every blank line);
  * retry: values above Int64::MAX are ignored (the spec has no bound; README documents this).
Strict mode (Utf8Mode::Strict): an error once a complete (or, at finish(), trailing) line is not
valid UTF-8; events dispatched before that line must still have been delivered under 1-byte feeding.
"""
import random
import sys

I64_MAX = (1 << 63) - 1
U64_MAX = (1 << 64) - 1


def hx(s):
    return s.encode("utf-8", "surrogatepass").hex()


def split_lines(data, cr_at_eof_terminates=True):
    """Split raw bytes into complete lines; returns (lines, trailing_partial_bytes)."""
    lines = []
    i = 0
    start = 0
    n = len(data)
    while i < n:
        c = data[i]
        if c == 0x0A:
            lines.append(data[start:i])
            i += 1
            start = i
        elif c == 0x0D:
            if i + 1 == n and not cr_at_eof_terminates:
                break
            lines.append(data[start:i])
            i += 2 if (i + 1 < n and data[i + 1] == 0x0A) else 1
            start = i
        else:
            i += 1
    return lines, data[start:]


def strip_bom(data):
    return data[3:] if data[:3] == b"\xef\xbb\xbf" else data


def interpret(lines, retry_ok):
    """§9.2.6 field processing over decoded lines; returns (events, last_event_id, stream_retry)."""
    events = []
    data_buf = None  # None == "data buffer is empty string" (no data field seen)
    data_parts = []
    etype = ""
    id_buf = ""
    last_id = ""
    blk_retry = None
    s_retry = None
    for line in lines:
        if line == "":
            last_id = id_buf
            if data_buf is not None:
                events.append((etype or "message", "\n".join(data_parts), last_id, blk_retry))
            data_buf = None
            data_parts = []
            etype = ""
            blk_retry = None
            continue
        if line[0] == ":":
            continue
        if ":" in line:
            name, value = line.split(":", 1)
            if value.startswith(" "):
                value = value[1:]
        else:
            name, value = line, ""
        if name == "data":
            data_buf = True
            data_parts.append(value)
        elif name == "event":
            etype = value
        elif name == "id":
            if "\x00" not in value:
                id_buf = value
        elif name == "retry":
            v = retry_ok(value)
            if v is not None:
                blk_retry = v
                s_retry = v
    return events, last_id, s_retry


def retry_spec(value):
    if value and all("0" <= c <= "9" for c in value):
        v = int(value)
        return v if v <= I64_MAX else None
    return None


def retry_rust(value):
    # Rust `str::parse::<u64>()`: optional leading '+', digits, <= u64::MAX
    body = value[1:] if value.startswith("+") else value
    if body and all("0" <= c <= "9" for c in body):
        v = int(body)
        return v if v <= U64_MAX else None
    return None


def fmt_events(events):
    return "".join("[t=%s,d=%s,i=%s,r=%s]" % (hx(t), hx(d), hx(i), "-" if r is None else r)
                   for t, d, i, r in events)


def oracle(raw):
    """Expected Pion Replace-mode output for any chunking (no limit can trigger in the corpus)."""
    body = strip_bom(raw)
    lines, _ = split_lines(body)
    dec = [l.decode("utf-8", "replace") for l in lines]
    ev, last, sr = interpret(dec, retry_spec)
    return "%s last=%s sretry=%s" % (fmt_events(ev), hx(last), "-" if sr is None else sr)


def strict_expect(raw):
    """(error_expected, events_delivered_before_error_under_1B_feeding_or_full_output)."""
    body = raw[3:] if raw[:3] == b"\xef\xbb\xbf" else raw
    lines, tail = split_lines(body)
    good = []
    for l in lines:
        try:
            good.append(l.decode("utf-8"))
        except UnicodeDecodeError:
            ev, _, _ = interpret(good, retry_spec)
            return True, fmt_events(ev)
    # Pion keeps a partial BOM (EF / EF BB) out of the line buffer until the next byte arrives.
    pending_bom = raw in (b"\xef", b"\xef\xbb")
    if tail and not pending_bom:
        try:
            tail.decode("utf-8")
        except UnicodeDecodeError:
            ev, _, _ = interpret(good, retry_spec)
            return True, fmt_events(ev)
    return False, oracle(raw)


def rust_expect(raw):
    """eventsource-stream 0.2.3 model: same rules plus its documented quirks (see REPORT.md U-1..U-4)."""
    # U-4: Utf8Stream keeps the first ill-formed byte in its buffer forever, yields nothing after it
    # and returns Err(Utf8) at EOF.
    try:
        text = raw.decode("utf-8")
        bad = False
    except UnicodeDecodeError as e:
        text = raw[: e.start].decode("utf-8")
        bad = True
    if text.startswith("\ufeff"):
        return "!PANIC"  # U-5: `&string[1..]` slices inside the 3-byte U+FEFF -> panic
    data = text.encode("utf-8", "surrogatepass")
    # U-3: a CR that is the last byte the parser ever sees is "Incomplete" (waits for a possible LF)
    lines, _ = split_lines(data, cr_at_eof_terminates=False)
    ev, _, _ = interpret([l.decode("utf-8") for l in lines], retry_rust)  # U-1/U-2: '+N' and u64 range
    return fmt_events(ev) + ("!ERR:Utf8" if bad else "")


# ---------------------------------------------------------------------------------------------
# corpus
# ---------------------------------------------------------------------------------------------

HAND = [
    # BOM
    b"\xef\xbb\xbfdata: a\n\n",
    b"\xef\xbb\xbf\xef\xbb\xbfdata: a\n\n",                # 2nd BOM is part of field name -> ignored
    b"data: a\n\n\xef\xbb\xbfdata: b\n\n",                  # later U+FEFF at line start must not be stripped
    b"\xef\xbb\xbfdata: a\n\n\xef\xbb\xbfid: 9\n\n",
    b"\xef\xbbdata: a\n\n",                                  # partial BOM
    b"\xefdata: a\n\ndata: b\n\n",
    b"\xef\n\ndata: x\n\n",
    b"\xef\xbb\xbf",
    b"\xef\xbb",
    b"\xef",
    b"\xef\xbb\xbf\n\ndata:\xef\xbb\xbfx\n\n",
    b"data: \xef\xbb\xbf\n\n",
    # UTF-8 multi-byte + ill-formed
    "data: 你好🚀\n\n".encode(),
    "event: 事件\nid: ✓\ndata: 𝄞x\n\n".encode(),
    b"data: \x80\n\n",
    b"data: a\x80b\n\n",
    b"data: \xc0\xaf\n\n",
    b"data: \xe4\xb8A\n\n",
    b"data: \xed\xa0\x80\n\n",
    b"data: \xf4\x90\x80\x80\n\n",
    b"data: \xf0\x9f\x98\n\n",
    b"data: \xf0\x9f\x98\x80\xf0\x9f\n\n",
    b"data: \xff\xfe\n\n",
    b"data: ok\n\ndata: \xe4\xb8",                          # truncated UTF-8 at EOF
    b"data: ok\n\ndata: \xe4\xb8\n\n",
    b"id: \xff\ndata: x\n\n",
    b"event: \xc3\ndata: x\n\n",
    b"\xffdata: x\n\n",
    b"data: ok\n\n:\xff comment\ndata: y\n\n",
    # line endings
    b"data: a\r\r\n",
    b"data: a\r\n\r\n",
    b"data: a\r\rdata: b\r\r",
    b"data: a\n\r",
    b"data: a\r\n\r",
    b"data: a\r",
    b"data: hi",
    b"data: hi\n",
    b"data: a\n\ndata: b",
    b"data: a\r\ndata: b\rdata: c\n\n",
    b"\r\n\r\n\n\r\rdata: z\r\n\r\n",
    b"data: a\n\r\n",
    # field rules
    b"data\n\n",
    b"data\ndata\n\n",
    b"data:\n\n",
    b"data:  two\n\n",
    b"data:\tx\n\n",
    b"data: a\ndata:\ndata: b\n\n",
    b":comment\n\n",
    b":\n\ndata: x\n\n",
    b"DATA: x\n\nData: y\n\n",
    b"data : x\n\n",
    b" data: x\n\n",
    b"dat: x\n\n",
    b"id: 1\ndata: a\n\nid: a\x00b\ndata: b\n\n",
    b"id: 1\ndata: a\n\nid\ndata: b\n\n",
    b"id: 1\ndata: a\n\nid:\ndata: b\n\n",
    b"id: 1\n\ndata: b\n\n",                               # id committed by data-less block
    b"id: 1\ndata: a\n\nid: 2\ndata: b",                   # trailing id not committed
    b"id: x:y\ndata: a\n\n",
    b"id:  sp\ndata: a\n\n",
    b"event: e\n\ndata: x\n\n",                             # event reset by data-less block
    b"event: e\ndata: x\n\ndata: y\n\n",
    b"event\ndata: x\n\n",
    b"event: \ndata: x\n\n",
    b"event: message\ndata: x\n\n",
    b"retry: 100\ndata: x\n\n",
    b"retry: +100\ndata: x\n\n",
    b"retry: -100\ndata: x\n\n",
    b"retry: 100ms\ndata: x\n\n",
    b"retry:  100\ndata: x\n\n",
    b"retry: 1 0\ndata: x\n\n",
    b"retry: \ndata: x\n\n",
    b"retry\ndata: x\n\n",
    b"retry: 0\ndata: x\n\n",
    b"retry: 007\ndata: x\n\n",
    b"retry: 9223372036854775807\ndata: x\n\n",
    b"retry: 9223372036854775808\ndata: x\n\n",
    b"retry: 18446744073709551615\ndata: x\n\n",
    b"retry: 99999999999999999999\ndata: x\n\n",
    b"retry: \xef\xbc\x91\ndata: x\n\n",                   # fullwidth digit
    b"retry: 5\n\ndata: x\n\n",                             # per-block retry reset; stream retry kept
    b"data: x\nretry: 7\n\n",
    b"",
    b"\n",
    b"\n\n\n\n",
    b"data: a\x00b\n\n",
    b"\x00data\n\n",
]

TOKENS_NAME = ["data", "data", "data", "event", "id", "retry", "", "dat", "DATA", "data ",
               " data", "\ufeffdata", "x", "datas"]
TOKENS_SEP = [": ", ":", ":  ", "", ": ", ":\t"]
TOKENS_VAL = ["", "a", "hello world", " lead", "trail ", "你好", "🚀", "\ufeff", "a\x00b", "x:y",
              "123", "+5", "-5", "0", "99999999999999999999", "18446744073709551615",
              "9223372036854775808", "1e3", "message", "data: nested"]
TOKENS_EOL = [b"\n", b"\n", b"\r\n", b"\r"]
RAW_BAD = [b"\x80", b"\xc0\xaf", b"\xe4\xb8", b"\xed\xa0\x80", b"\xf0\x9f\x98", b"\xff", b"\xf4\x90\x80\x80"]


def gen_random(rng):
    out = bytearray()
    if rng.random() < 0.15:
        out += b"\xef\xbb\xbf"
    for _ in range(rng.randint(1, 12)):
        r = rng.random()
        if r < 0.22:
            pass  # blank line
        elif r < 0.30:
            out += b":" + rng.choice(TOKENS_VAL).encode()
        else:
            out += rng.choice(TOKENS_NAME).encode() + rng.choice(TOKENS_SEP).encode()
            out += rng.choice(TOKENS_VAL).encode()
            if rng.random() < 0.05:
                out += rng.choice(RAW_BAD)
        out += rng.choice(TOKENS_EOL)
    if rng.random() < 0.6:
        out += rng.choice([b"\n", b"\r\n", b"\r"])
    if rng.random() < 0.15:
        out += b"data: partial"
    return bytes(out)


def gen(path, n_random, seed):
    rng = random.Random(seed)
    cases = list(HAND) + [gen_random(rng) for _ in range(n_random)]
    with open(path, "w") as f:
        for c in cases:
            f.write(c.hex() + "\n")
    print("corpus: %d hand-written + %d random = %d cases -> %s" % (len(HAND), n_random, len(cases), path))


# ---------------------------------------------------------------------------------------------
# diff
# ---------------------------------------------------------------------------------------------

def load(path):
    res = {}
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line:
            continue
        idx, strat, rest = (line.split(" ", 2) + [""])[:3]
        res[(int(idx), strat)] = rest
    return res


def diff(cases_path, pion_path, rust_path):
    cases = [bytes.fromhex(l.rstrip("\n")) for l in open(cases_path)]
    P = load(pion_path)
    R = load(rust_path)
    fails = []
    unexplained = []
    stats = {"pion_ok": 0, "rust_ok": 0, "rust_quirk": 0, "strict_ok": 0}
    quirk_cases = {}
    for i, raw in enumerate(cases):
        want = oracle(raw)
        bad = False
        for s in ("whole", "b1", "b2", "b3", "b7", "rnd"):
            got = P.get((i, s))
            if got != want:
                bad = True
                fails.append("case %d [%s] input=%s\n      want %s\n      got  %s" % (i, s, raw.hex(), want, got))
        # Strict mode
        err, exp = strict_expect(raw)
        sw, sb1 = P.get((i, "strict_whole")), P.get((i, "strict_b1"))
        if err:
            ok_b1 = sb1 == exp + "!ERR:InvalidUtf8"
            # whole-buffer feeding: the error must surface; which prefix events were returned with it
            # is the subject of redteam_error_* unit tests, not of this differential
            ok_w = (sw or "").endswith("!ERR:InvalidUtf8") and exp.startswith((sw or "")[: -len("!ERR:InvalidUtf8")])
        else:
            ok_b1 = sb1 == exp
            ok_w = sw == exp
        if not (ok_b1 and ok_w):
            bad = True
            fails.append("case %d [strict] input=%s\n      want err=%s %s\n      got  whole=%s\n           b1=%s" % (i, raw.hex(), err, exp, sw, sb1))
        else:
            stats["strict_ok"] += 1
        if not bad:
            stats["pion_ok"] += 1
        # Rust eventsource-stream 0.2.3
        rq = rust_expect(raw)
        spec_events = want.split(" last=")[0]
        for s in ("whole", "b1", "rnd"):
            got = R.get((i, s))
            if got != rq:
                unexplained.append("case %d [rust %s] input=%s\n      model %s\n      got   %s" % (i, s, raw.hex(), rq, got))
        if rq == spec_events:
            stats["rust_ok"] += 1
        else:
            stats["rust_quirk"] += 1
            if rq == "!PANIC":
                k = "U-5 leading BOM: panics (byte-slices inside U+FEFF)"
            elif rq.endswith("!ERR:Utf8"):
                k = "U-4 ill-formed UTF-8: stalls, then Err at EOF"
            elif raw.endswith(b"\r") and rust_expect(raw + b"\n").split("!")[0] == spec_events:
                k = "U-3 CR at EOF is not a line terminator"
            else:
                k = "U-1/U-2 retry: '+N' or > Int64::MAX accepted"
            quirk_cases.setdefault(k, []).append(i)
    n = len(cases)
    print("cases: %d (x6 Replace chunkings + 2 Strict feeds for Pion, x3 chunkings for Rust)" % n)
    print("Pion == WHATWG oracle under every chunking: %d/%d" % (stats["pion_ok"], n))
    print("Pion Strict mode == oracle: %d/%d" % (stats["strict_ok"], n))
    print("Rust eventsource-stream 0.2.3 == WHATWG oracle: %d/%d; differs only by its known quirks: %d" % (stats["rust_ok"], n, stats["rust_quirk"]))
    for k, v in sorted(quirk_cases.items()):
        print("  upstream quirk [%s]: %d cases, e.g. #%s" % (k, len(v), ", #".join(map(str, v[:5]))))
    for f in fails[:25]:
        print("  FINDING " + f)
    if len(fails) > 25:
        print("  ... %d more" % (len(fails) - 25))
    for u in unexplained[:15]:
        print("  UNEXPLAINED " + u)
    if len(unexplained) > 15:
        print("  ... %d more" % (len(unexplained) - 15))
    return 1 if (fails or unexplained) else 0


def main():
    if len(sys.argv) >= 5 and sys.argv[1] == "gen":
        gen(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
        return 0
    if len(sys.argv) >= 5 and sys.argv[1] == "diff":
        return diff(sys.argv[2], sys.argv[3], sys.argv[4])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
