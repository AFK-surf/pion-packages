// Differential oracle for packages/cel: Go github.com/google/cel-go v0.24.1 (default cel.NewEnv()).
// Same case-file and transcript format as audit/diff/pion_driver.
package main

import (
	"bufio"
	"encoding/hex"
	"fmt"
	"math"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/google/cel-go/cel"
	"github.com/google/cel-go/common/types"
	"github.com/google/cel-go/common/types/ref"
	"github.com/google/cel-go/common/types/traits"
)

func canon(v ref.Val) string {
	switch x := v.(type) {
	case types.Null:
		return "null"
	case types.Bool:
		if x {
			return "bool:true"
		}
		return "bool:false"
	case types.Int:
		return "int:" + strconv.FormatInt(int64(x), 10)
	case types.Uint:
		return "uint:" + strconv.FormatUint(uint64(x), 10)
	case types.Double:
		f := float64(x)
		if math.IsNaN(f) {
			return "double:nan"
		}
		return fmt.Sprintf("double:%016x", math.Float64bits(f))
	case types.String:
		return "string:" + hex.EncodeToString([]byte(string(x)))
	case types.Bytes:
		return "bytes:" + hex.EncodeToString([]byte(x))
	case types.Timestamp:
		return fmt.Sprintf("ts:%d.%d", x.Time.Unix(), x.Time.Nanosecond())
	case types.Duration:
		ns := x.Duration.Nanoseconds()
		return fmt.Sprintf("dur:%d.%d", ns/1e9, ns%1e9)
	case ref.Type:
		return "type:" + x.TypeName()
	}
	if l, ok := v.(traits.Lister); ok {
		n := int(l.Size().(types.Int))
		parts := make([]string, n)
		for i := 0; i < n; i++ {
			parts[i] = canon(l.Get(types.Int(i)))
		}
		return "[" + strings.Join(parts, ",") + "]"
	}
	if m, ok := v.(traits.Mapper); ok {
		parts := []string{}
		it := m.Iterator()
		for it.HasNext() == types.True {
			k := it.Next()
			parts = append(parts, canon(k)+"="+canon(m.Get(k)))
		}
		sort.Strings(parts)
		return "{" + strings.Join(parts, ",") + "}"
	}
	return "unknown:" + fmt.Sprint(v)
}

func oneLine(s string) string {
	return strings.NewReplacer("\n", " ", "\r", " ", "\t", " ").Replace(s)
}

func runCase(env *cel.Env, mode, src string) (out string) {
	defer func() {
		if r := recover(); r != nil {
			out = "EERR\tpanic: " + oneLine(fmt.Sprint(r))
		}
	}()
	ast, iss := env.Parse(src)
	if iss.Err() != nil {
		return "PERR\t" + oneLine(iss.Err().Error())
	}
	if mode == "C" {
		c, iss2 := env.Check(ast)
		if iss2.Err() != nil {
			return "CERR\t" + oneLine(iss2.Err().Error())
		}
		ast = c
	}
	prg, err := env.Program(ast)
	if err != nil {
		return "EERR\tprogram: " + oneLine(err.Error())
	}
	v, _, err := prg.Eval(cel.NoVars())
	if err != nil {
		return "EERR\t" + oneLine(err.Error())
	}
	if types.IsError(v) {
		return "EERR\t" + oneLine(fmt.Sprint(v))
	}
	return "OK " + canon(v)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Println("usage: cel_audit_oracle <cases>")
		os.Exit(2)
	}
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Println("error:", err)
		os.Exit(2)
	}
	env, err := cel.NewEnv()
	if err != nil {
		panic(err)
	}
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	_ = time.Now
	for i, line := range strings.Split(string(data), "\n") {
		if line == "" || line[0] == '#' {
			continue
		}
		f := strings.SplitN(line, "\t", 3)
		if len(f) < 2 {
			continue
		}
		src, _ := hex.DecodeString(f[1])
		fmt.Fprintf(w, "## %d\n%s\n", i+1, runCase(env, f[0], string(src)))
	}
}
