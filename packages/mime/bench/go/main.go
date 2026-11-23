package main

import (
	"bytes"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"mime/quotedprintable"
	"os"
	"strings"
)

func mix(h, v int64) int64 {
	return ((h * 131) + v) % 1000000007
}

func hashStr(h0 int64, s string) int64 {
	h := mix(h0, int64(len(s)))
	for i := 0; i < len(s); i++ {
		h = mix(h, int64(s[i]))
	}
	return h
}

func hashBytesSampled(h0 int64, b []byte) int64 {
	n := len(b)
	h := mix(h0, int64(n))
	if n == 0 {
		return h
	}
	for i := 0; i < n; i += 64 {
		h = mix(h, int64(b[i]))
	}
	h = mix(h, int64(b[n-1]))
	return h
}

func benchMultipart(data []byte) {
	r := multipart.NewReader(bytes.NewReader(data), "pion-bench-boundary-2026")
	var parts int64
	var bodyBytes int64
	var checksum int64
	for {
		p, err := r.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			os.Exit(2)
		}
		body, err := io.ReadAll(p)
		if err != nil {
			os.Exit(3)
		}
		parts++
		bodyBytes += int64(len(body))
		checksum = hashBytesSampled(checksum, body)
		if fn := p.FormName(); fn != "" {
			checksum = hashStr(checksum, fn)
		}
	}
	fmt.Println("mode=multipart")
	fmt.Printf("parts=%d\n", parts)
	fmt.Printf("body_bytes=%d\n", bodyBytes)
	fmt.Printf("checksum=%d\n", checksum)
}

func benchHeadersFull(data []byte) {
	rawLines := strings.Split(strings.TrimRight(string(data), "\r\n"), "\n")
	kinds := make([]byte, 0, len(rawLines))
	payloads := make([]string, 0, len(rawLines))
	for _, ln := range rawLines {
		ln = strings.TrimRight(ln, "\r")
		if len(ln) >= 2 {
			kinds = append(kinds, ln[0])
			payloads = append(payloads, ln[2:])
		}
	}
	dec := new(mime.WordDecoder)
	var ops int64
	var checksum int64
	for round := 0; round < 200; round++ {
		for j, p := range payloads {
			switch kinds[j] {
			case 'M':
				mt, params, err := mime.ParseMediaType(p)
				if err != nil {
					os.Exit(1)
				}
				checksum = hashStr(checksum, mt)
				checksum = mix(checksum, int64(len(params)))
			case 'D':
				disp, params, err := mime.ParseMediaType(p)
				if err != nil {
					os.Exit(2)
				}
				checksum = hashStr(checksum, disp)
				if fn, ok := params["filename"]; ok {
					checksum = hashStr(checksum, fn)
				}
			default:
				s, err := dec.DecodeHeader(p)
				if err != nil {
					os.Exit(3)
				}
				checksum = hashStr(checksum, s)
			}
			ops++
		}
	}
	fmt.Println("mode=headers_full")
	fmt.Printf("ops=%d\n", ops)
	fmt.Printf("checksum=%d\n", checksum)
}

func benchHeadersMt(data []byte) {
	rawLines := strings.Split(strings.TrimRight(string(data), "\r\n"), "\n")
	lines := make([]string, 0, len(rawLines))
	for _, ln := range rawLines {
		ln = strings.TrimRight(ln, "\r")
		if len(ln) > 0 {
			lines = append(lines, ln)
		}
	}
	var ops int64
	var checksum int64
	for round := 0; round < 200; round++ {
		for _, ln := range lines {
			mt, params, err := mime.ParseMediaType(ln)
			if err != nil {
				os.Exit(1)
			}
			checksum = hashStr(checksum, mt)
			if cs, ok := params["charset"]; ok {
				checksum = hashStr(checksum, cs)
			}
			ops++
		}
	}
	fmt.Println("mode=headers_mt")
	fmt.Printf("ops=%d\n", ops)
	fmt.Printf("checksum=%d\n", checksum)
}

func benchQP(data []byte) {
	dec, err := io.ReadAll(quotedprintable.NewReader(bytes.NewReader(data)))
	if err != nil {
		os.Exit(1)
	}
	checksum := hashBytesSampled(0, dec)
	fmt.Println("mode=qp")
	fmt.Printf("decoded_bytes=%d\n", len(dec))
	fmt.Printf("checksum=%d\n", checksum)
}

func main() {
	if len(os.Args) < 3 {
		fmt.Println("usage: go_mime_bench <mode> <corpus_path>")
		os.Exit(1)
	}
	mode := os.Args[1]
	data, err := os.ReadFile(os.Args[2])
	if err != nil {
		os.Exit(1)
	}
	switch mode {
	case "multipart":
		benchMultipart(data)
	case "headers_full":
		benchHeadersFull(data)
	case "headers_mt":
		benchHeadersMt(data)
	case "qp":
		benchQP(data)
	default:
		fmt.Println("unknown mode:", mode)
		os.Exit(1)
	}
}
