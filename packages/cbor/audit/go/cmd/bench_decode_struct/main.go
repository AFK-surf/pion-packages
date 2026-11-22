// Fairness check for packages/cbor/bench (workload 2): decode the same 2,000-record corpus
// 40x with fxamacker/cbor/v2 into typed structs (the idiomatic WebAuthn/COSE path) instead of
// map[any]any, then compute the exact same nodes/checksum as the generic tree walk, so stdout
// is byte-identical to bench_decode and it is a drop-in --impl for scripts/bench_compare.py.
package main

import (
	"fmt"
	"math"
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

func bsum(b []byte) uint64 {
	h := uint64(len(b)) * 7
	if len(b) > 0 {
		h += uint64(b[0]) + uint64(b[len(b)-1])
	}
	return h
}

func txt(s string) uint64 { return uint64(len(s)) * 11 }

func neg(x int64) uint64 { return uint64(-x) * 3 }

// Same formulas as walk_value in bench/pion_decode (map: len*41, array: len*37, ...).
func recordSum(r *record) (int64, uint64) {
	c := &r.CoseKey
	cose := 5*41 + (1 + 1) + (c.Kty + 1) + (3 + 1) + neg(c.Alg) + 3 + (c.Crv + 1) + 6 + bsum(c.X) + 9 + bsum(c.Y)
	att := 2*41 + txt("alg") + neg(r.AttStmt.Alg) + txt("sig") + bsum(r.AttStmt.Sig)
	t := &r.Telemetry
	okv := uint64(17)
	if t.Ok {
		okv = 13
	}
	tags := uint64(len(t.Tags)) * 37
	for _, s := range t.Tags {
		tags += txt(s)
	}
	tel := 4*41 + txt("ok") + okv + txt("seq") + (t.Seq + 1) + txt("tags") + tags + txt("latency_ms") + math.Float64bits(t.LatencyMs)
	sum := 5*41 + txt("fmt") + txt(r.Fmt) + txt("coseKey") + cose + txt("attStmt") + att +
		txt("authData") + bsum(r.AuthData) + txt("telemetry") + tel
	nodes := int64(1 + 5 + 1 + 11 + 5 + 1 + (1 + 4 + 1 + 1 + 1 + int64(len(t.Tags)) + 1))
	return nodes, sum
}

func main() {
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	const rounds = 40
	var totalNodes int64
	var totalChecksum uint64
	for r := 0; r < rounds; r++ {
		var recs []record
		if err := cbor.Unmarshal(data, &recs); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		totalNodes++
		totalChecksum += uint64(len(recs)) * 37
		for i := range recs {
			n, c := recordSum(&recs[i])
			totalNodes += n
			totalChecksum += c
		}
	}
	fmt.Printf("rounds=%d\nbytes=%d\nnodes=%d\nchecksum=%d\n", rounds, len(data), totalNodes, totalChecksum)
}
