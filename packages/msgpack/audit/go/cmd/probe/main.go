// Red-team reference probe: Go vmihailenco/msgpack/v5 v5.4.1 (same protocol as ../../../probe).
//
//	go_probe tree <opts> <hex-lines-file>  -> "OK <tree> -" | "ERR <msg>"
//
// The walker uses the library's own streaming API (PeekCode / DecodeArrayLen / DecodeMapLen /
// DecodeInterface / DecodeRaw) so map order and non-string keys survive; ext -1 is decoded with
// the library's time.Time decoder and printed as t<sec>.<nsec>. Go does not validate UTF-8.
package main

import (
	"bytes"
	"encoding/hex"
	"fmt"
	"math"
	"os"
	"strings"
	"time"

	"github.com/vmihailenco/msgpack/v5"
	"github.com/vmihailenco/msgpack/v5/msgpcode"
)

func extPayload(raw []byte) (int8, []byte) {
	c := raw[0]
	switch {
	case c >= msgpcode.FixExt1 && c <= msgpcode.FixExt16:
		return int8(raw[1]), raw[2:]
	case c == msgpcode.Ext8:
		return int8(raw[2]), raw[3:]
	case c == msgpcode.Ext16:
		return int8(raw[3]), raw[4:]
	default:
		return int8(raw[5]), raw[6:]
	}
}

func walk(d *msgpack.Decoder, sb *strings.Builder) error {
	c, err := d.PeekCode()
	if err != nil {
		return err
	}
	switch {
	case msgpcode.IsFixedArray(c) || c == msgpcode.Array16 || c == msgpcode.Array32:
		n, err := d.DecodeArrayLen()
		if err != nil {
			return err
		}
		sb.WriteByte('[')
		for i := 0; i < n; i++ {
			if i > 0 {
				sb.WriteByte(',')
			}
			if err := walk(d, sb); err != nil {
				return err
			}
		}
		sb.WriteByte(']')
		return nil
	case msgpcode.IsFixedMap(c) || c == msgpcode.Map16 || c == msgpcode.Map32:
		n, err := d.DecodeMapLen()
		if err != nil {
			return err
		}
		sb.WriteByte('{')
		for i := 0; i < n; i++ {
			if i > 0 {
				sb.WriteByte(',')
			}
			if err := walk(d, sb); err != nil {
				return err
			}
			sb.WriteByte(':')
			if err := walk(d, sb); err != nil {
				return err
			}
		}
		sb.WriteByte('}')
		return nil
	case msgpcode.IsExt(c):
		raw, err := d.DecodeRaw()
		if err != nil {
			return err
		}
		t, payload := extPayload(raw)
		if t == -1 {
			var tm time.Time
			if err := msgpack.Unmarshal(raw, &tm); err != nil {
				return err
			}
			fmt.Fprintf(sb, "t%d.%d", tm.Unix(), tm.Nanosecond())
			return nil
		}
		fmt.Fprintf(sb, "x%d:%s", t, hex.EncodeToString(payload))
		return nil
	}
	v, err := d.DecodeInterface()
	if err != nil {
		return err
	}
	switch x := v.(type) {
	case nil:
		sb.WriteString("nil")
	case bool:
		if x {
			sb.WriteString("T")
		} else {
			sb.WriteString("F")
		}
	case int8, int16, int32, int64:
		var n int64
		switch y := x.(type) {
		case int8:
			n = int64(y)
		case int16:
			n = int64(y)
		case int32:
			n = int64(y)
		case int64:
			n = y
		}
		if n >= 0 {
			fmt.Fprintf(sb, "u%d", n)
		} else {
			fmt.Fprintf(sb, "i%d", n)
		}
	case uint8:
		fmt.Fprintf(sb, "u%d", x)
	case uint16:
		fmt.Fprintf(sb, "u%d", x)
	case uint32:
		fmt.Fprintf(sb, "u%d", x)
	case uint64:
		fmt.Fprintf(sb, "u%d", x)
	case float32:
		fmt.Fprintf(sb, "f32:%08x", math.Float32bits(x))
	case float64:
		fmt.Fprintf(sb, "f64:%016x", math.Float64bits(x))
	case string:
		sb.WriteString("s:" + hex.EncodeToString([]byte(x)))
	case []byte:
		sb.WriteString("b:" + hex.EncodeToString(x))
	default:
		return fmt.Errorf("unexpected %T", v)
	}
	return nil
}

func runOne(in []byte) string {
	d := msgpack.NewDecoder(bytes.NewReader(in))
	var sb strings.Builder
	if err := walk(d, &sb); err != nil {
		return "ERR " + err.Error()
	}
	if d.Buffered().(*bytes.Reader).Len() != 0 {
		return "ERR trailing bytes"
	}
	return "OK " + sb.String() + " -"
}

func main() {
	if len(os.Args) < 4 || os.Args[1] != "tree" {
		fmt.Fprintln(os.Stderr, "usage: go_probe tree <opts> <file>")
		os.Exit(1)
	}
	src, err := os.ReadFile(os.Args[3])
	if err != nil {
		panic(err)
	}
	var out strings.Builder
	for _, line := range strings.Split(string(src), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		in, _ := hex.DecodeString(line)
		out.WriteString(runOne(in))
		out.WriteByte('\n')
	}
	os.Stdout.WriteString(out.String())
}
