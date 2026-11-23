// Go 1.27 archive/zip reference for the packages/zip red-team audit.
// Modes: batch <cases.bin> | file <zip> | paths <names.bin> | verify <zip>
package main

import (
	"archive/zip"
	"bytes"
	"compress/flate"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"hash/crc32"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
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

func line(data []byte) string {
	r, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil && err != zip.ErrInsecurePath {
		return "ERR " + strings.ReplaceAll(err.Error(), " ", "_")
	}
	var sb strings.Builder
	fmt.Fprintf(&sb, "OK n=%d", len(r.File))
	for _, f := range r.File {
		fmt.Fprintf(&sb, " |%s:", hex.EncodeToString([]byte(f.Name)))
		rc, err := f.Open()
		if err != nil {
			sb.WriteString("ERR:open")
			continue
		}
		b, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			sb.WriteString("ERR:read")
			continue
		}
		fmt.Fprintf(&sb, "OK:%d:%d", len(b), crc32.ChecksumIEEE(b))
	}
	return sb.String()
}

// verify: full metadata dump of an archive written by Pion.
func verify(data []byte) {
	r, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil && err != zip.ErrInsecurePath {
		fmt.Println("ERR", err)
		return
	}
	fmt.Printf("OK n=%d comment_len=%d\n", len(r.File), len(r.Comment))
	for _, f := range r.File {
		rc, err := f.Open()
		res := ""
		if err != nil {
			res = "ERR:" + err.Error()
		} else {
			b, err := io.ReadAll(rc)
			rc.Close()
			if err != nil {
				res = "ERR:" + err.Error()
			} else {
				res = fmt.Sprintf("OK:%d:%d", len(b), crc32.ChecksumIEEE(b))
			}
		}
		n := f.Name
		if len(n) > 64 {
			n = fmt.Sprintf("%s...(%d)", n[:16], len(n))
		}
		fmt.Printf("E %q method=%d mtime=%s mode=%v %s\n", n, f.Method, f.Modified.UTC().Format("2006-01-02T15:04:05"), f.Mode(), res)
	}
}

func main() {
	if len(os.Args) < 3 {
		os.Exit(2)
	}
	data, err := os.ReadFile(os.Args[2])
	if err != nil {
		os.Exit(3)
	}
	w := bytes.Buffer{}
	switch os.Args[1] {
	case "batch":
		for _, rec := range records(data) {
			w.WriteString(line(rec))
			w.WriteByte('\n')
		}
	case "file":
		w.WriteString(line(data) + "\n")
	case "prof":
		prof(data)
	case "verify":
		verify(data)
	case "paths":
		for _, rec := range records(data) {
			s := string(rec)
			// Go's own definition of "safe to extract" (archive/zip ErrInsecurePath uses filepath.IsLocal).
			if filepath.IsLocal(s) && !strings.Contains(s, `\`) {
				w.WriteString("OK\n")
			} else {
				w.WriteString("ERR\n")
			}
		}
	}
	os.Stdout.Write(w.Bytes())
}

// prof: W1/W2 component costs on the bench corpus zip (same breakdown as the Pion `prof` mode).
func prof(data []byte) {
	r, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		panic(err)
	}
	var comp [][]byte
	for _, f := range r.File {
		off, _ := f.DataOffset()
		comp = append(comp, data[off:off+int64(f.CompressedSize64)])
	}
	const iters = 5
	var outs [][]byte
	t0 := time.Now()
	for it := 0; it < iters; it++ {
		for _, c := range comp {
			b, _ := io.ReadAll(flate.NewReader(bytes.NewReader(c)))
			if it == 0 {
				outs = append(outs, b)
			}
		}
	}
	t1 := time.Now()
	var x uint32
	for it := 0; it < iters; it++ {
		for _, o := range outs {
			x ^= crc32.ChecksumIEEE(o)
		}
	}
	t2 := time.Now()
	for it := 0; it < iters; it++ {
		for _, f := range r.File {
			rc, _ := f.Open()
			io.Copy(io.Discard, rc)
			rc.Close()
		}
	}
	t3 := time.Now()
	for it := 0; it < iters; it++ {
		for _, o := range outs {
			var b bytes.Buffer
			w, _ := flate.NewWriter(&b, 6)
			w.Write(o)
			w.Close()
		}
	}
	t4 := time.Now()
	l6 := 0
	for _, o := range outs {
		var b bytes.Buffer
		w, _ := flate.NewWriter(&b, 6)
		w.Write(o)
		w.Close()
		l6 += b.Len()
	}
	ms := func(a, b time.Time) int64 { return b.Sub(a).Milliseconds() }
	fmt.Printf("read_inflate_only_ms %d\nread_crc32_only_ms %d\nread_entry_full_ms %d\nwrite_deflate_l6_only_ms %d\nwrite_deflate_l6_bytes %d\nchecksum %d\n", ms(t0, t1), ms(t1, t2), ms(t2, t3), ms(t3, t4), l6, x)
}
