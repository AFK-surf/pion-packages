// Red-team audit CLI: Go BurntSushi/toml side (decode -> toml-test JSON, errpos, bench-parse, bench-many).
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/BurntSushi/toml"
)

func tag(v any) any {
	switch x := v.(type) {
	case map[string]any:
		out := map[string]any{}
		for k, c := range x {
			out[k] = tag(c)
		}
		return out
	case []map[string]any:
		out := make([]any, len(x))
		for i, c := range x {
			out[i] = tag(c)
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, c := range x {
			out[i] = tag(c)
		}
		return out
	case string:
		return map[string]string{"type": "string", "value": x}
	case int64:
		return map[string]string{"type": "integer", "value": strconv.FormatInt(x, 10)}
	case float64:
		s := strconv.FormatFloat(x, 'g', -1, 64)
		if math.IsNaN(x) {
			s = "nan"
		} else if math.IsInf(x, 1) {
			s = "inf"
		} else if math.IsInf(x, -1) {
			s = "-inf"
		}
		return map[string]string{"type": "float", "value": s}
	case bool:
		return map[string]string{"type": "bool", "value": strconv.FormatBool(x)}
	case time.Time:
		switch x.Location().String() {
		case "datetime-local":
			return map[string]string{"type": "datetime-local", "value": x.Format("2006-01-02T15:04:05.999999999")}
		case "date-local":
			return map[string]string{"type": "date-local", "value": x.Format("2006-01-02")}
		case "time-local":
			return map[string]string{"type": "time-local", "value": x.Format("15:04:05.999999999")}
		}
		return map[string]string{"type": "datetime", "value": x.Format(time.RFC3339Nano)}
	}
	panic(fmt.Sprintf("unknown type %T", v))
}

const mod int64 = 1000000007

type stats struct{ tables, arrays, keys, strings, ints, floats, bools, boolTrue, datetimes, strBytes, intSum, keyHash, strHash int64 }

func polyHash(s string) int64 {
	var h int64 = 17
	for i := 0; i < len(s); i++ {
		h = (h*131 + int64(s[i])) % mod
	}
	return h
}

func walk(st *stats, v any) {
	switch x := v.(type) {
	case string:
		st.strings++
		st.strBytes += int64(len(x))
		st.strHash = (st.strHash + polyHash(x)) % mod
	case int64:
		st.ints++
		st.intSum = (st.intSum + ((x%mod)+mod)%mod) % mod
	case float64:
		st.floats++
	case bool:
		st.bools++
		if x {
			st.boolTrue++
		}
	case time.Time:
		st.datetimes++
	case []any:
		st.arrays++
		for _, i := range x {
			walk(st, i)
		}
	case []map[string]any:
		st.arrays++
		for _, i := range x {
			walk(st, i)
		}
	case map[string]any:
		st.tables++
		st.keys += int64(len(x))
		ks := make([]string, 0, len(x))
		for k := range x {
			ks = append(ks, k)
		}
		sort.Strings(ks)
		for _, k := range ks {
			st.keyHash = (st.keyHash + polyHash(k)) % mod
			walk(st, x[k])
		}
	}
}

func printStats(n int, st *stats) {
	fmt.Printf("iters=%d\ntables=%d\narrays=%d\nkeys=%d\nstrings=%d\nints=%d\nfloats=%d\nbools=%d\nbool_true=%d\ndatetimes=%d\nstr_bytes=%d\nint_sum=%d\nkey_hash=%d\nstr_hash=%d\n",
		n, st.tables, st.arrays, st.keys, st.strings, st.ints, st.floats, st.bools, st.boolTrue, st.datetimes, st.strBytes, st.intSum, st.keyHash, st.strHash)
}

func main() {
	mode, path := os.Args[1], os.Args[2]
	iters := 1
	if len(os.Args) > 3 {
		iters, _ = strconv.Atoi(os.Args[3])
	}
	data, err := os.ReadFile(path)
	if err != nil {
		os.Exit(2)
	}
	switch mode {
	case "decode", "errpos":
		var v map[string]any
		_, err := toml.Decode(string(data), &v)
		if err != nil {
			line, col, off := 0, 0, 0
			var pe toml.ParseError
			if errors.As(err, &pe) {
				line, col, off = pe.Position.Line, pe.Position.Col, pe.Position.Start
			}
			msg := strings.ReplaceAll(err.Error(), "\n", " ")
			if mode == "decode" {
				fmt.Fprintf(os.Stderr, "ERR %d %d %d %s\n", line, col, off, msg)
				os.Exit(1)
			}
			fmt.Printf("ERR %d %d %d %s\n", line, col, off, msg)
			return
		}
		if mode == "decode" {
			b, _ := json.Marshal(tag(v))
			fmt.Println(string(b))
		} else {
			fmt.Println("OK")
		}
	case "bench-parse":
		var st stats
		for i := 0; i < iters; i++ {
			var v map[string]any
			if _, err := toml.Decode(string(data), &v); err != nil {
				fmt.Println("parse error:", err)
				os.Exit(1)
			}
			walk(&st, v)
		}
		printStats(iters, &st)
	case "bench-many":
		var st stats
		n := 0
		for _, p := range strings.Split(string(data), "\n") {
			if p == "" {
				continue
			}
			b, _ := os.ReadFile(p)
			var v map[string]any
			if _, err := toml.Decode(string(b), &v); err != nil {
				fmt.Println("parse error:", err)
				os.Exit(1)
			}
			walk(&st, v)
			n++
		}
		printStats(n, &st)
	default:
		os.Exit(2)
	}
}
