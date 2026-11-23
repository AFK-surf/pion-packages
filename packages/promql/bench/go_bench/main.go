package main

import (
	"context"
	"fmt"
	"os"
	"sort"
	"strconv"
	"time"

	"github.com/prometheus/prometheus/model/labels"
	"github.com/prometheus/prometheus/promql"
	"github.com/prometheus/prometheus/promql/parser"
	"github.com/prometheus/prometheus/util/teststorage"
)

func fnv1aStr(h int64, s string) int64 {
	for i := 0; i < len(s); i++ {
		h = ((h ^ int64(s[i])) * 16777619) & 0xFFFFFFFF
	}
	return h
}

func fnv1aI64(h int64, v int64) int64 {
	h = ((h ^ (v & 0xFF)) * 16777619) & 0xFFFFFFFF
	h = ((h ^ ((v >> 8) & 0xFF)) * 16777619) & 0xFFFFFFFF
	h = ((h ^ ((v >> 16) & 0xFF)) * 16777619) & 0xFFFFFFFF
	h = ((h ^ ((v >> 24) & 0xFF)) * 16777619) & 0xFFFFFFFF
	return h
}

func runW1(totalOps int) int {
	queries := []string{
		`histogram_quantile(0.95, sum by (le, job) (rate(http_request_duration_seconds_bucket{code!~"5..",job=~"api|gateway"}[5m])))`,
		`sum by (service, cluster) (rate(http_requests_total{env="prod",status=~"5.."}[5m])) / sum by (service, cluster) (rate(http_requests_total{env="prod"}[5m]))`,
		`max_over_time(rate(container_cpu_usage_seconds_total{container!="POD",namespace="prod"}[5m])[1h:1m])`,
		`topk by (cluster) (10, sum by (cluster, pod) (container_memory_working_set_bytes{namespace=~"prod-.*"}))`,
		`rate(node_network_receive_bytes_total{device!~"lo|veth.*"}[5m]) * on (instance) group_left (role, zone) node_meta_info`,
		`avg without (instance) (rate(grpc_server_handled_total{grpc_code!="OK"}[10m])) > 0.05`,
		`sum by (job) (increase(payments_failed_total{region=~"us-.*|eu-.*"}[15m])) unless on (job) maintenance_window_active == 1`,
		`quantile(0.99, rate(db_query_duration_seconds_sum{db="orders"}[5m]) / rate(db_query_duration_seconds_count{db="orders"}[5m]))`,
		`label_replace(sum by (instance) (up{job="kube-apiserver"}), "host", "$1", "instance", "(.*):.*")`,
		`clamp_min(sum by (tenant) (rate(api_tokens_consumed_total[5m])) - on (tenant) group_left (tier) tenant_quota_limit, 0)`,
	}
	nq := len(queries)
	var checksum int64 = 2166136261
	var totalBytes int64
	for i := 0; i < totalOps; i++ {
		expr, err := parser.ParseExpr(queries[i%nq])
		if err != nil {
			fmt.Fprintf(os.Stderr, "w1 parse error: %v\n", err)
			return 1
		}
		s := expr.String()
		totalBytes += int64(len(s))
		checksum = fnv1aStr(checksum, s)
	}
	fmt.Printf("w1 ops=%d bytes=%d fnv1a=%d\n", totalOps, totalBytes, checksum)
	return 0
}

func runW2(totalOps int) int {
	selectors := []string{
		`http_requests_total{job="api",method="GET",code=~"2..",env!="dev"}[5m] offset 1h`,
		`container_cpu_usage_seconds_total{namespace="prod",pod=~"web-[0-9]+",container!~"POD|"}[15m] @ 1700000000`,
		`node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs|overlay",cluster="tokyo-1"} offset -5m`,
		`grpc_server_handling_seconds_bucket{grpc_service="orders.v1.OrderService",le="0.25"}[10m]`,
		`kube_pod_status_phase{namespace=~"payments|billing",phase="Running",cluster="us-east"} @ start()`,
	}
	ns := len(selectors)
	var checksum int64 = 2166136261
	var totalMatchers int64
	for i := 0; i < totalOps; i++ {
		expr, err := parser.ParseExpr(selectors[i%ns])
		if err != nil {
			fmt.Fprintf(os.Stderr, "w2 parse error: %v\n", err)
			return 1
		}
		var vs *parser.VectorSelector
		var rangeMs int64
		switch n := expr.(type) {
		case *parser.VectorSelector:
			vs = n
		case *parser.MatrixSelector:
			vs = n.VectorSelector.(*parser.VectorSelector)
			rangeMs = n.Range.Milliseconds()
		}
		offsetMs := vs.OriginalOffset.Milliseconds()
		totalMatchers += int64(len(vs.LabelMatchers))
		checksum = fnv1aI64(checksum, rangeMs)
		checksum = fnv1aI64(checksum, offsetMs)
		for _, m := range vs.LabelMatchers {
			checksum = fnv1aStr(checksum, m.Name)
			checksum = fnv1aStr(checksum, m.Type.String())
			checksum = fnv1aStr(checksum, m.Value)
		}
	}
	fmt.Printf("w2 ops=%d matchers=%d fnv1a=%d\n", totalOps, totalMatchers, checksum)
	return 0
}

func runW3(iters int) int {
	stor, err := teststorage.NewWithError()
	if err != nil {
		fmt.Fprintf(os.Stderr, "w3 storage error: %v\n", err)
		return 1
	}
	defer stor.Close()

	ctx := context.Background()
	app := stor.Appender(ctx)
	jobs := []string{"api", "web", "worker", "billing"}
	leVals := []string{"0.1", "0.25", "0.5", "1.0", "2.5", "+Inf"}
	leWeights := []float64{15.0, 40.0, 70.0, 88.0, 96.0, 100.0}

	for j, job := range jobs {
		for inst := 0; inst < 4; inst++ {
			ls := labels.FromStrings("__name__", "http_requests_total", "instance", fmt.Sprintf("inst-%d", inst), "job", job)
			rpm := float64((j+1)*60 + inst*15)
			for t := 0; t <= 10; t++ {
				if _, err := app.Append(0, ls, int64(t*60000), rpm*float64(t)); err != nil {
					fmt.Fprintf(os.Stderr, "w3 append error: %v\n", err)
					return 1
				}
			}
		}
		for b, le := range leVals {
			ls := labels.FromStrings("__name__", "http_request_duration_seconds_bucket", "job", job, "le", le)
			scale := float64(j + 1)
			for t := 0; t <= 10; t++ {
				if _, err := app.Append(0, ls, int64(t*60000), leWeights[b]*scale*float64(t)); err != nil {
					fmt.Fprintf(os.Stderr, "w3 append error: %v\n", err)
					return 1
				}
			}
		}
	}
	if err := app.Commit(); err != nil {
		fmt.Fprintf(os.Stderr, "w3 commit error: %v\n", err)
		return 1
	}

	engine := promql.NewEngine(promql.EngineOpts{
		MaxSamples:    50000000,
		Timeout:       time.Minute,
		LookbackDelta: 5 * time.Minute,
	})

	const qHQ = `histogram_quantile(0.95, sum by (le, job) (rate(http_request_duration_seconds_bucket[5m])))`
	const qRate = `sum by (job) (rate(http_requests_total[5m]))`

	var checksum int64 = 2166136261
	var totalPoints int64
	for it := 0; it < iters; it++ {
		q1, err := engine.NewInstantQuery(ctx, stor, nil, qHQ, time.UnixMilli(600000))
		if err != nil {
			fmt.Fprintf(os.Stderr, "w3 q1 error: %v\n", err)
			return 2
		}
		r1 := q1.Exec(ctx)
		if r1.Err != nil {
			q1.Close()
			fmt.Fprintf(os.Stderr, "w3 q1 exec error: %v\n", r1.Err)
			return 2
		}
		vec := r1.Value.(promql.Vector)
		sort.Slice(vec, func(i, j int) bool {
			return vec[i].Metric.Get("job") < vec[j].Metric.Get("job")
		})
		for _, s := range vec {
			q := int64(s.F*1000000.0 + 0.5)
			checksum = fnv1aI64(checksum, q)
			totalPoints++
		}
		q1.Close()

		q2, err := engine.NewRangeQuery(ctx, stor, nil, qRate, time.UnixMilli(300000), time.UnixMilli(600000), time.Minute)
		if err != nil {
			fmt.Fprintf(os.Stderr, "w3 q2 error: %v\n", err)
			return 3
		}
		r2 := q2.Exec(ctx)
		if r2.Err != nil {
			q2.Close()
			fmt.Fprintf(os.Stderr, "w3 q2 exec error: %v\n", r2.Err)
			return 3
		}
		mat := r2.Value.(promql.Matrix)
		sort.Slice(mat, func(i, j int) bool {
			return mat[i].Metric.Get("job") < mat[j].Metric.Get("job")
		})
		for _, s := range mat {
			for _, p := range s.Floats {
				q := int64(p.F*1000000.0 + 0.5)
				checksum = fnv1aI64(checksum, q)
				totalPoints++
			}
		}
		q2.Close()
	}
	fmt.Printf("w3 iters=%d points=%d fnv1a=%d\n", iters, totalPoints, checksum)
	return 0
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: go_promql <w1|w2|w3> [count]")
		os.Exit(1)
	}
	mode := os.Args[1]
	count := 1000
	if len(os.Args) >= 3 {
		if n, err := strconv.Atoi(os.Args[2]); err == nil {
			count = n
		}
	}
	switch mode {
	case "w1":
		os.Exit(runW1(count))
	case "w2":
		os.Exit(runW2(count))
	case "w3":
		os.Exit(runW3(count))
	default:
		fmt.Fprintf(os.Stderr, "unknown mode: %s\n", mode)
		os.Exit(1)
	}
}
