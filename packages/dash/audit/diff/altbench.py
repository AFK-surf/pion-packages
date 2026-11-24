#!/usr/bin/env python3
"""Second benchmark corpus, closer to production live / VOD manifests than bench/gen_data.py:
long tokenised CDN URLs (&amp; escaped queries), multi-Period ad insertion, Widevine + PlayReady pssh boxes
(PlayReady PRO ~1.5 KB base64) next to cenc:default_KID, and large SegmentTimelines (2 h DVR window, AAC
96256/95232 alternation that defeats @r compression).

altbench.py <out_file> [docs]  -> writes the bench_compare corpus (docs separated by '\\n===MPD===\\n'),
prints '<docs> <bytes>'. Deterministic; no media files.
"""
import base64
import random
import sys


def b64(R, n):
    return base64.b64encode(bytes(R.getrandbits(8) for _ in range(n))).decode()


def token(R):
    return "hdntl=exp=%d~acl=%%2f*~data=hdntl~hmac=%s" % (1700000000 + R.randint(0, 10 ** 7), "%064x" % R.getrandbits(256))


def drm(R):
    kid = "%08x-%04x-4%03x-8%03x-%012x" % (R.getrandbits(32), R.getrandbits(16), R.getrandbits(12), R.getrandbits(12), R.getrandbits(48))
    return ('<ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011" value="cenc" cenc:default_KID="%s"/>'
            '<ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed" value="Widevine"><cenc:pssh>%s</cenc:pssh></ContentProtection>'
            '<ContentProtection schemeIdUri="urn:uuid:9a04f079-9840-4286-ab92-e65be0885f95" value="MSPR 2.0"><cenc:pssh>%s</cenc:pssh></ContentProtection>'
            % (kid, b64(R, 90), b64(R, 1100)))


def video_timeline(R, n, ts):
    out = []
    t = R.randint(0, 10 ** 6) * ts
    out.append('<S t="%d" d="%d" r="%d"/>' % (t, 2 * ts, n // 2))
    for _ in range(n // 20):
        d = 2 * ts + R.choice((-1, 1)) * R.randint(1, ts // 10)
        out.append('<S d="%d"/>' % d)
        out.append('<S d="%d" r="%d"/>' % (2 * ts, R.randint(3, 18)))
    return "".join(out)


def audio_timeline(n):
    out = ['<S t="0" d="96256"/>']
    for i in range(n):
        out.append('<S d="%d"/>' % (95232 if i % 2 else 96256))
    return "".join(out)


def doc(R, idx):
    host = "https://vod-%d.cdn%d.example-streaming.com" % (R.randint(1, 99), R.randint(1, 9))
    path = "/live/%s/%s/" % ("%032x" % R.getrandbits(128), "channel-%d" % idx)
    periods = []
    t0 = 0
    for pi in range(R.randint(3, 6)):
        ad = pi % 2 == 1
        dur = R.randint(15, 45) if ad else R.randint(600, 1800)
        segs = dur // 2
        vids = "".join(
            '<Representation id="v%d_%d" bandwidth="%d" width="%d" height="%d" frameRate="30000/1001" codecs="%s" sar="1:1"/>'
            % (pi, k, bw, w, h, c, )
            for k, (bw, w, h, c) in enumerate([(400000, 640, 360, "avc1.4d401e"), (900000, 854, 480, "avc1.4d401f"),
                                              (1800000, 1280, 720, "avc1.640020"), (3500000, 1920, 1080, "avc1.640028"),
                                              (6000000, 1920, 1080, "hvc1.1.6.L120.90"), (12000000, 3840, 2160, "hvc1.2.4.L153.90")][:R.randint(4, 6)]))
        video = ('<AdaptationSet id="%d" contentType="video" mimeType="video/mp4" segmentAlignment="true" startWithSAP="1" maxWidth="3840" maxHeight="2160" par="16:9">'
                 '%s<Role schemeIdUri="urn:mpeg:dash:role:2011" value="main"/>'
                 '<SegmentTemplate timescale="90000" presentationTimeOffset="%d" initialization="$RepresentationID$/init.mp4?%s" media="$RepresentationID$/$Time$.m4s?%s">'
                 '<SegmentTimeline>%s</SegmentTimeline></SegmentTemplate>%s</AdaptationSet>'
                 % (pi * 10 + 1, "" if ad else drm(R), t0 * 90000, token(R).replace("&", "&amp;"), token(R).replace("&", "&amp;"),
                    video_timeline(R, segs, 90000), vids))
        audios = ""
        for li, lang in enumerate(["en", "es", "fr"][:1 if ad else R.randint(2, 3)]):
            audios += ('<AdaptationSet id="%d" contentType="audio" mimeType="audio/mp4" lang="%s" segmentAlignment="true">%s'
                       '<AudioChannelConfiguration schemeIdUri="urn:mpeg:dash:23003:3:audio_channel_configuration:2011" value="2"/>'
                       '<SegmentTemplate timescale="48000" initialization="$RepresentationID$/init.mp4" media="$RepresentationID$/$Time$.m4s?%s">'
                       '<SegmentTimeline>%s</SegmentTimeline></SegmentTemplate>'
                       '<Representation id="a%d_%s" bandwidth="128000" codecs="mp4a.40.2" audioSamplingRate="48000"/></AdaptationSet>'
                       % (pi * 10 + 2 + li, lang, "" if ad else drm(R), token(R).replace("&", "&amp;"), audio_timeline(segs), pi, lang))
        text = ('<AdaptationSet id="%d" contentType="text" mimeType="application/mp4" codecs="stpp" lang="en">'
                '<Role schemeIdUri="urn:mpeg:dash:role:2011" value="subtitle"/>'
                '<SegmentTemplate timescale="1000" duration="2000" startNumber="%d" media="sub/$Number%%06d$.m4s"/>'
                '<Representation id="t%d" bandwidth="2000"/></AdaptationSet>' % (pi * 10 + 9, R.randint(1, 10 ** 6), pi))
        periods.append('<Period id="%s" start="PT%dS"><BaseURL>%s</BaseURL>%s%s%s</Period>'
                       % ("ad-%d" % pi if ad else "content-%d" % pi, t0, ("ads/%d/" % pi) if ad else "content/", video, audios, text))
        t0 += dur
    return ('<?xml version="1.0" encoding="UTF-8"?>\n<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" xmlns:cenc="urn:mpeg:cenc:2013" '
            'id="alt-%d" type="dynamic" profiles="urn:mpeg:dash:profile:isoff-live:2011,urn:dvb:dash:profile:dvb-dash:2014" '
            'availabilityStartTime="2024-03-01T00:00:00Z" publishTime="2024-03-01T02:00:00Z" minimumUpdatePeriod="PT2S" '
            'timeShiftBufferDepth="PT2H" suggestedPresentationDelay="PT8S" minBufferTime="PT4S" maxSegmentDuration="PT2.1S">'
            '<BaseURL>%s%s</BaseURL><UTCTiming schemeIdUri="urn:mpeg:dash:utc:http-iso:2014" value="https://time.example.com/?iso"/>%s</MPD>'
            % (idx, host, path, "".join(periods)))


def main():
    out = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 12
    R = random.Random(2309)
    docs = [doc(R, i) for i in range(n)]
    data = "\n===MPD===\n".join(docs) + "\n"
    open(out, "w").write(data)
    print(n, len(data.encode()))


if __name__ == "__main__":
    main()
