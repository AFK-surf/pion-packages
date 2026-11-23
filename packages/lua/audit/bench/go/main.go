// Fairness / adversarial benchmark driver: Go github.com/yuin/gopher-lua v1.1.1.
// usage: go_bench <mode> <script.lua> [reps]
//   run         : one NewState() (all libs), DoFile-equivalent, stdout = print() output
//   run_lean    : one state with only base/table/string/math (the subset packages/lua ships)
//   fresh_full  : reps x { NewState() all libs; SetGlobal K=i; DoString(src) } -> "fresh:<reps>:<sum of returns>"
//   fresh_lean  : same, SkipOpenLibs + base/table/string/math only (== Pion's sandbox subset)
//   fresh_bare  : same, SkipOpenLibs + base only
//   chunk_lean  : compile once (parse+Compile), reps x fresh lean state + NewFunctionFromProto + PCall
package main

import (
	"fmt"
	"os"
	"strconv"

	lua "github.com/yuin/gopher-lua"
	"github.com/yuin/gopher-lua/parse"
	"strings"
)

func lean(bare bool) *lua.LState {
	L := lua.NewState(lua.Options{SkipOpenLibs: true})
	libs := []struct {
		n string
		f lua.LGFunction
	}{{lua.BaseLibName, lua.OpenBase}}
	if !bare {
		libs = append(libs, struct {
			n string
			f lua.LGFunction
		}{lua.TabLibName, lua.OpenTable}, struct {
			n string
			f lua.LGFunction
		}{lua.StringLibName, lua.OpenString}, struct {
			n string
			f lua.LGFunction
		}{lua.MathLibName, lua.OpenMath})
	}
	for _, l := range libs {
		L.Push(L.NewFunction(l.f))
		L.Push(lua.LString(l.n))
		L.Call(1, 0)
	}
	return L
}

func die(err error) {
	fmt.Fprintf(os.Stderr, "ERR: %v\n", err)
	os.Exit(1)
}

func ret(L *lua.LState) int64 {
	v := L.Get(-1)
	if n, ok := v.(lua.LNumber); ok {
		return int64(n)
	}
	return 0
}

func main() {
	mode, path := os.Args[1], os.Args[2]
	reps := 1
	if len(os.Args) > 3 {
		reps, _ = strconv.Atoi(os.Args[3])
	}
	b, err := os.ReadFile(path)
	if err != nil {
		die(err)
	}
	src := string(b)
	switch mode {
	case "run", "run_lean":
		var L *lua.LState
		if mode == "run" {
			L = lua.NewState()
		} else {
			L = lean(false)
		}
		if err := L.DoString(src); err != nil {
			die(err)
		}
	case "fresh_full", "fresh_lean", "fresh_bare":
		var acc int64
		for i := 1; i <= reps; i++ {
			var L *lua.LState
			switch mode {
			case "fresh_full":
				L = lua.NewState()
			case "fresh_lean":
				L = lean(false)
			default:
				L = lean(true)
			}
			L.SetGlobal("K", lua.LNumber(i))
			if err := L.DoString(src); err != nil {
				die(err)
			}
			acc += ret(L)
			L.Close()
		}
		fmt.Printf("fresh:%d:%d\n", reps, acc)
	case "chunk_lean":
		chunk, err := parse.Parse(strings.NewReader(src), "chunk")
		if err != nil {
			die(err)
		}
		proto, err := lua.Compile(chunk, "chunk")
		if err != nil {
			die(err)
		}
		var acc int64
		for i := 1; i <= reps; i++ {
			L := lean(false)
			L.SetGlobal("K", lua.LNumber(i))
			L.Push(L.NewFunctionFromProto(proto))
			if err := L.PCall(0, 1, nil); err != nil {
				die(err)
			}
			acc += ret(L)
			L.Close()
		}
		fmt.Printf("fresh:%d:%d\n", reps, acc)
	default:
		die(fmt.Errorf("bad mode %s", mode))
	}
}
