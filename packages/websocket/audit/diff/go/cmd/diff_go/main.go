// Red-team differential runner: coder/websocket v1.8.14 over the shared corpus.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha1"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// chunkConn serves the wire bytes `step` at a time and records everything written back.
type chunkConn struct {
	data   []byte
	pos    int
	step   int
	mu     sync.Mutex
	out    bytes.Buffer
	closed chan struct{}
	once   sync.Once
}

func (c *chunkConn) Read(p []byte) (int, error) {
	if c.pos >= len(c.data) {
		// Behave like a live socket with no more data: block until closed.
		<-c.closed
		return 0, net.ErrClosed
	}
	n := len(c.data) - c.pos
	if n > c.step {
		n = c.step
	}
	if n > len(p) {
		n = len(p)
	}
	copy(p, c.data[c.pos:c.pos+n])
	c.pos += n
	return n, nil
}
func (c *chunkConn) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.out.Write(p)
}
func (c *chunkConn) Close() error                       { c.once.Do(func() { close(c.closed) }); return nil }
func (c *chunkConn) LocalAddr() net.Addr                { return addr{} }
func (c *chunkConn) RemoteAddr() net.Addr               { return addr{} }
func (c *chunkConn) SetDeadline(t time.Time) error      { return nil }
func (c *chunkConn) SetReadDeadline(t time.Time) error  { return nil }
func (c *chunkConn) SetWriteDeadline(t time.Time) error { return nil }

type addr struct{}

func (addr) Network() string { return "mem" }
func (addr) String() string  { return "mem" }

type hijackRW struct {
	hdr  http.Header
	conn *chunkConn
}

func (h *hijackRW) Header() http.Header         { return h.hdr }
func (h *hijackRW) Write(p []byte) (int, error) { return len(p), nil }
func (h *hijackRW) WriteHeader(int)             {}
func (h *hijackRW) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	return h.conn, bufio.NewReadWriter(bufio.NewReaderSize(h.conn, 4096), bufio.NewWriter(h.conn)), nil
}

type rwc struct{ *chunkConn }

// fakeRT answers the client Upgrade with a valid 101 whose body is the wire stream.
type fakeRT struct{ conn *chunkConn }

func (f fakeRT) RoundTrip(r *http.Request) (*http.Response, error) {
	h := sha1.Sum([]byte(r.Header.Get("Sec-WebSocket-Key") + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	hdr := http.Header{}
	hdr.Set("Upgrade", "websocket")
	hdr.Set("Connection", "Upgrade")
	hdr.Set("Sec-WebSocket-Accept", base64.StdEncoding.EncodeToString(h[:]))
	return &http.Response{StatusCode: 101, Header: hdr, Body: rwc{f.conn}, Request: r}, nil
}

func fnv32(b []byte) uint32 {
	h := uint32(2166136261)
	for _, x := range b {
		h = (h ^ uint32(x)) * 16777619
	}
	return h
}

// lastCloseCode scans frames written by coder/websocket and returns the last close code.
func lastCloseCode(b []byte) int {
	code := -1
	for len(b) >= 2 {
		op := b[0] & 0x0f
		masked := b[1]&0x80 != 0
		n := int(b[1] & 0x7f)
		off := 2
		if n == 126 {
			n = int(b[2])<<8 | int(b[3])
			off = 4
		} else if n == 127 {
			n = 0
			for i := 2; i < 10; i++ {
				n = n<<8 | int(b[i])
			}
			off = 10
		}
		var mk []byte
		if masked {
			mk = b[off : off+4]
			off += 4
		}
		if off+n > len(b) {
			break
		}
		p := append([]byte(nil), b[off:off+n]...)
		for i := range p {
			if mk != nil {
				p[i] ^= mk[i&3]
			}
		}
		if op == 8 && n >= 2 {
			code = int(p[0])<<8 | int(p[1])
		}
		b = b[off+n:]
	}
	return code
}

func runCase(line string) string {
	p := strings.Split(line, " ")
	maxsz, _ := strconv.Atoi(p[2])
	chunk, _ := strconv.Atoi(p[3])
	wire, _ := hex.DecodeString(p[4])
	if chunk == 0 {
		chunk = len(wire) + 1
	}
	cc := &chunkConn{data: wire, step: chunk, closed: make(chan struct{})}
	ctx := context.Background()
	var c *websocket.Conn
	var err error
	if p[1] == "s" {
		req, _ := http.NewRequest("GET", "http://example.com/ws", nil)
		req.Header.Set("Connection", "Upgrade")
		req.Header.Set("Upgrade", "websocket")
		req.Header.Set("Sec-WebSocket-Version", "13")
		req.Header.Set("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")
		c, err = websocket.Accept(&hijackRW{hdr: http.Header{}, conn: cc}, req, &websocket.AcceptOptions{InsecureSkipVerify: true})
	} else {
		c, _, err = websocket.Dial(ctx, "ws://example.com/ws", &websocket.DialOptions{HTTPClient: &http.Client{Transport: fakeRT{cc}}})
	}
	if err != nil {
		return p[0] + " SETUP(" + err.Error() + ")"
	}
	c.SetReadLimit(int64(maxsz))
	var sb strings.Builder
	sb.WriteString(p[0])
	for {
		rctx, cancel := context.WithTimeout(ctx, 300*time.Millisecond)
		typ, data, err := c.Read(rctx)
		cancel()
		if err == nil {
			if typ == websocket.MessageText {
				fmt.Fprintf(&sb, " T%d:%d", len(data), fnv32(data))
			} else {
				fmt.Fprintf(&sb, " B%d:%d", len(data), fnv32(data))
			}
			continue
		}
		var ce websocket.CloseError
		if errors.As(err, &ce) {
			if ce.Code == websocket.StatusNoStatusRcvd {
				sb.WriteString(" C- END")
			} else {
				fmt.Fprintf(&sb, " C%d END", int(ce.Code))
			}
			break
		}
		code := -1
		for i := 0; i < 20 && code < 0; i++ {
			cc.mu.Lock()
			code = lastCloseCode(cc.out.Bytes())
			cc.mu.Unlock()
			if code < 0 {
				time.Sleep(10 * time.Millisecond)
			}
		}
		if code > 0 {
			fmt.Fprintf(&sb, " ERR%d", code)
		} else if errors.Is(err, context.DeadlineExceeded) {
			sb.WriteString(" END")
		} else {
			// Protocol error where coder/websocket drops the TCP connection without a close frame.
			sb.WriteString(" ERR-")
		}
		break
	}
	return sb.String()
}

func main() {
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	var lines []string
	for _, l := range strings.Split(string(data), "\n") {
		if l != "" {
			lines = append(lines, l)
		}
	}
	res := make([]string, len(lines))
	var wg sync.WaitGroup
	sem := make(chan struct{}, 32)
	for i, l := range lines {
		wg.Add(1)
		go func(i int, l string) {
			defer wg.Done()
			sem <- struct{}{}
			res[i] = runCase(l)
			<-sem
		}(i, l)
	}
	wg.Wait()
	for _, r := range res {
		fmt.Fprintln(w, r)
	}
}
