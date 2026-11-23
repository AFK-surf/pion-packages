// DoS / limit probes for Go github.com/google/cel-go v0.24.1 — the same probes and expressions
// as audit/dos/pion_dos. usage: go_dos <probe> <n> [costlimit]
// With a third argument cel-go runs with cel.CostLimit(costlimit) (its runtime budget, the
// closest equivalent of Pion's EvalLimits.max_cost); without it cel-go runs unlimited.
package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/google/cel-go/cel"
	"github.com/google/cel-go/common/types/ref"
	"github.com/google/cel-go/common/types/traits"
)

func rep(unit, sep string, n int) string {
	p := make([]string, n)
	for i := range p {
		p[i] = unit
	}
	return strings.Join(p, sep)
}

func listOfPow2(k int) string { return "[[0]]" + rep(".map(l, l + l)", "", k) + "[0]" }
func halfMibString() string   { return "['0123456789abcdef']" + rep(".map(s, s + s)", "", 15) + "[0]" }
func mibString() string       { return "['0123456789abcdef']" + rep(".map(s, s + s)", "", 16) + "[0]" }

func totalBytes(v ref.Val) int64 {
	switch x := v.Value().(type) {
	case string:
		return int64(len(x))
	}
	if l, ok := v.(traits.Lister); ok {
		var t int64
		it := l.Iterator()
		for it.HasNext().Value() == true {
			t += totalBytes(it.Next())
		}
		return t
	}
	return 8
}

func run(label, src string, vars []cel.EnvOption, act map[string]any, cost uint64) {
	env, err := cel.NewEnv(vars...)
	if err != nil {
		fmt.Println(label, "ENVERR", err)
		return
	}
	ast, iss := env.Compile(src)
	if iss.Err() != nil {
		msg := iss.Err().Error()
		if len(msg) > 160 {
			msg = msg[:160]
		}
		fmt.Println(label, "ERR(compile)", strings.ReplaceAll(msg, "\n", " "))
		return
	}
	opts := []cel.ProgramOption{}
	if cost > 0 {
		opts = append(opts, cel.CostLimit(cost), cel.EvalOptions(cel.OptTrackCost))
	}
	prg, err := env.Program(ast, opts...)
	if err != nil {
		fmt.Println(label, "ERR(program)", err)
		return
	}
	if act == nil {
		act = map[string]any{}
	}
	v, det, err := prg.Eval(act)
	if err != nil {
		fmt.Println(label, "ERR(eval)", err)
		return
	}
	c := uint64(0)
	if det != nil && det.ActualCost() != nil {
		c = *det.ActualCost()
	}
	fmt.Printf("%s OK result_bytes=%d actual_cost=%d\n", label, totalBytes(v), c)
}

func main() {
	probe := os.Args[1]
	n, _ := strconv.Atoi(os.Args[2])
	var cost uint64
	if len(os.Args) > 3 {
		cost, _ = strconv.ParseUint(os.Args[3], 10, 64)
	}
	switch probe {
	case "check_chain":
		run(probe, rep("1", "+", n), nil, nil, cost)
	case "check_member":
		run(probe, "dyn({'a':1})"+rep(".a", "", n), nil, nil, cost)
	case "check_index":
		run(probe, "dyn([0])"+rep("[0]", "", n), nil, nil, cost)
	case "or_chain":
		cl := make([]string, n)
		for i := range cl {
			cl[i] = "x == " + strconv.Itoa(i)
		}
		run(probe, strings.Join(cl, " || "), []cel.EnvOption{cel.Variable("x", cel.IntType)}, map[string]any{"x": int64(n - 1)}, cost)
	case "mem_amp":
		run(probe, "["+halfMibString()+"].map(s, ["+listOfPow2(n)+"].map(l, l.map(i, s + s)))", nil, nil, cost)
	case "cpu_in":
		run(probe, "["+listOfPow2(n)+"].map(L, L.map(i, 1 in L))", nil, nil, cost)
	case "cpu_size":
		run(probe, "["+mibString()+"].map(s, ["+listOfPow2(n)+"].map(l, l.map(i, size(s))))", nil, nil, cost)
	case "map_lookup":
		cnt := 1 << n
		m := make(map[int64]int64, cnt)
		ks := make([]int64, cnt)
		for i := 0; i < cnt; i++ {
			m[int64(i)] = int64(i)
			ks[i] = int64(i)
		}
		run(probe, "ks.map(k, m[k]).size()", []cel.EnvOption{
			cel.Variable("m", cel.MapType(cel.IntType, cel.IntType)), cel.Variable("ks", cel.ListType(cel.IntType)),
		}, map[string]any{"m": m, "ks": ks}, cost)
	case "act_lookup":
		vars := []cel.EnvOption{}
		act := map[string]any{}
		for i := 0; i < n; i++ {
			name := "v" + strconv.Itoa(i)
			vars = append(vars, cel.Variable(name, cel.IntType))
			act[name] = int64(i)
		}
		env, _ := cel.NewEnv(vars...)
		ast, _ := env.Compile("v" + strconv.Itoa(n-1) + " > 0")
		prg, _ := env.Program(ast)
		ok := 0
		for j := 0; j < 100000; j++ {
			if _, _, err := prg.Eval(act); err == nil {
				ok++
			}
		}
		fmt.Printf("act_lookup OK evals=%d\n", ok)
	default:
		fmt.Println("unknown probe", probe)
		os.Exit(2)
	}
}
