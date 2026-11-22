// W4: RFC 9110 HTTP-date parse (net/http.ParseTime) + format (http.TimeFormat).
package main

import (
	"fmt"
	"net/http"
	"os"
	"strings"
)

func main() {
	raw, _ := os.ReadFile(os.Args[1])
	var count, hash, sumSecs int64
	for _, line := range strings.Split(string(raw), "\n") {
		if line == "" {
			continue
		}
		t, err := http.ParseTime(line)
		if err != nil {
			fmt.Println("parse error:", line)
			os.Exit(1)
		}
		out := t.UTC().Format(http.TimeFormat)
		for i := 0; i < len(out); i++ {
			hash = (hash*131 + int64(out[i])) % 1000000007
		}
		sumSecs += t.Unix()
		count++
	}
	fmt.Printf("count=%d\nhash=%d\nsum_secs=%d\n", count, hash, sumSecs)
}
