// Encoder recursion probe, Go side: encode an n-deep nested array; also probe invalid UTF-8 text.
package main

import (
	"encoding/hex"
	"fmt"
	"os"
	"strconv"

	"github.com/fxamacker/cbor/v2"
)

func main() {
	if os.Args[1] == "badutf8" {
		b, err := cbor.Marshal(string([]byte{0xff}))
		fmt.Println(hex.EncodeToString(b), err)
		return
	}
	n, _ := strconv.Atoi(os.Args[1])
	var v any = uint64(0)
	for i := 0; i < n; i++ {
		v = []any{v}
	}
	b, err := cbor.Marshal(v)
	if err != nil {
		fmt.Println("ERR", err)
		return
	}
	fmt.Printf("OK len=%d\n", len(b))
}
