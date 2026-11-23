// NO_PROXY oracle: golang.org/x/net/http/httpproxy (the implementation behind Go's
// net/http.ProxyFromEnvironment). Input lines: rules_hex \t host_hex \t port. Output: 1 when
// the request would go direct (bypass), else 0; "L" marks hosts Go always sends direct
// (localhost / loopback) regardless of NO_PROXY, so the comparison can set them aside.
package main

import (
	"bufio"
	"encoding/hex"
	"fmt"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"

	"golang.org/x/net/http/httpproxy"
)

func main() {
	f, err := os.Open(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	defer f.Close()
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		parts := strings.Split(sc.Text(), "\t")
		rules, _ := hex.DecodeString(parts[0])
		host, _ := hex.DecodeString(parts[1])
		port, _ := strconv.Atoi(parts[2])
		h := strings.TrimSuffix(strings.TrimPrefix(string(host), "["), "]")
		if h == "localhost" || strings.HasSuffix(h, ".localhost") {
			fmt.Fprintln(w, "L")
			continue
		}
		if ip := net.ParseIP(h); ip != nil && ip.IsLoopback() {
			fmt.Fprintln(w, "L")
			continue
		}
		cfg := httpproxy.Config{HTTPProxy: "http://proxy.invalid:3128", NoProxy: string(rules)}
		u := &url.URL{Scheme: "http", Host: net.JoinHostPort(h, strconv.Itoa(port))}
		p, err := cfg.ProxyFunc()(u)
		switch {
		case err != nil:
			fmt.Fprintln(w, "E")
		case p == nil:
			fmt.Fprintln(w, "1")
		default:
			fmt.Fprintln(w, "0")
		}
	}
}
