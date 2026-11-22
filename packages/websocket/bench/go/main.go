package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"
	"time"
	"unicode/utf8"

	"github.com/coder/websocket"
)

// memConn is an in-memory net.Conn that feeds pre-encoded wire frames into
// coder/websocket's real Server Conn without OS socket/pipe overhead.
type memConn struct {
	buf []byte
	pos int
}

func (m *memConn) Read(p []byte) (int, error) {
	if m.pos >= len(m.buf) {
		return 0, io.EOF
	}
	n := copy(p, m.buf[m.pos:])
	m.pos += n
	return n, nil
}

func (m *memConn) Write(p []byte) (int, error)        { return len(p), nil }
func (m *memConn) Close() error                       { return nil }
func (m *memConn) LocalAddr() net.Addr                { return dummyAddr{} }
func (m *memConn) RemoteAddr() net.Addr               { return dummyAddr{} }
func (m *memConn) SetDeadline(t time.Time) error      { return nil }
func (m *memConn) SetReadDeadline(t time.Time) error  { return nil }
func (m *memConn) SetWriteDeadline(t time.Time) error { return nil }

type dummyAddr struct{}

func (dummyAddr) Network() string { return "mem" }
func (dummyAddr) String() string  { return "mem" }

type hijackRW struct {
	hdr  http.Header
	conn net.Conn
	br   *bufio.Reader
	bw   *bufio.Writer
}

func (h *hijackRW) Header() http.Header         { return h.hdr }
func (h *hijackRW) Write(p []byte) (int, error) { return len(p), nil }
func (h *hijackRW) WriteHeader(int)             {}
func (h *hijackRW) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	return h.conn, bufio.NewReadWriter(h.br, h.bw), nil
}

func encodeFrame(dst []byte, fin bool, opcode byte, maskKey uint32, payload []byte) []byte {
	b0 := opcode
	if fin {
		b0 |= 0x80
	}
	dst = append(dst, b0)
	plen := len(payload)
	if plen < 126 {
		dst = append(dst, byte(0x80|plen))
	} else if plen <= 65535 {
		dst = append(dst, 0x80|126, byte(plen>>8), byte(plen))
	} else {
		dst = append(dst, 0x80|127)
		var b8 [8]byte
		binary.BigEndian.PutUint64(b8[:], uint64(plen))
		dst = append(dst, b8[:]...)
	}
	var m [4]byte
	binary.BigEndian.PutUint32(m[:], maskKey)
	dst = append(dst, m[0], m[1], m[2], m[3])
	start := len(dst)
	dst = append(dst, payload...)
	out := dst[start:]
	// 8-byte batch XOR masking
	m64 := uint64(binary.LittleEndian.Uint32(m[:]))
	m64 = m64 | (m64 << 32)
	i := 0
	for i+8 <= len(out) {
		v := binary.LittleEndian.Uint64(out[i : i+8])
		binary.LittleEndian.PutUint64(out[i:i+8], v^m64)
		i += 8
	}
	for i < len(out) {
		out[i] ^= m[i&3]
		i++
	}
	return dst
}

func buildTextPool(size int) []byte {
	unit := []byte("WS:世界🌍123")
	pool := make([]byte, size)
	for i := 0; i < size; i++ {
		pool[i] = unit[i&15]
	}
	return pool
}

func buildBinPool(size int) []byte {
	pool := make([]byte, size)
	for i := 0; i < size; i++ {
		pool[i] = byte((i*37 + 13) & 0xFF)
	}
	return pool
}

func buildPingPool(size int) []byte {
	pool := make([]byte, size)
	for i := 0; i < size; i++ {
		pool[i] = byte(65 + (i % 26))
	}
	return pool
}

func updateDigest(h int64, data []byte) int64 {
	for _, b := range data {
		h = ((h & 0x00FFFFFFFFFFFFFF) * 31 + int64(b)) & 0x3FFFFFFFFFFFFFFF
	}
	return h
}

func main() {
	const cycles = 10000
	textPool := buildTextPool(2048)
	binPool := buildBinPool(4096)
	pingPool := buildPingPool(32)

	textT0 := make([][]byte, 16)
	for k := 0; k < 16; k++ {
		textT0[k] = textPool[0 : 1024+k*16]
	}
	binT1 := make([][]byte, 32)
	for k := 0; k < 32; k++ {
		binT1[k] = binPool[0 : 2048+k*16]
	}
	fragP1 := textPool[0:517]
	fragP2 := make([][]byte, 8)
	for k := 0; k < 8; k++ {
		fragP2[k] = textPool[517 : 1536+k*16]
	}

	var textMsgs, binMsgs, pingMsgs, wireBytes, payloadBytes int64
	var digest int64 = 1469598103

	mc := &memConn{buf: make([]byte, 0, 16384)}
	rw := &hijackRW{
		hdr:  make(http.Header),
		conn: mc,
		br:   bufio.NewReaderSize(mc, 32768),
		bw:   bufio.NewWriter(io.Discard),
	}
	req, _ := http.NewRequest("GET", "http://example.com/ws", bytes.NewReader(nil))
	req.Header.Set("Connection", "Upgrade")
	req.Header.Set("Upgrade", "websocket")
	req.Header.Set("Sec-WebSocket-Version", "13")
	req.Header.Set("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")

	conn, err := websocket.Accept(rw, req, &websocket.AcceptOptions{
		InsecureSkipVerify: true,
		OnPingReceived: func(ctx context.Context, payload []byte) bool {
			pingMsgs++
			payloadBytes += int64(len(payload))
			digest = updateDigest(digest, payload)
			return false
		},
	})
	if err != nil {
		panic(err)
	}
	conn.SetReadLimit(1048576)

	ctx := context.Background()
	for c := 0; c < cycles; c++ {
		mk := uint32((uint64(c)*2654435761 + 0x37FA213D) & 0xFFFFFFFF)
		mc.buf = mc.buf[:0]
		mc.pos = 0

		mc.buf = encodeFrame(mc.buf, true, 1, mk, textT0[c&15])
		mc.buf = encodeFrame(mc.buf, true, 2, mk^0x11111111, binT1[c&31])
		mc.buf = encodeFrame(mc.buf, false, 1, mk^0x22222222, fragP1)
		mc.buf = encodeFrame(mc.buf, true, 9, mk^0x33333333, pingPool)
		mc.buf = encodeFrame(mc.buf, true, 0, mk^0x44444444, fragP2[c&7])
		wireBytes += int64(len(mc.buf))

		// 3 data messages per cycle (Ping is handled synchronously via OnPingReceived)
		for m := 0; m < 3; m++ {
			typ, data, err := conn.Read(ctx)
			if err != nil {
				panic(err)
			}
			if typ == websocket.MessageText {
				if !utf8.Valid(data) {
					panic("invalid utf-8")
				}
				textMsgs++
			} else {
				binMsgs++
			}
			payloadBytes += int64(len(data))
			digest = update_digest_inline(digest, data)
		}
	}

	fmt.Printf("frames=%d\n", cycles*5)
	fmt.Printf("text_msgs=%d\n", textMsgs)
	fmt.Printf("binary_msgs=%d\n", binMsgs)
	fmt.Printf("ping_msgs=%d\n", pingMsgs)
	fmt.Printf("wire_bytes=%d\n", wireBytes)
	fmt.Printf("payload_bytes=%d\n", payloadBytes)
	fmt.Printf("digest=%d\n", digest)
}

func update_digest_inline(h int64, data []byte) int64 {
	return updateDigest(h, data)
}
