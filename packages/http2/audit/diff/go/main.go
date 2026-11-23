// Differential reference runner: Go golang.org/x/net/http2 (Framer) + http2/hpack (Decoder).
//
//	diff_go hpack  <corpus.txt>   same line format as `probe hpack`
//	diff_go frames <corpus.txt>   same line format as `probe frames`
package main

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"strings"

	"golang.org/x/net/http2"
	"golang.org/x/net/http2/hpack"
)

func b01(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

// reason returns "(msg)" when DIFF_REASON=1 (compare.py strips it before classifying).
func reason(err error) string {
	if os.Getenv("DIFF_REASON") != "1" {
		return ""
	}
	r := strings.NewReplacer("|", "/", ";", ",", "\t", " ", "(", "[", ")", "]")
	return "(" + r.Replace(err.Error()) + ")"
}

func parse(line string) (string, [][]byte) {
	tab := strings.IndexByte(line, '\t')
	name := line[:tab]
	var blocks [][]byte
	for _, h := range strings.Split(line[tab+1:], ",") {
		b, err := hex.DecodeString(h)
		if err != nil {
			panic(err)
		}
		blocks = append(blocks, b)
	}
	return name, blocks
}

func runHpack(w *bufio.Writer, name string, blocks [][]byte) {
	w.WriteString(name + "\t")
	dec := hpack.NewDecoder(4096, nil)
	for i, b := range blocks {
		if i > 0 {
			w.WriteString("|")
		}
		hs, err := dec.DecodeFull(b)
		if err != nil {
			w.WriteString("ERR" + reason(err))
			break
		}
		for j, f := range hs {
			if j > 0 {
				w.WriteString(" ")
			}
			w.WriteString(hex.EncodeToString([]byte(f.Name)) + ":" + hex.EncodeToString([]byte(f.Value)))
			if f.Sensitive {
				w.WriteString("!")
			}
		}
		w.WriteString(";")
	}
	w.WriteString("\n")
}

func runFrame(w *bufio.Writer, name string, data []byte) {
	w.WriteString(name + "\t")
	defer w.WriteString("\n")
	r := bytes.NewReader(data)
	fr := http2.NewFramer(io.Discard, r)
	fr.SetMaxReadFrameSize(16384)
	f, err := fr.ReadFrame()
	if err != nil {
		w.WriteString("ERR" + reason(err))
		return
	}
	if r.Len() != 0 {
		w.WriteString("TRAIL ")
	}
	switch ff := f.(type) {
	case *http2.DataFrame:
		fmt.Fprintf(w, "D %d %s %s", ff.StreamID, b01(ff.StreamEnded()), hex.EncodeToString(ff.Data()))
	case *http2.HeadersFrame:
		fmt.Fprintf(w, "H %d %s %s ", ff.StreamID, b01(ff.StreamEnded()), b01(ff.HeadersEnded()))
		if ff.HasPriority() {
			fmt.Fprintf(w, "%s/%d/%d ", b01(ff.Priority.Exclusive), ff.Priority.StreamDep, ff.Priority.Weight)
		} else {
			w.WriteString("- ")
		}
		w.WriteString(hex.EncodeToString(ff.HeaderBlockFragment()))
	case *http2.PriorityFrame:
		fmt.Fprintf(w, "P %d %s/%d/%d", ff.StreamID, b01(ff.Exclusive), ff.StreamDep, ff.Weight)
	case *http2.RSTStreamFrame:
		fmt.Fprintf(w, "R %d %d", ff.StreamID, uint32(ff.ErrCode))
	case *http2.SettingsFrame:
		// Settings value validation (ENABLE_PUSH, MAX_FRAME_SIZE, INITIAL_WINDOW_SIZE) is part of
		// x/net/http2's frame acceptance (ReadFrame checks INITIAL_WINDOW_SIZE; servers call Valid()).
		bad := false
		ff.ForeachSetting(func(s http2.Setting) error {
			if s.Valid() != nil {
				bad = true
			}
			return nil
		})
		if bad {
			w.WriteString("ERR")
			return
		}
		fmt.Fprintf(w, "S %s", b01(ff.IsAck()))
		ff.ForeachSetting(func(s http2.Setting) error {
			fmt.Fprintf(w, " %d=%d", uint16(s.ID), s.Val)
			return nil
		})
	case *http2.PushPromiseFrame:
		fmt.Fprintf(w, "PP %d %d %s %s", ff.StreamID, ff.PromiseID, b01(ff.HeadersEnded()), hex.EncodeToString(ff.HeaderBlockFragment()))
	case *http2.PingFrame:
		fmt.Fprintf(w, "G %s %s", b01(ff.IsAck()), hex.EncodeToString(ff.Data[:]))
	case *http2.GoAwayFrame:
		fmt.Fprintf(w, "GA %d %d %s", ff.LastStreamID, uint32(ff.ErrCode), hex.EncodeToString(ff.DebugData()))
	case *http2.WindowUpdateFrame:
		fmt.Fprintf(w, "W %d %d", ff.StreamID, ff.Increment)
	case *http2.ContinuationFrame:
		fmt.Fprintf(w, "C %d %s %s", ff.StreamID, b01(ff.HeadersEnded()), hex.EncodeToString(ff.HeaderBlockFragment()))
	case *http2.UnknownFrame:
		fmt.Fprintf(w, "U %d %d %s", uint8(ff.Type), ff.StreamID, hex.EncodeToString(ff.Payload()))
	default:
		fmt.Fprintf(w, "?%T", f)
	}
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: diff_go hpack|frames <corpus.txt>")
		os.Exit(2)
	}
	data, err := os.ReadFile(os.Args[2])
	if err != nil {
		panic(err)
	}
	w := bufio.NewWriterSize(os.Stdout, 1<<20)
	defer w.Flush()
	for _, line := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
		name, blocks := parse(line)
		switch os.Args[1] {
		case "hpack":
			runHpack(w, name, blocks)
		case "frames":
			runFrame(w, name, blocks[0])
		}
	}
}
