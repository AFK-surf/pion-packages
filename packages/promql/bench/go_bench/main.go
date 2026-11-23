package main

import (
	"fmt"
	"math"
	"os"
	"sort"
	"strconv"

	"github.com/prometheus/prometheus/promql/parser"
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

type sample struct {
	ts  int64
	val float64
}

type bucketSeries struct {
	job     string
	le      float64
	samples []sample
}

type counterSeries struct {
	job     string
	inst    string
	samples []sample
}

func extrapolatedRate(samples []sample, rangeStartMs, rangeEndMs int64) float64 {
	n := len(samples)
	first := samples[0]
	last := samples[n-1]
	resultVal := last.val - first.val
	var corr float64
	prev := first.val
	for i := 1; i < n; i++ {
		if samples[i].val < prev {
			corr += prev
		}
		prev = samples[i].val
	}
	resultVal += corr
	durStart := float64(first.ts-rangeStartMs) / 1000.0
	durEnd := float64(rangeEndMs-last.ts) / 1000.0
	sampledInt := float64(last.ts-first.ts) / 1000.0
	avgInt := sampledInt / float64(n-1)
	if resultVal > 0 && first.val >= 0 {
		durZero := sampledInt * (first.val / resultVal)
		if durZero < durStart {
			durStart = durZero
		}
	}
	thresh := avgInt * 1.1
	extrap := sampledInt
	if durStart < thresh {
		extrap += durStart
	} else {
		extrap += avgInt / 2.0
	}
	if durEnd < thresh {
		extrap += durEnd
	} else {
		extrap += avgInt / 2.0
	}
	rangeSec := float64(rangeEndMs-rangeStartMs) / 1000.0
	return (resultVal * (extrap / sampledInt)) / rangeSec
}

func histogramQuantile(phi float64, buckets [][2]float64) float64 {
	sort.Slice(buckets, func(i, j int) bool { return buckets[i][0] < buckets[j][0] })
	nb := len(buckets)
	for i := 1; i < nb; i++ {
		if buckets[i][1] < buckets[i-1][1] {
			buckets[i][1] = buckets[i-1][1]
		}
	}
	total := buckets[nb-1][1]
	rank := phi * total
	b := 0
	for b < nb-1 && buckets[b][1] < rank {
		b++
	}
	if b == nb-1 {
		return buckets[nb-2][0]
	}
	bucketStart := 0.0
	prevCnt := 0.0
	if b > 0 {
		bucketStart = buckets[b-1][0]
		prevCnt = buckets[b-1][1]
	}
	bucketEnd := buckets[b][0]
	count := buckets[b][1] - prevCnt
	return bucketStart + (bucketEnd-bucketStart)*((rank-prevCnt)/count)
}

func runW3(iters int) int {
	jobs := []string{"api", "web", "worker", "billing"}
	leVals := []float64{0.1, 0.25, 0.5, 1.0, 2.5, math.Inf(1)}
	leWeights := []float64{15.0, 40.0, 70.0, 88.0, 96.0, 100.0}

	var counters []counterSeries
	var hbuckets []bucketSeries
	for j, job := range jobs {
		for inst := 0; inst < 4; inst++ {
			smps := make([]sample, 11)
			rpm := float64((j+1)*60 + inst*15)
			for t := 0; t <= 10; t++ {
				smps[t] = sample{ts: int64(t * 60000), val: rpm * float64(t)}
			}
			counters = append(counters, counterSeries{job: job, inst: fmt.Sprintf("inst-%d", inst), samples: smps})
		}
		for b, le := range leVals {
			smps := make([]sample, 11)
			scale := float64(j + 1)
			for t := 0; t <= 10; t++ {
				smps[t] = sample{ts: int64(t * 60000), val: leWeights[b] * scale * float64(t)}
			}
			hbuckets = append(hbuckets, bucketSeries{job: job, le: le, samples: smps})
		}
	}

	var checksum int64 = 2166136261
	var totalPoints int64
	for it := 0; it < iters; it++ {
		// 1. histogram_quantile(0.95, sum by (le, job) (rate(http_request_duration_seconds_bucket[5m]))) at t=600s
		for _, job := range jobs {
			var bs [][2]float64
			for _, hb := range hbuckets {
				if hb.job != job {
					continue
				}
				var win []sample
				for _, s := range hb.samples {
					if s.ts > 300000 && s.ts <= 600000 {
						win = append(win, s)
					}
				}
				r := extrapolatedRate(win, 300000, 600000)
				bs = append(bs, [2]float64{hb.le, r})
			}
			hq := histogramQuantile(0.95, bs)
			q := int64(hq*1000000.0 + 0.5)
			checksum = fnv1aI64(checksum, q)
			totalPoints++
		}
		// 2. eval_range sum by (job) rate over [300s, 600s] step 60s
		for _, job := range jobs {
			for ts := int64(300000); ts <= 600000; ts += 60000 {
				var sum float64
				for _, cs := range counters {
					if cs.job != job {
						continue
					}
					var win []sample
					for _, s := range cs.samples {
						if s.ts > ts-300000 && s.ts <= ts {
							win = append(win, s)
						}
					}
					sum += extrapolatedRate(win, ts-300000, ts)
				}
				q := int64(sum*1000000.0 + 0.5)
				checksum = fnv1aI64(checksum, q)
				totalPoints++
			}
		}
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
