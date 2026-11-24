#!/usr/bin/env python3
"""Second, differently shaped benchmark corpus (bench/gen_corpus.py is the package's own): long absolute URLs,
EXT-X-PROGRAM-DATE-TIME on every segment, AES-128 key rotation with IVs, explicit byte ranges, larger masters.
Only features both parsers handle identically are used, so the two bench outputs must be byte-identical.

usage: altbench.py <out_file>   prints `<playlists> <bytes>`
"""
import sys

SEP = "\n===HLS_CASE_SEP===\n"


def media(i):
    out = ["#EXTM3U", "#EXT-X-VERSION:6", "#EXT-X-TARGETDURATION:7", "#EXT-X-MEDIA-SEQUENCE:%d" % (i * 1000),
           "#EXT-X-PLAYLIST-TYPE:VOD", '#EXT-X-MAP:URI="https://media-%02d.cdn.example.net/vod/title-%d/init.mp4"' % (i % 7, i)]
    for s in range(1000):
        if s % 10 == 0:
            out.append('#EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.net/v1/key/%d/%d?token=abcdef0123456789",IV=0x%032x'
                       % (i, s // 10, i * 7919 + s))
        if s % 97 == 96:
            out.append("#EXT-X-DISCONTINUITY")
        out.append("#EXT-X-PROGRAM-DATE-TIME:2026-11-%02dT%02d:%02d:%02d.%03dZ" % (1 + i % 28, s // 600 % 24, s // 10 % 60,
                                                                               s * 6 % 60, s * 37 % 1000))
        out.append("#EXTINF:%d.%03d,segment %d" % (5 + s % 2, (i * 31 + s * 17) % 1000, s))
        out.append("#EXT-X-BYTERANGE:%d@%d" % (180000 + s * 13 % 5000, s * 200000))
        out.append("https://media-%02d.cdn.example.net/vod/title-%d/video/avc1-1080p/segment-bundle-%04d.mp4" % (i % 7, i, s // 50))
    out.append("#EXT-X-ENDLIST")
    return "\n".join(out) + "\n"


def master(i):
    out = ["#EXTM3U", "#EXT-X-VERSION:6", "#EXT-X-INDEPENDENT-SEGMENTS"]
    for l, n in (("en", "English"), ("fr", "French"), ("de", "German"), ("ja", "Japanese"), ("es", "Spanish"), ("zh", "Chinese")):
        out.append('#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac-%d",NAME="%s",LANGUAGE="%s",AUTOSELECT=YES,URI="https://cdn.example.net/t%d/audio/%s/index.m3u8"'
                   % (i, n, l, i, l))
    for v in range(12):
        out.append('#EXT-X-STREAM-INF:BANDWIDTH=%d,AVERAGE-BANDWIDTH=%d,CODECS="avc1.64002%x,mp4a.40.2",RESOLUTION=%dx%d,FRAME-RATE=%s,AUDIO="aac-%d"'
                   % (400000 * (v + 1), 350000 * (v + 1), v % 10, 320 * (v + 1), 180 * (v + 1), "29.970" if v % 2 else "59.940", i))
        out.append("https://cdn.example.net/t%d/video/%dp/index.m3u8?session=%032x" % (i, 180 * (v + 1), i * 131 + v))
    return "\n".join(out) + "\n"


cases = [master(i) for i in range(20)] + [media(i) for i in range(40)]
text = SEP.join(cases)
open(sys.argv[1], "w").write(text)
print(len(cases), len(text.encode()))
