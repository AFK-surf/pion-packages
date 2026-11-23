// Fairness variants of bench/go_bench (copied verbatim, extra modes only) for the red-team audit.
//   w1load    : W1 without doc.Validate (LoadFromData + $ref resolution only)
//   w2reqonly : W2 loop without router.FindRoute (only http.NewRequest + strconv), same counters
//   w3route   : W3 loop up to router.FindRoute, without openapi3filter.ValidateRequest
package main

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"

	"github.com/getkin/kin-openapi/openapi3"
	"github.com/getkin/kin-openapi/openapi3filter"
	"github.com/getkin/kin-openapi/routers/gorillamux"
)

func fnv1aStr(seed uint32, s string) uint32 {
	h := seed
	for i := 0; i < len(s); i++ {
		h = (h ^ uint32(s[i])) * 16777619
	}
	return h
}

func buildLargeOpenAPISpec(numResources int) []byte {
	var sb strings.Builder
	sb.WriteString(`{"openapi":"3.0.3","info":{"title":"Cloud Platform API","version":"2.1.0"},"paths":{`)
	for i := 0; i < numResources; i++ {
		if i > 0 {
			sb.WriteString(",")
		}
		idx := strconv.Itoa(i)
		sb.WriteString(`"/v1/res` + idx + `":{`)
		sb.WriteString(`"get":{"operationId":"listRes` + idx + `","parameters":[{"$ref":"#/components/parameters/PageLimit"},{"$ref":"#/components/parameters/ApiKeyHeader"}],"responses":{"200":{"description":"ok","content":{"application/json":{"schema":{"type":"array","items":{"$ref":"#/components/schemas/Item` + idx + `"}}}}},"default":{"$ref":"#/components/responses/ApiError"}}},`)
		sb.WriteString(`"post":{"operationId":"createRes` + idx + `","parameters":[{"$ref":"#/components/parameters/PageLimit"},{"$ref":"#/components/parameters/ApiKeyHeader"}],"requestBody":{"required":true,"content":{"application/json":{"schema":{"$ref":"#/components/schemas/CreateItem` + idx + `"}}}},"responses":{"201":{"description":"created","content":{"application/json":{"schema":{"$ref":"#/components/schemas/Item` + idx + `"}}}},"default":{"$ref":"#/components/responses/ApiError"}}}`)
		sb.WriteString(`},`)

		sb.WriteString(`"/v1/res` + idx + `/featured":{"get":{"operationId":"featuredRes` + idx + `","responses":{"200":{"description":"featured","content":{"application/json":{"schema":{"$ref":"#/components/schemas/Item` + idx + `"}}}}}}},`)

		sb.WriteString(`"/v1/res` + idx + `/{id}":{"parameters":[{"name":"id","in":"path","required":true,"schema":{"type":"integer","minimum":1}}],`)
		sb.WriteString(`"get":{"operationId":"getRes` + idx + `","parameters":[{"$ref":"#/components/parameters/PageLimit"},{"$ref":"#/components/parameters/ApiKeyHeader"}],"responses":{"200":{"description":"item","content":{"application/json":{"schema":{"$ref":"#/components/schemas/Item` + idx + `"}}}},"default":{"$ref":"#/components/responses/ApiError"}}},`)
		sb.WriteString(`"delete":{"operationId":"deleteRes` + idx + `","responses":{"204":{"description":"deleted"}}}}`)
	}
	sb.WriteString(`},"components":{`)
	sb.WriteString(`"parameters":{`)
	sb.WriteString(`"PageLimit":{"name":"limit","in":"query","required":false,"schema":{"type":"integer","minimum":1,"maximum":100}},`)
	sb.WriteString(`"ApiKeyHeader":{"name":"X-Api-Key","in":"header","required":true,"schema":{"type":"string","minLength":8}}`)
	sb.WriteString(`},"responses":{`)
	sb.WriteString(`"ApiError":{"description":"error","content":{"application/json":{"schema":{"$ref":"#/components/schemas/Error"}}}}`)
	sb.WriteString(`},"schemas":{`)
	sb.WriteString(`"Error":{"type":"object","required":["code","message"],"properties":{"code":{"type":"integer"},"message":{"type":"string"}}}`)
	for i := 0; i < numResources; i++ {
		idx := strconv.Itoa(i)
		sb.WriteString(`,"Item` + idx + `":{"type":"object","required":["id","name","count"],"properties":{"id":{"type":"integer","minimum":1},"name":{"type":"string","minLength":1},"count":{"type":"integer","minimum":1},"tag":{"type":"string"}}}`)
		sb.WriteString(`,"CreateItem` + idx + `":{"type":"object","required":["name","count"],"properties":{"name":{"type":"string","minLength":1,"maxLength":64},"count":{"type":"integer","minimum":1,"maximum":10000},"tag":{"type":"string"}}}`)
	}
	sb.WriteString(`}}}`)
	return []byte(sb.String())
}

func runW1(iters int) {
	spec := buildLargeOpenAPISpec(50)
	ctx := context.Background()
	validCount := 0
	pathsCnt := 0
	opsCnt := 0
	var h uint32 = 2166136261
	for it := 0; it < iters; it++ {
		loader := openapi3.NewLoader()
		doc, err := loader.LoadFromData(spec)
		if err != nil {
			fmt.Fprintf(os.Stderr, "W1 load error: %v\n", err)
			os.Exit(1)
		}
		if err := doc.Validate(ctx); err == nil {
			validCount++
		}
		pathsCnt = doc.Paths.Len()
		ops := 0
		for _, pi := range doc.Paths.Map() {
			ops += len(pi.Operations())
		}
		opsCnt = ops
		h = fnv1aStr(h, doc.Info.Title)
		h = (h ^ uint32(ops)) * 16777619
	}
	fmt.Printf("W1 iters=%d paths=%d ops=%d valid=%d hash=%08x\n", iters, pathsCnt, opsCnt, validCount, h)
}

func runW2(ops int) {
	spec := buildLargeOpenAPISpec(50)
	loader := openapi3.NewLoader()
	doc, err := loader.LoadFromData(spec)
	if err != nil {
		fmt.Fprintf(os.Stderr, "W2 load error: %v\n", err)
		os.Exit(1)
	}
	router, err := gorillamux.NewRouter(doc)
	if err != nil {
		fmt.Fprintf(os.Stderr, "W2 router error: %v\n", err)
		os.Exit(1)
	}
	matched := 0
	notFound := 0
	var h uint32 = 2166136261
	for i := 0; i < ops; i++ {
		r := i % 50
		kind := i % 5
		rs := strconv.Itoa(r)
		idS := strconv.Itoa(i + 1)
		var method, path string
		switch kind {
		case 0:
			method, path = http.MethodGet, "/v1/res"+rs+"/featured"
		case 1:
			method, path = http.MethodGet, "/v1/res"+rs+"/"+idS
		case 2:
			method, path = http.MethodPost, "/v1/res"+rs
		case 3:
			method, path = http.MethodDelete, "/v1/res"+rs+"/"+idS
		default:
			method, path = http.MethodGet, "/v1/unknown/"+idS
		}
		req, _ := http.NewRequest(method, "http://localhost"+path, nil)
		route, pathParams, err := router.FindRoute(req)
		if err == nil {
			matched++
			if route.Operation != nil && route.Operation.OperationID != "" {
				h = fnv1aStr(h, route.Operation.OperationID)
			}
			if pv, ok := pathParams["id"]; ok {
				h = fnv1aStr(h, pv)
			}
		} else {
			notFound++
			h = fnv1aStr(h, "404")
		}
	}
	fmt.Printf("W2 ops=%d matched=%d not_found=%d hash=%08x\n", ops, matched, notFound, h)
}

func runW3(ops int) {
	spec := buildLargeOpenAPISpec(50)
	loader := openapi3.NewLoader()
	doc, err := loader.LoadFromData(spec)
	if err != nil {
		fmt.Fprintf(os.Stderr, "W3 load error: %v\n", err)
		os.Exit(1)
	}
	router, err := gorillamux.NewRouter(doc)
	if err != nil {
		fmt.Fprintf(os.Stderr, "W3 router error: %v\n", err)
		os.Exit(1)
	}
	ctx := context.Background()
	passed := 0
	failed := 0
	var h uint32 = 2166136261
	for i := 0; i < ops; i++ {
		r := i % 50
		rs := strconv.Itoa(r)
		kind := i % 4
		var req *http.Request
		switch kind {
		case 0:
			body := []byte(`{"name":"item-` + strconv.Itoa(i) + `","count":10,"tag":"alpha"}`)
			req, _ = http.NewRequest(http.MethodPost, "http://localhost/v1/res"+rs+"?limit=25", bytes.NewReader(body))
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("X-Api-Key", "key-12345678")
		case 1:
			body := []byte(`{"name":"item","count":10}`)
			req, _ = http.NewRequest(http.MethodPost, "http://localhost/v1/res"+rs+"?limit=25", bytes.NewReader(body))
			req.Header.Set("Content-Type", "application/json")
		case 2:
			body := []byte(`{"name":"","count":-5}`)
			req, _ = http.NewRequest(http.MethodPost, "http://localhost/v1/res"+rs, bytes.NewReader(body))
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("X-Api-Key", "key-12345678")
		default:
			req, _ = http.NewRequest(http.MethodGet, "http://localhost/v1/res"+rs+"/"+strconv.Itoa(i+1)+"?limit=10", nil)
			req.Header.Set("X-Api-Key", "key-12345678")
		}
		route, pathParams, err := router.FindRoute(req)
		if err != nil {
			failed++
			h = fnv1aStr(h, "0")
			continue
		}
		input := &openapi3filter.RequestValidationInput{
			Request:    req,
			PathParams: pathParams,
			Route:      route,
		}
		if err := openapi3filter.ValidateRequest(ctx, input); err == nil {
			passed++
			h = fnv1aStr(h, "1")
		} else {
			failed++
			h = fnv1aStr(h, "0")
		}
	}
	fmt.Printf("W3 ops=%d passed=%d failed=%d hash=%08x\n", ops, passed, failed, h)
}

func runW1Load(iters int) {
	spec := buildLargeOpenAPISpec(50)
	var h uint32 = 2166136261
	pathsCnt, opsCnt := 0, 0
	for it := 0; it < iters; it++ {
		loader := openapi3.NewLoader()
		doc, err := loader.LoadFromData(spec)
		if err != nil {
			fmt.Fprintf(os.Stderr, "W1 load error: %v\n", err)
			os.Exit(1)
		}
		pathsCnt = doc.Paths.Len()
		ops := 0
		for _, pi := range doc.Paths.Map() {
			ops += len(pi.Operations())
		}
		opsCnt = ops
		h = fnv1aStr(h, doc.Info.Title)
		h = (h ^ uint32(ops)) * 16777619
	}
	fmt.Printf("W1LOAD iters=%d paths=%d ops=%d hash=%08x\n", iters, pathsCnt, opsCnt, h)
}

func runW2ReqOnly(ops int) {
	var h uint32 = 2166136261
	for i := 0; i < ops; i++ {
		r := i % 50
		kind := i % 5
		rs := strconv.Itoa(r)
		idS := strconv.Itoa(i + 1)
		var method, path string
		switch kind {
		case 0:
			method, path = http.MethodGet, "/v1/res"+rs+"/featured"
		case 1:
			method, path = http.MethodGet, "/v1/res"+rs+"/"+idS
		case 2:
			method, path = http.MethodPost, "/v1/res"+rs
		case 3:
			method, path = http.MethodDelete, "/v1/res"+rs+"/"+idS
		default:
			method, path = http.MethodGet, "/v1/unknown/"+idS
		}
		req, _ := http.NewRequest(method, "http://localhost"+path, nil)
		h = fnv1aStr(h, req.URL.Path)
	}
	fmt.Printf("W2REQONLY ops=%d hash=%08x\n", ops, h)
}

func runW3Route(ops int) {
	spec := buildLargeOpenAPISpec(50)
	loader := openapi3.NewLoader()
	doc, err := loader.LoadFromData(spec)
	if err != nil {
		os.Exit(1)
	}
	router, err := gorillamux.NewRouter(doc)
	if err != nil {
		os.Exit(1)
	}
	var h uint32 = 2166136261
	for i := 0; i < ops; i++ {
		r := i % 50
		rs := strconv.Itoa(r)
		kind := i % 4
		var req *http.Request
		switch kind {
		case 0:
			body := []byte(`{"name":"item-` + strconv.Itoa(i) + `","count":10,"tag":"alpha"}`)
			req, _ = http.NewRequest(http.MethodPost, "http://localhost/v1/res"+rs+"?limit=25", bytes.NewReader(body))
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("X-Api-Key", "key-12345678")
		case 1:
			body := []byte(`{"name":"item","count":10}`)
			req, _ = http.NewRequest(http.MethodPost, "http://localhost/v1/res"+rs+"?limit=25", bytes.NewReader(body))
			req.Header.Set("Content-Type", "application/json")
		case 2:
			body := []byte(`{"name":"","count":-5}`)
			req, _ = http.NewRequest(http.MethodPost, "http://localhost/v1/res"+rs, bytes.NewReader(body))
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("X-Api-Key", "key-12345678")
		default:
			req, _ = http.NewRequest(http.MethodGet, "http://localhost/v1/res"+rs+"/"+strconv.Itoa(i+1)+"?limit=10", nil)
			req.Header.Set("X-Api-Key", "key-12345678")
		}
		route, _, err := router.FindRoute(req)
		if err == nil && route != nil {
			h = fnv1aStr(h, "1")
		}
	}
	fmt.Printf("W3ROUTE ops=%d hash=%08x\n", ops, h)
}

func main() {
	mode := "w1"
	if len(os.Args) >= 2 {
		mode = os.Args[1]
	}
	switch mode {
	case "w1":
		iters := 10
		if len(os.Args) >= 3 {
			if v, err := strconv.Atoi(os.Args[2]); err == nil {
				iters = v
			}
		}
		runW1(iters)
	case "w2":
		ops := 50000
		if len(os.Args) >= 3 {
			if v, err := strconv.Atoi(os.Args[2]); err == nil {
				ops = v
			}
		}
		runW2(ops)
	case "w3":
		ops := 10000
		if len(os.Args) >= 3 {
			if v, err := strconv.Atoi(os.Args[2]); err == nil {
				ops = v
			}
		}
		runW3(ops)
	case "w1load":
		runW1Load(10)
	case "w2reqonly":
		runW2ReqOnly(50000)
	case "w3route":
		runW3Route(10000)
	default:
		fmt.Fprintf(os.Stderr, "unknown mode: %s\n", mode)
		os.Exit(1)
	}
}
