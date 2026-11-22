// Differential runner (Go net/http side): corpus `name<TAB>kind<TAB>hex` ->
// `name<TAB>verdict<TAB>detail` with verdict OK <framing|bodylen> / PARTIAL / ERR.
package main

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
)

func partial(err error) bool {
	return errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, io.EOF)
}

func framing(te []string, cl int64, hasCL bool) string {
	for _, t := range te {
		if strings.EqualFold(t, "chunked") {
			return "chunked"
		}
	}
	if hasCL && cl > 0 {
		return fmt.Sprintf("cl=%d", cl)
	}
	return "none"
}

func countHostLines(raw []byte) int {
	end := bytes.Index(raw, []byte("\r\n\r\n"))
	if end < 0 {
		end = len(raw)
	}
	n := 0
	for _, l := range strings.Split(string(raw[:end]), "\r\n")[1:] {
		if i := strings.IndexByte(l, ':'); i >= 0 && strings.EqualFold(l[:i], "host") {
			n++
		}
	}
	return n
}

// validHostHeader mirrors golang.org/x/net/http/httpguts.ValidHostHeader (used by the
// net/http server): every byte must be in validHostByte.
func validHostHeader(h string) bool {
	for i := 0; i < len(h); i++ {
		c := h[i]
		ok := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
			strings.IndexByte("!$%&'()*+,-.:;=[]_~", c) >= 0
		if !ok {
			return false
		}
	}
	return true
}

func main() {
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}
	for _, line := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
		f := strings.Split(line, "\t")
		raw, _ := hex.DecodeString(f[2])
		var out string
		switch f[1] {
		case "req":
			req, err := http.ReadRequest(bufio.NewReader(bytes.NewReader(raw)))
			switch {
			case err != nil && partial(err):
				out = "PARTIAL\t"
			case err != nil:
				out = "ERR\t" + err.Error()
			default:
				// The net/http *server* (server.go readRequest) additionally enforces
				// RFC 9112 §3.2 on the Host field lines, which exported ReadRequest has
				// already moved out of req.Header; replay those checks on the raw lines.
				nHost := countHostLines(raw)
				if req.ProtoAtLeast(1, 1) && nHost == 0 && req.Method != "CONNECT" {
					out = "ERR\tmissing required Host header (net/http server)"
				} else if nHost == 1 && !validHostHeader(req.Host) {
					out = "ERR\tmalformed Host header (net/http server)"
				} else {
					_, hasCL := req.Header["Content-Length"]
					out = "OK " + framing(req.TransferEncoding, req.ContentLength, hasCL || req.ContentLength > 0) + "\t"
				}
			}
		case "resp":
			resp, err := http.ReadResponse(bufio.NewReader(bytes.NewReader(raw)), nil)
			switch {
			case err != nil && partial(err):
				out = "PARTIAL\t"
			case err != nil:
				out = "ERR\t" + err.Error()
			default:
				if resp.Body == http.NoBody {
					// 1xx / 204 / 304 (and HEAD): net/http never reads a body.
					out = "OK none\t"
				} else {
					out = "OK " + framing(resp.TransferEncoding, resp.ContentLength, resp.ContentLength > 0) + "\t"
				}
			}
		case "chunked":
			msg := append([]byte("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"), raw...)
			resp, err := http.ReadResponse(bufio.NewReader(bytes.NewReader(msg)), nil)
			if err != nil {
				out = "ERR\t" + err.Error()
				break
			}
			body, err := io.ReadAll(resp.Body)
			switch {
			case err != nil && partial(err):
				out = "PARTIAL\t"
			case err != nil:
				out = "ERR\t" + err.Error()
			default:
				out = fmt.Sprintf("OK %d\t", len(body))
			}
		}
		fmt.Printf("%s\t%s\n", f[0], out)
	}
}
