"""Generate DoS / complexity / benchmark-blind-spot inputs for RT-vcard.

usage: gen_dos.py <out_dir>
All files are deterministic. Sizes stay within VCardLimits::default() unless noted.
"""

import base64
import os
import sys

CRLF = b"\r\n"


def card(lines, ver=b"4.0"):
    return b"BEGIN:VCARD\r\nVERSION:" + ver + CRLF + b"".join(l + CRLF for l in lines) + b"END:VCARD\r\n"


def main(out):
    os.makedirs(out, exist_ok=True)

    def w(name, data):
        with open(os.path.join(out, name), "wb") as fh:
            fh.write(data)

    # D1: Quoted-Printable soft breaks -> parser re-copies the whole logical line on every `=CRLF`
    for n in (37500, 75000, 150000, 300000):
        w("d1_qp_%d.vcf" % n, card([b"FN:x", b"NOTE;ENCODING=QUOTED-PRINTABLE:" + b"a=\r\n" * n + b"b"], b"2.1"))
    # D2: 200k folded continuation lines in one property (must stay linear)
    w("d2_fold_200k.vcf", card([b"FN:x", b"NOTE:" + b"x\r\n " * 200000 + b"y"]))
    # D3: 50k properties in one card (default max_properties_per_card = 2048 -> LimitExceeded)
    w("d3_props_50k.vcf", card([b"FN:x"] + [b"X-P%d:v" % i for i in range(50000)]))
    # D4: 50k parameters on one property (default max_params_per_prop = 128 -> LimitExceeded)
    w("d4_params_50k.vcf", card([b"FN:x", b"NOTE" + b";X-A=b" * 50000 + b":v"]))
    # D5: largest inline avatars a default max_line_bytes (1 MiB) allows: 720 KiB data: URI + 360 KiB
    # ENCODING=b, x8 cards (~11.5 MB); decode must stay linear
    blob = bytes(range(256)) * (720 * 1024 // 256)
    w("d5_photo_8m.vcf", card([b"FN:x", b"PHOTO:data:image/png;base64," + base64.b64encode(blob),
                               b"PHOTO;ENCODING=b;TYPE=PNG:" + base64.b64encode(blob[: 360 * 1024])], b"3.0") * 8)
    # D6: memory amplification: 64 MiB of minimal `a;b;c:` properties, every limit respected
    one = card([b"a;b;c:"] * 2040, b"4.0")
    w("d6_amp_64m.vcf", one * (67108864 // len(one)))
    # D6s: same shape at 16 MiB (native RSS ratio vs go-vcard)
    w("d6_amp_16m.vcf", one * (16 * 1024 * 1024 // len(one)))

    # B*: benchmark blind spots (informative, not gating), ~4-6 MB each
    wide = card([b"FN:Wide %d" % 0, b"N:Doe;John;;;"]
                + [b"item%d.TEL;TYPE=cell,voice;PREF=%d:+1-555-%04d" % (i, i % 100 + 1, i) for i in range(1500)]
                + [b"EMAIL;TYPE=work:u%d@example.com" % i for i in range(500)])
    w("b1_wide_cards.vcf", wide * 30)
    note = ("lorem ipsum 会议纪要 \U0001F600 " * 40).encode()
    folded, cur = [], b""
    for ch in note.decode():
        e = ch.encode()
        if len(cur) + len(e) > 74:
            folded.append(cur)
            cur = b""
        cur += e
    folded.append(cur)
    w("b2_heavy_fold.vcf", card([b"FN:x", b"NOTE:" + b"\r\n ".join(folded)]) * 1500)
    w("b3_escape_dense.vcf", card([b"FN:a\\,b\\;c\\\\d\\ne", b"N:" + b"x\\\\;y\\,z," * 20 + b";g;;;",
                                   b"ADR:" + b";".join([b"p\\,q\\;r\\\\" * 10] * 7),
                                   b"ORG:" + b"A\\;B;" * 30 + b"Z"]) * 6000)
    qp = "".join("=%02X" % b for b in ("会议纪要 \U0001F600 lorem " * 20).encode())
    qpl = [qp[i:i + 72] for i in range(0, len(qp), 72)]
    w("b4_qp_v21.vcf", card([b"FN;CHARSET=UTF-8;ENCODING=QUOTED-PRINTABLE:" + "=\r\n".join(qpl).encode()], b"2.1") * 3000)


if __name__ == "__main__":
    main(sys.argv[1])
