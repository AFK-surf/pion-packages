package main

import (
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/robfig/cron/v3"
)

func readLines(path string) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "read error: %v\n", err)
		os.Exit(1)
	}
	raw := strings.Split(string(data), "\n")
	out := make([]string, 0, len(raw))
	for _, line := range raw {
		if len(line) > 0 {
			out = append(out, line)
		}
	}
	return out
}

func benchParse(exprs []string) {
	parser := cron.NewParser(cron.Minute | cron.Hour | cron.Dom | cron.Month | cron.Dow)
	base := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
	rounds := 1000
	var okCount int64
	var sumSecs int64
	var xorSecs int64
	for r := 0; r < rounds; r++ {
		for _, expr := range exprs {
			sched, err := parser.Parse(expr)
			if err != nil {
				fmt.Fprintf(os.Stderr, "parse error %q: %v\n", expr, err)
				os.Exit(1)
			}
			okCount++
			if r == rounds-1 {
				nxt := sched.Next(base)
				ts := nxt.Unix()
				sumSecs += ts
				xorSecs ^= ts
			}
		}
	}
	fmt.Println("mode=parse")
	fmt.Printf("ops=%d\n", okCount)
	fmt.Printf("sum_secs=%d\n", sumSecs)
	fmt.Printf("xor_secs=%d\n", xorSecs)
}

func benchNext(exprs []string) {
	parser := cron.NewParser(cron.Minute | cron.Hour | cron.Dom | cron.Month | cron.Dow)
	base := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
	compiled := make([]cron.Schedule, 0, len(exprs))
	for _, expr := range exprs {
		sched, err := parser.Parse(expr)
		if err != nil {
			fmt.Fprintf(os.Stderr, "parse error %q: %v\n", expr, err)
			os.Exit(1)
		}
		compiled = append(compiled, sched)
	}
	rounds := 20
	steps := 50
	var totalOps int64
	var sumSecs int64
	var xorSecs int64
	for r := 0; r < rounds; r++ {
		for _, sched := range compiled {
			cur := base
			for k := 0; k < steps; k++ {
				nxt := sched.Next(cur)
				ts := nxt.Unix()
				sumSecs += ts
				xorSecs ^= ts
				cur = nxt
				totalOps++
			}
		}
	}
	fmt.Println("mode=next")
	fmt.Printf("ops=%d\n", totalOps)
	fmt.Printf("sum_secs=%d\n", sumSecs)
	fmt.Printf("xor_secs=%d\n", xorSecs)
}

func benchSparse() {
	parser := cron.NewParser(cron.Minute | cron.Hour | cron.Dom | cron.Month | cron.Dow)
	base := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
	rareExprs := []string{
		"0 0 29 2 *",
		"0 0 31 12 *",
		"0 0 30 4 *",
		"0 0 1 1 *",
		"0 0 31 1,3,5,7,8,10,12 *",
	}
	compiled := make([]cron.Schedule, 0, len(rareExprs))
	for _, expr := range rareExprs {
		sched, err := parser.Parse(expr)
		if err != nil {
			fmt.Fprintf(os.Stderr, "parse error %q: %v\n", expr, err)
			os.Exit(1)
		}
		compiled = append(compiled, sched)
	}
	rounds := 125
	steps := 16
	var totalOps int64
	var sumSecs int64
	var xorSecs int64
	for r := 0; r < rounds; r++ {
		for _, sched := range compiled {
			cur := base
			for k := 0; k < steps; k++ {
				nxt := sched.Next(cur)
				ts := nxt.Unix()
				sumSecs += ts
				xorSecs ^= ts
				cur = nxt
				totalOps++
			}
		}
	}
	fmt.Println("mode=sparse")
	fmt.Printf("ops=%d\n", totalOps)
	fmt.Printf("sum_secs=%d\n", sumSecs)
	fmt.Printf("xor_secs=%d\n", xorSecs)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: cron_bench_go <parse|next|sparse> [exprs_file]")
		os.Exit(1)
	}
	switch os.Args[1] {
	case "sparse":
		benchSparse()
	case "parse":
		path := "/private/tmp/pion-cron-bench/exprs_100.txt"
		if len(os.Args) > 2 {
			path = os.Args[2]
		}
		benchParse(readLines(path))
	case "next":
		path := "/private/tmp/pion-cron-bench/exprs_100.txt"
		if len(os.Args) > 2 {
			path = os.Args[2]
		}
		benchNext(readLines(path))
	default:
		fmt.Fprintf(os.Stderr, "unknown mode: %s\n", os.Args[1])
		os.Exit(1)
	}
}
