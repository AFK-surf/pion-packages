package main

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"fmt"
	"hash/adler32"
	"hash/crc32"
	"io"
	"os"
	"strconv"
)

func main() {
	if len(os.Args) < 4 {
		fmt.Fprintln(os.Stderr, "usage: flate_bench <decompress|compress6|compress1|checksum> <file> <iters> [dump_path]")
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
	case "decompress":
		var lastOut []byte
		var totalBytes int64
		for i := 0; i < iters; i++ {
			gr, err := gzip.NewReader(bytes.NewReader(data))
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			out, err := io.ReadAll(gr)
			_ = gr.Close()
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			totalBytes += int64(len(out))
			lastOut = out
		}
		w := bufio.NewWriter(os.Stdout)
		fmt.Fprintf(w, "total_bytes=%d\n", totalBytes)
		_, _ = w.Write(lastOut)
		_ = w.WriteByte('\n')
		_ = w.Flush()

	case "compress6", "compress1":
		lvl := 6
		if mode == "compress1" {
			lvl = 1
		}
		var lastGz []byte
		for i := 0; i < iters; i++ {
			var buf bytes.Buffer
			buf.Grow(len(data) / 2)
			gw, err := gzip.NewWriterLevel(&buf, lvl)
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			if _, err := gw.Write(data); err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			if err := gw.Close(); err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			lastGz = buf.Bytes()
		}
		if len(os.Args) >= 5 {
			if err := os.WriteFile(os.Args[4], lastGz, 0644); err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
		}
		fmt.Printf("mode=%s input_bytes=%d iters=%d\n", mode, len(data), iters)

	case "checksum":
		var c uint32
		a := adler32.New()
		for i := 0; i < iters; i++ {
			c = crc32.Update(c, crc32.IEEETable, data)
			_, _ = a.Write(data)
		}
		fmt.Printf("crc32=%d\n", int64(c))
		fmt.Printf("adler32=%d\n", int64(a.Sum32()))

	default:
		fmt.Fprintf(os.Stderr, "unknown mode: %s\n", mode)
		os.Exit(1)
	}
}
