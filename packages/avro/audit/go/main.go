// Red-team differential oracle for packages/avro: Go github.com/hamba/avro/v2 v2.28.0.
//
//	oracle batch <cases.txt> <out.txt>   one result line per case line (see ../diff_oracle.py)
//	oracle ocf_read <file.avro>          decode every OCF record into `any`
//	oracle ocf_info <file.avro>          print the embedded avro.schema and the Go type of field 0
//
// Case lines (all payloads lower-case hex):
//
//	S <schema>                  -> ok <pcf-hex> <crc64-avro-hex> | err
//	D <schema> <data>           -> ok <canon> | err
//	R <writer> <reader> <data>  -> ok <canon> | err
//
// <canon> is the schema-directed canonical text shared with ../probe (union wrappers are
// transparent, map keys are sorted, records print in reader field order).
package main

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"fmt"
	"math"
	"os"
	"reflect"
	"sort"
	"strings"

	"github.com/hamba/avro/v2"
	"github.com/hamba/avro/v2/ocf"
)

func parse(s string) (avro.Schema, error) {
	return avro.ParseWithCache(s, "", &avro.SchemaCache{})
}

func canon(sb *strings.Builder, s avro.Schema, v any) error {
	if s.Type() == avro.Ref {
		s = s.(*avro.RefSchema).Schema()
	}
	switch s.Type() {
	case avro.Null:
		if v != nil {
			return fmt.Errorf("null")
		}
		sb.WriteString("n")
	case avro.Boolean:
		b, ok := v.(bool)
		if !ok {
			return fmt.Errorf("bool %T", v)
		}
		if b {
			sb.WriteString("t")
		} else {
			sb.WriteString("f")
		}
	case avro.Int:
		switch x := v.(type) {
		case int:
			fmt.Fprintf(sb, "I%d", x)
		case int32:
			fmt.Fprintf(sb, "I%d", x)
		default:
			return fmt.Errorf("int %T", v)
		}
	case avro.Long:
		switch x := v.(type) {
		case int64:
			fmt.Fprintf(sb, "L%d", x)
		case int:
			fmt.Fprintf(sb, "L%d", x)
		default:
			return fmt.Errorf("long %T", v)
		}
	case avro.Float:
		x, ok := v.(float32)
		if !ok {
			return fmt.Errorf("float %T", v)
		}
		fmt.Fprintf(sb, "f%08x", math.Float32bits(x))
	case avro.Double:
		x, ok := v.(float64)
		if !ok {
			return fmt.Errorf("double %T", v)
		}
		fmt.Fprintf(sb, "d%016x", math.Float64bits(x))
	case avro.Bytes:
		b, ok := v.([]byte)
		if !ok {
			return fmt.Errorf("bytes %T", v)
		}
		sb.WriteString("b" + hex.EncodeToString(b))
	case avro.String:
		x, ok := v.(string)
		if !ok {
			return fmt.Errorf("string %T", v)
		}
		sb.WriteString("s" + hex.EncodeToString([]byte(x)))
	case avro.Fixed:
		rv := reflect.ValueOf(v)
		if rv.Kind() != reflect.Array {
			return fmt.Errorf("fixed %T", v)
		}
		b := make([]byte, rv.Len())
		for i := range b {
			b[i] = byte(rv.Index(i).Uint())
		}
		sb.WriteString("x" + hex.EncodeToString(b))
	case avro.Enum:
		x, ok := v.(string)
		if !ok {
			return fmt.Errorf("enum %T", v)
		}
		sb.WriteString("e" + x)
	case avro.Array:
		xs, ok := v.([]any)
		if !ok {
			return fmt.Errorf("array %T", v)
		}
		sb.WriteString("[")
		for i, x := range xs {
			if i > 0 {
				sb.WriteString(",")
			}
			if err := canon(sb, s.(*avro.ArraySchema).Items(), x); err != nil {
				return err
			}
		}
		sb.WriteString("]")
	case avro.Map:
		m, ok := v.(map[string]any)
		if !ok {
			return fmt.Errorf("map %T", v)
		}
		keys := make([]string, 0, len(m))
		for k := range m {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		sb.WriteString("{")
		for i, k := range keys {
			if i > 0 {
				sb.WriteString(",")
			}
			sb.WriteString("k" + hex.EncodeToString([]byte(k)) + ":")
			if err := canon(sb, s.(*avro.MapSchema).Values(), m[k]); err != nil {
				return err
			}
		}
		sb.WriteString("}")
	case avro.Record:
		m, ok := v.(map[string]any)
		if !ok {
			return fmt.Errorf("record %T", v)
		}
		sb.WriteString("(")
		for i, f := range s.(*avro.RecordSchema).Fields() {
			if i > 0 {
				sb.WriteString(",")
			}
			fv, ok := m[f.Name()]
			if !ok {
				return fmt.Errorf("missing field %s", f.Name())
			}
			if err := canon(sb, f.Type(), fv); err != nil {
				return err
			}
		}
		sb.WriteString(")")
	case avro.Union:
		types := s.(*avro.UnionSchema).Types()
		if v == nil {
			for _, t := range types {
				if t.Type() == avro.Null {
					sb.WriteString("n")
					return nil
				}
			}
			return fmt.Errorf("union null")
		}
		if m, ok := v.(map[string]any); ok && len(m) == 1 {
			for k, inner := range m {
				for _, t := range types {
					if typeName(t) == k {
						return canon(sb, t, inner)
					}
				}
			}
		}
		// Resolution may strip the union (writer non-union -> reader union): first branch that fits.
		for _, t := range types {
			var tmp strings.Builder
			if canon(&tmp, t, v) == nil {
				sb.WriteString(tmp.String())
				return nil
			}
		}
		return fmt.Errorf("union value %T", v)
	default:
		return fmt.Errorf("type %s", s.Type())
	}
	return nil
}

func recursive(s avro.Schema, stack map[string]bool) bool {
	switch t := s.(type) {
	case *avro.RefSchema:
		return stack[t.Schema().FullName()]
	case *avro.RecordSchema:
		if stack[t.FullName()] {
			return true
		}
		stack[t.FullName()] = true
		defer delete(stack, t.FullName())
		for _, f := range t.Fields() {
			if recursive(f.Type(), stack) {
				return true
			}
		}
	case *avro.ArraySchema:
		return recursive(t.Items(), stack)
	case *avro.MapSchema:
		return recursive(t.Values(), stack)
	case *avro.UnionSchema:
		for _, x := range t.Types() {
			if recursive(x, stack) {
				return true
			}
		}
	}
	return false
}

func typeName(s avro.Schema) string {
	if s.Type() == avro.Ref {
		s = s.(*avro.RefSchema).Schema()
	}
	if n, ok := s.(avro.NamedSchema); ok {
		return n.FullName()
	}
	name := string(s.Type())
	if l, ok := s.(avro.LogicalTypeSchema); ok && l.Logical() != nil {
		name += "." + string(l.Logical().Type())
	}
	return name
}

func msg(err error) string {
	m := strings.ReplaceAll(err.Error(), "\n", " ")
	if len(m) > 160 {
		m = m[:160]
	}
	return m
}

func unhex(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}

func runCase(line string) (out string) {
	defer func() {
		if r := recover(); r != nil {
			out = "err panic"
		}
	}()
	f := strings.Fields(line)
	if len(f) == 0 {
		return "err empty"
	}
	switch f[0] {
	case "S":
		s, err := parse(string(unhex(f[1])))
		if err != nil {
			return "err " + msg(err)
		}
		fp, err := s.FingerprintUsing(avro.CRC64Avro)
		if err != nil {
			return "err fp"
		}
		return "ok " + hex.EncodeToString([]byte(s.String())) + " " + hex.EncodeToString(fp)
	case "D":
		s, err := parse(string(unhex(f[1])))
		if err != nil {
			return "err schema"
		}
		data := []byte{}
		if len(f) > 2 {
			data = unhex(f[2])
		}
		if recursive(s, map[string]bool{}) {
			// hamba v2.28.0 decodes a zero-byte self-recursive record forever (fatal stack overflow).
			return "skip recursive"
		}
		var v any
		if err := avro.Unmarshal(s, data, &v); err != nil {
			return "err " + msg(err)
		}
		var sb strings.Builder
		if err := canon(&sb, s, v); err != nil {
			return "err canon " + err.Error()
		}
		return "ok " + sb.String()
	case "R":
		w, err := parse(string(unhex(f[1])))
		if err != nil {
			return "err writer"
		}
		r, err := parse(string(unhex(f[2])))
		if err != nil {
			return "err reader"
		}
		data := []byte{}
		if len(f) > 3 {
			data = unhex(f[3])
		}
		if recursive(w, map[string]bool{}) || recursive(r, map[string]bool{}) {
			// hamba v2.28.0 SchemaCompatibility.resolve recurses forever on recursive
			// records (fatal "stack overflow", not recoverable) -> no oracle verdict.
			return "skip recursive"
		}
		res, err := avro.NewSchemaCompatibility().Resolve(r, w)
		if err != nil {
			return "err resolve: " + msg(err)
		}
		var v any
		if err := avro.Unmarshal(res, data, &v); err != nil {
			return "err " + msg(err)
		}
		var sb strings.Builder
		if err := canon(&sb, r, v); err != nil {
			return "err canon " + err.Error()
		}
		return "ok " + sb.String()
	}
	return "err op"
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: oracle batch <in> <out> | ocf_read <file> | ocf_info <file>")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "batch":
		in, err := os.ReadFile(os.Args[2])
		if err != nil {
			panic(err)
		}
		var out bytes.Buffer
		sc := bufio.NewScanner(bytes.NewReader(in))
		sc.Buffer(make([]byte, 1<<20), 1<<28)
		for sc.Scan() {
			out.WriteString(runCase(sc.Text()))
			out.WriteByte('\n')
		}
		if err := os.WriteFile(os.Args[3], out.Bytes(), 0o644); err != nil {
			panic(err)
		}
	case "deep_list_dec":
		var n int
		fmt.Sscan(os.Args[2], &n)
		s, _ := parse(`{"type":"record","name":"Node","fields":[{"name":"v","type":"long"},{"name":"next","type":["null","Node"]}]}`)
		data := make([]byte, 2*n+2)
		for i := 0; i < n; i++ {
			data[2*i+1] = 2
		}
		var v any
		if err := avro.Unmarshal(s, data, &v); err != nil {
			fmt.Println("err", err)
			os.Exit(1)
		}
		fmt.Printf("ok nodes=%d\n", n+1)
	case "ocf_read_all":
		// like Pion read_ocf: materialise every record before returning
		raw, err := os.ReadFile(os.Args[2])
		if err != nil {
			panic(err)
		}
		dec, err := ocf.NewDecoder(bytes.NewReader(raw))
		if err != nil {
			fmt.Println("err header:", err)
			os.Exit(1)
		}
		var all []any
		for dec.HasNext() {
			var v any
			if err := dec.Decode(&v); err != nil {
				fmt.Println("err decode:", err)
				os.Exit(1)
			}
			all = append(all, v)
		}
		if err := dec.Error(); err != nil {
			fmt.Println("err block:", err)
			os.Exit(1)
		}
		fmt.Printf("ok records=%d\n", len(all))
	case "ocf_read", "ocf_info":
		raw, err := os.ReadFile(os.Args[2])
		if err != nil {
			panic(err)
		}
		dec, err := ocf.NewDecoder(bytes.NewReader(raw))
		if err != nil {
			fmt.Println("err header:", err)
			os.Exit(1)
		}
		if os.Args[1] == "ocf_info" {
			fmt.Printf("avro.schema=%s\n", dec.Metadata()["avro.schema"])
		}
		n := 0
		for dec.HasNext() {
			var v any
			if err := dec.Decode(&v); err != nil {
				fmt.Println("err decode:", err)
				os.Exit(1)
			}
			if os.Args[1] == "ocf_info" && n == 0 {
				if m, ok := v.(map[string]any); ok {
					keys := make([]string, 0, len(m))
					for k := range m {
						keys = append(keys, k)
					}
					sort.Strings(keys)
					for _, k := range keys {
						fmt.Printf("field %s go_type=%T value=%v\n", k, m[k], m[k])
					}
				}
			}
			n++
		}
		if err := dec.Error(); err != nil {
			fmt.Println("err block:", err)
			os.Exit(1)
		}
		fmt.Printf("ok records=%d\n", n)
	default:
		fmt.Fprintln(os.Stderr, "unknown mode")
		os.Exit(2)
	}
}
