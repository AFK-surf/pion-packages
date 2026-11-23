// Adversarial benchmark, Go vmihailenco/msgpack/v5 v5.4.1. Output is byte-identical to
// `pion_probe bench` and `rust_probe bench` (nodes / payload_bytes) so bench_compare.py can verify.
//
//	go_bench <dec|dupdec|prefix> <file> <iters>
//
// dec    : msgpack.Unmarshal into `any` (the library's generic path, same as packages/msgpack/bench/go)
// dupdec : dec + idiomatic duplicate-key rejection with a Go map (randomized hash) per msgpack map
// prefix : streaming msgpack.NewDecoder(bytes.Reader) loop, one Decode per concatenated frame
package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"strconv"
	"time"

	"github.com/vmihailenco/msgpack/v5"
)

type acc struct{ nodes, payload int64 }

func keyOf(k any) any {
	switch x := k.(type) {
	case int8:
		return int64(x)
	case int16:
		return int64(x)
	case int32:
		return int64(x)
	case uint8:
		return int64(x)
	case uint16:
		return int64(x)
	case uint32:
		return int64(x)
	case uint64:
		if x <= 1<<63-1 {
			return int64(x)
		}
		return x
	case []byte:
		return "b" + string(x)
	case string:
		return "s" + x
	}
	return fmt.Sprintf("%T:%v", k, k)
}

func (a *acc) walk(v any) {
	a.nodes++
	switch x := v.(type) {
	case string:
		a.payload += int64(len(x))
	case []byte:
		a.payload += int64(len(x))
	case time.Time:
	case []any:
		for _, it := range x {
			a.walk(it)
		}
	case map[string]any:
		for k, it := range x {
			a.walk(k)
			a.walk(it)
		}
	case map[any]any:
		for k, it := range x {
			a.walk(k)
			a.walk(it)
		}
	}
}

// decodeOrdered keeps every pair (Go maps would silently drop duplicates) so dup detection is real.
func decodeDup(d *msgpack.Decoder, a *acc) error {
	c, err := d.PeekCode()
	if err != nil {
		return err
	}
	if (c >= 0x80 && c <= 0x8f) || c == 0xde || c == 0xdf {
		n, err := d.DecodeMapLen()
		if err != nil {
			return err
		}
		a.nodes++
		seen := make(map[any]struct{}, n)
		for i := 0; i < n; i++ {
			k, err := d.DecodeInterface()
			if err != nil {
				return err
			}
			kk := keyOf(k)
			if _, dup := seen[kk]; dup {
				return fmt.Errorf("duplicate map key")
			}
			seen[kk] = struct{}{}
			a.walk(k)
			if err := decodeDup(d, a); err != nil {
				return err
			}
		}
		return nil
	}
	if (c >= 0x90 && c <= 0x9f) || c == 0xdc || c == 0xdd {
		n, err := d.DecodeArrayLen()
		if err != nil {
			return err
		}
		a.nodes++
		for i := 0; i < n; i++ {
			if err := decodeDup(d, a); err != nil {
				return err
			}
		}
		return nil
	}
	v, err := d.DecodeInterface()
	if err != nil {
		return err
	}
	a.walk(v)
	return nil
}

func main() {
	mode, path := os.Args[1], os.Args[2]
	iters, _ := strconv.Atoi(os.Args[3])
	data, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}
	var a acc
	for r := 0; r < iters; r++ {
		switch mode {
		case "dec":
			var v any
			if err := msgpack.Unmarshal(data, &v); err != nil {
				fmt.Println("ERR", err)
				os.Exit(2)
			}
			a.walk(v)
		case "dupdec":
			if err := decodeDup(msgpack.NewDecoder(bytes.NewReader(data)), &a); err != nil {
				fmt.Println("ERR", err)
				os.Exit(2)
			}
		case "prefix":
			d := msgpack.NewDecoder(bytes.NewReader(data))
			for {
				var v any
				err := d.Decode(&v)
				if err == io.EOF {
					break
				}
				if err != nil {
					fmt.Println("ERR", err)
					os.Exit(2)
				}
				a.walk(v)
			}
		}
	}
	fmt.Printf("nodes=%d\npayload_bytes=%d\n", a.nodes, a.payload)
}
