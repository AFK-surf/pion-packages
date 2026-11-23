package main

import (
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
)

func runFindIter(data string, iters int) {
	pat := `(?:ERROR|WARN) \[[a-z0-9_-]+\] req_id=[0-9a-f]{8,16}|https?://[A-Za-z0-9._/-]+`
	re := regexp.MustCompile(pat)
	var totalMatches int64
	var checksum int64
	for it := 0; it < iters; it++ {
		locs := re.FindAllStringIndex(data, -1)
		for _, loc := range locs {
			totalMatches++
			checksum = (checksum*131 + int64(loc[0]) + int64(loc[1])*7) % 1000000007
		}
	}
	fmt.Println("mode=find_iter")
	fmt.Printf("iters=%d\n", iters)
	fmt.Printf("matches=%d\n", totalMatches)
	fmt.Printf("checksum=%d\n", checksum)
}

func runCapturesIter(data string, iters int) {
	pat := `([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z) (INFO|WARN|ERROR) \[([a-z0-9_-]+)\] req_id=([0-9a-f]+) path=[^ ]+ status=([0-9]{3}) latency=([0-9]+)ms`
	re := regexp.MustCompile(pat)
	var totalMatches int64
	var checksum int64
	for it := 0; it < iters; it++ {
		all := re.FindAllStringSubmatchIndex(data, -1)
		for _, sub := range all {
			totalMatches++
			for g := 1; g <= 6; g++ {
				s := sub[g*2]
				e := sub[g*2+1]
				checksum = (checksum*131 + int64(e-s) + int64(s)) % 1000000007
			}
		}
	}
	fmt.Println("mode=captures_iter")
	fmt.Printf("iters=%d\n", iters)
	fmt.Printf("matches=%d\n", totalMatches)
	fmt.Printf("checksum=%d\n", checksum)
}

func runRegexSet(data string, iters int) {
	rules := []string{
		"ERROR",
		"FATAL",
		"status=50[0-9]",
		"status=429",
		"latency=[5-9][0-9]{2}ms",
		"latency=[0-9]{4,}ms",
		"timeout",
		"connection refused",
		"SELECT .* FROM",
		`\.\./\.\./`,
		"OOMKilled",
		"panic:",
		"tls: handshake",
		"rate_limit",
		"^2026-11-23T00:",
		`\[auth-api\]`,
	}
	compiled := make([]*regexp.Regexp, len(rules))
	for i, r := range rules {
		compiled[i] = regexp.MustCompile(r)
	}
	rawLines := strings.Split(data, "\n")
	lines := make([]string, 0, len(rawLines))
	for _, l := range rawLines {
		if len(l) > 0 {
			lines = append(lines, l)
		}
	}
	var matchedLines int64
	var totalHits int64
	var checksum int64
	for it := 0; it < iters; it++ {
		for _, line := range lines {
			anyHit := false
			for idx, re := range compiled {
				if re.MatchString(line) {
					anyHit = true
					totalHits++
					checksum = (checksum*131 + int64(idx+1)) % 1000000007
				}
			}
			if anyHit {
				matchedLines++
			}
		}
	}
	fmt.Println("mode=regex_set")
	fmt.Printf("rules=%d\n", len(rules))
	fmt.Printf("lines=%d\n", len(lines))
	fmt.Printf("iters=%d\n", iters)
	fmt.Printf("matched_lines=%d\n", matchedLines)
	fmt.Printf("total_hits=%d\n", totalHits)
	fmt.Printf("checksum=%d\n", checksum)
}

func runRedos(iters int) {
	re1 := regexp.MustCompile(strings.Repeat("a?", 40) + strings.Repeat("a", 40))
	re2 := regexp.MustCompile(`(a+)+$`)
	re3 := regexp.MustCompile(`(a|aa)+$`)
	re4 := regexp.MustCompile(`^([a-zA-Z]+)*$`)

	sA40 := strings.Repeat("a", 40)
	sA39 := strings.Repeat("a", 39)
	sEvilB := strings.Repeat("a", 4000) + "b"
	sEvilBang := strings.Repeat("a", 4000) + "!"

	var hits int64
	for it := 0; it < iters; it++ {
		if re1.MatchString(sA40) {
			hits += 1
		}
		if re1.MatchString(sA39) {
			hits += 10
		}
		if re2.MatchString(sEvilB) {
			hits += 100
		}
		if re3.MatchString(sEvilB) {
			hits += 1000
		}
		if re4.MatchString(sEvilBang) {
			hits += 10000
		}
	}
	fmt.Println("mode=redos")
	fmt.Printf("iters=%d\n", iters)
	fmt.Printf("hits=%d\n", hits)
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: go_regexp <mode> <data_file> [iters]")
		os.Exit(1)
	}
	mode := os.Args[1]
	dataFile := os.Args[2]
	iters := 5
	if len(os.Args) > 3 {
		if v, err := strconv.Atoi(os.Args[3]); err == nil && v > 0 {
			iters = v
		}
	}
	if mode == "redos" {
		runRedos(iters)
		return
	}
	raw, err := os.ReadFile(dataFile)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	data := string(raw)
	switch mode {
	case "find_iter":
		runFindIter(data, iters)
	case "captures_iter":
		runCapturesIter(data, iters)
	case "regex_set":
		runRegexSet(data, iters)
	default:
		fmt.Fprintf(os.Stderr, "unknown mode: %s\n", mode)
		os.Exit(1)
	}
}
