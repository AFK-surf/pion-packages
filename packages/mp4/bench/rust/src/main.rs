use std::env;
use std::fmt::Write as _;
use std::fs;
use std::io::{Cursor, Seek, SeekFrom};

use mp4::{BoxHeader, BoxType, MoofBox, Mp4Reader, ReadBox};

struct SampleRow {
    offset: u64,
    size: u32,
    dts: i64,
    pts: i64,
    duration: u32,
    is_sync: bool,
}

fn sample_flags_is_sync(flags: u32) -> bool {
    let non_sync = ((flags >> 16) & 1) != 0;
    let depends_on = (flags >> 24) & 3;
    !non_sync && depends_on != 1
}

fn extract_mp4_samples(data: &[u8]) -> Result<(u32, Vec<(u32, u32, Vec<SampleRow>)>), String> {
    let cursor = Cursor::new(data);
    let reader = Mp4Reader::read_header(cursor, data.len() as u64).map_err(|e| e.to_string())?;
    let mvhd_ts = reader.moov.mvhd.timescale;

    let mut tracks_out = Vec::with_capacity(reader.moov.traks.len());
    for trak in &reader.moov.traks {
        let tid = trak.tkhd.track_id;
        let ts = trak.mdia.mdhd.timescale;
        let stbl = &trak.mdia.minf.stbl;

        let sample_count = stbl.stsz.sample_count as usize;
        let const_sz = stbl.stsz.sample_size;

        // Chunk offsets (stco / co64)
        let chunk_offsets: Vec<u64> = if let Some(ref stco) = stbl.stco {
            stco.entries.iter().map(|&x| x as u64).collect()
        } else if let Some(ref co64) = stbl.co64 {
            co64.entries.clone()
        } else {
            Vec::new()
        };

        // Sync sample bitmap
        let has_stss = stbl.stss.is_some();
        let mut sync_flags = vec![!has_stss; sample_count];
        if let Some(ref stss) = stbl.stss {
            for &sn in &stss.entries {
                if sn >= 1 && (sn as usize) <= sample_count {
                    sync_flags[(sn - 1) as usize] = true;
                }
            }
        }

        let stts = &stbl.stts.entries;
        let ctts = stbl.ctts.as_ref().map(|c| (c.version, &c.entries));
        let stsc = &stbl.stsc.entries;

        let mut samples = Vec::with_capacity(sample_count);
        let mut stts_idx = 0usize;
        let mut stts_rem = stts.first().map(|e| e.sample_count).unwrap_or(0);
        let mut stts_delta = stts.first().map(|e| e.sample_delta).unwrap_or(0);

        let mut ctts_idx = 0usize;
        let mut ctts_rem = ctts.and_then(|(_, e)| e.first()).map(|e| e.sample_count).unwrap_or(0);
        let mut ctts_off: i64 = ctts
            .and_then(|(ver, e)| {
                e.first().map(|x| {
                    if ver == 0 {
                        x.sample_offset as u32 as i64
                    } else {
                        x.sample_offset as i64
                    }
                })
            })
            .unwrap_or(0);

        let mut stsc_idx = 0usize;
        let mut cur_chunk = 1u32;
        let mut chunk_rem = 0u32;
        let mut cur_offset = 0u64;
        let mut cur_dts = 0i64;

        for s in 0..sample_count {
            while chunk_rem == 0 {
                while stsc_idx + 1 < stsc.len() && stsc[stsc_idx + 1].first_chunk <= cur_chunk {
                    stsc_idx += 1;
                }
                chunk_rem = stsc[stsc_idx].samples_per_chunk;
                cur_offset = chunk_offsets[(cur_chunk - 1) as usize];
                cur_chunk += 1;
            }
            let sz = if const_sz > 0 {
                const_sz
            } else {
                stbl.stsz.sample_sizes[s]
            };
            while stts_rem == 0 && stts_idx + 1 < stts.len() {
                stts_idx += 1;
                stts_rem = stts[stts_idx].sample_count;
                stts_delta = stts[stts_idx].sample_delta;
            }
            let dur = if stts_rem > 0 {
                stts_rem -= 1;
                stts_delta
            } else {
                0
            };

            if let Some((ver, entries)) = ctts {
                while ctts_rem == 0 && ctts_idx + 1 < entries.len() {
                    ctts_idx += 1;
                    ctts_rem = entries[ctts_idx].sample_count;
                    ctts_off = if ver == 0 {
                        entries[ctts_idx].sample_offset as u32 as i64
                    } else {
                        entries[ctts_idx].sample_offset as i64
                    };
                }
            }
            let cto = if ctts_rem > 0 {
                ctts_rem -= 1;
                ctts_off
            } else {
                0
            };

            samples.push(SampleRow {
                offset: cur_offset,
                size: sz,
                dts: cur_dts,
                pts: cur_dts + cto,
                duration: dur,
                is_sync: sync_flags[s],
            });
            cur_offset += sz as u64;
            chunk_rem -= 1;
            cur_dts += dur as i64;
        }
        tracks_out.push((tid, ts, samples));
    }

    Ok((mvhd_ts, tracks_out))
}

struct FragRow {
    seq: u32,
    tid: u32,
    base_decode_time: i64,
    samples: Vec<SampleRow>,
}

fn parse_fmp4_pair(
    init_data: &[u8],
    media_data: &[u8],
) -> Result<(Vec<(u32, u32)>, Vec<FragRow>), String> {
    let init_cur = Cursor::new(init_data);
    let init_reader =
        Mp4Reader::read_header(init_cur, init_data.len() as u64).map_err(|e| e.to_string())?;
    let tracks: Vec<(u32, u32)> = init_reader
        .moov
        .traks
        .iter()
        .map(|t| (t.tkhd.track_id, t.mdia.mdhd.timescale))
        .collect();
    let trexs = init_reader
        .moov
        .mvex
        .as_ref()
        .map(|m| vec![m.trex.clone()])
        .unwrap_or_default();

    let mut cur = Cursor::new(media_data);
    let end = media_data.len() as u64;
    let mut frags = Vec::new();

    while cur.position() < end {
        let box_start = cur.position();
        let hdr = BoxHeader::read(&mut cur).map_err(|e| e.to_string())?;
        let box_size = if hdr.size == 0 {
            end - box_start
        } else {
            hdr.size
        };
        if hdr.name == BoxType::MoofBox {
            let moof = MoofBox::read_box(&mut cur, box_size).map_err(|e| e.to_string())?;
            let seq = moof.mfhd.sequence_number;
            let mut has_prev_traf = false;
            let mut prev_traf_end = box_start;

            for traf in &moof.trafs {
                let tfhd = &traf.tfhd;
                let tid = tfhd.track_id;
                let trex = trexs.iter().find(|t| t.track_id == tid);

                let def_dur = tfhd
                    .default_sample_duration
                    .or_else(|| trex.map(|t| t.default_sample_duration))
                    .unwrap_or(0);
                let def_size = tfhd
                    .default_sample_size
                    .or_else(|| trex.map(|t| t.default_sample_size))
                    .unwrap_or(0);
                let def_flags = tfhd
                    .default_sample_flags
                    .or_else(|| trex.map(|t| t.default_sample_flags))
                    .unwrap_or(0);

                let default_base_is_moof = (tfhd.flags & 0x020000) != 0;
                let base_offset = if let Some(bdo) = tfhd.base_data_offset {
                    bdo
                } else if default_base_is_moof || !has_prev_traf {
                    box_start
                } else {
                    prev_traf_end
                };

                let base_decode_time = traf
                    .tfdt
                    .as_ref()
                    .map(|t| t.base_media_decode_time as i64)
                    .unwrap_or(0);

                let mut cur_dts = base_decode_time;
                let mut running_offset = base_offset;
                let mut samples = Vec::new();

                if let Some(ref trun) = traf.trun {
                    if let Some(doff) = trun.data_offset {
                        running_offset = (base_offset as i64 + doff as i64) as u64;
                    }
                    let has_first_flags = (trun.flags & 0x000004) != 0;
                    let first_flags = trun.first_sample_flags.unwrap_or(def_flags);
                    let sc = trun.sample_count as usize;
                    for si in 0..sc {
                        let dur = trun.sample_durations.get(si).copied().unwrap_or(def_dur);
                        let sz = trun.sample_sizes.get(si).copied().unwrap_or(def_size);
                        let sflags = if let Some(&fl) = trun.sample_flags.get(si) {
                            fl
                        } else if si == 0 && has_first_flags {
                            first_flags
                        } else {
                            def_flags
                        };
                        let cto: i64 = if let Some(&raw_cto) = trun.sample_cts.get(si) {
                            if trun.version == 0 {
                                raw_cto as i64
                            } else {
                                (raw_cto as i32) as i64
                            }
                        } else {
                            0
                        };
                        samples.push(SampleRow {
                            offset: running_offset,
                            size: sz,
                            dts: cur_dts,
                            pts: cur_dts + cto,
                            duration: dur,
                            is_sync: sample_flags_is_sync(sflags),
                        });
                        running_offset += sz as u64;
                        cur_dts += dur as i64;
                    }
                }
                has_prev_traf = true;
                prev_traf_end = running_offset;
                frags.push(FragRow {
                    seq,
                    tid,
                    base_decode_time,
                    samples,
                });
            }
        }
        cur.seek(SeekFrom::Start(box_start + box_size))
            .map_err(|e| e.to_string())?;
    }
    Ok((tracks, frags))
}

fn format_samples(out: &mut String, samples: &[SampleRow]) {
    for (i, s) in samples.iter().enumerate() {
        let _ = writeln!(
            out,
            "s {} off={} sz={} dts={} pts={} dur={} sync={}",
            i,
            s.offset,
            s.size,
            s.dts,
            s.pts,
            s.duration,
            if s.is_sync { 1 } else { 0 }
        );
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: mp4-bench-rust <mp4|fmp4> ...");
        std::process::exit(1);
    }
    match args[1].as_str() {
        "mp4" => {
            let data = fs::read(&args[2]).expect("read mp4");
            let iters: usize = args[3].parse().expect("iters");
            let mut total_samples: i64 = 0;
            let mut last = None;
            for r in 0..iters {
                let res = extract_mp4_samples(&data).expect("parse mp4");
                for (_, _, s) in &res.1 {
                    total_samples += s.len() as i64;
                }
                if r == iters - 1 {
                    last = Some(res);
                }
            }
            let (mvhd_ts, tracks) = last.unwrap();
            let mut out = String::with_capacity(65536);
            let _ = writeln!(
                out,
                "mode=mp4 iters={} total_samples={} mvhd_ts={} tracks={}",
                iters,
                total_samples,
                mvhd_ts,
                tracks.len()
            );
            for (tid, ts, samples) in &tracks {
                let _ = writeln!(out, "track id={} ts={} samples={}", tid, ts, samples.len());
                format_samples(&mut out, samples);
            }
            print!("{}", out);
        }
        "fmp4" => {
            if args.len() < 5 {
                eprintln!("usage: mp4-bench-rust fmp4 <init> <media> <iters>");
                std::process::exit(1);
            }
            let init_data = fs::read(&args[2]).expect("read init");
            let media_data = fs::read(&args[3]).expect("read media");
            let iters: usize = args[4].parse().expect("iters");
            let mut total_samples: i64 = 0;
            let mut last = None;
            for r in 0..iters {
                let res = parse_fmp4_pair(&init_data, &media_data).expect("parse fmp4");
                for f in &res.1 {
                    total_samples += f.samples.len() as i64;
                }
                if r == iters - 1 {
                    last = Some(res);
                }
            }
            let (tracks, frags) = last.unwrap();
            let mut out = String::with_capacity(65536);
            let _ = writeln!(
                out,
                "mode=fmp4 iters={} total_samples={} tracks={} frags={}",
                iters,
                total_samples,
                tracks.len(),
                frags.len()
            );
            for (tid, ts) in &tracks {
                let _ = writeln!(out, "track id={} ts={}", tid, ts);
            }
            for f in &frags {
                let _ = writeln!(
                    out,
                    "frag seq={} tid={} base={} samples={}",
                    f.seq,
                    f.tid,
                    f.base_decode_time,
                    f.samples.len()
                );
                format_samples(&mut out, &f.samples);
            }
            print!("{}", out);
        }
        other => {
            eprintln!("unknown mode: {}", other);
            std::process::exit(1);
        }
    }
}
