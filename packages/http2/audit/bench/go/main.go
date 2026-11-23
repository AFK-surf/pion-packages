// Fairness re-benchmark, Go side (golang.org/x/net v0.62.0): same corpora/rounds/checksums as pion_fair.
//
//	go_fair hpack_decode <hpack_stream.bin>
//	go_fair hpack_encode <headers_plain.bin>   (Go's encoder: Huffman when shorter; no switch to disable)
//	go_fair frames       <frame_stream.bin>    Framer + ReadMetaHeaders (CONTINUATION + HPACK + field checks)
//
// Strings are hashed in place (no []byte(string) conversion per field).
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

func mix(h, v int64) int64 { return ((h * 131) + v) % 1000000007 }

func hashStr(h int64, s string) int64 {
	h = mix(h, int64(len(s)))
	for i := 0; i < len(s); i++ {
		h = mix(h, int64(s[i]))
	}
	return h
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
		h = hashStr(h, f.Name)
		h = hashStr(h, f.Value)
	}
	return h
}

func hashHeadersSet(h int64, hs []hpack.HeaderField) int64 {
	var sum int64
	for _, f := range hs {
		sum = (sum + hashStr(hashStr(0, f.Name), f.Value)) % 1000000007
	}
	return mix(mix(h, int64(len(hs))), sum)
}

func b2i(b bool) int64 {
	if b {
		return 1
	}
	return 0
}

func decode(data []byte) {
	count := int(binary.BigEndian.Uint32(data))
	blocks := make([][]byte, count)
	pos := 4
	for i := range blocks {
		l := int(binary.BigEndian.Uint32(data[pos:]))
		pos += 4
		blocks[i] = data[pos : pos+l]
		pos += l
	}
	var tb, th, ck int64
	for r := 0; r < 100; r++ {
		dec := hpack.NewDecoder(4096, nil)
		for _, b := range blocks {
			hs, err := dec.DecodeFull(b)
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			tb++
			th += int64(len(hs))
			ck = hashHeaders(ck, hs)
		}
	}
	fmt.Printf("mode=hpack_decode\nblocks=%d\nheaders=%d\nchecksum=%d\n", tb, th, ck)
}

func encode(data []byte) {
	count := int(binary.BigEndian.Uint32(data))
	lists := make([][]hpack.HeaderField, count)
	pos := 4
	for i := range lists {
		hc := int(binary.BigEndian.Uint16(data[pos:]))
		pos += 2
		hs := make([]hpack.HeaderField, hc)
		for j := range hs {
			nl := int(binary.BigEndian.Uint16(data[pos:]))
			pos += 2
			n := string(data[pos : pos+nl])
			pos += nl
			vl := int(binary.BigEndian.Uint16(data[pos:]))
			pos += 2
			v := string(data[pos : pos+vl])
			pos += vl
			hs[j] = hpack.HeaderField{Name: n, Value: v, Sensitive: data[pos] != 0}
			pos++
		}
		lists[i] = hs
	}
	var tb, th, sink, vck int64
	var buf bytes.Buffer
	for r := 0; r < 100; r++ {
		enc := hpack.NewEncoder(&buf)
		dec := hpack.NewDecoder(4096, nil)
		for _, hs := range lists {
			buf.Reset()
			for _, f := range hs {
				enc.WriteField(f)
			}
			tb++
			th += int64(len(hs))
			sink += int64(buf.Len())
			if r == 99 {
				rt, err := dec.DecodeFull(buf.Bytes())
				if err != nil {
					fmt.Fprintln(os.Stderr, err)
					os.Exit(1)
				}
				vck = hashHeaders(vck, rt)
			}
		}
	}
	if sink <= 0 {
		os.Exit(1)
	}
	fmt.Printf("mode=hpack_encode\nblocks=%d\nheaders=%d\nverify_checksum=%d\n", tb, th, vck)
}

func frames(data []byte) {
	var nf, ne, ck int64
	for r := 0; r < 100; r++ {
		fr := http2.NewFramer(io.Discard, bytes.NewReader(data))
		fr.SetMaxReadFrameSize(16384)
		fr.MaxHeaderListSize = 65536
		fr.ReadMetaHeaders = hpack.NewDecoder(4096, nil)
		for {
			f, err := fr.ReadFrame()
			if err == io.EOF {
				break
			}
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			nf++
			switch ff := f.(type) {
			case *http2.MetaHeadersFrame:
				nf += int64(continuations(ff))
				ne++
				ck = mix(mix(mix(ck, 1), int64(ff.StreamID)), b2i(ff.StreamEnded()))
				ck = hashHeadersSet(ck, ff.Fields)
			case *http2.DataFrame:
				ne++
				ck = hashBytes(mix(mix(mix(ck, 2), int64(ff.StreamID)), b2i(ff.StreamEnded())), ff.Data())
			case *http2.SettingsFrame:
				ne++
				ck = mix(mix(ck, 3), b2i(ff.IsAck()))
			case *http2.WindowUpdateFrame:
				ne++
				ck = mix(mix(mix(ck, 4), int64(ff.StreamID)), int64(ff.Increment))
			case *http2.PingFrame:
				ne++
				ck = hashBytes(mix(mix(ck, 5), b2i(ff.IsAck())), ff.Data[:])
			case *http2.PriorityFrame:
				ne++
				ck = mix(ck, 6) // h2 exposes no PRIORITY stream id accessor
			}
		}
	}
	fmt.Printf("mode=frames\nframes=%d\nevents=%d\nchecksum=%d\n", nf, ne, ck)
}

// The Framer folds HEADERS+CONTINUATION into one MetaHeadersFrame; count the folded frames so
// frames= matches the wire frame count reported by Pion and h2.
func continuations(f *http2.MetaHeadersFrame) int {
	if f.HeadersFrame.HeadersEnded() {
		return 0
	}
	return 1 // corpus splits a block into exactly HEADERS + 1 CONTINUATION
}

func main() {
	data, err := os.ReadFile(os.Args[2])
	if err != nil {
		panic(err)
	}
	switch os.Args[1] {
	case "hpack_decode":
		decode(data)
	case "hpack_encode":
		encode(data)
	case "frames":
		frames(data)
	}
}
