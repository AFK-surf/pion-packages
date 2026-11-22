// Red-team differential driver for Go gopkg.in/yaml.v3.
// Modes: json <file> (canonical JSON per doc or "ERR <msg>", exit 2), rt <file> (Marshal round trip), rtjson <file> (Marshal -> Unmarshal -> canonical JSON).
package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"reflect"
	"sort"
	"strconv"

	"gopkg.in/yaml.v3"
)

func writeJSONString(buf *bytes.Buffer, s string) {
	buf.WriteByte('"')
	for i := 0; i < len(s); i++ {
		b := s[i]
		switch {
		case b == '"':
			buf.WriteString(`\"`)
		case b == '\\':
			buf.WriteString(`\\`)
		case b == '\b':
			buf.WriteString(`\b`)
		case b == '\f':
			buf.WriteString(`\f`)
		case b == '\n':
			buf.WriteString(`\n`)
		case b == '\r':
			buf.WriteString(`\r`)
		case b == '\t':
			buf.WriteString(`\t`)
		case b < 0x20:
			fmt.Fprintf(buf, `\u%04x`, b)
		default:
			buf.WriteByte(b)
		}
	}
	buf.WriteByte('"')
}

func fmtFloat(f float64) string {
	if math.IsNaN(f) || math.IsInf(f, 0) {
		return "null"
	}
	return strconv.FormatFloat(f, 'g', -1, 64)
}

func keyStr(k any) string {
	switch v := k.(type) {
	case string:
		return v
	case nil:
		return "null"
	case bool:
		if v {
			return "true"
		}
		return "false"
	case int:
		return strconv.Itoa(v)
	case int64:
		return strconv.FormatInt(v, 10)
	case uint64:
		return strconv.FormatUint(v, 10)
	case float64:
		return fmtFloat(v)
	default:
		var b bytes.Buffer
		canon(&b, k)
		return b.String()
	}
}

func canon(buf *bytes.Buffer, v any) {
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
		buf.WriteString(strconv.Itoa(val))
	case int64:
		buf.WriteString(strconv.FormatInt(val, 10))
	case uint64:
		buf.WriteString(strconv.FormatUint(val, 10))
	case float64:
		buf.WriteString(fmtFloat(val))
	case string:
		writeJSONString(buf, val)
	case []byte:
		writeJSONString(buf, string(val))
	case []any:
		buf.WriteByte('[')
		for i, it := range val {
			if i > 0 {
				buf.WriteByte(',')
			}
			canon(buf, it)
		}
		buf.WriteByte(']')
	case map[string]any:
		m := map[string]any{}
		for k, x := range val {
			m[k] = x
		}
		writeObj(buf, m)
	case map[any]any:
		m := map[string]any{}
		for k, x := range val {
			m[keyStr(k)] = x
		}
		writeObj(buf, m)
	default:
		rv := reflect.ValueOf(v)
		writeJSONString(buf, fmt.Sprintf("%T:%v", v, rv))
	}
}

func writeObj(buf *bytes.Buffer, m map[string]any) {
	keys := make([]string, 0, len(m))
	for k := range m {
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
		canon(buf, m[k])
	}
	buf.WriteByte('}')
}

func main() {
	if len(os.Args) < 3 {
		fmt.Println("usage: go_driver json|rt <file>")
		os.Exit(1)
	}
	data, err := os.ReadFile(os.Args[2])
	if err != nil {
		fmt.Println("ERR cannot read")
		os.Exit(1)
	}
	dec := yaml.NewDecoder(bytes.NewReader(data))
	var docs []any
	for {
		var doc any
		err := dec.Decode(&doc)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			fmt.Printf("ERR %v\n", err)
			os.Exit(2)
		}
		docs = append(docs, doc)
	}
	var out bytes.Buffer
	switch os.Args[1] {
	case "json":
		for _, d := range docs {
			canon(&out, d)
			out.WriteByte('\n')
		}
	case "rtjson":
		for _, d := range docs {
			emitted, err := yaml.Marshal(d)
			var again any
			if err == nil {
				err = yaml.Unmarshal(emitted, &again)
			}
			if err != nil {
				fmt.Fprintf(&out, "RT_ERR %v\n", err)
				continue
			}
			canon(&out, again)
			out.WriteByte('\n')
		}
	case "rt":
		bad := false
		for i, d := range docs {
			var a, b bytes.Buffer
			canon(&a, d)
			emitted, err := yaml.Marshal(d)
			if err != nil {
				fmt.Fprintf(&out, "RT_ERR doc=%d marshal %v\n", i, err)
				bad = true
				continue
			}
			var again any
			if err := yaml.Unmarshal(emitted, &again); err != nil {
				fmt.Fprintf(&out, "RT_ERR doc=%d %v\n", i, err)
				bad = true
				continue
			}
			canon(&b, again)
			if a.String() != b.String() || fmt.Sprintf("%#v", d) != fmt.Sprintf("%#v", again) {
				fmt.Fprintf(&out, "RT_DIFF doc=%d\n  orig : %#v\n  again: %#v\n", i, d, again)
				bad = true
			}
		}
		if !bad {
			out.WriteString("RT_OK\n")
		}
		os.Stdout.Write(out.Bytes())
		if bad {
			os.Exit(3)
		}
		return
	}
	os.Stdout.Write(out.Bytes())
}
