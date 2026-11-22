// Red-team differential probe: Go fxamacker/cbor/v2 side.
// usage: go_probe <mode> <file-of-hex-lines>   (same protocol as the Pion probe)
package main

import (
	"bufio"
	"encoding/hex"
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/fxamacker/cbor/v2"
)

func main() {
	mode := os.Args[1]
	f, err := os.Open(os.Args[2])
	if err != nil {
		panic(err)
	}
	dopts := cbor.DecOptions{}
	switch {
	case mode == "dup":
		dopts.DupMapKey = cbor.DupMapKeyEnforcedAPF
	case mode == "strict":
		dopts.DupMapKey = cbor.DupMapKeyEnforcedAPF
		dopts.IndefLength = cbor.IndefLengthForbidden
	case strings.HasPrefix(mode, "depth="):
		n, _ := strconv.Atoi(mode[6:])
		dopts.MaxNestedLevels = n
	}
	dm, err := dopts.DecMode()
	if err != nil {
		fmt.Println("BADOPT", err)
		os.Exit(3)
	}
	var eo cbor.EncOptions
	switch mode {
	case "enc_ctap2":
		eo = cbor.CTAP2EncOptions()
	default:
		eo = cbor.CoreDetEncOptions()
	}
	em, _ := eo.EncMode()
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<30)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		in, err := hex.DecodeString(line)
		if err != nil {
			panic(err)
		}
		var v any
		if err := dm.Unmarshal(in, &v); err != nil {
			fmt.Fprintln(w, "ERR", err)
			continue
		}
		out, err := em.Marshal(v)
		if err != nil {
			fmt.Fprintln(w, "ENCERR", err)
			continue
		}
		fmt.Fprintln(w, "OK", hex.EncodeToString(out))
	}
}
