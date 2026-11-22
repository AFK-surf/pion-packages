package main

import (
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/BurntSushi/toml"
)

const mod int64 = 1000000007

type stats struct {
	tables    int64
	arrays    int64
	keys      int64
	strings   int64
	ints      int64
	floats    int64
	bools     int64
	boolTrue  int64
	datetimes int64
	strBytes  int64
	intSum    int64
	keyHash   int64
	strHash   int64
}

func polyHash(s string) int64 {
	var h int64 = 17
	for i := 0; i < len(s); i++ {
		h = (h*131 + int64(s[i])) % mod
	}
	return h
}

func walkVal(st *stats, v any) {
	switch x := v.(type) {
	case string:
		st.strings++
		st.strBytes += int64(len(x))
		st.strHash = (st.strHash + polyHash(x)) % mod
	case int64:
		st.ints++
		m := ((x % mod) + mod) % mod
		st.intSum = (st.intSum + m) % mod
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
		for _, item := range x {
			walkVal(st, item)
		}
	case []map[string]any:
		st.arrays++
		for _, item := range x {
			walkVal(st, item)
		}
	case map[string]any:
		st.tables++
		st.keys += int64(len(x))
		for k, child := range x {
			st.keyHash = (st.keyHash + polyHash(k)) % mod
			walkVal(st, child)
		}
	}
}

func main() {
	path := "/tmp/pion-toml-bench/corpus.toml"
	iters := 40
	if len(os.Args) > 1 {
		path = os.Args[1]
	}
	if len(os.Args) > 2 {
		if n, err := strconv.Atoi(os.Args[2]); err == nil {
			iters = n
		}
	}
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, "failed to read input:", err)
		os.Exit(1)
	}
	content := string(data)
	var st stats
	for i := 0; i < iters; i++ {
		var parsed map[string]any
		if _, err := toml.Decode(content, &parsed); err != nil {
			fmt.Fprintln(os.Stderr, "parse error:", err)
			os.Exit(1)
		}
		walkVal(&st, parsed)
	}
	fmt.Printf("iters=%d\n", iters)
	fmt.Printf("tables=%d\n", st.tables)
	fmt.Printf("arrays=%d\n", st.arrays)
	fmt.Printf("keys=%d\n", st.keys)
	fmt.Printf("strings=%d\n", st.strings)
	fmt.Printf("ints=%d\n", st.ints)
	fmt.Printf("floats=%d\n", st.floats)
	fmt.Printf("bools=%d\n", st.bools)
	fmt.Printf("bool_true=%d\n", st.boolTrue)
	fmt.Printf("datetimes=%d\n", st.datetimes)
	fmt.Printf("str_bytes=%d\n", st.strBytes)
	fmt.Printf("int_sum=%d\n", st.intSum)
	fmt.Printf("key_hash=%d\n", st.keyHash)
	fmt.Printf("str_hash=%d\n", st.strHash)
}
