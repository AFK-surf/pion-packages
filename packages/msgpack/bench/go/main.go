package main

import (
	"bytes"
	"fmt"
	"math"
	"os"
	"time"

	"github.com/vmihailenco/msgpack/v5"
)

type walkStats struct {
	nodes    int64
	checksum uint64
}

func walkInt(v int64) walkStats {
	if v >= 0 {
		return walkStats{nodes: 1, checksum: uint64(v) + 1}
	}
	return walkStats{nodes: 1, checksum: (uint64(0) - uint64(v))*3 + 5}
}

func walkValue(v any) walkStats {
	switch x := v.(type) {
	case nil:
		return walkStats{nodes: 1, checksum: 19}
	case bool:
		if x {
			return walkStats{nodes: 1, checksum: 13}
		}
		return walkStats{nodes: 1, checksum: 17}
	case int8:
		return walkInt(int64(x))
	case int16:
		return walkInt(int64(x))
	case int32:
		return walkInt(int64(x))
	case int64:
		return walkInt(x)
	case int:
		return walkInt(int64(x))
	case uint8:
		return walkStats{nodes: 1, checksum: uint64(x) + 1}
	case uint16:
		return walkStats{nodes: 1, checksum: uint64(x) + 1}
	case uint32:
		return walkStats{nodes: 1, checksum: uint64(x) + 1}
	case uint64:
		return walkStats{nodes: 1, checksum: x + 1}
	case float32:
		return walkStats{nodes: 1, checksum: math.Float64bits(float64(x))}
	case float64:
		return walkStats{nodes: 1, checksum: math.Float64bits(x)}
	case string:
		h := uint64(len(x)) * 11
		if len(x) > 0 {
			h += uint64(x[0])
			h += uint64(x[len(x)-1])
		}
		return walkStats{nodes: 1, checksum: h}
	case []byte:
		h := uint64(len(x)) * 7
		if len(x) > 0 {
			h += uint64(x[0])
			h += uint64(x[len(x)-1])
		}
		return walkStats{nodes: 1, checksum: h}
	case time.Time:
		sec := uint64(x.Unix())
		nsec := uint64(x.Nanosecond())
		return walkStats{nodes: 1, checksum: sec*31 + nsec}
	case []any:
		nodes := int64(1)
		sum := uint64(len(x)) * 37
		for _, item := range x {
			sub := walkValue(item)
			nodes += sub.nodes
			sum += sub.checksum
		}
		return walkStats{nodes: nodes, checksum: sum}
	case map[string]any:
		nodes := int64(1)
		sum := uint64(len(x)) * 41
		for k, val := range x {
			sk := walkValue(k)
			sv := walkValue(val)
			nodes += sk.nodes + sv.nodes
			sum += sk.checksum*131 + sv.checksum
		}
		return walkStats{nodes: nodes, checksum: sum}
	case map[any]any:
		nodes := int64(1)
		sum := uint64(len(x)) * 41
		for k, val := range x {
			sk := walkValue(k)
			sv := walkValue(val)
			nodes += sk.nodes + sv.nodes
			sum += sk.checksum*131 + sv.checksum
		}
		return walkStats{nodes: nodes, checksum: sum}
	default:
		panic(fmt.Sprintf("unexpected type %T", v))
	}
}

func runDecode(path string, rounds int) {
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	var totalNodes int64
	var totalChecksum uint64
	for r := 0; r < rounds; r++ {
		var v any
		if err := msgpack.Unmarshal(data, &v); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		st := walkValue(v)
		totalNodes += st.nodes
		totalChecksum += st.checksum
	}
	fmt.Printf("rounds=%d\nbytes=%d\nnodes=%d\nchecksum=%d\n", rounds, len(data), totalNodes, totalChecksum)
}

func runEncodeRPC() {
	const ops = 50000
	regions := [4]string{"ap-northeast-1", "us-east-1", "eu-west-1", "us-west-2"}
	svcs := [16]string{
		"edge-gw-0", "edge-gw-1", "edge-gw-2", "edge-gw-3",
		"edge-gw-4", "edge-gw-5", "edge-gw-6", "edge-gw-7",
		"edge-gw-8", "edge-gw-9", "edge-gw-10", "edge-gw-11",
		"edge-gw-12", "edge-gw-13", "edge-gw-14", "edge-gw-15",
	}
	tags := []string{"prod", "telemetry", "v2", "grpc"}
	payload := make([]byte, 24)
	for p := 0; p < 24; p++ {
		payload[p] = byte((p*13 + 5) & 0xFF)
	}
	var totalBytes int64
	var checksum uint64
	var buf bytes.Buffer
	enc := msgpack.NewEncoder(&buf)
	enc.UseCompactInts(true)
	enc.SetSortMapKeys(true)
	for i := 0; i < ops; i++ {
		i64 := int64(i)
		meta := map[string]any{
			"err":     nil,
			"region":  regions[i&3],
			"retries": uint64(i & 3),
		}
		rec := map[string]any{
			"delta":      -(i64*17 + 1),
			"id":         uint64(1000000 + i64),
			"latency_ms": 1.25 + float64(i%97)*0.25,
			"meta":       meta,
			"ok":         (i % 5) != 0,
			"payload":    payload,
			"svc":        svcs[i&15],
			"tags":       tags,
		}
		buf.Reset()
		if err := enc.Encode(rec); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		b := buf.Bytes()
		n := len(b)
		totalBytes += int64(n)
		checksum += uint64(n)
		checksum += uint64(b[0])
		checksum += uint64(b[n/2])
		checksum += uint64(b[n-1])
	}
	fmt.Printf("ops=%d\ntotal_bytes=%d\nchecksum=%d\n", ops, totalBytes, checksum)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: bench_go <decode-rpc|encode-rpc|decode-large> [path]")
		os.Exit(1)
	}
	switch os.Args[1] {
	case "decode-rpc":
		runDecode(os.Args[2], 40)
	case "encode-rpc":
		runEncodeRPC()
	case "decode-large":
		runDecode(os.Args[2], 4)
	default:
		fmt.Fprintf(os.Stderr, "unknown cmd: %s\n", os.Args[1])
		os.Exit(1)
	}
}
