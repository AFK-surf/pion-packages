// Fairness re-check of packages/msgpack/bench (workloads 1 and 2) with idiomatic Go: typed structs
// with msgpack tags instead of `any` / map[string]any + SetSortMapKeys. stdout is byte-identical to
// packages/msgpack/bench/go (same nodes/checksum formula, same encoded bytes), so
// scripts/bench_compare.py's SHA-256 check still applies.
//
//	go_bench_struct decode-rpc <rpc_2000.msgpack>   (40 rounds)
//	go_bench_struct encode-rpc                      (50,000 records)
package main

import (
	"bytes"
	"fmt"
	"math"
	"os"
	"time"

	"github.com/vmihailenco/msgpack/v5"
)

type Meta struct {
	Err     any    `msgpack:"err"`
	Region  string `msgpack:"region"`
	Retries uint64 `msgpack:"retries"`
}

type Rec struct {
	Delta     int64     `msgpack:"delta"`
	ID        uint64    `msgpack:"id"`
	LatencyMs float64   `msgpack:"latency_ms"`
	Meta      Meta      `msgpack:"meta"`
	Ok        bool      `msgpack:"ok"`
	Payload   []byte    `msgpack:"payload"`
	Svc       string    `msgpack:"svc"`
	Tags      []string  `msgpack:"tags"`
	Ts        time.Time `msgpack:"ts"`
}

// EncRec is the 8-field record of workload 2 (no ts), fields in sorted key order.
type EncRec struct {
	Delta     int64    `msgpack:"delta"`
	ID        uint64   `msgpack:"id"`
	LatencyMs float64  `msgpack:"latency_ms"`
	Meta      Meta     `msgpack:"meta"`
	Ok        bool     `msgpack:"ok"`
	Payload   []byte   `msgpack:"payload"`
	Svc       string   `msgpack:"svc"`
	Tags      []string `msgpack:"tags"`
}

func cStr(s string) uint64 {
	h := uint64(len(s)) * 11
	if len(s) > 0 {
		h += uint64(s[0]) + uint64(s[len(s)-1])
	}
	return h
}

func cBin(b []byte) uint64 {
	h := uint64(len(b)) * 7
	if len(b) > 0 {
		h += uint64(b[0]) + uint64(b[len(b)-1])
	}
	return h
}

func cInt(v int64) uint64 {
	if v >= 0 {
		return uint64(v) + 1
	}
	return (uint64(0)-uint64(v))*3 + 5
}

func kv(k string, v uint64) uint64 { return cStr(k)*131 + v }

func recSum(r *Rec) (int64, uint64) {
	ok := uint64(17)
	if r.Ok {
		ok = 13
	}
	meta := uint64(3)*41 + kv("err", 19) + kv("region", cStr(r.Meta.Region)) + kv("retries", r.Meta.Retries+1)
	tags := uint64(len(r.Tags)) * 37
	for _, t := range r.Tags {
		tags += cStr(t)
	}
	sum := uint64(9)*41 + kv("delta", cInt(r.Delta)) + kv("id", r.ID+1) +
		kv("latency_ms", math.Float64bits(r.LatencyMs)) + kv("meta", meta) + kv("ok", ok) +
		kv("payload", cBin(r.Payload)) + kv("svc", cStr(r.Svc)) + kv("tags", tags) +
		kv("ts", uint64(r.Ts.Unix())*31+uint64(r.Ts.Nanosecond()))
	nodes := int64(1 + 18 + 6 + 4) // map + 9 pairs + meta pairs + tags items
	return nodes, sum
}

func decodeRPC(path string) {
	data, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}
	const rounds = 40
	var nodes int64
	var sum uint64
	for r := 0; r < rounds; r++ {
		var recs []Rec
		if err := msgpack.Unmarshal(data, &recs); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		n, s := int64(1), uint64(len(recs))*37
		for i := range recs {
			rn, rs := recSum(&recs[i])
			n += rn
			s += rs
		}
		nodes += n
		sum += s
	}
	fmt.Printf("rounds=%d\nbytes=%d\nnodes=%d\nchecksum=%d\n", rounds, len(data), nodes, sum)
}

func encodeRPC() {
	const ops = 50000
	regions := [4]string{"ap-northeast-1", "us-east-1", "eu-west-1", "us-west-2"}
	svcs := [16]string{}
	for i := range svcs {
		svcs[i] = fmt.Sprintf("edge-gw-%d", i)
	}
	tags := []string{"prod", "telemetry", "v2", "grpc"}
	payload := make([]byte, 24)
	for p := range payload {
		payload[p] = byte((p*13 + 5) & 0xFF)
	}
	var total int64
	var checksum uint64
	var buf bytes.Buffer
	enc := msgpack.NewEncoder(&buf)
	enc.UseCompactInts(true)
	for i := 0; i < ops; i++ {
		i64 := int64(i)
		rec := EncRec{
			Delta: -(i64*17 + 1), ID: uint64(1000000 + i64), LatencyMs: 1.25 + float64(i%97)*0.25,
			Meta: Meta{Err: nil, Region: regions[i&3], Retries: uint64(i & 3)},
			Ok:   (i % 5) != 0, Payload: payload, Svc: svcs[i&15], Tags: tags,
		}
		buf.Reset()
		if err := enc.Encode(&rec); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		b := buf.Bytes()
		n := len(b)
		total += int64(n)
		checksum += uint64(n) + uint64(b[0]) + uint64(b[n/2]) + uint64(b[n-1])
	}
	fmt.Printf("ops=%d\ntotal_bytes=%d\nchecksum=%d\n", ops, total, checksum)
}

func main() {
	switch os.Args[1] {
	case "decode-rpc":
		decodeRPC(os.Args[2])
	case "encode-rpc":
		encodeRPC()
	}
}
