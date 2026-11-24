#!/usr/bin/env python3
"""Deterministic synthetic MPEG-DASH .mpd corpus generator for differential parity
against Rust `dash-mpd` and head-to-head benchmarking.

Generates 60 diverse, valid ISO/IEC 23009-1 MPD manifests separated by `===MPD===\\n`
into `<out_dir>/mpd_corpus.txt`. Zero third-party copyrighted media files.
"""

import os
import sys


def make_static_segment_base(idx: int) -> str:
    dur_s = 60 + idx * 17
    bw_low = 450000 + idx * 10000
    bw_hd = 2800000 + idx * 50000
    bw_4k = 8500000 + idx * 100000
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" id="vod-sb-{idx}" type="static" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011" mediaPresentationDuration="PT{dur_s}.5S" minBufferTime="PT2S">
  <BaseURL>https://cdn.example.com/vod/clip-{idx}/</BaseURL>
  <Period id="p0" start="PT0S">
    <AdaptationSet id="1" contentType="video" mimeType="video/mp4" segmentAlignment="true" par="16:9" minWidth="640" maxWidth="3840" minHeight="360" maxHeight="2160">
      <Role schemeIdUri="urn:mpeg:dash:role:2011" value="main"/>
      <Representation id="v360" bandwidth="{bw_low}" width="640" height="360" frameRate="30" sar="1:1" codecs="avc1.4d401e" startWithSAP="1">
        <BaseURL>v360.mp4</BaseURL>
        <SegmentBase timescale="30000" indexRange="680-1199" indexRangeExact="true">
          <Initialization range="0-679"/>
        </SegmentBase>
      </Representation>
      <Representation id="v1080" bandwidth="{bw_hd}" width="1920" height="1080" frameRate="30000/1001" sar="1:1" codecs="avc1.640028" startWithSAP="1">
        <BaseURL>v1080.mp4</BaseURL>
        <SegmentBase timescale="30000" indexRange="712-1450" indexRangeExact="true">
          <Initialization range="0-711"/>
        </SegmentBase>
      </Representation>
      <Representation id="v2160" bandwidth="{bw_4k}" width="3840" height="2160" frameRate="60" sar="1:1" codecs="av01.0.12M.08" startWithSAP="1">
        <BaseURL>v2160.mp4</BaseURL>
        <SegmentBase timescale="60000" indexRange="820-1890" indexRangeExact="true">
          <Initialization range="0-819"/>
        </SegmentBase>
      </Representation>
    </AdaptationSet>
    <AdaptationSet id="2" contentType="audio" mimeType="audio/mp4" lang="en" segmentAlignment="true">
      <AudioChannelConfiguration schemeIdUri="urn:mpeg:dash:23003:3:audio_channel_configuration:2011" value="2"/>
      <Representation id="a128" bandwidth="128000" codecs="mp4a.40.2" audioSamplingRate="48000" startWithSAP="1">
        <BaseURL>audio_en.m4a</BaseURL>
        <SegmentBase timescale="48000" indexRange="600-980">
          <Initialization range="0-599"/>
        </SegmentBase>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>"""


def make_dynamic_timeline(idx: int) -> str:
    t0 = 1000000 + idx * 96000
    r_cnt = 3 + (idx % 6)
    day = 1 + (idx % 28)
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" id="live-tl-{idx}" type="dynamic" profiles="urn:mpeg:dash:profile:isoff-live:2011" availabilityStartTime="2026-03-{day:02d}T00:00:00Z" publishTime="2026-03-{day:02d}T02:15:30Z" minimumUpdatePeriod="PT4S" timeShiftBufferDepth="PT120S" suggestedPresentationDelay="PT12S" maxSegmentDuration="PT4S" minBufferTime="PT2S">
  <Location>https://live.example.com/ch{idx}/manifest.mpd</Location>
  <UTCTiming schemeIdUri="urn:mpeg:dash:utc:http-iso:2014" value="https://time.example.com/iso"/>
  <BaseURL>https://live-cdn.example.com/ch{idx}/</BaseURL>
  <Period id="p-{idx}" start="PT0S">
    <AdaptationSet id="10" contentType="video" mimeType="video/mp4" segmentAlignment="true" bitstreamSwitching="true">
      <SegmentTemplate timescale="90000" startNumber="100" initialization="v_$RepresentationID$_init.m4s" media="v_$RepresentationID$_$Time$.m4s">
        <SegmentTimeline>
          <S t="{t0}" d="180000" r="{r_cnt}"/>
          <S d="180000" r="1"/>
          <S d="90000"/>
        </SegmentTimeline>
      </SegmentTemplate>
      <Representation id="hd720" bandwidth="2200000" width="1280" height="720" frameRate="30" codecs="avc1.64001f"/>
      <Representation id="hd1080" bandwidth="5000000" width="1920" height="1080" frameRate="60" codecs="avc1.64002a"/>
    </AdaptationSet>
    <AdaptationSet id="20" contentType="audio" mimeType="audio/mp4" lang="ja">
      <AudioChannelConfiguration schemeIdUri="urn:mpeg:dash:23003:3:audio_channel_configuration:2011" value="2"/>
      <SegmentTemplate timescale="48000" startNumber="100" initialization="a_$RepresentationID$_init.m4s" media="a_$RepresentationID$_$Number%05d$.m4s">
        <SegmentTimeline>
          <S t="480000" d="96000" r="{r_cnt + 2}"/>
        </SegmentTimeline>
      </SegmentTemplate>
      <Representation id="a192" bandwidth="192000" codecs="mp4a.40.2" audioSamplingRate="48000"/>
    </AdaptationSet>
  </Period>
</MPD>"""


def make_drm_multi_period(idx: int) -> str:
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" xmlns:cenc="urn:mpeg:cenc:2013" id="drm-mp-{idx}" type="static" profiles="urn:mpeg:dash:profile:isoff-live:2011" mediaPresentationDuration="PT3M20S" minBufferTime="PT4S">
  <BaseURL>https://drm-cdn.example.com/asset-{idx}/</BaseURL>
  <Period id="intro" start="PT0S" duration="PT20S">
    <AdaptationSet id="1" contentType="video" mimeType="video/mp4" segmentAlignment="true">
      <ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011" value="cenc" cenc:default_KID="01020304-0506-0708-090a-0b0c0d0e0f{idx:02x}"/>
      <ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed" value="Widevine">
        <cenc:pssh>AAAAW3Bzc2gAAAAA7e+LqXnWSs6jyCfc1R0h7QAAADsIARIQ</cenc:pssh>
      </ContentProtection>
      <ContentProtection schemeIdUri="urn:uuid:9a04f079-9840-4286-ab92-e65be0885f95" value="PlayReady">
        <cenc:pssh>AAACBnBzc2gAAAAAmgTweZhAQoarkuZb4IhflQ==</cenc:pssh>
      </ContentProtection>
      <SegmentTemplate timescale="1000" duration="4000" startNumber="1" initialization="$RepresentationID$/init.mp4" media="$RepresentationID$/seg_$Number%04d$.m4s"/>
      <Representation id="v720" bandwidth="2400000" width="1280" height="720" frameRate="24000/1001" codecs="avc1.64001f"/>
      <Representation id="v1080" bandwidth="4800000" width="1920" height="1080" frameRate="24000/1001" codecs="avc1.640028"/>
    </AdaptationSet>
  </Period>
  <Period id="main" start="PT20S" duration="PT3M">
    <AdaptationSet id="2" contentType="video" mimeType="video/mp4" segmentAlignment="true">
      <Role schemeIdUri="urn:mpeg:dash:role:2011" value="main"/>
      <SupplementalProperty schemeIdUri="urn:mpeg:dash:srd:2014" value="0,0,0,1920,1080"/>
      <EssentialProperty schemeIdUri="urn:mpeg:mpegB:cicp:TransferCharacteristics" value="16"/>
      <SegmentTemplate timescale="1000" startNumber="1" initialization="main/$RepresentationID$/init.mp4" media="main/$RepresentationID$/chunk_$Number$.m4s">
        <SegmentTimeline>
          <S t="0" d="6000" r="29"/>
        </SegmentTimeline>
      </SegmentTemplate>
      <Representation id="hdr1080" bandwidth="6000000" width="1920" height="1080" frameRate="24" codecs="hev1.2.4.L120.90"/>
    </AdaptationSet>
    <AdaptationSet id="3" contentType="text" mimeType="text/vtt" lang="en">
      <Role schemeIdUri="urn:mpeg:dash:role:2011" value="subtitle"/>
      <Accessibility schemeIdUri="urn:tva:metadata:cs:AudioPurposeCS:2007" value="2"/>
      <Representation id="sub_en" bandwidth="1200">
        <BaseURL>subs/en.vtt</BaseURL>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>"""


def make_segment_list(idx: int) -> str:
    segs = "\n".join(
        f'          <SegmentURL media="seg_{k}.m4s" mediaRange="{k * 1024}-{(k + 1) * 1024 - 1}"/>'
        for k in range(1, 7 + (idx % 4))
    )
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" id="sl-{idx}" type="static" profiles="urn:mpeg:dash:profile:isoff-main:2011" mediaPresentationDuration="PT36S" minBufferTime="PT2S">
  <BaseURL>https://cdn.example.com/list-{idx}/</BaseURL>
  <Period id="p0" start="PT0S">
    <AdaptationSet id="1" contentType="video" mimeType="video/mp4">
      <Representation id="v1" bandwidth="{1500000 + idx * 25000}" width="1280" height="720" codecs="avc1.64001f">
        <SegmentList timescale="1000" duration="4000" startNumber="1">
          <Initialization sourceURL="init.mp4" range="0-1023"/>
{segs}
        </SegmentList>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>"""


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: gen_data.py <out_dir>", file=sys.stderr)
        return 1
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)

    manifests = []
    for i in range(15):
        manifests.append(make_static_segment_base(i))
    for i in range(15):
        manifests.append(make_dynamic_timeline(i))
    for i in range(15):
        manifests.append(make_drm_multi_period(i))
    for i in range(15):
        manifests.append(make_segment_list(i))

    corpus_path = os.path.join(out_dir, "mpd_corpus.txt")
    with open(corpus_path, "w", encoding="utf-8") as f:
        f.write("\n===MPD===\n".join(manifests) + "\n")
    print(f"Generated {len(manifests)} MPD manifests -> {corpus_path} ({os.path.getsize(corpus_path)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
