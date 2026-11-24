#!/usr/bin/env python3
"""Generate deterministic HLS Master, Media, and LL-HLS corpora for differential oracle and benchmarks."""

import os
import sys

SEP = "===HLS_CASE_SEP==="


def make_master_case(idx: int) -> str:
    lines = [
        "#EXTM3U",
        f"#EXT-X-VERSION:{6 + (idx % 4)}",
    ]
    if idx % 2 == 0:
        lines.append("#EXT-X-INDEPENDENT-SEGMENTS")
    if idx % 3 == 0:
        sign = "-" if idx % 6 == 0 else ""
        lines.append(f"#EXT-X-START:TIME-OFFSET={sign}{1 + (idx % 10)}.25,PRECISE={'YES' if idx % 2 == 0 else 'NO'}")
    lines.append(
        f'#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-aac",NAME="English {idx}",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="audio_{idx}_en.m3u8"'
    )
    lines.append(
        f'#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-aac",NAME="Japanese {idx}",LANGUAGE="ja",DEFAULT=NO,AUTOSELECT=YES,URI="audio_{idx}_ja.m3u8"'
    )
    lines.append(
        f'#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English CC",LANGUAGE="en",DEFAULT=NO,AUTOSELECT=YES,FORCED=NO,URI="subs_{idx}.m3u8"'
    )
    lines.append(
        '#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc",NAME="CC1",LANGUAGE="en",INSTREAM-ID="CC1"'
    )
    if idx % 4 == 0:
        lines.append(
            f'#EXT-X-SESSION-DATA:DATA-ID="com.example.id.{idx}",VALUE="Stream-{idx}",LANGUAGE="en"'
        )
    if idx % 5 == 0:
        lines.append(
            f'#EXT-X-SESSION-KEY:METHOD=AES-128,URI="https://keys.example.com/s/{idx}",IV=0x{idx:032x}'
        )
    profiles = [
        (800000, 720000, "avc1.4d401e,mp4a.40.2", "640x360", "29.970", "low"),
        (2200000, 1950000, "avc1.64001f,mp4a.40.2", "1280x720", "29.970", "mid"),
        (5200000, 4700000, "hvc1.1.6.L120.90,mp4a.40.2", "1920x1080", "59.940", "high"),
        (12000000, 10500000, "hvc1.1.6.L150.90,mp4a.40.2", "3840x2160", "59.940", "uhd"),
    ]
    for bw, abw, codecs, res, fps, label in profiles:
        lines.append(
            f'#EXT-X-STREAM-INF:BANDWIDTH={bw + idx * 100},AVERAGE-BANDWIDTH={abw + idx * 50},CODECS="{codecs}",RESOLUTION={res},FRAME-RATE={fps},AUDIO="audio-aac",SUBTITLES="subs",CLOSED-CAPTIONS=NONE'
        )
        lines.append(f"streams/{idx}/{label}.m3u8")
    lines.append(
        f'#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH={250000 + idx},RESOLUTION=1280x720,CODECS="avc1.64001f",URI="streams/{idx}/iframe.m3u8"'
    )
    return "\n".join(lines) + "\n"


def make_media_case(idx: int, seg_count: int, llhls: bool = False) -> str:
    td = 4 + (idx % 7)
    msn = idx * 10
    dsn = idx % 5
    lines = [
        "#EXTM3U",
        f"#EXT-X-VERSION:{9 if llhls else 7}",
        f"#EXT-X-TARGETDURATION:{td}",
        f"#EXT-X-MEDIA-SEQUENCE:{msn}",
    ]
    if dsn > 0:
        lines.append(f"#EXT-X-DISCONTINUITY-SEQUENCE:{dsn}")
    if not llhls:
        lines.append("#EXT-X-PLAYLIST-TYPE:VOD" if idx % 2 == 0 else "#EXT-X-PLAYLIST-TYPE:EVENT")
    else:
        lines.append("#EXT-X-SERVER-CONTROL:CAN-SKIP-UNTIL=24.0,PART-HOLD-BACK=1.002,CAN-BLOCK-RELOAD=YES")
        lines.append("#EXT-X-PART-INF:PART-TARGET=0.334")
        if idx % 2 == 0:
            lines.append(f"#EXT-X-SKIP:SKIPPED-SEGMENTS={idx % 8}")

    use_byterange = (idx % 3 == 1) and not llhls
    if idx % 2 == 0:
        lines.append(f'#EXT-X-MAP:URI="init_{idx}.mp4",BYTERANGE="720@0"')
    if idx % 3 == 0:
        lines.append(
            f'#EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.com/k/{idx}",IV=0x{idx + 1:032x}'
        )

    offset = 720
    for s in range(seg_count):
        if s > 0 and s % 15 == 0:
            lines.append("#EXT-X-DISCONTINUITY")
        if s == 2 and idx % 3 == 0:
            lines.append("#EXT-X-KEY:METHOD=NONE")
        if s == 0:
            lines.append(f"#EXT-X-PROGRAM-DATE-TIME:2026-11-24T{(idx % 24):02d}:00:00.000Z")
        if llhls and s >= seg_count - 2:
            lines.append(f'#EXT-X-PART:DURATION=0.334,URI="seg_{idx}_{s}_p0.m4s",INDEPENDENT=YES')
            lines.append(f'#EXT-X-PART:DURATION=0.333,URI="seg_{idx}_{s}_p1.m4s"')
        dur_ms = (td - 1) * 1000 + ((idx * 37 + s * 13) % 999)
        dur_str = f"{dur_ms // 1000}.{dur_ms % 1000:03d}"
        title = f"Seg {s}" if s % 5 == 0 else ""
        lines.append(f"#EXTINF:{dur_str},{title}")
        if use_byterange:
            seg_len = 1024 + (s % 7) * 512
            if s == 0:
                lines.append(f"#EXT-X-BYTERANGE:{seg_len}@{offset}")
            else:
                # Implicit offset continuation on same URI
                lines.append(f"#EXT-X-BYTERANGE:{seg_len}")
            offset += seg_len
            lines.append(f"bundle_{idx}.mp4")
        else:
            lines.append(f"seg_{idx}_{msn + s}.m4s")

    if llhls:
        lines.append(f'#EXT-X-PART:DURATION=0.334,URI="seg_{idx}_next_p0.m4s",INDEPENDENT=YES')
        lines.append(f'#EXT-X-PRELOAD-HINT:TYPE=PART,URI="seg_{idx}_next_p1.m4s"')
        lines.append(f'#EXT-X-RENDITION-REPORT:URI="../alt/index.m3u8",LAST-MSN={msn + seg_count},LAST-PART=0')
    elif idx % 2 == 0:
        lines.append("#EXT-X-ENDLIST")

    return "\n".join(lines) + "\n"


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit("usage: gen_corpus.py <out_dir>")
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)

    # Differential oracle corpus: 200 diverse playlists
    diff_cases = []
    for i in range(60):
        diff_cases.append(make_master_case(i))
    for i in range(100):
        diff_cases.append(make_media_case(i, seg_count=8 + (i % 12), llhls=False))
    for i in range(40):
        diff_cases.append(make_media_case(i + 200, seg_count=6 + (i % 6), llhls=True))

    diff_path = os.path.join(out_dir, "diff_corpus.txt")
    with open(diff_path, "w", encoding="utf-8") as f:
        f.write(f"\n{SEP}\n".join(diff_cases))

    # Benchmark corpus: realistic large playlists (~1.5 MB)
    bench_cases = []
    for i in range(20):
        bench_cases.append(make_master_case(i))
    for i in range(50):
        bench_cases.append(make_media_case(i, seg_count=200, llhls=(i % 5 == 0)))

    bench_path = os.path.join(out_dir, "bench_corpus.txt")
    with open(bench_path, "w", encoding="utf-8") as f:
        f.write(f"\n{SEP}\n".join(bench_cases))

    print(f"{len(diff_cases)} {len(bench_cases)}")


if __name__ == "__main__":
    main()
