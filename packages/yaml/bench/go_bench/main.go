package main

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"math"
	"os"
	"sort"
	"strconv"

	"gopkg.in/yaml.v3"
)

func writeJSONString(buf *bytes.Buffer, s string) {
	buf.WriteByte('"')
	mark := 0
	for i := 0; i < len(s); i++ {
		b := s[i]
		if b == '"' || b == '\\' || b < 0x20 {
			if mark < i {
				buf.WriteString(s[mark:i])
			}
			switch b {
			case '"':
				buf.WriteString(`\"`)
			case '\\':
				buf.WriteString(`\\`)
			case '\b':
				buf.WriteString(`\b`)
			case '\f':
				buf.WriteString(`\f`)
			case '\n':
				buf.WriteString(`\n`)
			case '\r':
				buf.WriteString(`\r`)
			case '\t':
				buf.WriteString(`\t`)
			default:
				fmt.Fprintf(buf, `\u%04x`, b)
			}
			mark = i + 1
		}
	}
	if mark < len(s) {
		buf.WriteString(s[mark:])
	}
	buf.WriteByte('"')
}

func writeCanonicalJSON(buf *bytes.Buffer, v any) {
	switch val := v.(type) {
	case nil:
		buf.WriteString("null")
	case bool:
		if val {
			buf.WriteString("true")
		} else {
			buf.WriteString("false")
		}
	case int:
		buf.WriteString(strconv.FormatInt(int64(val), 10))
	case int64:
		buf.WriteString(strconv.FormatInt(val, 10))
	case uint64:
		buf.WriteString(strconv.FormatUint(val, 10))
	case float64:
		if math.IsNaN(val) || math.IsInf(val, 0) {
			buf.WriteString("null")
		} else {
			buf.WriteString(strconv.FormatFloat(val, 'g', -1, 64))
		}
	case string:
		writeJSONString(buf, val)
	case []any:
		buf.WriteByte('[')
		for i, item := range val {
			if i > 0 {
				buf.WriteByte(',')
			}
			writeCanonicalJSON(buf, item)
		}
		buf.WriteByte(']')
	case map[string]any:
		keys := make([]string, 0, len(val))
		for k := range val {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		buf.WriteByte('{')
		for i, k := range keys {
			if i > 0 {
				buf.WriteByte(',')
			}
			writeJSONString(buf, k)
			buf.WriteByte(':')
			writeCanonicalJSON(buf, val[k])
		}
		buf.WriteByte('}')
	default:
		writeJSONString(buf, fmt.Sprintf("%v", val))
	}
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: bench_go <corpus.yaml>")
		os.Exit(1)
	}
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	dec := yaml.NewDecoder(bytes.NewReader(data))
	var out bytes.Buffer
	out.Grow(len(data))
	for {
		var doc any
		err := dec.Decode(&doc)
		if err == io.EOF {
			break
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		writeCanonicalJSON(&out, doc)
		out.WriteByte('\n')
	}
	w := bufio.NewWriter(os.Stdout)
	_, _ = w.Write(out.Bytes())
	_ = w.Flush()
}
