package main

import (
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/google/cel-go/cel"
)

func fnv1aStep(h int64, b int64) int64 {
	return ((h ^ b) * 16777619) & 0xFFFFFFFF
}

func runW1(iters int) int {
	env, err := cel.NewEnv(
		cel.Variable("role", cel.StringType),
		cel.Variable("env", cel.StringType),
		cel.Variable("replicas", cel.IntType),
		cel.Variable("method", cel.StringType),
		cel.Variable("quota_used", cel.IntType),
		cel.Variable("cost", cel.IntType),
		cel.Variable("quota_limit", cel.IntType),
		cel.Variable("ns", cel.StringType),
		cel.Variable("tier", cel.StringType),
		cel.Variable("labels", cel.MapType(cel.StringType, cel.StringType)),
		cel.Variable("privileged", cel.BoolType),
	)
	if err != nil {
		fmt.Fprintf(os.Stderr, "env error: %v\n", err)
		return 1
	}

	rules := []string{
		"role == 'admin' || (env == 'staging' && replicas <= 5)",
		"method == 'GET' || (method == 'POST' && quota_used + cost <= quota_limit)",
		"ns != 'kube-system' && replicas >= 1 && replicas <= 50 && (tier == 'gold' || tier == 'silver')",
		"has(labels.team) && labels.team == 'platform' && !privileged",
	}
	progs := make([]cel.Program, len(rules))
	for i, r := range rules {
		ast, iss := env.Compile(r)
		if iss.Err() != nil {
			fmt.Fprintf(os.Stderr, "compile error: %v\n", iss.Err())
			return 1
		}
		prg, err := env.Program(ast)
		if err != nil {
			fmt.Fprintf(os.Stderr, "program error: %v\n", err)
			return 1
		}
		progs[i] = prg
	}

	roles := []string{"admin", "dev", "viewer", "ops"}
	envs := []string{"prod", "staging", "dev", "staging"}
	methods := []string{"GET", "POST", "DELETE", "POST"}
	namespaces := []string{"default", "kube-system", "payments", "infra"}
	tiers := []string{"gold", "bronze", "silver", "gold"}
	teams := []string{"platform", "growth", "platform", "ml"}

	acts := make([]map[string]any, 16)
	for k := 0; k < 16; k++ {
		var labels map[string]string
		if k%3 == 0 {
			labels = map[string]string{"owner": "sre"}
		} else {
			labels = map[string]string{"team": teams[k%4]}
		}
		acts[k] = map[string]any{
			"role":        roles[k%4],
			"env":         envs[(k/2)%4],
			"replicas":    int64(k%12 + 1),
			"method":      methods[(k/4)%4],
			"quota_used":  int64(k * 100),
			"cost":        int64(250),
			"quota_limit": int64(1000),
			"ns":          namespaces[k%4],
			"tier":        tiers[(k+1)%4],
			"labels":      labels,
			"privileged":  k%5 == 0,
		}
	}

	allow := 0
	deny := 0
	var checksum int64 = 2166136261
	for i := 0; i < iters; i++ {
		act := acts[i&15]
		for _, prg := range progs {
			out, _, err := prg.Eval(act)
			if err != nil {
				fmt.Fprintf(os.Stderr, "eval error: %v\n", err)
				return 3
			}
			b, ok := out.Value().(bool)
			if !ok {
				return 2
			}
			if b {
				allow++
				checksum = fnv1aStep(checksum, 1)
			} else {
				deny++
				checksum = fnv1aStep(checksum, 0)
			}
		}
	}
	fmt.Printf("w1 ops=%d allow=%d deny=%d checksum=%d\n", iters*4, allow, deny, checksum)
	return 0
}

func runW2(iters int) int {
	env, err := cel.NewEnv(
		cel.Variable("containers", cel.ListType(cel.MapType(cel.StringType, cel.StringType))),
		cel.Variable("tags", cel.ListType(cel.StringType)),
		cel.Variable("scores", cel.ListType(cel.IntType)),
		cel.Variable("now", cel.TimestampType),
		cel.Variable("expires_at", cel.TimestampType),
	)
	if err != nil {
		fmt.Fprintf(os.Stderr, "w2 env error: %v\n", err)
		return 1
	}

	rules := []string{
		"containers.all(c, c.image.matches('^gcr\\\\.io/prod/[a-z0-9-]+:v[0-9]+$')) && now < expires_at",
		"tags.exists(t, t == 'prod' || t == 'canary') && scores.filter(s, s >= 80).size() >= 2 && (expires_at - now) > duration('30m')",
	}
	progs := make([]cel.Program, len(rules))
	for i, r := range rules {
		ast, iss := env.Compile(r)
		if iss.Err() != nil {
			fmt.Fprintf(os.Stderr, "w2 compile error: %v\n", iss.Err())
			return 1
		}
		prg, err := env.Program(ast)
		if err != nil {
			fmt.Fprintf(os.Stderr, "w2 program error: %v\n", err)
			return 1
		}
		progs[i] = prg
	}

	baseTS, err := time.Parse(time.RFC3339, "2026-11-23T10:00:00Z")
	if err != nil {
		return 1
	}

	acts := make([]map[string]any, 16)
	for k := 0; k < 16; k++ {
		var img2 string
		if k%3 == 0 {
			img2 = "docker.io/untrusted/app:latest"
		} else {
			img2 = fmt.Sprintf("gcr.io/prod/worker-%d:v%d", k, k+1)
		}
		containers := []map[string]string{
			{"image": "gcr.io/prod/api-gw:v12"},
			{"image": img2},
		}
		var tags []string
		if k%4 == 0 {
			tags = []string{"dev", "nightly"}
		} else if k%2 == 0 {
			tags = []string{"canary", "eu-west"}
		} else {
			tags = []string{"prod", "us-east"}
		}
		scores := []int64{
			int64(60 + (k%5)*10),
			int64(75 + (k%4)*8),
			int64(85 + (k%3)*5),
		}
		var deltaSecs int64
		if k%5 == 0 {
			deltaSecs = -600
		} else if k%5 == 1 {
			deltaSecs = 900
		} else {
			deltaSecs = 3600
		}
		expTS := baseTS.Add(time.Duration(deltaSecs) * time.Second)
		acts[k] = map[string]any{
			"containers": containers,
			"tags":       tags,
			"scores":     scores,
			"now":        baseTS,
			"expires_at": expTS,
		}
	}

	allow := 0
	deny := 0
	var checksum int64 = 2166136261
	for i := 0; i < iters; i++ {
		act := acts[i&15]
		for _, prg := range progs {
			out, _, err := prg.Eval(act)
			if err != nil {
				fmt.Fprintf(os.Stderr, "w2 eval error: %v\n", err)
				return 3
			}
			b, ok := out.Value().(bool)
			if !ok {
				return 2
			}
			if b {
				allow++
				checksum = fnv1aStep(checksum, 1)
			} else {
				deny++
				checksum = fnv1aStep(checksum, 0)
			}
		}
	}
	fmt.Printf("w2 ops=%d allow=%d deny=%d checksum=%d\n", iters*2, allow, deny, checksum)
	return 0
}

func runW3(iters int) int {
	env, err := cel.NewEnv(
		cel.Variable("user", cel.StringType),
		cel.Variable("role", cel.StringType),
		cel.Variable("count", cel.IntType),
		cel.Variable("tags", cel.ListType(cel.StringType)),
		cel.Variable("now", cel.TimestampType),
	)
	if err != nil {
		fmt.Fprintf(os.Stderr, "w3 env error: %v\n", err)
		return 1
	}

	exprs := []string{
		"role == 'admin' && count > 0",
		"user.startsWith('svc-') || role == 'ops'",
		"tags.exists(t, t == 'prod') && count < 100",
		"tags.all(t, t.size() >= 2 && t.size() <= 16)",
		"tags.filter(t, t.startsWith('us-')).size() >= 1",
		"user.matches('^[a-z]+-[0-9]+$') && count % 2 == 0",
		"now > timestamp('2026-01-01T00:00:00Z') && count + 10 <= 50",
		"(role == 'admin' ? 100 : 10) >= count",
		"'prod' in tags && !(role == 'guest')",
		"tags.map(t, t.size()).exists(n, n >= 4)",
	}

	nowTS, err := time.Parse(time.RFC3339, "2026-11-23T10:00:00Z")
	if err != nil {
		return 1
	}
	act := map[string]any{
		"user":  "svc-42",
		"role":  "admin",
		"count": int64(24),
		"tags":  []string{"prod", "us-east", "canary"},
		"now":   nowTS,
	}

	allow := 0
	deny := 0
	var checksum int64 = 2166136261
	for i := 0; i < iters; i++ {
		for _, expr := range exprs {
			ast, iss := env.Compile(expr)
			if iss.Err() != nil {
				fmt.Fprintf(os.Stderr, "w3 compile error: %v\n", iss.Err())
				return 1
			}
			prg, err := env.Program(ast)
			if err != nil {
				fmt.Fprintf(os.Stderr, "w3 program error: %v\n", err)
				return 1
			}
			out, _, err := prg.Eval(act)
			if err != nil {
				fmt.Fprintf(os.Stderr, "w3 eval error: %v\n", err)
				return 3
			}
			b, ok := out.Value().(bool)
			if !ok {
				return 2
			}
			if b {
				allow++
				checksum = fnv1aStep(checksum, 1)
			} else {
				deny++
				checksum = fnv1aStep(checksum, 0)
			}
		}
	}
	fmt.Printf("w3 ops=%d allow=%d deny=%d checksum=%d\n", iters*10, allow, deny, checksum)
	return 0
}

func main() {
	if len(os.Args) < 3 {
		fmt.Println("usage: go_cel <w1|w2|w3> <iters>")
		os.Exit(1)
	}
	mode := os.Args[1]
	iters, err := strconv.Atoi(os.Args[2])
	if err != nil || iters <= 0 {
		iters = 1000
	}
	switch mode {
	case "w1":
		os.Exit(runW1(iters))
	case "w2":
		os.Exit(runW2(iters))
	case "w3":
		os.Exit(runW3(iters))
	default:
		fmt.Printf("unknown mode: %s\n", mode)
		os.Exit(1)
	}
}
