// Go oracle for the packages/promql red-team audit.
//
// Reference: github.com/prometheus/prometheus v0.302.1 (Prometheus 3.2.1):
//   - promql/parser.ParseExpr + Expr.String() + parser.Prettify (parse mode)
//   - promql.Engine over an in-memory TSDB head (eval mode)
//
// parser.EnableExperimentalFunctions is switched on because packages/promql
// advertises limitk / limit_ratio / mad_over_time / double_exponential_smoothing.
//
// usage:
//
//	oracle parse <file>   lines "<id>\t<hex query>"
//	    -> "<id>\tERR" | "<id>\tOK\t<type>\t<hex String()>\t<rt>\t<hex Prettify()>"
//	       rt = 1 when ParseExpr(String()) re-formats to the same string (0 marks an
//	       upstream formatter quirk; such format diffs are reported but not counted)
//	oracle eval <file>    same eval script format as the Pion probe
package main

import (
	"bufio"
	"context"
	"encoding/hex"
	"fmt"
	"math"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/prometheus/prometheus/model/labels"
	"github.com/prometheus/prometheus/promql"
	"github.com/prometheus/prometheus/promql/parser"
	"github.com/prometheus/prometheus/util/teststorage"
)

func typeName(t parser.ValueType) string {
	switch t {
	case parser.ValueTypeScalar:
		return "scalar"
	case parser.ValueTypeVector:
		return "instant vector"
	case parser.ValueTypeMatrix:
		return "range vector"
	case parser.ValueTypeString:
		return "string"
	}
	return "none"
}

func readLines(path string) []string {
	f, err := os.Open(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	defer f.Close()
	var out []string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<26)
	for sc.Scan() {
		out = append(out, sc.Text())
	}
	return out
}

func unhex(s string) string {
	b, err := hex.DecodeString(s)
	if err != nil {
		return ""
	}
	return string(b)
}

func runParse(path string, w *bufio.Writer) {
	for _, line := range readLines(path) {
		if line == "" {
			continue
		}
		cols := strings.Split(line, "\t")
		if len(cols) < 2 {
			continue
		}
		q := unhex(cols[1])
		e, err := parser.ParseExpr(q)
		if err != nil {
			fmt.Fprintf(w, "%s\tERR\n", cols[0])
			continue
		}
		str := e.String()
		rt := "0"
		if e2, err := parser.ParseExpr(str); err == nil && e2.String() == str {
			rt = "1"
		}
		fmt.Fprintf(w, "%s\tOK\t%s\t%s\t%s\t%s\n", cols[0], typeName(e.Type()),
			hex.EncodeToString([]byte(str)), rt, hex.EncodeToString([]byte(parser.Prettify(e))))
	}
}

func fmtF(v float64) string {
	switch {
	case math.IsNaN(v):
		return "NaN"
	case math.IsInf(v, 1):
		return "+Inf"
	case math.IsInf(v, -1):
		return "-Inf"
	}
	return strconv.FormatFloat(v, 'g', -1, 64)
}

var valueEscaper = strings.NewReplacer("\\", "\\\\", "\"", "\\\"", "\n", "\\n")

func fmtLabels(ls labels.Labels) string {
	var sb strings.Builder
	sb.WriteString("{")
	i := 0
	ls.Range(func(l labels.Label) {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(l.Name + "=\"" + valueEscaper.Replace(l.Value) + "\"")
		i++
	})
	sb.WriteString("}")
	return sb.String()
}

func parseNum(s string) float64 {
	switch strings.ToLower(s) {
	case "nan":
		return math.NaN()
	case "inf", "+inf":
		return math.Inf(1)
	case "-inf":
		return math.Inf(-1)
	}
	v, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return math.NaN()
	}
	return v
}

func printMatrix(w *bufio.Writer, id string, m promql.Matrix) {
	var rows []string
	for _, s := range m {
		var sb strings.Builder
		sb.WriteString(fmtLabels(s.Metric) + "\t")
		for j, p := range s.Floats {
			if j > 0 {
				sb.WriteString(" ")
			}
			sb.WriteString(strconv.FormatInt(p.T, 10) + ":" + fmtF(p.F))
		}
		rows = append(rows, sb.String())
	}
	sort.Strings(rows)
	fmt.Fprintf(w, "%s\tmatrix\t%d\n", id, len(rows))
	for _, r := range rows {
		fmt.Fprintf(w, "%s\t\t%s\n", id, r)
	}
}

func printResult(w *bufio.Writer, id string, res *promql.Result) {
	if res.Err != nil {
		fmt.Fprintf(w, "%s\tERR\n", id)
		return
	}
	switch v := res.Value.(type) {
	case promql.Scalar:
		fmt.Fprintf(w, "%s\tscalar\t%s\n", id, fmtF(v.V))
	case promql.String:
		fmt.Fprintf(w, "%s\tstring\t%s\n", id, hex.EncodeToString([]byte(v.V)))
	case promql.Vector:
		var rows []string
		for _, s := range v {
			rows = append(rows, fmtLabels(s.Metric)+"\t"+fmtF(s.F))
		}
		sort.Strings(rows)
		fmt.Fprintf(w, "%s\tvector\t%d\n", id, len(rows))
		for _, r := range rows {
			fmt.Fprintf(w, "%s\t\t%s\n", id, r)
		}
	case promql.Matrix:
		printMatrix(w, id, v)
	default:
		fmt.Fprintf(w, "%s\tERR\n", id)
	}
}

type series struct {
	lset    labels.Labels
	samples [][2]string
}

func runEval(path string, w *bufio.Writer) {
	opts := promql.EngineOpts{
		MaxSamples:               50000000,
		Timeout:                  30 * time.Second,
		LookbackDelta:            5 * time.Minute,
		EnableAtModifier:         true,
		EnableNegativeOffset:     true,
		NoStepSubqueryIntervalFn: func(int64) int64 { return 60000 },
	}
	engine := promql.NewEngine(opts)
	var cur []series
	var stor *teststorage.TestStorage
	dirty := true
	load := func() {
		if !dirty {
			return
		}
		if stor != nil {
			stor.Close()
		}
		var err error
		stor, err = teststorage.NewWithError()
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		app := stor.Appender(context.Background())
		for _, s := range cur {
			for _, p := range s.samples {
				t, _ := strconv.ParseInt(p[0], 10, 64)
				if _, err := app.Append(0, s.lset, t, parseNum(p[1])); err != nil {
					fmt.Fprintln(os.Stderr, "append:", err)
				}
			}
		}
		if err := app.Commit(); err != nil {
			fmt.Fprintln(os.Stderr, "commit:", err)
		}
		dirty = false
	}
	defer func() {
		if stor != nil {
			stor.Close()
		}
	}()
	for _, line := range readLines(path) {
		if line == "" || line[0] == '#' {
			continue
		}
		cols := strings.Split(line, "\t")
		switch cols[0] {
		case "clear":
			cur = nil
			dirty = true
		case "series":
			b := labels.NewScratchBuilder(4)
			if cols[1] != "" {
				for _, kv := range strings.Split(cols[1], ",") {
					i := strings.IndexByte(kv, '=')
					b.Add(kv[:i], unhex(kv[i+1:]))
				}
			}
			b.Sort()
			s := series{lset: b.Labels()}
			for _, p := range strings.Fields(cols[2]) {
				tv := strings.SplitN(p, ":", 2)
				s.samples = append(s.samples, [2]string{tv[0], tv[1]})
			}
			cur = append(cur, s)
			dirty = true
		case "instant":
			load()
			id := cols[1]
			q := unhex(cols[3])
			if _, err := parser.ParseExpr(q); err != nil {
				fmt.Fprintf(w, "%s\tPARSE_ERR\n", id)
				continue
			}
			t, _ := strconv.ParseInt(cols[2], 10, 64)
			qry, err := engine.NewInstantQuery(context.Background(), stor, nil, q, time.UnixMilli(t))
			if err != nil {
				fmt.Fprintf(w, "%s\tERR\n", id)
				continue
			}
			printResult(w, id, qry.Exec(context.Background()))
			qry.Close()
		case "range":
			load()
			id := cols[1]
			q := unhex(cols[5])
			if _, err := parser.ParseExpr(q); err != nil {
				fmt.Fprintf(w, "%s\tPARSE_ERR\n", id)
				continue
			}
			s, _ := strconv.ParseInt(cols[2], 10, 64)
			e, _ := strconv.ParseInt(cols[3], 10, 64)
			st, _ := strconv.ParseInt(cols[4], 10, 64)
			// The Prometheus HTTP API (web/api/v1 queryRange) validates these before the
			// engine runs; the bare engine would loop forever on step <= 0.
			if e < s || st <= 0 || (e-s)/st > 11000 {
				fmt.Fprintf(w, "%s\tERR\n", id)
				continue
			}
			qry, err := engine.NewRangeQuery(context.Background(), stor, nil, q, time.UnixMilli(s), time.UnixMilli(e), time.Duration(st)*time.Millisecond)
			if err != nil {
				fmt.Fprintf(w, "%s\tERR\n", id)
				continue
			}
			printResult(w, id, qry.Exec(context.Background()))
			qry.Close()
		}
	}
}

// runW3Engine replays bench W3 (packages/promql/bench, same 40 series and both queries)
// through the real promql.Engine, to price what the hand-written Go loop in
// bench/go_bench skips (parsing, selector matching, label hashing, generic grouping).
func runW3Engine(iters int, w *bufio.Writer) {
	stor, err := teststorage.NewWithError()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	defer stor.Close()
	app := stor.Appender(context.Background())
	jobs := []string{"api", "web", "worker", "billing"}
	les := []string{"0.1", "0.25", "0.5", "1.0", "2.5", "+Inf"}
	weights := []float64{15, 40, 70, 88, 96, 100}
	for j, job := range jobs {
		for inst := 0; inst < 4; inst++ {
			ls := labels.FromStrings("__name__", "http_requests_total", "instance", fmt.Sprintf("inst-%d", inst), "job", job)
			rpm := float64((j+1)*60 + inst*15)
			for t := 0; t <= 10; t++ {
				app.Append(0, ls, int64(t*60000), rpm*float64(t))
			}
		}
		for b, le := range les {
			ls := labels.FromStrings("__name__", "http_request_duration_seconds_bucket", "job", job, "le", le)
			for t := 0; t <= 10; t++ {
				app.Append(0, ls, int64(t*60000), weights[b]*float64(j+1)*float64(t))
			}
		}
	}
	app.Commit()
	engine := promql.NewEngine(promql.EngineOpts{MaxSamples: 50000000, Timeout: time.Minute, LookbackDelta: 5 * time.Minute})
	points := 0
	var sum float64
	for it := 0; it < iters; it++ {
		q1, _ := engine.NewInstantQuery(context.Background(), stor, nil,
			"histogram_quantile(0.95, sum by (le, job) (rate(http_request_duration_seconds_bucket[5m])))", time.UnixMilli(600000))
		r1 := q1.Exec(context.Background())
		for _, s := range r1.Value.(promql.Vector) {
			sum += s.F
			points++
		}
		q1.Close()
		q2, _ := engine.NewRangeQuery(context.Background(), stor, nil,
			"sum by (job) (rate(http_requests_total[5m]))", time.UnixMilli(300000), time.UnixMilli(600000), time.Minute)
		r2 := q2.Exec(context.Background())
		for _, s := range r2.Value.(promql.Matrix) {
			for _, p := range s.Floats {
				sum += p.F
				points++
			}
		}
		q2.Close()
	}
	fmt.Fprintf(w, "w3engine iters=%d points=%d sum=%.6f\n", iters, points, sum)
}

func main() {
	parser.EnableExperimentalFunctions = true
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: oracle parse|eval <file>")
		os.Exit(2)
	}
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	switch os.Args[1] {
	case "parse":
		runParse(os.Args[2], w)
	case "eval":
		runEval(os.Args[2], w)
	case "w3engine":
		n, _ := strconv.Atoi(os.Args[2])
		runW3Engine(n, w)
	default:
		fmt.Fprintln(os.Stderr, "unknown mode")
		os.Exit(2)
	}
}
