// Red-team differential oracle for packages/jq: runs a JSON corpus of
// [query, input_json] pairs through github.com/itchyny/gojq v0.12.17 and
// emits one JSON result line per case (same schema as audit/diff/pion_runner).
//
//	oracle run <corpus.json>          -> {"ok":[<sorted compact json>...]} | {"err":"..."} | {"timeout":true}
//	oracle yaml <gojq cli/test.yaml>  -> corpus JSON extracted from gojq's own CLI test-suite
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/itchyny/gojq"
	"gopkg.in/yaml.v3"
)

type result struct {
	Ok      []string `json:"ok,omitempty"`
	Err     *string  `json:"err,omitempty"`
	Timeout bool     `json:"timeout,omitempty"`
}

const maxOutputs = 100000

// timeout per case; RT_TIMEOUT_MS overrides the 3 s default (audit/dos uses a longer one).
func timeout() time.Duration {
	if ms, err := strconv.Atoi(os.Getenv("RT_TIMEOUT_MS")); err == nil && ms > 0 {
		return time.Duration(ms) * time.Millisecond
	}
	return 3 * time.Second
}

func runCase(q, in string) result {
	dec := json.NewDecoder(strings.NewReader(in))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		s := "invalid json: " + err.Error()
		return result{Err: &s}
	}
	query, err := gojq.Parse(q)
	if err != nil {
		s := "syntax: " + err.Error()
		return result{Err: &s}
	}
	code, err := gojq.Compile(query)
	if err != nil {
		s := "compile: " + err.Error()
		return result{Err: &s}
	}
	ch := make(chan result, 1)
	go func() {
		defer func() {
			if r := recover(); r != nil {
				s := fmt.Sprintf("panic: %v", r)
				ch <- result{Err: &s}
			}
		}()
		out := []string{}
		iter := code.Run(v)
		for {
			x, ok := iter.Next()
			if !ok {
				break
			}
			if e, isErr := x.(error); isErr {
				s := "runtime: " + e.Error()
				ch <- result{Err: &s}
				return
			}
			b, err := gojq.Marshal(x)
			if err != nil {
				s := "marshal: " + err.Error()
				ch <- result{Err: &s}
				return
			}
			out = append(out, string(b))
			if len(out) > maxOutputs {
				s := "too many outputs"
				ch <- result{Err: &s}
				return
			}
		}
		ch <- result{Ok: out}
	}()
	select {
	case r := <-ch:
		return r
	case <-time.After(timeout()):
		return result{Timeout: true}
	}
}

func cmdRun(path string) int {
	raw, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	var cases [][2]string
	if err := json.Unmarshal(raw, &cases); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	for _, c := range cases {
		r := runCase(c[0], c[1])
		var buf bytes.Buffer
		enc := json.NewEncoder(&buf)
		enc.SetEscapeHTML(false)
		if r.Ok == nil && r.Err == nil && !r.Timeout {
			r.Ok = []string{}
		}
		if r.Err == nil && !r.Timeout {
			// force "ok":[] to be present even when empty
			b, _ := json.Marshal(map[string][]string{"ok": r.Ok})
			w.Write(b)
			w.WriteByte('\n')
			continue
		}
		enc.Encode(r)
		w.Write(buf.Bytes())
	}
	return 0
}

type yamlCase struct {
	Name     string   `yaml:"name"`
	Args     []string `yaml:"args"`
	Input    string   `yaml:"input"`
	Expected string   `yaml:"expected"`
	Error    string   `yaml:"error"`
	Env      []string `yaml:"env"`
}

// cmdYaml keeps only cases whose sole argument is the query (no flags, env,
// modules or --arg), splitting multi-value inputs into one case per value.
func cmdYaml(path string) int {
	raw, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	var cs []yamlCase
	if err := yaml.Unmarshal(raw, &cs); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	out := [][2]string{}
	for _, c := range cs {
		if len(c.Args) != 1 || len(c.Env) > 0 || strings.HasPrefix(c.Args[0], "-") {
			continue
		}
		q := c.Args[0]
		if strings.Contains(q, "input") || strings.Contains(q, "$__") || strings.Contains(q, "$ENV") ||
			strings.Contains(q, "env") || strings.Contains(q, "import") || strings.Contains(q, "include") {
			continue
		}
		dec := json.NewDecoder(strings.NewReader(c.Input))
		dec.UseNumber()
		for {
			var v json.RawMessage
			if err := dec.Decode(&v); err != nil {
				if err != io.EOF {
					// non-JSON input (raw/yaml) - skip
				}
				break
			}
			out = append(out, [2]string{q, string(v)})
		}
	}
	b, _ := json.Marshal(out)
	os.Stdout.Write(b)
	return 0
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: oracle run <corpus.json> | oracle yaml <test.yaml>")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "run":
		os.Exit(cmdRun(os.Args[2]))
	case "yaml":
		os.Exit(cmdYaml(os.Args[2]))
	}
	os.Exit(2)
}
