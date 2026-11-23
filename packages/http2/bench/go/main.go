package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"io"
	"os"

	"golang.org/x/net/http2"
	"golang.org/x/net/http2/hpack"
)

func mix(h, v int64) int64 {
	return ((h * 131) + v) % 1000000007
}

func hashBytes(h int64, b []byte) int64 {
	h = mix(h, int64(len(b)))
	for _, c := range b {
		h = mix(h, int64(c))
	}
	return h
}

func hashHeaders(h int64, hs []hpack.HeaderField) int64 {
	h = mix(h, int64(len(hs)))
	for _, f := range hs {
		h = hashBytes(h, []byte(f.Name))
		h = hashBytes(h, []byte(f.Value))
	}
	return h
}

func benchHpackDecode(data []byte) {
	count := int(binary.BigEndian.Uint32(data[0:4]))
	blocks := make([][]byte, count)
	pos := 4
	for i := 0; i < count; i++ {
		blen := int(binary.BigEndian.Uint32(data[pos : pos+4]))
		pos += 4
		blocks[i] = data[pos : pos+blen]
		pos += blen
	}

	var totalBlocks, totalHeaders, checksum int64
	for round := 0; round < 100; round++ {
		dec := hpack.NewDecoder(4096, nil)
		for bi := 0; bi < count; bi++ {
			hs, err := dec.DecodeFull(blocks[bi])
			if err != nil {
				fmt.Fprintf(os.Stderr, "decode error: %v\n", err)
				os.Exit(1)
			}
			totalBlocks++
			totalHeaders += int64(len(hs))
			checksum = hashHeaders(checksum, hs)
		}
	}

	fmt.Println("mode=hpack_decode")
	fmt.Printf("blocks=%d\n", totalBlocks)
	fmt.Printf("headers=%d\n", totalHeaders)
	fmt.Printf("checksum=%d\n", checksum)
}

func benchHpackEncode(data []byte) {
	count := int(binary.BigEndian.Uint32(data[0:4]))
	lists := make([][]hpack.HeaderField, count)
	pos := 4
	for i := 0; i < count; i++ {
		hcount := int(binary.BigEndian.Uint16(data[pos : pos+2]))
		pos += 2
		hs := make([]hpack.HeaderField, hcount)
		for j := 0; j < hcount; j++ {
			nlen := int(binary.BigEndian.Uint16(data[pos : pos+2]))
			pos += 2
			name := string(data[pos : pos+nlen])
			pos += nlen
			vlen := int(binary.BigEndian.Uint16(data[pos : pos+2]))
			pos += 2
			val := string(data[pos : pos+vlen])
			pos += vlen
			sens := data[pos] != 0
			pos++
			hs[j] = hpack.HeaderField{Name: name, Value: val, Sensitive: sens}
		}
		lists[i] = hs
	}

	var totalBlocks, totalHeaders, encodedSink, verifyChecksum int64
	var buf bytes.Buffer
	for round := 0; round < 100; round++ {
		buf.Reset()
		enc := hpack.NewEncoder(&buf)
		verifyRound := round == 99
		dec := hpack.NewDecoder(4096, nil)
		for bi := 0; bi < count; bi++ {
			buf.Reset()
			hs := lists[bi]
			for _, f := range hs {
				if err := enc.WriteField(f); err != nil {
					fmt.Fprintf(os.Stderr, "encode error: %v\n", err)
					os.Exit(1)
				}
			}
			wire := buf.Bytes()
			totalBlocks++
			totalHeaders += int64(len(hs))
			encodedSink += int64(len(wire))
			if verifyRound {
				rt, err := dec.DecodeFull(wire)
				if err != nil {
					fmt.Fprintf(os.Stderr, "verify decode error: %v\n", err)
					os.Exit(1)
				}
				verifyChecksum = hashHeaders(verifyChecksum, rt)
			}
		}
	}

	if encodedSink <= 0 {
		os.Exit(1)
	}
	fmt.Println("mode=hpack_encode")
	fmt.Printf("blocks=%d\n", totalBlocks)
	fmt.Printf("headers=%d\n", totalHeaders)
	fmt.Printf("verify_checksum=%d\n", verifyChecksum)
}

func benchFrameStream(data []byte) {
	var totalFrames, totalEvents, checksum int64
	var pendingBuf bytes.Buffer
	for round := 0; round < 100; round++ {
		r := bytes.NewReader(data)
		fr := http2.NewFramer(io.Discard, r)
		dec := hpack.NewDecoder(4096, nil)
		var pendingSid uint32
		var pendingEs bool
		pendingBuf.Reset()
		for {
			f, err := fr.ReadFrame()
			if err == io.EOF {
				break
			}
			if err != nil {
				fmt.Fprintf(os.Stderr, "frame error: %v\n", err)
				os.Exit(1)
			}
			totalFrames++
			switch ff := f.(type) {
			case *http2.HeadersFrame:
				if ff.HeadersEnded() {
					hs, err := dec.DecodeFull(ff.HeaderBlockFragment())
					if err != nil {
						fmt.Fprintf(os.Stderr, "hpack error: %v\n", err)
						os.Exit(1)
					}
					totalEvents++
					checksum = mix(checksum, 1)
					checksum = mix(checksum, int64(ff.StreamID))
					if ff.StreamEnded() {
						checksum = mix(checksum, 1)
					} else {
						checksum = mix(checksum, 0)
					}
					checksum = hashHeaders(checksum, hs)
				} else {
					pendingSid = ff.StreamID
					pendingEs = ff.StreamEnded()
					pendingBuf.Reset()
					pendingBuf.Write(ff.HeaderBlockFragment())
				}
			case *http2.ContinuationFrame:
				pendingBuf.Write(ff.HeaderBlockFragment())
				if ff.HeadersEnded() {
					hs, err := dec.DecodeFull(pendingBuf.Bytes())
					if err != nil {
						fmt.Fprintf(os.Stderr, "hpack cont error: %v\n", err)
						os.Exit(1)
					}
					totalEvents++
					checksum = mix(checksum, 1)
					checksum = mix(checksum, int64(pendingSid))
					if pendingEs {
						checksum = mix(checksum, 1)
					} else {
						checksum = mix(checksum, 0)
					}
					checksum = hashHeaders(checksum, hs)
					pendingSid = 0
					pendingBuf.Reset()
				}
			case *http2.DataFrame:
				totalEvents++
				checksum = mix(checksum, 2)
				checksum = mix(checksum, int64(ff.StreamID))
				if ff.StreamEnded() {
					checksum = mix(checksum, 1)
				} else {
					checksum = mix(checksum, 0)
				}
				checksum = hashBytes(checksum, ff.Data())
			case *http2.SettingsFrame:
				totalEvents++
				checksum = mix(checksum, 3)
				checksum = mix(checksum, int64(ff.NumSettings()))
				if ff.IsAck() {
					checksum = mix(checksum, 1)
				} else {
					checksum = mix(checksum, 0)
				}
			case *http2.WindowUpdateFrame:
				totalEvents++
				checksum = mix(checksum, 4)
				checksum = mix(checksum, int64(ff.StreamID))
				checksum = mix(checksum, int64(ff.Increment))
			case *http2.PingFrame:
				totalEvents++
				checksum = mix(checksum, 5)
				if ff.IsAck() {
					checksum = mix(checksum, 1)
				} else {
					checksum = mix(checksum, 0)
				}
				checksum = hashBytes(checksum, ff.Data[:])
			case *http2.PriorityFrame:
				totalEvents++
				checksum = mix(checksum, 6)
				checksum = mix(checksum, int64(ff.StreamID))
				checksum = mix(checksum, int64(ff.Weight))
			}
		}
	}

	fmt.Println("mode=frame_stream")
	fmt.Printf("frames=%d\n", totalFrames)
	fmt.Printf("events=%d\n", totalEvents)
	fmt.Printf("checksum=%d\n", checksum)
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: go_http2_bench <hpack_decode|hpack_encode|frame_stream> <corpus.bin>")
		os.Exit(1)
	}
	mode := os.Args[1]
	data, err := os.ReadFile(os.Args[2])
	if err != nil {
		fmt.Fprintf(os.Stderr, "read error: %v\n", err)
		os.Exit(1)
	}
	switch mode {
	case "hpack_decode":
		benchHpackDecode(data)
	case "hpack_encode":
		benchHpackEncode(data)
	case "frame_stream":
		benchFrameStream(data)
	default:
		fmt.Fprintf(os.Stderr, "unknown mode: %s\n", mode)
		os.Exit(1)
	}
}
