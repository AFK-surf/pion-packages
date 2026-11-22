package main

import (
	"archive/tar"
	"bytes"
	"fmt"
	"io"
	"os"
)

func fnv1aBytes(h uint64, b []byte) uint64 {
	for _, c := range b {
		h = (h ^ uint64(c)) * 1099511628211
	}
	return h
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: go_read <corpus.tar>")
		os.Exit(1)
	}
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	const rounds = 20
	var totalEntries int64
	var totalNameBytes int64
	var totalPayloadBytes int64
	var checksum uint64 = 14695981039346656037
	buf := make([]byte, 0, 8192)

	for r := 0; r < rounds; r++ {
		tr := tar.NewReader(bytes.NewReader(data))
		for {
			hdr, err := tr.Next()
			if err == io.EOF {
				break
			}
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(2)
			}
			totalEntries++
			nb := []byte(hdr.Name)
			totalNameBytes += int64(len(nb))
			checksum = fnv1aBytes(checksum, nb)
			checksum = (checksum ^ uint64(hdr.Size)) * 1099511628211
			checksum = (checksum ^ uint64(hdr.Typeflag)) * 1099511628211

			buf = buf[:0]
			if hdr.Size > 0 {
				if cap(buf) < int(hdr.Size) {
					buf = make([]byte, int(hdr.Size))
				} else {
					buf = buf[:int(hdr.Size)]
				}
				if _, err := io.ReadFull(tr, buf); err != nil {
					fmt.Fprintln(os.Stderr, err)
					os.Exit(3)
				}
				totalPayloadBytes += int64(len(buf))
				checksum = fnv1aBytes(checksum, buf)
			}
		}
	}

	fmt.Printf("rounds=%d\n", rounds)
	fmt.Printf("entries=%d\n", totalEntries)
	fmt.Printf("name_bytes=%d\n", totalNameBytes)
	fmt.Printf("payload_bytes=%d\n", totalPayloadBytes)
	fmt.Printf("checksum=%d\n", checksum)
}
