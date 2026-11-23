package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"unicode/utf16"
)

type w1Stats struct {
	objects  int64
	arrays   int64
	strings  int64
	ints     int64
	floats   int64
	bools    int64
	nulls    int64
	intSum   int64
	strBytes int64
}

func fnv1aBytes(b []byte) uint64 {
	var h uint64 = 14695981039346656037
	for _, c := range b {
		h = (h ^ uint64(c)) * 1099511628211
	}
	return h
}

func decodeUseNumber(data []byte) (any, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, err
	}
	return v, nil
}

func walkW1(st *w1Stats, root any) {
	stack := []any{root}
	for len(stack) > 0 {
		v := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		switch x := v.(type) {
		case nil:
			st.nulls++
		case bool:
			st.bools++
		case json.Number:
			s := string(x)
			if !strings.ContainsAny(s, ".eE") {
				st.ints++
				if iv, err := x.Int64(); err == nil {
					st.intSum += iv % 1000003
				}
			} else {
				st.floats++
			}
		case string:
			st.strings++
			st.strBytes += int64(len(x))
		case []any:
			st.arrays++
			for _, item := range x {
				stack = append(stack, item)
			}
		case map[string]any:
			st.objects++
			for _, child := range x {
				stack = append(stack, child)
			}
		}
	}
}

func runW1(path string, iters int) int {
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "read error: %v\n", err)
		return 1
	}
	var st w1Stats
	for i := 0; i < iters; i++ {
		v, err := decodeUseNumber(data)
		if err != nil {
			fmt.Fprintf(os.Stderr, "parse error: %v\n", err)
			return 2
		}
		walkW1(&st, v)
	}
	fmt.Printf(
		"w1 objects=%d arrays=%d strings=%d ints=%d floats=%d bools=%d nulls=%d int_sum=%d str_bytes=%d\n",
		st.objects, st.arrays, st.strings, st.ints, st.floats, st.bools, st.nulls, st.intSum, st.strBytes,
	)
	return 0
}

type w2Item struct {
	ID        int64   `json:"id"`
	Login     string  `json:"login"`
	Processed bool    `json:"processed"`
	Score     float64 `json:"score"`
	Tag       string  `json:"tag"`
}

type w2Out struct {
	Count int      `json:"count"`
	Items []w2Item `json:"items"`
}

func runW2(path string, iters int) int {
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "read error: %v\n", err)
		return 1
	}
	var totalBytes int64
	var keptTotal int64
	var lastHash uint64
	for i := 0; i < iters; i++ {
		v, err := decodeUseNumber(data)
		if err != nil {
			fmt.Fprintf(os.Stderr, "parse error: %v\n", err)
			return 2
		}
		root := v.(map[string]any)
		recs := root["records"].([]any)
		items := make([]w2Item, 0, len(recs)/2+1)
		for _, raw := range recs {
			r := raw.(map[string]any)
			active, _ := r["active"].(bool)
			if !active {
				continue
			}
			idNum := r["id"].(json.Number)
			idVal, _ := idNum.Int64()
			scoreNum := r["score"].(json.Number)
			scoreVal, _ := scoreNum.Float64()
			actor := r["actor"].(map[string]any)
			login, _ := actor["login"].(string)
			payload := r["payload"].(map[string]any)
			tags := payload["tags"].([]any)
			tag0, _ := tags[0].(string)
			items = append(items, w2Item{
				ID:        idVal,
				Login:     login,
				Processed: true,
				Score:     scoreVal,
				Tag:       tag0,
			})
			keptTotal++
		}
		var buf bytes.Buffer
		enc := json.NewEncoder(&buf)
		enc.SetEscapeHTML(false)
		if err := enc.Encode(w2Out{Count: len(items), Items: items}); err != nil {
			fmt.Fprintf(os.Stderr, "encode error: %v\n", err)
			return 3
		}
		out := bytes.TrimSuffix(buf.Bytes(), []byte("\n"))
		totalBytes += int64(len(out))
		lastHash = fnv1aBytes(out)
	}
	fmt.Printf("w2 kept=%d total_bytes=%d hash=%d\n", keptTotal, totalBytes, lastHash)
	return 0
}

func lessUTF16(a, b string) bool {
	ua := utf16.Encode([]rune(a))
	ub := utf16.Encode([]rune(b))
	n := len(ua)
	if len(ub) < n {
		n = len(ub)
	}
	for i := 0; i < n; i++ {
		if ua[i] != ub[i] {
			return ua[i] < ub[i]
		}
	}
	return len(ua) < len(ub)
}

func makeW3Key(kIdx int) string {
	if kIdx%500 == 0 {
		return fmt.Sprintf("k_%05d_😀", kIdx)
	} else if kIdx%500 == 1 {
		return fmt.Sprintf("k_%05d_דּ", kIdx)
	}
	return fmt.Sprintf("field_%05d", kIdx)
}

func runW3(path string, iters int) int {
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "read error: %v\n", err)
		return 1
	}
	var lookupSum int64
	var canonBytes int64
	var lastHash uint64
	for i := 0; i < iters; i++ {
		v, err := decodeUseNumber(data)
		if err != nil {
			fmt.Fprintf(os.Stderr, "parse error: %v\n", err)
			return 2
		}
		obj := v.(map[string]any)
		n := len(obj)
		for q := 0; q < n; q++ {
			kIdx := (q*7919 + 13) % n
			k := makeW3Key(kIdx)
			val, ok := obj[k]
			if !ok {
				fmt.Fprintf(os.Stderr, "missing key %s\n", k)
				return 3
			}
			iv, _ := val.(json.Number).Int64()
			lookupSum += iv % 1000003
		}
		keys := make([]string, 0, n)
		for k := range obj {
			keys = append(keys, k)
		}
		sort.Slice(keys, func(a, b int) bool {
			return lessUTF16(keys[a], keys[b])
		})
		var buf bytes.Buffer
		buf.Grow(len(data))
		buf.WriteByte('{')
		for idx, k := range keys {
			if idx > 0 {
				buf.WriteByte(',')
			}
			kb, _ := json.Marshal(k)
			buf.Write(kb)
			buf.WriteByte(':')
			iv, _ := obj[k].(json.Number).Int64()
			if iv >= -9007199254740991 && iv <= 9007199254740991 {
				buf.WriteString(strconv.FormatInt(iv, 10))
			} else {
				buf.WriteString(strconv.FormatFloat(float64(iv), 'f', 0, 64))
			}
		}
		buf.WriteByte('}')
		out := buf.Bytes()
		canonBytes += int64(len(out))
		lastHash = fnv1aBytes(out)
	}
	fmt.Printf("w3 lookup_sum=%d canon_bytes=%d hash=%d\n", lookupSum, canonBytes, lastHash)
	return 0
}

func main() {
	if len(os.Args) < 4 {
		fmt.Fprintln(os.Stderr, "usage: json_bench_go <w1|w2|w3> <file> <iters>")
		os.Exit(1)
	}
	iters, err := strconv.Atoi(os.Args[3])
	if err != nil {
		fmt.Fprintf(os.Stderr, "invalid iters: %v\n", err)
		os.Exit(1)
	}
	var rc int
	switch os.Args[1] {
	case "w1":
		rc = runW1(os.Args[2], iters)
	case "w2":
		rc = runW2(os.Args[2], iters)
	case "w3":
		rc = runW3(os.Args[2], iters)
	default:
		fmt.Fprintf(os.Stderr, "unknown mode: %s\n", os.Args[1])
		rc = 1
	}
	os.Exit(rc)
}
