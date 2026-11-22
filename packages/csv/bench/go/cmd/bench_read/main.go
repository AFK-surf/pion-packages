package main

import (
	"encoding/csv"
	"fmt"
	"io"
	"os"
	"strings"
)

func main() {
	path := "/tmp/pion-csv-bench/mixed_200k.csv"
	if len(os.Args) > 1 {
		path = os.Args[1]
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, "failed to read input file:", err)
		os.Exit(1)
	}
	content := string(raw)

	var totalRecords int64
	var totalFields int64
	var totalBytes int64
	var hash int64
	var firstSample string
	var lastSample string

	for round := 0; round < 2; round++ {
		r := csv.NewReader(strings.NewReader(content))
		r.ReuseRecord = true
		// Skip header row to match has_headers=true in Pion and Rust
		if _, err := r.Read(); err != nil {
			fmt.Fprintln(os.Stderr, "header error:", err)
			os.Exit(1)
		}
		for {
			rec, err := r.Read()
			if err == io.EOF {
				break
			}
			if err != nil {
				fmt.Fprintln(os.Stderr, "parse error:", err)
				os.Exit(1)
			}
			totalRecords++
			totalFields += int64(len(rec))
			for _, f := range rec {
				totalBytes += int64(len(f))
				for j := 0; j < len(f); j++ {
					hash = (hash*131 + int64(f[j])) & 0x7FFFFFFF
				}
			}
			if totalRecords == 1 {
				firstSample = rec[0] + "|" + rec[3] + "|" + rec[7]
			}
			if totalRecords == 400000 {
				lastSample = rec[0] + "|" + rec[3] + "|" + rec[7]
			}
		}
	}

	fmt.Printf("records=%d\n", totalRecords)
	fmt.Printf("fields=%d\n", totalFields)
	fmt.Printf("bytes=%d\n", totalBytes)
	fmt.Printf("hash=%d\n", hash)
	fmt.Printf("first=%s\n", firstSample)
	fmt.Printf("last=%s\n", lastSample)
}
