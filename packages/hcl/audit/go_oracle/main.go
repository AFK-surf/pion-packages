// Go reference oracle for the packages/hcl red-team audit.
//
// Reads a case file (one case per line: `id<TAB>mode<TAB>hex(input)`) and prints, per case,
// `id<TAB>OK<TAB><json>` or `id<TAB>ERR<TAB>-` using official github.com/hashicorp/hcl/v2 v2.23.0
// and github.com/zclconf/go-cty v1.16.2. The Pion driver (../pion_driver) prints the same
// format for the same file; ../compare.py diffs the two.
//
// Modes:
//
//	expr  hclsyntax.ParseExpression + Value(ctx)
//	tmpl  hclsyntax.ParseTemplate + Value(ctx)
//	body  hclsyntax.ParseConfig, then attributes -> values, blocks -> {type: {label: ... [body...]}}
//	      (the same block mapping packages/hcl `eval_body_to_json` documents)
//	json  hcl/json.Parse + Body.JustAttributes + Value(ctx)
//	fmt   hclsyntax.ParseConfig must succeed (else ERR), then hclwrite.Format -> JSON string
//	fmt2  as fmt, but prints whether Format(Format(src)) == Format(src) (idempotency)
package main

import (
	"bufio"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/ext/tryfunc"
	"github.com/hashicorp/hcl/v2/hclsyntax"
	"github.com/hashicorp/hcl/v2/hclwrite"
	hcljson "github.com/hashicorp/hcl/v2/json"
	"github.com/zclconf/go-cty/cty"
	"github.com/zclconf/go-cty/cty/function"
	"github.com/zclconf/go-cty/cty/function/stdlib"
	ctyjson "github.com/zclconf/go-cty/cty/json"
)

// stdCtx mirrors the fixed context in ../pion_driver/src/main.pion exactly.
func stdCtx() *hcl.EvalContext {
	return &hcl.EvalContext{
		Variables: map[string]cty.Value{
			"s":   cty.StringVal("hello"),
			"n":   cty.NumberIntVal(4),
			"f":   cty.NumberFloatVal(1.5),
			"t":   cty.True,
			"nul": cty.NullVal(cty.DynamicPseudoType),
			"l":   cty.TupleVal([]cty.Value{cty.StringVal("a"), cty.StringVal("b"), cty.StringVal("c")}),
			"e":   cty.EmptyTupleVal,
			"o": cty.ObjectVal(map[string]cty.Value{
				"a": cty.NumberIntVal(1),
				"b": cty.StringVal("x"),
				"c": cty.TupleVal([]cty.Value{cty.NumberIntVal(1), cty.NumberIntVal(2)}),
			}),
			"objs": cty.TupleVal([]cty.Value{
				cty.ObjectVal(map[string]cty.Value{"id": cty.StringVal("x"), "v": cty.NumberIntVal(1)}),
				cty.ObjectVal(map[string]cty.Value{"id": cty.StringVal("y"), "v": cty.NumberIntVal(2)}),
			}),
			"nested": cty.TupleVal([]cty.Value{
				cty.TupleVal([]cty.Value{cty.NumberIntVal(1), cty.NumberIntVal(2)}),
				cty.TupleVal([]cty.Value{cty.NumberIntVal(3)}),
			}),
		},
		Functions: map[string]function.Function{
			"lower":      stdlib.LowerFunc,
			"upper":      stdlib.UpperFunc,
			"trimspace":  stdlib.TrimSpaceFunc,
			"join":       stdlib.JoinFunc,
			"split":      stdlib.SplitFunc,
			"concat":     stdlib.ConcatFunc,
			"length":     tfLengthFunc,
			"merge":      stdlib.MergeFunc,
			"keys":       stdlib.KeysFunc,
			"values":     stdlib.ValuesFunc,
			"min":        stdlib.MinFunc,
			"max":        stdlib.MaxFunc,
			"abs":        stdlib.AbsoluteFunc,
			"ceil":       stdlib.CeilFunc,
			"floor":      stdlib.FloorFunc,
			"range":      stdlib.RangeFunc,
			"reverse":    stdlib.ReverseListFunc,
			"substr":     stdlib.SubstrFunc,
			"format":     stdlib.FormatFunc,
			"jsonencode": stdlib.JSONEncodeFunc,
			"jsondecode": stdlib.JSONDecodeFunc,
			"coalesce":   stdlib.CoalesceFunc,
			"flatten":    stdlib.FlattenFunc,
			"element":    stdlib.ElementFunc,
			"tostring":   stdlib.MakeToFunc(cty.String),
			"tonumber":   stdlib.MakeToFunc(cty.Number),
			"tobool":     stdlib.MakeToFunc(cty.Bool),
			"try":        tryfunc.TryFunc,
			"can":        tryfunc.CanFunc,
		},
	}
}

// tfLengthFunc is Terraform's `length` (internal/lang/funcs.LengthFunc): grapheme-cluster count
// for strings, element/attribute count for collections and structural types.
var tfLengthFunc = function.New(&function.Spec{
	Params: []function.Parameter{{Name: "value", Type: cty.DynamicPseudoType, AllowDynamicType: true}},
	Type:   function.StaticReturnType(cty.Number),
	Impl: func(args []cty.Value, retType cty.Type) (cty.Value, error) {
		v := args[0]
		switch {
		case v.Type() == cty.String:
			return stdlib.Strlen(v)
		case v.Type().IsListType(), v.Type().IsSetType(), v.Type().IsMapType(), v.Type().IsTupleType():
			return v.Length(), nil
		case v.Type().IsObjectType():
			return cty.NumberIntVal(int64(len(v.Type().AttributeTypes()))), nil
		}
		return cty.UnknownVal(cty.Number), fmt.Errorf("argument must be a string, a collection type, or a structural type")
	},
})

func toJSON(v cty.Value) (string, error) {
	if !v.IsWhollyKnown() {
		return "", fmt.Errorf("unknown value")
	}
	b, err := json.Marshal(ctyjson.SimpleJSONValue{Value: v})
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// bodyValue maps a native-syntax body the way packages/hcl eval_body_to_json does.
func bodyValue(body *hclsyntax.Body, ctx *hcl.EvalContext) (map[string]interface{}, error) {
	out := map[string]interface{}{}
	names := make([]string, 0, len(body.Attributes))
	for name := range body.Attributes {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		v, diags := body.Attributes[name].Expr.Value(ctx)
		if diags.HasErrors() {
			return nil, diags
		}
		js, err := toJSON(v)
		if err != nil {
			return nil, err
		}
		out[name] = json.RawMessage(js)
	}
	for _, b := range body.Blocks {
		sub, err := bodyValue(b.Body, ctx)
		if err != nil {
			return nil, err
		}
		cur := out
		key := b.Type
		for _, l := range b.Labels {
			next, ok := cur[key].(map[string]interface{})
			if !ok {
				if _, exists := cur[key]; exists {
					return nil, fmt.Errorf("block/attribute name clash on %q", key)
				}
				next = map[string]interface{}{}
				cur[key] = next
			}
			cur = next
			key = l
		}
		list, ok := cur[key].([]interface{})
		if !ok {
			if _, exists := cur[key]; exists {
				return nil, fmt.Errorf("block/attribute name clash on %q", key)
			}
		}
		cur[key] = append(list, sub)
	}
	return out, nil
}

func run(mode string, src []byte) (string, bool) {
	ctx := stdCtx()
	start := hcl.Pos{Line: 1, Column: 1, Byte: 0}
	switch mode {
	case "expr":
		e, diags := hclsyntax.ParseExpression(src, "case.hcl", start)
		if diags.HasErrors() {
			return "", false
		}
		v, diags := e.Value(ctx)
		if diags.HasErrors() {
			return "", false
		}
		js, err := toJSON(v)
		return js, err == nil
	case "tmpl":
		e, diags := hclsyntax.ParseTemplate(src, "case.tmpl", start)
		if diags.HasErrors() {
			return "", false
		}
		v, diags := e.Value(ctx)
		if diags.HasErrors() {
			return "", false
		}
		js, err := toJSON(v)
		return js, err == nil
	case "body":
		f, diags := hclsyntax.ParseConfig(src, "case.hcl", start)
		if diags.HasErrors() {
			return "", false
		}
		m, err := bodyValue(f.Body.(*hclsyntax.Body), ctx)
		if err != nil {
			return "", false
		}
		b, err := json.Marshal(m)
		return string(b), err == nil
	case "json":
		f, diags := hcljson.Parse(src, "case.json")
		if diags.HasErrors() {
			return "", false
		}
		attrs, diags := f.Body.JustAttributes()
		if diags.HasErrors() {
			return "", false
		}
		m := map[string]json.RawMessage{}
		for name, a := range attrs {
			v, diags := a.Expr.Value(ctx)
			if diags.HasErrors() {
				return "", false
			}
			js, err := toJSON(v)
			if err != nil {
				return "", false
			}
			m[name] = json.RawMessage(js)
		}
		b, err := json.Marshal(m)
		return string(b), err == nil
	case "fmt":
		_, diags := hclsyntax.ParseConfig(src, "case.hcl", start)
		if diags.HasErrors() {
			return "", false
		}
		b, _ := json.Marshal(string(hclwrite.Format(src)))
		return string(b), true
	case "fmt2":
		_, diags := hclsyntax.ParseConfig(src, "case.hcl", start)
		if diags.HasErrors() {
			return "", false
		}
		once := hclwrite.Format(src)
		return fmt.Sprint(string(hclwrite.Format(once)) == string(once)), true
	}
	return "", false
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: go_oracle <cases.tsv>")
		os.Exit(2)
	}
	fh, err := os.Open(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	defer fh.Close()
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	sc := bufio.NewScanner(fh)
	sc.Buffer(make([]byte, 1<<20), 64<<20)
	for sc.Scan() {
		line := sc.Text()
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.SplitN(line, "\t", 3)
		if len(f) != 3 {
			fmt.Fprintf(os.Stderr, "bad case line: %q\n", line)
			os.Exit(2)
		}
		src, err := hex.DecodeString(f[2])
		if err != nil {
			fmt.Fprintf(os.Stderr, "bad hex in %s\n", f[0])
			os.Exit(2)
		}
		js, ok := func() (js string, ok bool) {
			defer func() {
				if r := recover(); r != nil {
					js, ok = "", false
				}
			}()
			return run(f[1], src)
		}()
		if ok {
			fmt.Fprintf(w, "%s\tOK\t%s\n", f[0], js)
		} else {
			fmt.Fprintf(w, "%s\tERR\t-\n", f[0])
		}
	}
}
