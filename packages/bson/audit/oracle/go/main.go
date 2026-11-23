// Red-team differential oracle: Go go.mongodb.org/mongo-driver/v2/bson.
// Same line protocol as the Rust oracle (B / J / D / X).
package main

import (
	"bufio"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"os"
	"strings"

	"go.mongodb.org/mongo-driver/v2/bson"
)

func clean(s string) string { return strings.NewReplacer("\t", " ", "\n", " ", "\r", " ").Replace(s) }

func op(kind, arg string) (res string) {
	defer func() {
		if r := recover(); r != nil {
			res = "PANIC"
		}
	}()
	raw, _ := hex.DecodeString(arg)
	switch kind {
	case "B":
		if err := bson.Raw(raw).Validate(); err != nil {
			return "ERR\t" + clean(err.Error())
		}
		var d bson.D
		if err := bson.Unmarshal(raw, &d); err != nil {
			return "ERR\t" + clean(err.Error())
		}
		re, err := bson.Marshal(d)
		reh := hex.EncodeToString(re)
		if err != nil {
			reh = "ENCERR:" + clean(err.Error())
		}
		c, err1 := bson.MarshalExtJSON(bson.Raw(raw), true, false)
		r, err2 := bson.MarshalExtJSON(bson.Raw(raw), false, false)
		if err1 != nil || err2 != nil {
			return "ERR\textjson: " + clean(fmt.Sprint(err1, err2))
		}
		return "OK\t" + reh + "\t" + string(c) + "\t" + string(r)
	case "J":
		var d bson.D
		if err := bson.UnmarshalExtJSON(raw, false, &d); err != nil {
			return "ERR\t" + clean(err.Error())
		}
		b, err := bson.Marshal(d)
		if err != nil {
			return "ERR\tencode: " + clean(err.Error())
		}
		return "OK\t" + hex.EncodeToString(b)
	case "D":
		d, err := bson.ParseDecimal128(string(raw))
		if err != nil {
			return "ERR\t" + clean(err.Error())
		}
		h, l := d.GetBytes()
		b := make([]byte, 16)
		binary.LittleEndian.PutUint64(b[0:], l)
		binary.LittleEndian.PutUint64(b[8:], h)
		return "OK\t" + hex.EncodeToString(b) + "\t" + d.String()
	case "X":
		l := binary.LittleEndian.Uint64(raw[0:])
		h := binary.LittleEndian.Uint64(raw[8:])
		return "OK\t" + bson.NewDecimal128(h, l).String()
	}
	return "ERR\tbad op"
}

func main() {
	f, err := os.Open(os.Args[1])
	if err != nil {
		panic(err)
	}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64<<20), 64<<20)
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	for sc.Scan() {
		k, a, _ := strings.Cut(sc.Text(), "\t")
		fmt.Fprintln(w, op(k, a))
	}
}
