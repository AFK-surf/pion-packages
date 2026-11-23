// Differential oracle: Go robfig/cron/v3 v3.0.1 (5-field standard parser, or 6-field with
// seconds for opts "sec"/"q"; no year field, no Quartz L/W/#, no backward search, 5-year lookahead).
// Input lines: opts<TAB>expr<TAB>start_unix<TAB>n. Output: "ERR" | "OK m=- N <next chain>".
package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/robfig/cron/v3"
)

func unescape(s string) string {
	r := strings.NewReplacer(`\t`, "\t", `\n`, "\n", `\r`, "\r", `\\`, `\`)
	return r.Replace(s)
}

// bench runs the same workloads / output as the Pion probe's bench-step / bench-parse.
func bench(mode, path string, steps, rounds int) {
	data, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}
	std := cron.NewParser(cron.Minute | cron.Hour | cron.Dom | cron.Month | cron.Dow | cron.Descriptor)
	sec := cron.NewParser(cron.SecondOptional | cron.Minute | cron.Hour | cron.Dom | cron.Month | cron.Dow | cron.Descriptor)
	type tc struct {
		p    cron.Parser
		expr string
	}
	var cases []tc
	for _, line := range strings.Split(string(data), "\n") {
		if line == "" {
			continue
		}
		f := strings.Split(line, "\t")
		p := sec
		if f[0] == "std" {
			p = std
		}
		cases = append(cases, tc{p, unescape(f[1])})
	}
	base := time.Unix(1704067200, 0).UTC()
	var ops, errs, sum, xor int64
	if mode == "bench-step" {
		var compiled []cron.Schedule
		for _, c := range cases {
			s, err := c.p.Parse(c.expr)
			if err != nil {
				panic(err)
			}
			compiled = append(compiled, s)
		}
		for r := 0; r < rounds; r++ {
			for _, s := range compiled {
				cur := base
				for k := 0; k < steps; k++ {
					n := s.Next(cur)
					if n.IsZero() {
						errs++
						break
					}
					ts := n.Unix()
					sum += ts
					xor ^= ts
					cur = n
					ops++
				}
			}
		}
	} else {
		for r := 0; r < rounds; r++ {
			for _, c := range cases {
				s, err := c.p.Parse(c.expr)
				if err != nil {
					errs++
					continue
				}
				ops++
				if r == rounds-1 {
					if n := s.Next(base); !n.IsZero() {
						sum += n.Unix()
						xor ^= n.Unix()
					}
				}
			}
		}
	}
	fmt.Printf("ops=%d\nnone_or_err=%d\nsum=%d\nxor=%d\n", ops, errs, sum, xor)
}

func main() {
	if os.Args[1] == "bench-step" {
		st, _ := strconv.Atoi(os.Args[3])
		rd, _ := strconv.Atoi(os.Args[4])
		bench(os.Args[1], os.Args[2], st, rd)
		return
	}
	if os.Args[1] == "bench-parse" {
		rd, _ := strconv.Atoi(os.Args[3])
		bench(os.Args[1], os.Args[2], 0, rd)
		return
	}
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}
	std := cron.NewParser(cron.Minute | cron.Hour | cron.Dom | cron.Month | cron.Dow | cron.Descriptor)
	sec := cron.NewParser(cron.SecondOptional | cron.Minute | cron.Hour | cron.Dom | cron.Month | cron.Dow | cron.Descriptor)
	w := bufio.NewWriterSize(os.Stdout, 1<<20)
	defer w.Flush()
	for _, line := range strings.Split(string(data), "\n") {
		if line == "" {
			continue
		}
		f := strings.Split(line, "\t")
		p := sec
		if f[0] == "std" {
			p = std
		}
		if f[0] == "and" {
			fmt.Fprintln(w, "SKIP")
			continue
		}
		var sched cron.Schedule
		func() {
			defer func() { recover() }()
			sched, err = p.Parse(unescape(f[1]))
		}()
		if err != nil || sched == nil {
			fmt.Fprintln(w, "ERR")
			continue
		}
		ts, _ := strconv.ParseInt(f[2], 10, 64)
		n, _ := strconv.Atoi(f[3])
		cur := time.Unix(ts, 0).UTC()
		var sb strings.Builder
		sb.WriteString("OK m=- N")
		for i := 0; i < n; i++ {
			nx := sched.Next(cur)
			if nx.IsZero() {
				sb.WriteString(" -")
				break
			}
			sb.WriteString(" " + strconv.FormatInt(nx.Unix(), 10))
			cur = nx
		}
		fmt.Fprintln(w, sb.String())
	}
}
