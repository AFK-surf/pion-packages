package main

import (
	"fmt"
	"os"

	"github.com/fxamacker/cbor/v2"
)

func makeBytes(length int, seed int) []byte {
	b := make([]byte, length)
	for i := 0; i < length; i++ {
		b[i] = byte((seed*31 + i*17 + 7) & 0xFF)
	}
	return b
}

func fnv1aUpdate(h uint64, data []byte) uint64 {
	acc := h
	for _, b := range data {
		acc = (acc ^ uint64(b)) * 1099511628211
	}
	return acc
}

func main() {
	const ops = 50000
	em, err := cbor.CoreDetEncOptions().EncMode()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	var totalBytes int64
	var hash uint64 = 14695981039346656037

	for i := 0; i < ops; i++ {
		authData := makeBytes(37, i)
		sig := makeBytes(64, i+1)
		xCoord := makeBytes(32, i+2)
		yCoord := makeBytes(32, i+3)

		coseKey := map[int64]any{
			1:  uint64(2),
			3:  int64(-7),
			-1: uint64(1),
			-2: xCoord,
			-3: yCoord,
		}
		attStmt := map[string]any{
			"alg": int64(-7),
			"sig": sig,
		}
		telemetry := map[string]any{
			"ok":         i%2 == 0,
			"seq":        uint64(i),
			"tags":       []string{"tokyo", "arm64", "cbor"},
			"latency_ms": float64(12.3),
		}
		record := map[string]any{
			"fmt":       "packed",
			"coseKey":   coseKey,
			"attStmt":   attStmt,
			"authData":  authData,
			"telemetry": telemetry,
		}

		encoded, err := em.Marshal(record)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		totalBytes += int64(len(encoded))
		hash = fnv1aUpdate(hash, encoded)
	}

	fmt.Printf("ops=%d\ntotal_bytes=%d\nfnv1a=%d\n", ops, totalBytes, hash)
}
