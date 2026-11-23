// Differential oracle for packages/openapi red-team audit: Go github.com/getkin/kin-openapi v0.131.0.
//
// Reads JSONL cases on stdin. Each case:
//
//	{"id": str, "spec": str (JSON or YAML text), "ops": [op, ...]}
//
// op kinds:
//
//	{"k":"route","m":"GET","p":"/users/1"}
//	{"k":"req","m":..,"p":..,"q":[[k,v]],"h":[[k,v]],"c":[[k,v]],"ct":str|null,"b":str|null}
//	{"k":"resp", same request fields, "st":200,"rh":[[k,v]],"rct":str|null,"rb":str|null}
//
// Prints one line per case:  id<TAB>load=..<TAB>valid=..<TAB>op results joined by '|'
// Route results: "op:<operationId>[,<k>=<v>...]" | "404" | "405"; req/resp: "ok" | "err".
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"

	"github.com/getkin/kin-openapi/openapi3"
	"github.com/getkin/kin-openapi/openapi3filter"
	"github.com/getkin/kin-openapi/routers"
	"github.com/getkin/kin-openapi/routers/gorillamux"
)

type Op struct {
	K   string      `json:"k"`
	M   string      `json:"m"`
	P   string      `json:"p"`
	Q   [][2]string `json:"q"`
	H   [][2]string `json:"h"`
	C   [][2]string `json:"c"`
	CT  *string     `json:"ct"`
	B   *string     `json:"b"`
	St  int         `json:"st"`
	RH  [][2]string `json:"rh"`
	RCT *string     `json:"rct"`
	RB  *string     `json:"rb"`
}

type Case struct {
	ID   string `json:"id"`
	Spec string `json:"spec"`
	Ops  []Op   `json:"ops"`
}

func buildReq(o Op) *http.Request {
	var body io.Reader
	if o.B != nil {
		body = bytes.NewReader([]byte(*o.B))
	}
	raw := "http://localhost" + o.P
	if len(o.Q) > 0 {
		parts := make([]string, 0, len(o.Q))
		for _, kv := range o.Q {
			parts = append(parts, url.QueryEscape(kv[0])+"="+url.QueryEscape(kv[1]))
		}
		raw += "?" + strings.Join(parts, "&")
	}
	req, err := http.NewRequest(o.M, raw, body)
	if err != nil {
		return nil
	}
	for _, kv := range o.H {
		req.Header.Add(kv[0], kv[1])
	}
	for _, kv := range o.C {
		req.AddCookie(&http.Cookie{Name: kv[0], Value: kv[1]})
	}
	if o.CT != nil {
		req.Header.Set("Content-Type", *o.CT)
	}
	return req
}

func routeStr(router routers.Router, req *http.Request) (string, *routers.Route, map[string]string) {
	if req == nil {
		return "badreq", nil, nil
	}
	route, params, err := router.FindRoute(req)
	if err != nil {
		if err == routers.ErrMethodNotAllowed {
			return "405", nil, nil
		}
		return "404", nil, nil
	}
	s := "op:" + route.Operation.OperationID
	keys := make([]string, 0, len(params))
	for k := range params {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		// gorillamux leaves path params percent-encoded (UseEncodedPath); decode like openapi3filter does
		v, err := url.PathUnescape(params[k])
		if err != nil {
			v = params[k]
		}
		s += "," + k + "=" + v
	}
	return s, route, params
}

func run(c Case) string {
	ctx := context.Background()
	loader := openapi3.NewLoader()
	loader.IsExternalRefsAllowed = false
	doc, err := loader.LoadFromData([]byte(c.Spec))
	if err != nil {
		return c.ID + "\tload=err\tvalid=-\t-"
	}
	valid := "ok"
	if err := doc.Validate(ctx); err != nil {
		valid = "err"
	}
	router, err := gorillamux.NewRouter(doc)
	if err != nil {
		return c.ID + "\tload=ok\tvalid=" + valid + "\trouter=err"
	}
	opts := &openapi3filter.Options{AuthenticationFunc: openapi3filter.NoopAuthenticationFunc, IncludeResponseStatus: true}
	res := make([]string, 0, len(c.Ops))
	for _, o := range c.Ops {
		req := buildReq(o)
		rs, route, params := routeStr(router, req)
		switch o.K {
		case "route":
			res = append(res, rs)
		case "req":
			if route == nil {
				res = append(res, "R"+rs)
				continue
			}
			in := &openapi3filter.RequestValidationInput{Request: req, PathParams: params, Route: route, Options: opts}
			if err := openapi3filter.ValidateRequest(ctx, in); err != nil {
				res = append(res, "err")
			} else {
				res = append(res, "ok")
			}
		case "resp":
			if route == nil {
				res = append(res, "R"+rs)
				continue
			}
			in := &openapi3filter.RequestValidationInput{Request: req, PathParams: params, Route: route, Options: opts}
			h := http.Header{}
			for _, kv := range o.RH {
				h.Add(kv[0], kv[1])
			}
			ct := "application/json"
			if o.RCT != nil {
				ct = *o.RCT
			}
			h.Set("Content-Type", ct)
			var rb []byte
			if o.RB != nil {
				rb = []byte(*o.RB)
			}
			rin := &openapi3filter.ResponseValidationInput{RequestValidationInput: in, Status: o.St, Header: h, Options: opts}
			rin.SetBodyBytes(rb)
			if err := openapi3filter.ValidateResponse(ctx, rin); err != nil {
				res = append(res, "err")
			} else {
				res = append(res, "ok")
			}
		}
	}
	return c.ID + "\tload=ok\tvalid=" + valid + "\t" + strings.Join(res, "|")
}

// dosMode: go_oracle <stage> <spec-file>  (stage: parse | validate | from_doc) — same stages as dos/pion_dos.
// from_doc = load + gorillamux.NewRouter (kin keeps $ref as shared pointers; nothing is pre-expanded).
func dosMode(stage, file string) {
	data, err := os.ReadFile(file)
	if err != nil {
		fmt.Println("error: cannot read spec")
		os.Exit(2)
	}
	loader := openapi3.NewLoader()
	loader.IsExternalRefsAllowed = false
	doc, err := loader.LoadFromData(data)
	if err != nil {
		fmt.Printf("parse\tERR\t%.80s\n", err.Error())
		return
	}
	switch stage {
	case "parse":
		fmt.Printf("parse\tOK\tpaths=%d\n", doc.Paths.Len())
	case "validate":
		if err := doc.Validate(context.Background()); err != nil {
			fmt.Printf("validate\tOK\tissues=1 %.60s\n", err.Error())
		} else {
			fmt.Println("validate\tOK\tissues=0")
		}
	default:
		if _, err := gorillamux.NewRouter(doc); err != nil {
			fmt.Printf("from_doc\tERR\t%.60s\n", err.Error())
		} else {
			fmt.Println("from_doc\tOK")
		}
	}
}

func main() {
	if len(os.Args) == 3 {
		dosMode(os.Args[1], os.Args[2])
		return
	}
	sc := bufio.NewScanner(os.Stdin)
	sc.Buffer(make([]byte, 1<<20), 64<<20)
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	for sc.Scan() {
		line := sc.Bytes()
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		var c Case
		if err := json.Unmarshal(line, &c); err != nil {
			fmt.Fprintln(w, "?\tbadcase")
			continue
		}
		func() {
			defer func() {
				if r := recover(); r != nil {
					fmt.Fprintln(w, c.ID+"\tpanic")
				}
			}()
			fmt.Fprintln(w, run(c))
		}()
	}
}
