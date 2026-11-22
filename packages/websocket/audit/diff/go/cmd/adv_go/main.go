// Red-team adversarial benchmark: coder/websocket v1.8.14 server over a chunked wire stream.
// usage: adv_go <wire.ws> <chunk_bytes> <msgs_per_round> <rounds>
// coder/websocket does not validate UTF-8, so text messages are checked with utf8.Valid
// (RFC 6455 §8.1 requires it; tungstenite and Pion validate internally).
package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"time"
	"unicode/utf8"

	"github.com/coder/websocket"
)

type chunked struct {
	data              []byte
	pos, step, rounds int
}

func (c *chunked) Read(p []byte) (int, error) {
	if c.pos >= len(c.data) {
		if c.rounds <= 1 {
			return 0, io.EOF
		}
		c.rounds--
		c.pos = 0
	}
	n := min(len(c.data)-c.pos, c.step, len(p))
	copy(p, c.data[c.pos:c.pos+n])
	c.pos += n
	return n, nil
}
func (c *chunked) Write(p []byte) (int, error)        { return len(p), nil }
func (c *chunked) Close() error                       { return nil }
func (c *chunked) LocalAddr() net.Addr                { return addr{} }
func (c *chunked) RemoteAddr() net.Addr               { return addr{} }
func (c *chunked) SetDeadline(t time.Time) error      { return nil }
func (c *chunked) SetReadDeadline(t time.Time) error  { return nil }
func (c *chunked) SetWriteDeadline(t time.Time) error { return nil }

type addr struct{}

func (addr) Network() string { return "mem" }
func (addr) String() string  { return "mem" }

type hijackRW struct {
	hdr  http.Header
	conn *chunked
}

func (h *hijackRW) Header() http.Header         { return h.hdr }
func (h *hijackRW) Write(p []byte) (int, error) { return len(p), nil }
func (h *hijackRW) WriteHeader(int)             {}
func (h *hijackRW) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	return h.conn, bufio.NewReadWriter(bufio.NewReaderSize(h.conn, 32768), bufio.NewWriter(io.Discard)), nil
}

func main() {
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}
	step, _ := strconv.Atoi(os.Args[2])
	per, _ := strconv.Atoi(os.Args[3])
	rounds, _ := strconv.Atoi(os.Args[4])
	want := per * rounds
	conn := &chunked{data: data, step: step, rounds: rounds}
	req, _ := http.NewRequest("GET", "http://example.com/ws", nil)
	req.Header.Set("Connection", "Upgrade")
	req.Header.Set("Upgrade", "websocket")
	req.Header.Set("Sec-WebSocket-Version", "13")
	req.Header.Set("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")
	c, err := websocket.Accept(&hijackRW{hdr: http.Header{}, conn: conn}, req, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		panic(err)
	}
	c.SetReadLimit(32 << 20)
	ctx := context.Background()
	var msgs int
	h := uint64(7)
	fold := func(h, v uint64) uint64 { return (h*31 + v) & 0x1FFFFFFFFFFFFFFF }
	for msgs < want {
		typ, b, err := c.Read(ctx)
		if err != nil {
			fmt.Fprintln(os.Stderr, "decode error:", err)
			os.Exit(1)
		}
		msgs++
		if typ == websocket.MessageText {
			if !utf8.Valid(b) {
				fmt.Fprintln(os.Stderr, "invalid utf-8")
				os.Exit(1)
			}
			h = fold(h, 1)
			continue
		}
		l := len(b)
		h = fold(h, uint64(l)+uint64(b[0])+uint64(b[l/2])*256+uint64(b[l-1])*65536)
	}
	fmt.Printf("msgs=%d\ndigest=%d\n", msgs, h)
}
