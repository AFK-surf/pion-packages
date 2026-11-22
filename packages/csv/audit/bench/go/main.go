// Adversarial read benchmark (Go encoding/csv side). Usage: go_adv <mode> FILE
// Modes as bench/pion_adv. Go has no full trim: trim_comment applies strings.TrimSpace per field,
// which equals Rust/Pion ASCII trimming on this ASCII-padded corpus.
package main

import (
	"bytes"
	"encoding/csv"
	"fmt"
	"io"
	"os"
	"strings"
)

func main() {
	mode, path := os.Args[1], os.Args[2]
	raw, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}
	r := csv.NewReader(bytes.NewReader(raw))
	r.ReuseRecord = true
	r.FieldsPerRecord = -1
	switch mode {
	case "semicolon":
		r.Comma = ';'
	case "trim_comment":
		r.Comment = '#'
	}
	if mode == "escape" {
		fmt.Println("unsupported: encoding/csv has no escape character")
		os.Exit(3)
	}
	if mode == "read_all" {
		r.ReuseRecord = false
		all, err := r.ReadAll()
		if err != nil {
			panic(err)
		}
		var records, fields, total, hash int64
		for _, rec := range all[1:] {
			records++
			fields += int64(len(rec))
			for _, f := range rec {
				total += int64(len(f))
				for j := 0; j < len(f); j++ {
					hash = (hash*131 + int64(f[j])) & 0x7FFFFFFF
				}
			}
		}
		fmt.Printf("records=%d\nfields=%d\nbytes=%d\nhash=%d\n", records, fields, total, hash)
		return
	}
	if _, err := r.Read(); err != nil { // header row (has_headers = true elsewhere)
		panic(err)
	}
	var records, fields, total, hash int64
	for {
		rec, err := r.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			fmt.Println("parse error:", err)
			os.Exit(1)
		}
		records++
		fields += int64(len(rec))
		for _, f := range rec {
			if mode == "trim_comment" {
				f = strings.TrimSpace(f)
			}
			total += int64(len(f))
			for j := 0; j < len(f); j++ {
				hash = (hash*131 + int64(f[j])) & 0x7FFFFFFF
			}
		}
	}
	fmt.Printf("records=%d\nfields=%d\nbytes=%d\nhash=%d\n", records, fields, total, hash)
}
