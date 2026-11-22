// Red-team handshake differential runner: coder/websocket v1.8.14 Accept / Dial.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha1"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/coder/websocket"
)

type nopConn struct{ bytes.Buffer }

func (c *nopConn) Close() error                       { return nil }
func (c *nopConn) LocalAddr() net.Addr                { return addr{} }
func (c *nopConn) RemoteAddr() net.Addr               { return addr{} }
func (c *nopConn) SetDeadline(t time.Time) error      { return nil }
func (c *nopConn) SetReadDeadline(t time.Time) error  { return nil }
func (c *nopConn) SetWriteDeadline(t time.Time) error { return nil }

type addr struct{}

func (addr) Network() string { return "mem" }
func (addr) String() string  { return "mem" }

type hijackRW struct {
	hdr    http.Header
	status int
}

func (h *hijackRW) Header() http.Header         { return h.hdr }
func (h *hijackRW) Write(p []byte) (int, error) { return len(p), nil }
func (h *hijackRW) WriteHeader(s int)           { h.status = s }
func (h *hijackRW) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	c := &nopConn{}
	return c, bufio.NewReadWriter(bufio.NewReader(c), bufio.NewWriter(c)), nil
}

func accept(key string) string {
	h := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	return base64.StdEncoding.EncodeToString(h[:])
}

type rwc struct{ *nopConn }

type rawRT struct{ raw string }

func (f rawRT) RoundTrip(r *http.Request) (*http.Response, error) {
	raw := strings.ReplaceAll(f.raw, "{ACCEPT}", accept(r.Header.Get("Sec-WebSocket-Key")))
	resp, err := http.ReadResponse(bufio.NewReader(strings.NewReader(raw)), r)
	if err != nil {
		return nil, err
	}
	resp.Body = rwc{&nopConn{}}
	return resp, nil
}

var _ io.ReadWriteCloser = rwc{}

func main() {
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}
	for _, l := range strings.Split(string(data), "\n") {
		if l == "" {
			continue
		}
		p := strings.Split(l, " ")
		rawb, _ := hex.DecodeString(p[2])
		raw := string(rawb)
		res := "ERR"
		if p[1] == "req" {
			req, err := http.ReadRequest(bufio.NewReader(strings.NewReader(raw)))
			if err == nil {
				rw := &hijackRW{hdr: http.Header{}}
				c, err := websocket.Accept(rw, req, &websocket.AcceptOptions{InsecureSkipVerify: true})
				if err == nil {
					res = "OK key=" + req.Header.Get("Sec-WebSocket-Key")
					c.CloseNow()
				}
			}
		} else {
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			c, _, err := websocket.Dial(ctx, "ws://example.com/ws", &websocket.DialOptions{HTTPClient: &http.Client{Transport: rawRT{raw}}})
			cancel()
			if err == nil {
				res = "OK"
				c.CloseNow()
			}
		}
		fmt.Println(p[0], res)
	}
	// Builder: a subprotocol carrying CRLF must not reach the wire as an extra header.
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, _, err = websocket.Dial(ctx, "ws://127.0.0.1:1/ws", &websocket.DialOptions{Subprotocols: []string{"chat\r\nX-Evil: 1"}})
	if err != nil && strings.Contains(err.Error(), "invalid header field value") {
		fmt.Println("builder_crlf_subprotocol REJECTED")
	} else {
		fmt.Println("builder_crlf_subprotocol INJECTED", err)
	}
}
