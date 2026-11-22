// Red-team adversarial benchmark: Go fxamacker/cbor/v2 side.
// usage: go_bench <dec|dupdec|enc_det|enc_ctap2> <file.cbor> <iters>
// Prints "nodes=<n> bytes=<payload bytes>" — byte-identical to the Pion/Rust sides.
package main

import (
	"fmt"
	"math/big"
	"os"
	"strconv"

	"github.com/fxamacker/cbor/v2"
)

func walk(v any, acc *[2]int64) {
	acc[0]++
	switch x := v.(type) {
	case cbor.ByteString:
		acc[1] += int64(len(x))
	case []byte:
		acc[1] += int64(len(x))
	case string:
		acc[1] += int64(len(x))
	case cbor.Tag:
		walk(x.Content, acc)
	case []any:
		for _, e := range x {
			walk(e, acc)
		}
	case map[any]any:
		for k, e := range x {
			walk(k, acc)
			walk(e, acc)
		}
	case uint64, int64, float64, bool, nil, big.Int, *big.Int, cbor.SimpleValue:
	default:
		panic(fmt.Sprintf("unexpected %T", v))
	}
}

func main() {
	mode, path := os.Args[1], os.Args[2]
	iters, _ := strconv.Atoi(os.Args[3])
	data, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}
	do := cbor.DecOptions{}
	if mode == "dupdec" {
		do.DupMapKey = cbor.DupMapKeyEnforcedAPF
	}
	dm, _ := do.DecMode()
	var acc [2]int64
	switch mode {
	case "dec", "dupdec":
		for r := 0; r < iters; r++ {
			var v any
			if err := dm.Unmarshal(data, &v); err != nil {
				fmt.Println("ERR", err)
				os.Exit(2)
			}
			walk(v, &acc)
		}
	default:
		var v any
		if err := dm.Unmarshal(data, &v); err != nil {
			os.Exit(2)
		}
		eo := cbor.CoreDetEncOptions()
		if mode == "enc_ctap2" {
			eo = cbor.CTAP2EncOptions()
		}
		em, _ := eo.EncMode()
		for r := 0; r < iters; r++ {
			b, err := em.Marshal(v)
			if err != nil {
				fmt.Println("ERR", err)
				os.Exit(2)
			}
			acc[1] += int64(len(b))
		}
	}
	fmt.Printf("nodes=%d bytes=%d\n", acc[0], acc[1])
}
