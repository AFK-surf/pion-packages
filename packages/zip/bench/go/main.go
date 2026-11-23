package main

import (
	"archive/zip"
	"bytes"
	"compress/flate"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"strconv"
)

func main() {
	if len(os.Args) < 4 {
		fmt.Fprintln(os.Stderr, "usage: go_bench <read|write|lookup> <file> <iters>")
		os.Exit(1)
	}
	mode := os.Args[1]
	path := os.Args[2]
	iters, err := strconv.Atoi(os.Args[3])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	switch mode {
	case "read":
		var totalFiles int64
		var totalBytes int64
		var xorCRC uint32
		for it := 0; it < iters; it++ {
			r, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			for _, f := range r.File {
				rc, err := f.Open()
				if err != nil {
					fmt.Fprintln(os.Stderr, err)
					os.Exit(1)
				}
				out, err := io.ReadAll(rc)
				rc.Close()
				if err != nil {
					fmt.Fprintln(os.Stderr, err)
					os.Exit(1)
				}
				totalFiles++
				totalBytes += int64(len(out))
				xorCRC ^= f.CRC32
			}
		}
		fmt.Printf("mode=read files=%d total_bytes=%d xor_crc=%d\n", totalFiles, totalBytes, xorCRC)

	case "write":
		count := int(binary.LittleEndian.Uint32(data[0:4]))
		names := make([]string, count)
		payloads := make([][]byte, count)
		pos := 4
		for i := 0; i < count; i++ {
			nlen := int(binary.LittleEndian.Uint16(data[pos : pos+2]))
			pos += 2
			names[i] = string(data[pos : pos+nlen])
			pos += nlen
			dlen := int(binary.LittleEndian.Uint32(data[pos : pos+4]))
			pos += 4
			payloads[i] = data[pos : pos+dlen]
			pos += dlen
		}

		var lastZip []byte
		for it := 0; it < iters; it++ {
			var buf bytes.Buffer
			zw := zip.NewWriter(&buf)
			zw.RegisterCompressor(zip.Deflate, func(out io.Writer) (io.WriteCloser, error) {
				return flate.NewWriter(out, 6)
			})
			for i := 0; i < count; i++ {
				w, err := zw.Create(names[i])
				if err != nil {
					fmt.Fprintln(os.Stderr, err)
					os.Exit(1)
				}
				if _, err := w.Write(payloads[i]); err != nil {
					fmt.Fprintln(os.Stderr, err)
					os.Exit(1)
				}
			}
			if err := zw.Close(); err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			lastZip = buf.Bytes()
		}
		r, err := zip.NewReader(bytes.NewReader(lastZip), int64(len(lastZip)))
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		var totalUncomp uint64
		var xorCRC uint32
		for _, f := range r.File {
			totalUncomp += f.UncompressedSize64
			xorCRC ^= f.CRC32
		}
		fmt.Printf("mode=write files=%d total_uncomp=%d xor_crc=%d\n", len(r.File), totalUncomp, xorCRC)

	case "lookup":
		queries := make([]string, 20000)
		var rng int64 = 123456789
		for q := 0; q < 20000; q++ {
			rng = (rng*1103515245 + 12345) & 0x7FFFFFFF
			idx := int(rng % 20000)
			queries[q] = fmt.Sprintf("dir_%02d/file_%05d.txt", idx%100, idx)
		}
		var totalLookups int64
		var totalBytes int64
		var acc int64
		for it := 0; it < iters; it++ {
			r, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			for _, q := range queries {
				f, err := r.Open(q)
				if err != nil {
					fmt.Fprintln(os.Stderr, err)
					os.Exit(1)
				}
				b, err := io.ReadAll(f)
				f.Close()
				if err != nil {
					fmt.Fprintln(os.Stderr, err)
					os.Exit(1)
				}
				totalLookups++
				totalBytes += int64(len(b))
				acc += int64(b[6])
			}
		}
		fmt.Printf("mode=lookup lookups=%d total_bytes=%d checksum=%d\n", totalLookups, totalBytes, acc)

	default:
		fmt.Fprintln(os.Stderr, "unknown mode:", mode)
		os.Exit(1)
	}
}
