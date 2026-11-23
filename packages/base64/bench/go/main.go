// Head-to-head benchmark for packages/base64: Go standard library
// (encoding/base64, encoding/base32, encoding/hex). Same modes, input
// and stdout as bench/pion_bench.
package main

import (
	"encoding/base32"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"os"
	"strconv"
)

func gen(n int) []byte {
	out := make([]byte, n)
	x := uint32(0x9E3779B9)
	for i := range out {
		x ^= x << 13
		x ^= x >> 17
		x ^= x << 5
		out[i] = byte(x)
	}
	return out
}

func fnv1a(b []byte) uint64 {
	h := uint64(14695981039346656037)
	for _, c := range b {
		h = (h ^ uint64(c)) * 1099511628211
	}
	return h
}

func encode(mode string, data []byte) string {
	switch mode {
	case "b64_encode", "b64_decode":
		return base64.StdEncoding.EncodeToString(data)
	case "url_encode", "url_decode":
		return base64.RawURLEncoding.EncodeToString(data)
	case "b32_encode", "b32_decode":
		return base32.StdEncoding.EncodeToString(data)
	default:
		return hex.EncodeToString(data)
	}
}

func decode(mode string, s string) ([]byte, error) {
	switch mode {
	case "b64_decode":
		return base64.StdEncoding.Strict().DecodeString(s)
	case "url_decode":
		return base64.RawURLEncoding.Strict().DecodeString(s)
	case "b32_decode":
		return base32.StdEncoding.DecodeString(s)
	default:
		return hex.DecodeString(s)
	}
}

func main() {
	if len(os.Args) < 2 {
		fmt.Println("usage: base64_bench <mode> [size_bytes] [rounds]")
		os.Exit(2)
	}
	mode := os.Args[1]
	size, rounds := 4194304, 16
	if len(os.Args) > 2 {
		size, _ = strconv.Atoi(os.Args[2])
	}
	if len(os.Args) > 3 {
		rounds, _ = strconv.Atoi(os.Args[3])
	}
	data := gen(size)
	sample, outLen := 0, 0
	var last []byte
	switch mode {
	case "b64_encode", "url_encode", "b32_encode", "hex_encode":
		for r := 0; r < rounds; r++ {
			s := encode(mode, data)
			outLen = len(s)
			sample += int(s[r*7919%outLen])
			if r == rounds-1 {
				last = []byte(s)
			}
		}
	default:
		text := encode(mode, data)
		for r := 0; r < rounds; r++ {
			b, err := decode(mode, text)
			if err != nil {
				fmt.Println("decode error:", err)
				os.Exit(1)
			}
			outLen = len(b)
			sample += int(b[r*7919%outLen])
			if r == rounds-1 {
				last = b
			}
		}
	}
	fmt.Printf("mode=%s\ninput_bytes=%d\nrounds=%d\noutput_bytes=%d\nsample=%d\nfnv1a64=%d\n",
		mode, size, rounds, outLen, sample, fnv1a(last))
}
