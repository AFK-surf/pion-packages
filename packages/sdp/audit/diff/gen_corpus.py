#!/usr/bin/env python3
"""Named differential corpus for packages/sdp: writes `name<TAB>hex` lines.

Real-browser shaped offers/answers (Chrome / Google Meet, Firefox, Safari) plus targeted
adversarial variants. Every case is self-contained bytes; nothing is fetched.
"""
import sys

H = "v=0\r\no=- 4611731400430051336 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n"

CHROME = (
    H
    + "a=group:BUNDLE 0 1 2\r\na=extmap-allow-mixed\r\na=msid-semantic: WMS stream1\r\n"
    "m=audio 9 UDP/TLS/RTP/SAVPF 111 63 9 0 8 13 110 126\r\nc=IN IP4 0.0.0.0\r\n"
    "a=rtcp:9 IN IP4 0.0.0.0\r\n"
    "a=candidate:1467250027 1 udp 2122260223 192.168.1.10 54321 typ host generation 0 network-id 1 network-cost 10\r\n"
    "a=candidate:842163049 1 udp 1677729535 203.0.113.5 60001 typ srflx raddr 192.168.1.10 rport 54321 generation 0 network-id 1\r\n"
    "a=candidate:3 1 udp 2122194687 4a1b2c3d-0000-4000-8000-123456789abc.local 50000 typ host generation 0\r\n"
    "a=candidate:4 1 tcp 1518280447 2001:db8::1 9 typ host tcptype active generation 0 network-id 2\r\n"
    "a=ice-ufrag:Ab3d\r\na=ice-pwd:0123456789abcdefghijklmn\r\na=ice-options:trickle\r\n"
    "a=fingerprint:sha-256 AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99\r\n"
    "a=setup:actpass\r\na=mid:0\r\na=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level\r\n"
    "a=sendrecv\r\na=msid:stream1 track-a\r\na=rtcp-mux\r\na=rtpmap:111 opus/48000/2\r\n"
    "a=rtcp-fb:111 transport-cc\r\na=fmtp:111 minptime=10;useinbandfec=1\r\n"
    "a=rtpmap:63 red/48000/2\r\na=fmtp:63 111/111\r\na=rtpmap:9 G722/8000\r\na=rtpmap:0 PCMU/8000\r\n"
    "a=rtpmap:8 PCMA/8000\r\na=rtpmap:13 CN/8000\r\na=rtpmap:110 telephone-event/48000\r\n"
    "a=rtpmap:126 telephone-event/8000\r\na=ssrc:1001 cname:abcdEFGH\r\n"
    "m=video 9 UDP/TLS/RTP/SAVPF 96 97\r\nc=IN IP4 0.0.0.0\r\nb=AS:1500\r\nb=TIAS:2000000\r\n"
    "a=ice-ufrag:Ab3d\r\na=ice-pwd:0123456789abcdefghijklmn\r\n"
    "a=fingerprint:sha-256 aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99\r\n"
    "a=setup:actpass\r\na=mid:1\r\na=extmap:14 urn:ietf:params:rtp-hdrext:toffset\r\n"
    "a=extmap:3/sendonly urn:3gpp:video-orientation\r\na=sendonly\r\na=msid:stream1 track-v\r\n"
    "a=rtcp-mux\r\na=rtcp-rsize\r\na=rtpmap:96 VP8/90000\r\na=rtcp-fb:96 nack pli\r\n"
    "a=rtcp-fb:* transport-cc\r\na=rtpmap:97 rtx/90000\r\na=fmtp:97 apt=96\r\n"
    "a=rid:h send pt=96;max-width=1280\r\na=rid:q send\r\na=rid:f send\r\na=simulcast:send h;q;f\r\n"
    "a=ssrc-group:FID 2001 2002\r\na=ssrc:2001 cname:abcdEFGH\r\na=ssrc:2002 cname:abcdEFGH\r\n"
    "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\nc=IN IP6 ::1\r\na=ice-ufrag:Ab3d\r\n"
    "a=ice-pwd:0123456789abcdefghijklmn\r\na=setup:actpass\r\na=mid:2\r\na=sctp-port:5000\r\n"
    "a=max-message-size:262144\r\n"
)

FIREFOX = (
    "v=0\r\no=mozilla...THIS_IS_SDPARTA-99.0 7051458624451127011 0 IN IP4 0.0.0.0\r\ns=-\r\nt=0 0\r\n"
    "a=fingerprint:sha-256 6C:3F:0C:40:E8:6B:7A:2B:6E:8B:3B:6E:4B:6B:6E:8B:3B:6E:4B:6B:6E:8B:3B:6E:4B:6B:6E:8B:3B:6E:4B:6B\r\n"
    "a=group:BUNDLE 0 1\r\na=ice-options:trickle\r\na=msid-semantic:WMS *\r\n"
    "m=audio 9 UDP/TLS/RTP/SAVPF 109 9 0 8 101\r\nc=IN IP4 0.0.0.0\r\n"
    "a=candidate:0 1 UDP 2122252543 192.0.2.1 49170 typ host\r\n"
    "a=candidate:1 1 TCP 2105524479 192.0.2.1 9 typ host tcptype active\r\na=sendrecv\r\n"
    "a=end-of-candidates\r\na=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level\r\n"
    "a=extmap:2/recvonly urn:ietf:params:rtp-hdrext:csrc-audio-level\r\n"
    "a=fmtp:109 maxplaybackrate=48000;stereo=1;useinbandfec=1\r\na=fmtp:101 0-15\r\n"
    "a=ice-pwd:b9e1a2c3d4e5f60718293a4b5c6d7e8f\r\na=ice-ufrag:5a1b2c3d\r\na=mid:0\r\n"
    "a=msid:{7a1b} {8c2d}\r\na=rtcp-mux\r\na=rtpmap:109 opus/48000/2\r\na=rtpmap:9 G722/8000/1\r\n"
    "a=rtpmap:0 PCMU/8000\r\na=rtpmap:8 PCMA/8000\r\na=rtpmap:101 telephone-event/8000/1\r\n"
    "a=setup:actpass\r\na=ssrc:3735928559 cname:{0f1e2d3c}\r\n"
    "m=video 9 UDP/TLS/RTP/SAVPF 120 124 121\r\nc=IN IP4 0.0.0.0\r\nb=TIAS:2000000\r\n"
    "a=sendonly\r\na=extmap:3 urn:ietf:params:rtp-hdrext:sdes:mid\r\na=fmtp:120 max-fs=12288;max-fr=60\r\n"
    "a=fmtp:124 apt=120\r\na=ice-pwd:b9e1a2c3d4e5f60718293a4b5c6d7e8f\r\na=ice-ufrag:5a1b2c3d\r\na=mid:1\r\n"
    "a=rid:a send\r\na=rid:b send\r\na=rid:c send\r\na=simulcast:send a;b;c\r\n"
    "a=rtcp-fb:120 nack\r\na=rtcp-fb:120 nack pli\r\na=rtcp-fb:120 ccm fir\r\na=rtcp-fb:120 goog-remb\r\n"
    "a=rtcp-mux\r\na=rtcp-rsize\r\na=rtpmap:120 VP8/90000\r\na=rtpmap:124 rtx/90000\r\na=rtpmap:121 VP9/90000\r\n"
    "a=setup:actpass\r\na=ssrc:1 cname:{0f1e2d3c}\r\n"
)

SAFARI = (
    "v=0\r\no=- 1234 1 IN IP6 ::1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE a v\r\n"
    "a=fingerprint:sha-1 01:02:03:04:05:06:07:08:09:0A:0B:0C:0D:0E:0F:10:11:12:13:14\r\n"
    "m=audio 0 UDP/TLS/RTP/SAVPF 0\r\nc=IN IP6 2001:db8::2\r\na=inactive\r\na=mid:a\r\n"
    "a=rtpmap:0 PCMU/8000\r\na=setup:passive\r\na=ice-ufrag:sfri\r\na=ice-pwd:0123456789abcdefghijklmn\r\n"
    "m=video 9 UDP/TLS/RTP/SAVPF 96\r\nc=IN IP4 0.0.0.0\r\na=recvonly\r\na=mid:v\r\na=rtpmap:96 H264/90000\r\n"
    "a=rid:h recv\r\na=rid:l recv\r\na=simulcast:recv h;~l\r\na=setup:active\r\n"
    "a=ice-ufrag:sfri\r\na=ice-pwd:0123456789abcdefghijklmn\r\n"
)

VID = "m=video 9 UDP/TLS/RTP/SAVPF 96\r\nc=IN IP4 0.0.0.0\r\na=mid:0\r\na=rtpmap:96 VP8/90000\r\n"


def v(extra_media="", sess=""):
    return H + sess + VID + extra_media


CASES = [
    ("browser_chrome_meet_offer", CHROME),
    ("browser_chrome_lf_only", CHROME.replace("\r\n", "\n")),
    ("browser_firefox_offer", FIREFOX),
    ("browser_safari_answer_simulcast_paused", SAFARI),
    # --- simulcast RFC 8853
    ("sim_alternatives_comma", v("a=rid:1 send\r\na=rid:2 send\r\na=rid:3 send\r\na=simulcast:send 1,2;3\r\n")),
    ("sim_paused_tilde", v("a=rid:h send\r\na=rid:q send\r\na=simulcast:send h;~q\r\n")),
    ("sim_send_and_recv", v("a=rid:h send\r\na=rid:r recv\r\na=simulcast:send h recv r\r\n")),
    ("sim_duplicate_send_dir", v("a=simulcast:send a send b\r\n")),
    ("sim_empty_list", v("a=simulcast:send ;;\r\n")),
    # --- extmap ids (RFC 8285)
    ("extmap_id_0", v("a=extmap:0 urn:x\r\n")),
    ("extmap_id_14", v("a=extmap:14 urn:x\r\n")),
    ("extmap_id_15", v("a=extmap:15 urn:x\r\n")),
    ("extmap_id_255", v("a=extmap:255 urn:x\r\n")),
    ("extmap_id_256", v("a=extmap:256 urn:x\r\n")),
    ("extmap_id_4095", v("a=extmap:4095 urn:x\r\n")),
    ("extmap_id_4096", v("a=extmap:4096 urn:x\r\n")),
    ("extmap_id_65536", v("a=extmap:65536 urn:x\r\n")),
    # --- fingerprint
    ("fp_malformed_media_session_fallback",
     v("a=fingerprint:sha-256\r\n", "a=fingerprint:sha-256 AA:BB\r\n")),
    ("fp_non_hex", v("a=fingerprint:sha-256 zz:zz\r\n")),
    ("fp_wrong_length_sha256", v("a=fingerprint:sha-256 AA:BB\r\n")),
    ("fp_two_algorithms", v("a=fingerprint:sha-1 01:02:03:04:05:06:07:08:09:0A:0B:0C:0D:0E:0F:10:11:12:13:14\r\n"
                            "a=fingerprint:sha-256 AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99\r\n")),
    # --- ICE candidates
    ("cand_priority_u32_max", v("a=candidate:1 1 udp 4294967295 1.2.3.4 1 typ host\r\n")),
    ("cand_priority_u32_overflow", v("a=candidate:1 1 udp 4294967296 1.2.3.4 1 typ host\r\n")),
    ("cand_port_65536", v("a=candidate:1 1 udp 1 1.2.3.4 65536 typ host\r\n")),
    ("cand_component_0", v("a=candidate:1 0 udp 1 1.2.3.4 1 typ host\r\n")),
    ("cand_ipv6_mdns_ext", v("a=candidate:1 1 udp 1 abcd.local 9 typ host generation 0 network-id 3 network-cost 999 foo bar\r\n")),
    ("cand_odd_extension", v("a=candidate:1 1 udp 1 1.2.3.4 9 typ host foo\r\n")),
    ("cand_double_prefix", v("a=candidate:candidate:1 1 udp 1 1.2.3.4 9 typ host\r\n")),
    ("cand_on_rejected_mline_breaks_summary",
     v("m=audio 0 UDP/TLS/RTP/SAVPF 0\r\na=mid:1\r\na=candidate:garbage\r\n")),
    # --- payload types / numbers
    ("rtpmap_pt_128", v("a=rtpmap:128 X/90000\r\n")),
    ("rtpmap_no_clock", v("a=rtpmap:96 VP8\r\n")),
    ("ssrc_u32_overflow", v("a=ssrc:4294967296 cname:x\r\n")),
    ("m_port_65536", H + "m=video 65536 RTP/AVP 0\r\n"),
    ("m_port_huge", H + "m=video 99999999999999999999 RTP/AVP 0\r\n"),
    ("m_port_count_0", H + "m=video 49170/0 RTP/AVP 0\r\n"),
    ("m_port_count_2", H + "m=video 49170/2 RTP/AVP 0\r\n"),
    ("m_port_plus_count_overflow", H + "m=video 65535/2 RTP/AVP 0\r\n"),
    ("m_no_formats", H + "m=video 9 RTP/AVP\r\n"),
    ("b_huge", H + "b=AS:99999999999999999999\r\n"),
    ("max_message_size_overflow", H + "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=max-message-size:99999999999999999999\r\n"),
    ("sctp_port_65536", H + "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=sctp-port:65536\r\n"),
    ("legacy_sctpmap", H + "m=application 9 DTLS/SCTP 5000\r\na=sctpmap:5000 webrtc-datachannel 1024\r\n"),
    # --- line structure
    ("dup_v", "v=0\r\nv=0\r\no=- 1 1 IN IP4 x\r\ns=-\r\nt=0 0\r\n"),
    ("v_1", "v=1\r\no=- 1 1 IN IP4 x\r\ns=-\r\nt=0 0\r\n"),
    ("o_5_fields", "v=0\r\no=- 1 1 IN IP4\r\ns=-\r\nt=0 0\r\n"),
    ("o_negative_sid", "v=0\r\no=- -1 1 IN IP4 x\r\ns=-\r\nt=0 0\r\n"),
    ("dup_s", H + "s=again\r\n"),
    ("dup_i_session", H.replace("t=0 0", "i=one\r\ni=two\r\nt=0 0")),
    ("order_t_before_o", "v=0\r\nt=0 0\r\no=- 1 1 IN IP4 x\r\ns=-\r\n"),
    ("order_a_before_s", "v=0\r\no=- 1 1 IN IP4 x\r\na=x\r\ns=-\r\nt=0 0\r\n"),
    ("t_in_media", v("t=0 0\r\n")),
    ("o_in_media", v("o=- 1 1 IN IP4 x\r\n")),
    ("unknown_type_x", H + "x=1\r\n"),
    ("uppercase_type_A", H + "A=1\r\n"),
    ("rzk_dropped", H.replace("t=0 0\r\n", "t=2873397496 2873404696\r\nr=7d 1h 0 25h\r\nz=2882844526 -1h\r\nk=clear:secret\r\n")),
    ("e_p_dropped", H.replace("t=0 0", "e=a@b.example\r\np=+1 617 555-6011\r\nt=0 0")),
    ("e_in_media", v("e=a@b\r\n")),
    ("no_c_anywhere", H + "m=audio 9 RTP/AVP 0\r\n"),
    ("two_c_in_media", H + "m=video 9 RTP/AVP 0\r\nc=IN IP4 224.2.1.1/127\r\nc=IN IP4 224.2.1.2/127\r\n"),
    ("t_start_gt_stop", "v=0\r\no=- 1 1 IN IP4 x\r\ns=-\r\nt=10 5\r\n"),
    ("trailing_blank_line", H + "\r\n"),
    ("trailing_space_line", H.replace("s=-", "s=- ")),
    ("tab_in_session_name", H.replace("s=-", "s=a\tb")),
    ("tab_in_attr_value", H + "a=x:a\tb\r\n"),
    ("del_in_i", H.replace("t=0 0", "i=a\x7fb\r\nt=0 0")),
    ("utf8_in_s", H.replace("s=-", "s=caf\u00e9 \u4f1a\u8bae")),
    ("latin1_byte_in_s", None),  # filled below with raw 0xE9
    ("nul_in_attr", H + "a=x:\x00\r\n"),
    ("bare_cr", H + "a=x\ra=y\r\n"),
    ("multi_space_m", H + "m=video  9 RTP/AVP 0\r\n"),
    ("a_empty", H + "a=\r\n"),
    ("a_colon_only_name", H + "a=:x\r\n"),
    ("a_property_with_space", H + "a=x y\r\n"),
    ("group_bundle_empty", H.replace("t=0 0\r\n", "t=0 0\r\na=group:BUNDLE\r\n") + VID),
    ("group_bundle_dup_mids", H.replace("t=0 0\r\n", "t=0 0\r\na=group:BUNDLE 0 0 9\r\n") + VID),
    ("setup_uppercase", v("a=setup:ACTPASS\r\n")),
    ("direction_conflict", v("a=sendonly\r\na=recvonly\r\n")),
    ("mid_duplicate_across_media", H + VID + VID),
]


def main():
    out = open(sys.argv[1], "w")
    for name, text in CASES:
        if text is None:
            data = (H.replace("s=-", "s=caf")).encode() + b""
            data = data.replace(b"s=caf", b"s=caf\xe9")
        else:
            data = text.encode("utf-8")
        out.write(name + "\t" + data.hex() + "\n")
    out.close()
    print(f"{len(CASES)} cases -> {sys.argv[1]}")


if __name__ == "__main__":
    main()
