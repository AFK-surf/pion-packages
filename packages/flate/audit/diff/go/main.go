// Go compress/{flate,zlib,gzip} reference side of the flate red-team differential harness.
// Protocol is identical to `audit/src/main.pion` (batch / compress / file / cfile).
package main

import (
	"bytes"
	"compress/flate"
	"compress/gzip"
	"compress/zlib"
	"encoding/binary"
	"fmt"
	"hash/crc32"
	"io"
	"os"
	"strconv"
	"strings"
	"bufio"
)

func records(b []byte) [][]byte {
	var out [][]byte
	for p := 0; p+4 <= len(b); {
		n := int(binary.LittleEndian.Uint32(b[p:]))
		p += 4
		out = append(out, b[p:p+n])
		p += n
	}
	return out
}

func decode(op string, data []byte, limit int64) ([]byte, error) {
	var r io.Reader
	var err error
	switch op {
	case "inflate":
		r = flate.NewReader(bytes.NewReader(data))
	case "zlib":
		r, err = zlib.NewReader(bytes.NewReader(data))
	default:
		r, err = gzip.NewReader(bytes.NewReader(data))
	}
	if err != nil {
		return nil, err
	}
	out, err := io.ReadAll(io.LimitReader(r, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(out)) > limit {
		return nil, fmt.Errorf("OutputLimitExceeded")
	}
	return out, nil
}

func line(out []byte, err error) string {
	if err != nil {
		return "ERR " + strings.ReplaceAll(err.Error(), " ", "_")
	}
	return fmt.Sprintf("OK %d %d", len(out), crc32.ChecksumIEEE(out))
}

func compress(level int, data []byte) []byte {
	var buf bytes.Buffer
	w, err := flate.NewWriter(&buf, level)
	if err != nil {
		panic(err)
	}
	w.Write(data)
	w.Close()
	return buf.Bytes()
}

// adlerUpdate continues an Adler-32 state (hash/adler32 has no Update with seed).
func adlerUpdate(adler uint32, p []byte) uint32 {
	s1, s2 := adler&0xffff, adler>>16
	for len(p) > 0 {
		n := len(p)
		if n > 5552 {
			n = 5552
		}
		for _, x := range p[:n] {
			s1 += uint32(x)
			s2 += s1
		}
		s1 %= 65521
		s2 %= 65521
		p = p[n:]
	}
	return s2<<16 | s1
}

func main() {
	a := os.Args
	switch a[1] {
	case "batch":
		data, _ := os.ReadFile(a[3])
		limit := int64(16777216)
		if len(a) >= 5 {
			limit, _ = strconv.ParseInt(a[4], 10, 64)
		}
		w := bufio.NewWriter(os.Stdout)
		for _, rec := range records(data) {
			fmt.Fprintln(w, line(decode(a[2], rec, limit)))
		}
		w.Flush()
	case "compress":
		lvl, _ := strconv.Atoi(a[2])
		data, _ := os.ReadFile(a[3])
		var buf bytes.Buffer
		for _, rec := range records(data) {
			c := compress(lvl, rec)
			var l [4]byte
			binary.LittleEndian.PutUint32(l[:], uint32(len(c)))
			buf.Write(l[:])
			buf.Write(c)
		}
		os.WriteFile(a[4], buf.Bytes(), 0o644)
	case "file":
		data, _ := os.ReadFile(a[3])
		limit := int64(268435456)
		if len(a) >= 5 {
			limit, _ = strconv.ParseInt(a[4], 10, 64)
		}
		out, err := decode(a[2], data, limit)
		fmt.Println(line(out, err))
	case "bench":
		data, _ := os.ReadFile(a[3])
		iters, _ := strconv.Atoi(a[4])
		op := a[2]
		var last []byte
		var c, ad uint32 = 0, 1
		for i := 0; i < iters; i++ {
			switch op {
			case "d":
				zr, err := gzip.NewReader(bytes.NewReader(data))
				if err != nil {
					os.Exit(1)
				}
				last, err = io.ReadAll(zr)
				if err != nil {
					os.Exit(1)
				}
			case "crc":
				c = crc32.Update(c, crc32.IEEETable, data)
				ad = adlerUpdate(ad, data)
			default:
				lvl, _ := strconv.Atoi(op)
				var buf bytes.Buffer
				w, _ := gzip.NewWriterLevel(&buf, lvl)
				w.Write(data)
				w.Close()
				last = buf.Bytes()
			}
		}
		switch op {
		case "d":
			fmt.Printf("OK %d %d\n", len(last), crc32.ChecksumIEEE(last))
		case "crc":
			fmt.Printf("OK %d %d\n", c, ad)
		default:
			zr, _ := gzip.NewReader(bytes.NewReader(last))
			out, _ := io.ReadAll(zr)
			fmt.Printf("OK %d %d\n", len(out), crc32.ChecksumIEEE(out))
		}
	case "cfile":
		lvl, _ := strconv.Atoi(a[2])
		data, _ := os.ReadFile(a[3])
		c := compress(lvl, data)
		if len(a) >= 5 {
			os.WriteFile(a[4], c, 0o644)
		}
		fmt.Printf("OK %d\n", len(c))
	}
}
