// Connection-level reference: run each scenario against a real golang.org/x/net/http2 Server
// (MaxConcurrentStreams = 4) over net.Pipe and report what the server did.
//
//	conn_go <scenarios.txt>
//
// Output per scenario: `<name>\t<summary>` where summary lists GOAWAY(code), RST_STREAM(sid:code)
// and response HEADERS(sid:status) in arrival order (compressed: repeated items counted).
package main

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/http2"
	"golang.org/x/net/http2/hpack"
)

func run(chunks [][]byte) string {
	cli, srv := net.Pipe()
	s := &http2.Server{MaxConcurrentStreams: 4}
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		w.WriteHeader(200)
	})
	go s.ServeConn(srv, &http2.ServeConnOpts{Handler: h})

	var mu sync.Mutex
	var events []string
	done := make(chan struct{})
	go func() {
		defer close(done)
		fr := http2.NewFramer(io.Discard, cli)
		fr.ReadMetaHeaders = hpack.NewDecoder(4096, nil)
		for {
			f, err := fr.ReadFrame()
			if err != nil {
				return
			}
			mu.Lock()
			switch ff := f.(type) {
			case *http2.GoAwayFrame:
				events = append(events, fmt.Sprintf("GOAWAY(%v)", ff.ErrCode))
			case *http2.RSTStreamFrame:
				events = append(events, fmt.Sprintf("RST(%d:%v)", ff.StreamID, ff.ErrCode))
			case *http2.MetaHeadersFrame:
				events = append(events, fmt.Sprintf("RESP(%d:%s)", ff.StreamID, ff.PseudoValue("status")))
			}
			mu.Unlock()
			if _, ok := f.(*http2.GoAwayFrame); ok {
				return
			}
		}
	}()
	// writer: preface + empty SETTINGS + SETTINGS ACK for the server's SETTINGS, then the chunks
	go func() {
		w := bufio.NewWriter(cli)
		w.WriteString(http2.ClientPreface)
		w.Write([]byte{0, 0, 0, 4, 0, 0, 0, 0, 0})
		w.Write([]byte{0, 0, 0, 4, 1, 0, 0, 0, 0})
		w.Flush()
		for i, c := range chunks {
			if i > 0 {
				time.Sleep(20 * time.Millisecond)
			}
			if _, err := cli.Write(c); err != nil {
				return
			}
		}
	}()
	select {
	case <-done:
	case <-time.After(time.Duration(len(chunks))*20*time.Millisecond + 700*time.Millisecond):
	}
	cli.Close()
	mu.Lock()
	defer mu.Unlock()
	return summarize(events)
}

func summarize(ev []string) string {
	if len(ev) == 0 {
		return "ACCEPTED (no response, no error)"
	}
	var b bytes.Buffer
	for i := 0; i < len(ev); {
		j := i
		for j < len(ev) && kind(ev[j]) == kind(ev[i]) {
			j++
		}
		if b.Len() > 0 {
			b.WriteString(" ")
		}
		if j-i > 3 {
			fmt.Fprintf(&b, "%s..%s(x%d)", ev[i], ev[j-1], j-i)
		} else {
			b.WriteString(strings.Join(ev[i:j], " "))
		}
		i = j
	}
	return b.String()
}

func kind(s string) string { return s[:strings.IndexByte(s, '(')] }

func main() {
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}
	for _, line := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
		tab := strings.IndexByte(line, '\t')
		var chunks [][]byte
		for _, h := range strings.Split(line[tab+1:], ",") {
			b, _ := hex.DecodeString(h)
			chunks = append(chunks, b)
		}
		fmt.Printf("%s\t%s\n", line[:tab], run(chunks))
	}
}
