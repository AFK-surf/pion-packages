package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"

	"github.com/itchyny/gojq"
)

func marshalCompact(v any) (string, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return "", err
	}
	b := buf.Bytes()
	if len(b) > 0 && b[len(b)-1] == '\n' {
		b = b[:len(b)-1]
	}
	return string(b), nil
}

func runQueryOnce(code *gojq.Code, doc any) ([]any, error) {
	iter := code.Run(doc)
	var out []any
	for {
		v, ok := iter.Next()
		if !ok {
			break
		}
		if err, isErr := v.(error); isErr {
			return nil, err
		}
		out = append(out, v)
	}
	return out, nil
}

func runW1(path string) int {
	raw, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	var doc any
	if err := json.Unmarshal(raw, &doc); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	q, err := gojq.Parse(`[.[] | select(.ok)] | group_by(.ns) | map({ns: .[0].ns, count: length, total_ms: (map(.latency_ms) | add), max_ms: (map(.latency_ms) | max)}) | sort_by(-.total_ms)`)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	code, err := gojq.Compile(q)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	var lastOut string
	for r := 0; r < 5; r++ {
		vals, err := runQueryOnce(code, doc)
		if err != nil || len(vals) != 1 {
			fmt.Fprintln(os.Stderr, "run error:", err)
			return 1
		}
		lastOut, err = marshalCompact(vals[0])
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
	}
	fmt.Println(lastOut)
	return 0
}

func runW2(path string) int {
	raw, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	var doc any
	if err := json.Unmarshal(raw, &doc); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	q, err := gojq.Parse(`(.. | objects | select(has("score") and .active) | .score) |= . * 2 + 1 | [.. | objects | select(has("score")) | .score] | {count: length, total: add, min: min, max: max}`)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	code, err := gojq.Compile(q)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	var lastOut string
	for r := 0; r < 10; r++ {
		vals, err := runQueryOnce(code, doc)
		if err != nil || len(vals) != 1 {
			fmt.Fprintln(os.Stderr, "run error:", err)
			return 1
		}
		lastOut, err = marshalCompact(vals[0])
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
	}
	fmt.Println(lastOut)
	return 0
}

func runW3(path string) int {
	raw, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	var doc any
	if err := json.Unmarshal(raw, &doc); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	queries := []string{
		`reduce .items[] as $x (0; . + $x.price * $x.qty)`,
		`def sum_tree: if type == "array" then (map(sum_tree) | add) elif type == "object" then ([.[]] | map(sum_tree) | add) elif type == "number" then . else 0 end; .nested | sum_tree`,
		`[.items[] | "\(.sku):\(.price)x\(.qty)"] | join("|")`,
		`[.items[] | [.sku, .category, .price, .qty] | @csv]`,
		`[.items[] | select(.sku | test("^[A-Z]{2}-[0-9]{3}$")) | .sku]`,
	}
	var buf bytes.Buffer
	for r := 0; r < 200; r++ {
		for _, qs := range queries {
			q, err := gojq.Parse(qs)
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				return 1
			}
			code, err := gojq.Compile(q)
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				return 1
			}
			vals, err := runQueryOnce(code, doc)
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				return 1
			}
			if r == 199 {
				for _, v := range vals {
					s, err := marshalCompact(v)
					if err != nil {
						fmt.Fprintln(os.Stderr, err)
						return 1
					}
					buf.WriteString(s)
					buf.WriteByte('\n')
				}
			}
		}
	}
	os.Stdout.Write(buf.Bytes())
	return 0
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: jq_bench_go <w1|w2|w3> <input.json>")
		os.Exit(1)
	}
	switch os.Args[1] {
	case "w1":
		os.Exit(runW1(os.Args[2]))
	case "w2":
		os.Exit(runW2(os.Args[2]))
	case "w3":
		os.Exit(runW3(os.Args[2]))
	default:
		fmt.Fprintln(os.Stderr, "unknown mode:", os.Args[1])
		os.Exit(1)
	}
}
