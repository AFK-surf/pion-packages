package main

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
)

const mod int64 = 1000000007

func hashStr(h int64, s string) int64 {
	for i := 0; i < len(s); i++ {
		h = (h*131 + int64(s[i])) % mod
	}
	return h
}

func hashBytes(h int64, b []byte) int64 {
	for i := 0; i < len(b); i++ {
		h = (h*131 + int64(b[i])) % mod
	}
	return h
}

func benchReq(data []byte) {
	var count, totalHeaders, totalBytes, hash int64
	for round := 0; round < 4; round++ {
		br := bufio.NewReaderSize(bytes.NewReader(data), 65536)
		for {
			if _, err := br.Peek(1); err == io.EOF {
				break
			}
			req, err := http.ReadRequest(br)
			if err != nil {
				fmt.Fprintf(os.Stderr, "req parse error: %v\n", err)
				os.Exit(1)
			}
			count++
			// net/http moves Host out of req.Header into req.Host
			hcnt := int64(0)
			if req.Host != "" {
				hcnt++
			}
			for _, vs := range req.Header {
				hcnt += int64(len(vs))
			}
			totalHeaders += hcnt
			hash = hashStr(hash, req.Method)
			hash = hashStr(hash, req.RequestURI)
			hash = hashStr(hash, req.Host)
			hash = hashStr(hash, req.Header.Get("X-Request-Id"))
		}
		totalBytes += int64(len(data))
	}
	fmt.Println("mode=req")
	fmt.Printf("count=%d\n", count)
	fmt.Printf("headers=%d\n", totalHeaders)
	fmt.Printf("bytes=%d\n", totalBytes)
	fmt.Printf("hash=%d\n", hash)
}

func benchRespChunked(data []byte) {
	var count, totalBody, hash int64
	bodyBuf := make([]byte, 0, 4096)
	for round := 0; round < 4; round++ {
		br := bufio.NewReaderSize(bytes.NewReader(data), 65536)
		for {
			if _, err := br.Peek(1); err == io.EOF {
				break
			}
			resp, err := http.ReadResponse(br, nil)
			if err != nil {
				fmt.Fprintf(os.Stderr, "resp parse error: %v\n", err)
				os.Exit(1)
			}
			count++
			hash = (hash*131 + int64(resp.StatusCode)) % mod
			hash = hashStr(hash, resp.Header.Get("Content-Type"))
			bodyBuf = bodyBuf[:0]
			var tmp [4096]byte
			for {
				n, rerr := resp.Body.Read(tmp[:])
				if n > 0 {
					totalBody += int64(n)
					hash = hashBytes(hash, tmp[:n])
				}
				if rerr == io.EOF {
					break
				}
				if rerr != nil {
					fmt.Fprintf(os.Stderr, "chunked read error: %v\n", rerr)
					os.Exit(1)
				}
			}
			resp.Body.Close()
		}
	}
	fmt.Println("mode=resp_chunked")
	fmt.Printf("count=%d\n", count)
	fmt.Printf("body_bytes=%d\n", totalBody)
	fmt.Printf("hash=%d\n", hash)
}

type sseDecoder struct {
	bomState   int
	skipNextLF bool
	lineBuf    []byte
	eventType  string
	dataBuf    strings.Builder
	hasData    bool
	lastID     string
}

func (d *sseDecoder) processLine(line []byte, events, dataBytes, hash *int64) {
	if len(line) == 0 {
		if d.hasData {
			et := d.eventType
			if et == "" {
				et = "message"
			}
			ds := d.dataBuf.String()
			*events++
			*dataBytes += int64(len(ds))
			*hash = hashStr(*hash, et)
			*hash = hashStr(*hash, d.lastID)
			*hash = hashStr(*hash, ds)
			d.dataBuf.Reset()
			d.hasData = false
			d.eventType = ""
		} else {
			d.eventType = ""
		}
		return
	}
	if line[0] == ':' {
		return
	}
	colon := bytes.IndexByte(line, ':')
	var field, val []byte
	if colon >= 0 {
		field = line[:colon]
		vs := colon + 1
		if vs < len(line) && line[vs] == ' ' {
			vs++
		}
		val = line[vs:]
	} else {
		field = line
	}
	switch string(field) {
	case "data":
		if d.hasData {
			d.dataBuf.WriteByte('\n')
		}
		d.dataBuf.Write(val)
		d.hasData = true
	case "event":
		d.eventType = string(val)
	case "id":
		if bytes.IndexByte(val, 0) < 0 {
			d.lastID = string(val)
		}
	}
}

func (d *sseDecoder) feed(chunk []byte, events, dataBytes, hash *int64) {
	pos := 0
	for pos < len(chunk) && d.bomState < 3 {
		b := chunk[pos]
		switch d.bomState {
		case 0:
			if b == 0xEF {
				d.bomState = 1
				pos++
			} else {
				d.bomState = 3
			}
		case 1:
			if b == 0xBB {
				d.bomState = 2
				pos++
			} else {
				d.bomState = 3
				d.lineBuf = append(d.lineBuf, 0xEF)
			}
		case 2:
			if b == 0xBF {
				d.bomState = 3
				pos++
			} else {
				d.bomState = 3
				d.lineBuf = append(d.lineBuf, 0xEF, 0xBB)
			}
		}
	}
	for pos < len(chunk) {
		if d.skipNextLF {
			d.skipNextLF = false
			if chunk[pos] == '\n' {
				pos++
				continue
			}
		}
		segStart := pos
		for pos < len(chunk) && chunk[pos] != '\n' && chunk[pos] != '\r' {
			pos++
		}
		if pos < len(chunk) {
			nl := chunk[pos]
			if len(d.lineBuf) == 0 {
				d.processLine(chunk[segStart:pos], events, dataBytes, hash)
			} else {
				d.lineBuf = append(d.lineBuf, chunk[segStart:pos]...)
				d.processLine(d.lineBuf, events, dataBytes, hash)
				d.lineBuf = d.lineBuf[:0]
			}
			if nl == '\r' {
				if pos+1 < len(chunk) && chunk[pos+1] == '\n' {
					pos += 2
				} else if pos+1 >= len(chunk) {
					d.skipNextLF = true
					pos++
				} else {
					pos++
				}
			} else {
				pos++
			}
		} else {
			d.lineBuf = append(d.lineBuf, chunk[segStart:]...)
		}
	}
}

func benchSSE(data []byte) {
	var events, dataBytes, hash int64
	for round := 0; round < 2; round++ {
		dec := &sseDecoder{lineBuf: make([]byte, 0, 256)}
		for off := 0; off < len(data); off += 4096 {
			end := off + 4096
			if end > len(data) {
				end = len(data)
			}
			dec.feed(data[off:end], &events, &dataBytes, &hash)
		}
	}
	fmt.Println("mode=sse")
	fmt.Printf("events=%d\n", events)
	fmt.Printf("data_bytes=%d\n", dataBytes)
	fmt.Printf("hash=%d\n", hash)
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: http1_bench_go <req|resp_chunked|sse> <file>")
		os.Exit(1)
	}
	data, err := os.ReadFile(os.Args[2])
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to read %s: %v\n", os.Args[2], err)
		os.Exit(1)
	}
	switch os.Args[1] {
	case "req":
		benchReq(data)
	case "resp_chunked":
		benchRespChunked(data)
	case "sse":
		benchSSE(data)
	default:
		fmt.Fprintf(os.Stderr, "unknown mode: %s\n", os.Args[1])
		os.Exit(1)
	}
}
