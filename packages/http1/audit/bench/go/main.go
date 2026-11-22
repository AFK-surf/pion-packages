// Adversarial head-to-head runner (Go net/http side) for the http1 red-team audit.
// The SSE decoder is copied verbatim from packages/http1/bench/go (a hand port).
package main

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"testing/iotest"
)

const mod int64 = 1000000007

func hashStr(h int64, s string) int64 {
	for i := 0; i < len(s); i++ {
		h = (h*131 + int64(s[i])) % mod
	}
	return h
}

func benchReq64(data []byte) {
	var count, headers, hash int64
	for round := 0; round < 4; round++ {
		br := bufio.NewReaderSize(bytes.NewReader(data), 65536)
		for {
			if _, err := br.Peek(1); err == io.EOF {
				break
			}
			req, err := http.ReadRequest(br)
			if err != nil {
				fmt.Fprintln(os.Stderr, "req parse error:", err)
				os.Exit(1)
			}
			count++
			n := int64(0)
			if req.Host != "" {
				n++
			}
			for _, vs := range req.Header {
				n += int64(len(vs))
			}
			headers += n
			hash = hashStr(hash, req.Method)
			hash = hashStr(hash, req.RequestURI)
			hash = hashStr(hash, req.Host)
			hash = hashStr(hash, req.Header.Get("X-Request-Id"))
		}
	}
	fmt.Printf("mode=req64\ncount=%d\nheaders=%d\nhash=%d\n", count, headers, hash)
}

func benchChunk1m(data []byte) {
	var count, body, hash int64
	buf := make([]byte, 65536)
	for round := 0; round < 16; round++ {
		br := bufio.NewReaderSize(bytes.NewReader(data), 65536)
		for {
			if _, err := br.Peek(1); err == io.EOF {
				break
			}
			resp, err := http.ReadResponse(br, nil)
			if err != nil {
				fmt.Fprintln(os.Stderr, "resp parse error:", err)
				os.Exit(1)
			}
			count++
			var off int64
			for {
				n, rerr := resp.Body.Read(buf)
				d := buf[:n]
				k := (off+4095)/4096*4096 - off
				for ; k < int64(n); k += 4096 {
					hash = (hash*131 + int64(d[k])) % mod
				}
				off += int64(n)
				if rerr == io.EOF {
					break
				}
				if rerr != nil {
					fmt.Fprintln(os.Stderr, "body error:", rerr)
					os.Exit(1)
				}
			}
			resp.Body.Close()
			body += off
		}
	}
	fmt.Printf("mode=chunk1m\ncount=%d\nbody_bytes=%d\nhash=%d\n", count, body, hash)
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
	fmt.Printf("mode=sse_multiline\nevents=%d\ndata_bytes=%d\nhash=%d\n", events, dataBytes, hash)
}

// Go reads the drip through bufio over a one-byte reader: incremental, no re-scan.
func benchDrip(data []byte) {
	complete := 0
	for round := 0; round < 4; round++ {
		br := bufio.NewReader(iotest.OneByteReader(bytes.NewReader(data)))
		if _, err := http.ReadRequest(br); err != nil {
			fmt.Fprintln(os.Stderr, "drip error:", err)
			os.Exit(1)
		}
		complete++
	}
	fmt.Printf("mode=drip\nbytes=%d\ncomplete=%d\n", len(data), complete)
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: adv_go <req64|chunk1m|sse_multiline|drip> <file>")
		os.Exit(1)
	}
	data, err := os.ReadFile(os.Args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	switch os.Args[1] {
	case "req64":
		benchReq64(data)
	case "chunk1m":
		benchChunk1m(data)
	case "sse_multiline":
		benchSSE(data)
	case "drip":
		benchDrip(data)
	default:
		fmt.Fprintln(os.Stderr, "unknown mode")
		os.Exit(1)
	}
}
