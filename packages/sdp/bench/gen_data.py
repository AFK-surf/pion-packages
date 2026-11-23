#!/usr/bin/env python3
"""Generate realistic large Chrome / Google Meet style WebRTC Offer & Answer SDP corpora."""

import os
import sys


def build_meet_offer() -> str:
    lines = [
        "v=0",
        "o=- 4611731400430051336 2 IN IP4 127.0.0.1",
        "s=-",
        "t=0 0",
        "a=group:BUNDLE 0 1 2 3",
        "a=extmap-allow-mixed",
        "a=msid-semantic: WMS meet-room-9876543210",
        "a=ice-options:trickle renomination",
        "a=fingerprint:sha-256 9F:8E:7D:6C:5B:4A:39:28:17:06:F5:E4:D3:C2:B1:A0:9F:8E:7D:6C:5B:4A:39:28:17:06:F5:E4:D3:C2:B1:A0",
    ]

    # Media 0: Audio (Opus, RED, CN, telephone-event, G722, PCMU, PCMA) + 12 ICE candidates
    lines.extend([
        "m=audio 9 UDP/TLS/RTP/SAVPF 111 63 9 0 8 13 110 126",
        "c=IN IP4 0.0.0.0",
        "b=AS:128",
        "a=rtcp:9 IN IP4 0.0.0.0",
    ])
    for i in range(6):
        lines.append(
            f"a=candidate:{1467250000 + i} 1 udp {2122260223 - i * 1000} 192.168.1.{10 + i} {54320 + i} typ host generation 0 ufrag m9Xk2pQ1 network-id {i + 1} network-cost {10 + i * 5}"
        )
        lines.append(
            f"a=candidate:{842163000 + i} 1 udp {1677729535 - i * 1000} 203.0.113.{10 + i} {60000 + i} typ srflx raddr 192.168.1.{10 + i} rport {54320 + i} generation 0 ufrag m9Xk2pQ1 network-id {i + 1}"
        )
    lines.extend([
        "a=candidate:310293847 1 tcp 1518280447 192.168.1.10 9 typ host tcptype active generation 0 ufrag m9Xk2pQ1 network-id 1",
        "a=candidate:410293848 1 udp 41885439 198.51.100.42 443 typ relay raddr 203.0.113.10 rport 60000 generation 0 ufrag m9Xk2pQ1 network-id 1 network-cost 999",
        "a=ice-ufrag:m9Xk2pQ1",
        "a=ice-pwd:V3ryS3cur3G00gl3M33tIc3P4ssw0rd2026",
        "a=setup:actpass",
        "a=mid:0",
        "a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level",
        "a=extmap:2 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time",
        "a=extmap:3 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01",
        "a=extmap:4 urn:ietf:params:rtp-hdrext:sdes:mid",
        "a=sendrecv",
        "a=msid:meet-room-9876543210 audio-track-local-01",
        "a=rtcp-mux",
        "a=rtpmap:111 opus/48000/2",
        "a=rtcp-fb:111 transport-cc",
        "a=fmtp:111 minptime=10;useinbandfec=1;stereo=0;sprop-stereo=0",
        "a=rtpmap:63 red/48000/2",
        "a=fmtp:63 111/111",
        "a=rtpmap:9 G722/8000",
        "a=rtpmap:0 PCMU/8000",
        "a=rtpmap:8 PCMA/8000",
        "a=rtpmap:13 CN/8000",
        "a=rtpmap:110 telephone-event/48000",
        "a=rtpmap:126 telephone-event/8000",
        "a=ssrc:1001001001 cname:chrome-meet-local-cname",
        "a=ssrc:1001001001 msid:meet-room-9876543210 audio-track-local-01",
    ])

    # Media 1 & 2: Camera Video + Screenshare Video (VP8, VP9, H.264 profiles, AV1, RTX, RED, ULPFEC, FlexFEC)
    for m_idx, (mid, track_name, bw) in enumerate(
        [("1", "camera-video-01", 2500), ("2", "screenshare-video-02", 4000)], start=1
    ):
        lines.extend([
            "m=video 9 UDP/TLS/RTP/SAVPF 96 97 98 99 100 101 102 103 104 105 106 107 108 109 114 115 116",
            "c=IN IP4 0.0.0.0",
            f"b=AS:{bw}",
            "a=rtcp:9 IN IP4 0.0.0.0",
            "a=ice-ufrag:m9Xk2pQ1",
            "a=ice-pwd:V3ryS3cur3G00gl3M33tIc3P4ssw0rd2026",
            "a=setup:actpass",
            f"a=mid:{mid}",
            "a=extmap:1 urn:ietf:params:rtp-hdrext:toffset",
            "a=extmap:2 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time",
            "a=extmap:3 urn:3gpp:video-orientation",
            "a=extmap:4 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01",
            "a=extmap:5 http://www.webrtc.org/experiments/rtp-hdrext/playout-delay",
            "a=extmap:6 http://www.webrtc.org/experiments/rtp-hdrext/video-content-type",
            "a=extmap:7 http://www.webrtc.org/experiments/rtp-hdrext/video-timing",
            "a=extmap:8 http://www.webrtc.org/experiments/rtp-hdrext/color-space",
            "a=extmap:9 urn:ietf:params:rtp-hdrext:sdes:mid",
            "a=extmap:10 urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id",
            "a=extmap:11 urn:ietf:params:rtp-hdrext:sdes:repaired-rtp-stream-id",
            "a=extmap:12/sendonly https://aomediacodec.github.io/av1-rtp-spec/#dependency-descriptor-rtp-header-extension",
            "a=sendrecv",
            f"a=msid:meet-room-9876543210 {track_name}",
            "a=rtcp-mux",
            "a=rtcp-rsize",
            "a=rtpmap:96 VP8/90000",
            "a=rtcp-fb:96 goog-remb",
            "a=rtcp-fb:96 transport-cc",
            "a=rtcp-fb:96 ccm fir",
            "a=rtcp-fb:96 nack",
            "a=rtcp-fb:96 nack pli",
            "a=rtpmap:97 rtx/90000",
            "a=fmtp:97 apt=96",
            "a=rtpmap:98 VP9/90000",
            "a=rtcp-fb:98 goog-remb",
            "a=rtcp-fb:98 transport-cc",
            "a=rtcp-fb:98 ccm fir",
            "a=rtcp-fb:98 nack",
            "a=rtcp-fb:98 nack pli",
            "a=fmtp:98 profile-id=0",
            "a=rtpmap:99 rtx/90000",
            "a=fmtp:99 apt=98",
            "a=rtpmap:100 VP9/90000",
            "a=rtcp-fb:100 goog-remb",
            "a=rtcp-fb:100 transport-cc",
            "a=rtcp-fb:100 ccm fir",
            "a=rtcp-fb:100 nack",
            "a=rtcp-fb:100 nack pli",
            "a=fmtp:100 profile-id=2",
            "a=rtpmap:101 rtx/90000",
            "a=fmtp:101 apt=100",
            "a=rtpmap:102 H264/90000",
            "a=rtcp-fb:102 goog-remb",
            "a=rtcp-fb:102 transport-cc",
            "a=rtcp-fb:102 ccm fir",
            "a=rtcp-fb:102 nack",
            "a=rtcp-fb:102 nack pli",
            "a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42001f",
            "a=rtpmap:103 rtx/90000",
            "a=fmtp:103 apt=102",
            "a=rtpmap:104 H264/90000",
            "a=rtcp-fb:104 goog-remb",
            "a=rtcp-fb:104 transport-cc",
            "a=rtcp-fb:104 ccm fir",
            "a=rtcp-fb:104 nack",
            "a=rtcp-fb:104 nack pli",
            "a=fmtp:104 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
            "a=rtpmap:105 rtx/90000",
            "a=fmtp:105 apt=104",
            "a=rtpmap:106 H264/90000",
            "a=rtcp-fb:106 goog-remb",
            "a=rtcp-fb:106 transport-cc",
            "a=rtcp-fb:106 ccm fir",
            "a=rtcp-fb:106 nack",
            "a=rtcp-fb:106 nack pli",
            "a=fmtp:106 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640032",
            "a=rtpmap:107 rtx/90000",
            "a=fmtp:107 apt=106",
            "a=rtpmap:108 AV1/90000",
            "a=rtcp-fb:108 goog-remb",
            "a=rtcp-fb:108 transport-cc",
            "a=rtcp-fb:108 ccm fir",
            "a=rtcp-fb:108 nack",
            "a=rtcp-fb:108 nack pli",
            "a=fmtp:108 level-idx=5;profile=0;tier=0",
            "a=rtpmap:109 rtx/90000",
            "a=fmtp:109 apt=108",
            "a=rtpmap:114 red/90000",
            "a=rtpmap:115 rtx/90000",
            "a=fmtp:115 apt=114",
            "a=rtpmap:116 ulpfec/90000",
            "a=rtcp-fb:* transport-cc",
            "a=rid:q send pt=96;max-width=320;max-height=180;max-fps=15",
            "a=rid:h send pt=96;max-width=640;max-height=360;max-fps=30",
            "a=rid:f send pt=96;max-width=1280;max-height=720;max-fps=30",
            "a=simulcast:send q;h;f",
            f"a=ssrc-group:SIM {2000000 + m_idx * 100 + 1} {2000000 + m_idx * 100 + 3} {2000000 + m_idx * 100 + 5}",
            f"a=ssrc-group:FID {2000000 + m_idx * 100 + 1} {2000000 + m_idx * 100 + 2}",
            f"a=ssrc-group:FID {2000000 + m_idx * 100 + 3} {2000000 + m_idx * 100 + 4}",
            f"a=ssrc-group:FID {2000000 + m_idx * 100 + 5} {2000000 + m_idx * 100 + 6}",
        ])
        for s_off in range(1, 7):
            ssrc = 2000000 + m_idx * 100 + s_off
            lines.append(f"a=ssrc:{ssrc} cname:chrome-meet-local-cname")
            lines.append(f"a=ssrc:{ssrc} msid:meet-room-9876543210 {track_name}")

    # Media 3: DataChannel
    lines.extend([
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
        "c=IN IP4 0.0.0.0",
        "a=ice-ufrag:m9Xk2pQ1",
        "a=ice-pwd:V3ryS3cur3G00gl3M33tIc3P4ssw0rd2026",
        "a=setup:actpass",
        "a=mid:3",
        "a=sctp-port:5000",
        "a=max-message-size:262144",
    ])

    return "\r\n".join(lines) + "\r\n"


def build_meet_answer() -> str:
    # Realistic Google Meet SFU Answer SDP (ice-lite, active DTLS, 8 remote participant video m-lines)
    lines = [
        "v=0",
        "o=meet-sfu 8899112233445566 1 IN IP4 142.250.190.14",
        "s=-",
        "t=0 0",
        "a=group:BUNDLE 0 1 2 3 4 5 6 7 8 9",
        "a=ice-lite",
        "a=ice-options:trickle",
        "a=fingerprint:sha-256 12:34:56:78:9A:BC:DE:F0:12:34:56:78:9A:BC:DE:F0:12:34:56:78:9A:BC:DE:F0:12:34:56:78:9A:BC:DE:F0",
    ]
    lines.extend([
        "m=audio 19305 UDP/TLS/RTP/SAVPF 111 63 0",
        "c=IN IP4 142.250.190.14",
        "a=candidate:1001 1 udp 2130706431 142.250.190.14 19305 typ host generation 0",
        "a=candidate:1002 1 udp 2130706430 2001:4860:4864:5::14 19305 typ host generation 0",
        "a=ice-ufrag:sfuUfrag99",
        "a=ice-pwd:SfuIcePasswordForGoogleMeet2026XYZ",
        "a=setup:active",
        "a=mid:0",
        "a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level",
        "a=extmap:3 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01",
        "a=sendrecv",
        "a=rtcp-mux",
        "a=rtpmap:111 opus/48000/2",
        "a=fmtp:111 minptime=10;useinbandfec=1",
        "a=rtpmap:63 red/48000/2",
        "a=rtpmap:0 PCMU/8000",
    ])
    for idx in range(1, 9):
        lines.extend([
            "m=video 19305 UDP/TLS/RTP/SAVPF 96 97 98 99 102 103 108 109",
            "c=IN IP4 142.250.190.14",
            "a=ice-ufrag:sfuUfrag99",
            "a=ice-pwd:SfuIcePasswordForGoogleMeet2026XYZ",
            "a=setup:active",
            f"a=mid:{idx}",
            "a=extmap:2 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time",
            "a=extmap:3 urn:3gpp:video-orientation",
            "a=extmap:4 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01",
            "a=extmap:9 urn:ietf:params:rtp-hdrext:sdes:mid",
            "a=sendrecv" if idx <= 2 else "a=sendonly",
            f"a=msid:sfu-participant-{idx} video-track-{idx}",
            "a=rtcp-mux",
            "a=rtcp-rsize",
            "a=rtpmap:96 VP8/90000",
            "a=rtcp-fb:96 transport-cc",
            "a=rtcp-fb:96 nack",
            "a=rtcp-fb:96 nack pli",
            "a=rtpmap:97 rtx/90000",
            "a=fmtp:97 apt=96",
            "a=rtpmap:98 VP9/90000",
            "a=fmtp:98 profile-id=0",
            "a=rtpmap:99 rtx/90000",
            "a=fmtp:99 apt=98",
            "a=rtpmap:102 H264/90000",
            "a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
            "a=rtpmap:103 rtx/90000",
            "a=fmtp:103 apt=102",
            "a=rtpmap:108 AV1/90000",
            "a=rtpmap:109 rtx/90000",
            "a=fmtp:109 apt=108",
            f"a=ssrc-group:FID {3000000 + idx * 10} {3000000 + idx * 10 + 1}",
            f"a=ssrc:{3000000 + idx * 10} cname:sfu-p{idx}",
            f"a=ssrc:{3000000 + idx * 10 + 1} cname:sfu-p{idx}",
        ])
    lines.extend([
        "m=application 19305 UDP/DTLS/SCTP webrtc-datachannel",
        "c=IN IP4 142.250.190.14",
        "a=ice-ufrag:sfuUfrag99",
        "a=ice-pwd:SfuIcePasswordForGoogleMeet2026XYZ",
        "a=setup:active",
        "a=mid:9",
        "a=sctp-port:5000",
        "a=max-message-size:262144",
    ])
    return "\r\n".join(lines) + "\r\n"


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: gen_data.py <out_dir>", file=sys.stderr)
        return 1
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)
    offer = build_meet_offer()
    answer = build_meet_answer()
    with open(os.path.join(out_dir, "meet_offer.sdp"), "wb") as f:
        f.write(offer.encode("utf-8"))
    with open(os.path.join(out_dir, "meet_answer.sdp"), "wb") as f:
        f.write(answer.encode("utf-8"))
    print(f"Generated meet_offer.sdp ({len(offer)} B) and meet_answer.sdp ({len(answer)} B)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
