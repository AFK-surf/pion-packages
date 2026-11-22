// Fairness check for packages/cbor/bench (workload 1): the same 50k WebAuthn/COSE + Telemetry
// records encoded with fxamacker/cbor/v2 the idiomatic way (typed structs, `keyasint`) instead
// of map[string]any + reflection on every key. Output is byte-identical to bench_encode
// (same ops / total_bytes / fnv1a), so it is a drop-in --impl for scripts/bench_compare.py.
package main

import (
	"fmt"
	"os"

	"github.com/fxamacker/cbor/v2"
)

type coseKey struct {
	Kty uint64 `cbor:"1,keyasint"`
	Alg int64  `cbor:"3,keyasint"`
	Crv uint64 `cbor:"-1,keyasint"`
	X   []byte `cbor:"-2,keyasint"`
	Y   []byte `cbor:"-3,keyasint"`
}

type attStmt struct {
	Alg int64  `cbor:"alg"`
	Sig []byte `cbor:"sig"`
}

type telemetry struct {
	Ok        bool     `cbor:"ok"`
	Seq       uint64   `cbor:"seq"`
	Tags      []string `cbor:"tags"`
	LatencyMs float64  `cbor:"latency_ms"`
}

type record struct {
	Fmt       string    `cbor:"fmt"`
	CoseKey   coseKey   `cbor:"coseKey"`
	AttStmt   attStmt   `cbor:"attStmt"`
	AuthData  []byte    `cbor:"authData"`
	Telemetry telemetry `cbor:"telemetry"`
}

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
	tags := []string{"tokyo", "arm64", "cbor"}
	for i := 0; i < ops; i++ {
		r := record{
			Fmt:       "packed",
			CoseKey:   coseKey{Kty: 2, Alg: -7, Crv: 1, X: makeBytes(32, i+2), Y: makeBytes(32, i+3)},
			AttStmt:   attStmt{Alg: -7, Sig: makeBytes(64, i+1)},
			AuthData:  makeBytes(37, i),
			Telemetry: telemetry{Ok: i%2 == 0, Seq: uint64(i), Tags: tags, LatencyMs: 12.3},
		}
		encoded, err := em.Marshal(&r)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		totalBytes += int64(len(encoded))
		hash = fnv1aUpdate(hash, encoded)
	}
	fmt.Printf("ops=%d\ntotal_bytes=%d\nfnv1a=%d\n", ops, totalBytes, hash)
}
