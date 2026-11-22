package main

import (
	"fmt"
	"os"
	"strings"
	"time"
)

func main() {
	path := "/tmp/time-bench-rfc3339.txt"
	if len(os.Args) > 1 {
		path = os.Args[1]
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "read error: %v\n", err)
		os.Exit(1)
	}
	content := string(raw)
	jst := time.FixedZone("JST", 9*3600)

	var count int64
	var totalBytes int64
	var hash int64
	var sumSecs int64
	var sumNanos int64
	var firstOut string
	var lastOut string

	for _, line := range strings.Split(content, "\n") {
		if len(line) == 0 {
			continue
		}
		t, err := time.Parse(time.RFC3339Nano, line)
		if err != nil {
			fmt.Fprintf(os.Stderr, "parse error: %v\n", err)
			os.Exit(1)
		}
		out := t.In(jst).Format(time.RFC3339Nano)
		if count == 0 {
			firstOut = out
		}
		lastOut = out
		count++
		totalBytes += int64(len(out))
		sumSecs += t.Unix()
		sumNanos += int64(t.Nanosecond())
		for i := 0; i < len(out); i++ {
			hash = (hash*131 + int64(out[i])) % 1000000007
		}
	}

	fmt.Printf("count=%d\n", count)
	fmt.Printf("total_bytes=%d\n", totalBytes)
	fmt.Printf("hash=%d\n", hash)
	fmt.Printf("sum_secs=%d\n", sumSecs)
	fmt.Printf("sum_nanos=%d\n", sumNanos)
	fmt.Printf("first=%s\n", firstOut)
	fmt.Printf("last=%s\n", lastOut)
}
