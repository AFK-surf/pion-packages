package main

import (
	"fmt"
	"math"
	"os"

	"github.com/fxamacker/cbor/v2"
)

func walkValue(v any) (int64, uint64) {
	switch x := v.(type) {
	case uint64:
		return 1, x + 1
	case int64:
		if x >= 0 {
			return 1, uint64(x) + 1
		}
		// CBOR Negative(n) represents -1 - n, so n + 1 = -x
		return 1, uint64(-x) * 3
	case []byte:
		h := uint64(len(x)) * 7
		if len(x) > 0 {
			h += uint64(x[0]) + uint64(x[len(x)-1])
		}
		return 1, h
	case string:
		return 1, uint64(len(x)) * 11
	case bool:
		if x {
			return 1, 13
		}
		return 1, 17
	case nil:
		return 1, 19
	case float64:
		return 1, math.Float64bits(x)
	case float32:
		return 1, math.Float64bits(float64(x))
	case cbor.Tag:
		sn, sc := walkValue(x.Content)
		return 1 + sn, x.Number*31 + sc
	case []any:
		nodes := int64(1)
		sum := uint64(len(x)) * 37
		for _, elem := range x {
			sn, sc := walkValue(elem)
			nodes += sn
			sum += sc
		}
		return nodes, sum
	case map[any]any:
		nodes := int64(1)
		sum := uint64(len(x)) * 41
		for k, val := range x {
			kn, kc := walkValue(k)
			vn, vc := walkValue(val)
			nodes += kn + vn
			sum += kc + vc
		}
		return nodes, sum
	default:
		panic(fmt.Sprintf("unexpected type %T", v))
	}
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: go_decode <corpus.cbor>")
		os.Exit(1)
	}
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	const rounds = 40
	var totalNodes int64
	var totalChecksum uint64
	for r := 0; r < rounds; r++ {
		var v any
		if err := cbor.Unmarshal(data, &v); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		n, c := walkValue(v)
		totalNodes += n
		totalChecksum += c
	}

	fmt.Printf("rounds=%d\nbytes=%d\nnodes=%d\nchecksum=%d\n", rounds, len(data), totalNodes, totalChecksum)
}
