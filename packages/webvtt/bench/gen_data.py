#!/usr/bin/env python3
"""Generate a realistic 8,000-cue W3C WebVTT corpus for head-to-head benchmarking."""

import sys


def fmt_ts(ms: int, force_hours: bool) -> str:
    h = ms // 3600000
    rem = ms % 3600000
    m = rem // 60000
    rem = rem % 60000
    s = rem // 1000
    mil = rem % 1000
    if force_hours or h > 0:
        return f"{h:02d}:{m:02d}:{s:02d}.{mil:03d}"
    return f"{m:02d}:{s:02d}.{mil:03d}"


def main() -> int:
    out_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pion-webvtt-bench/corpus.vtt"
    num_cues = int(sys.argv[2]) if len(sys.argv) > 2 else 8000

    parts = [
        "\ufeffWEBVTT - Benchmark Long-Form Video Subtitles\n",
        "Kind: captions\n",
        "Language: en-US\n",
        "\n",
        "STYLE\n",
        "::cue {\n",
        "  color: white;\n",
        "  background-color: rgba(0, 0, 0, 0.75);\n",
        "}\n",
        "\n",
        "STYLE\n",
        "::cue(v[voice=\"Host\"]) { color: #9cf; }\n",
        "\n",
        "REGION\n",
        "id:bottom width:80% lines:2 regionanchor:50%,100% viewportanchor:50%,92% scroll:up\n",
        "\n",
        "REGION\n",
        "id:banner width:60% lines:1 regionanchor:50%,0% viewportanchor:50%,8%\n",
        "\n",
        "NOTE Generated deterministic WebVTT benchmark corpus\n",
        "Contains overlapping banners, rich tags, entities, and settings.\n",
        "\n",
    ]

    speakers = ["Host", "Alice", "Bob", "Narrator"]
    settings_pool = [
        "align:center line:90% size:80% region:bottom",
        "align:start position:10%,line-left size:75%",
        "align:end position:90%,line-right line:85%,end",
        "",
    ]

    for i in range(num_cues):
        start_ms = i * 1800
        if i % 20 == 0:
            # Long overlapping banner cue spanning ~8 dialogue cues
            end_ms = start_ms + 14500
            setting = "align:center line:8% size:60% region:banner"
        else:
            end_ms = start_ms + 2400
            setting = settings_pool[i % len(settings_pool)]

        force_h = (i % 2 == 0)
        s_ts = fmt_ts(start_ms, force_h)
        e_ts = fmt_ts(end_ms, force_h)

        if i % 500 == 0 and i > 0:
            parts.append(f"NOTE Chapter marker {i // 500}\n\n")

        parts.append(f"cue-{i}\n")
        if setting:
            parts.append(f"{s_ts} --> {e_ts} {setting}\n")
        else:
            parts.append(f"{s_ts} --> {e_ts}\n")

        mod = i % 4
        if mod == 0:
            spk = speakers[i % len(speakers)]
            mid_ts = fmt_ts(start_ms + 750, False)
            parts.append(
                f"<v.loud {spk}>Welcome to <b>segment {i}</b> &amp; <i>live Q&amp;A</i>!<"
                f"{mid_ts}> Check <c.hi>A &lt; B &gt; C</c>.</v>\n\n"
            )
        elif mod == 1:
            parts.append(
                f"Plain subtitle line number {i} for steady-state playback testing.\n"
                f"Second line of dialogue without markup.\n\n"
            )
        elif mod == 2:
            parts.append(
                f"<lang en-US><u>Topic {i}</u>: spacing&nbsp;check &amp; <ruby>字幕<rt>じまく</rt></ruby></lang>\n\n"
            )
        else:
            parts.append(
                f"Fast-path clean dialogue cue {i} with zero HTML tags or entities.\n\n"
            )

    with open(out_path, "w", encoding="utf-8", newline="") as f:
        f.write("".join(parts))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
