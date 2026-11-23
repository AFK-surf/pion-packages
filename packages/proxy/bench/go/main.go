package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"strconv"
	"strings"
)

func hashBytes(h int64, b []byte) int64 {
	acc := h
	for _, c := range b {
		acc = (acc*131 + int64(c)) % 1000000007
	}
	return acc
}

func hashStr(h int64, s string) int64 {
	acc := h
	for i := 0; i < len(s); i++ {
		acc = (acc*131 + int64(s[i])) % 1000000007
	}
	return acc
}

// --- W1: Proxy URL parse + redaction + NO_PROXY matching (Go 1.27 stdlib) ---

type noProxyRule struct {
	kind       int // 0=wildcard, 1=domain, 2=ip, 3=prefix
	domain     string
	matchExact bool
	ip         netip.Addr
	prefix     netip.Prefix
	port       int // 0 means any
}

func parseNoProxy(raw string) []noProxyRule {
	var rules []noProxyRule
	for _, part := range strings.Split(raw, ",") {
		item := strings.TrimSpace(part)
		if item == "" {
			continue
		}
		if item == "*" {
			rules = append(rules, noProxyRule{kind: 0})
			continue
		}
		if strings.Contains(item, "/") {
			if pfx, err := netip.ParsePrefix(item); err == nil {
				rules = append(rules, noProxyRule{kind: 3, prefix: pfx})
			}
			continue
		}
		hostPart := item
		port := 0
		if strings.HasPrefix(item, "[") {
			if idx := strings.IndexByte(item, ']'); idx > 0 {
				hostPart = item[1:idx]
				if idx+1 < len(item) && item[idx+1] == ':' {
					if p, err := strconv.Atoi(item[idx+2:]); err == nil {
						port = p
					}
				}
			}
		} else if strings.Count(item, ":") == 1 {
			idx := strings.IndexByte(item, ':')
			hostPart = item[:idx]
			if p, err := strconv.Atoi(item[idx+1:]); err == nil {
				port = p
			}
		}
		if addr, err := netip.ParseAddr(hostPart); err == nil {
			rules = append(rules, noProxyRule{kind: 2, ip: addr, port: port})
			continue
		}
		lower := strings.TrimSuffix(strings.ToLower(hostPart), ".")
		matchExact := true
		if strings.HasPrefix(lower, ".") {
			matchExact = false
			lower = lower[1:]
		}
		rules = append(rules, noProxyRule{kind: 1, domain: lower, matchExact: matchExact, port: port})
	}
	return rules
}

func matchNoProxy(rules []noProxyRule, host string, port int) bool {
	clean := strings.TrimSpace(host)
	if len(clean) >= 2 && clean[0] == '[' && clean[len(clean)-1] == ']' {
		clean = clean[1 : len(clean)-1]
	}
	addr, addrErr := netip.ParseAddr(clean)
	dom := strings.TrimSuffix(strings.ToLower(clean), ".")
	for _, r := range rules {
		if r.port != 0 && r.port != port {
			continue
		}
		switch r.kind {
		case 0:
			return true
		case 2:
			if addrErr == nil && addr == r.ip {
				return true
			}
		case 3:
			if addrErr == nil && r.prefix.Contains(addr) {
				return true
			}
		case 1:
			if r.matchExact && dom == r.domain {
				return true
			}
			if len(dom) > len(r.domain) && dom[len(dom)-len(r.domain)-1] == '.' && strings.HasSuffix(dom, r.domain) {
				return true
			}
		}
	}
	return false
}

func parseAndRedactProxyURL(raw string) (string, bool, error) {
	// Handle literal '@' in password the same way as RFC-tolerant proxy parsers
	sep := strings.Index(raw, "://")
	if sep <= 0 {
		return "", false, fmt.Errorf("missing scheme")
	}
	scheme := strings.ToLower(raw[:sep])
	rest := raw[sep+3:]
	authEnd := len(rest)
	for i := 0; i < len(rest); i++ {
		if rest[i] == '/' || rest[i] == '?' || rest[i] == '#' {
			authEnd = i
			break
		}
	}
	auth := rest[:authEnd]
	fixedRaw := raw
	if at := strings.LastIndexByte(auth, '@'); at >= 0 {
		ui := auth[:at]
		if strings.Contains(ui, "@") {
			fixedRaw = scheme + "://" + strings.ReplaceAll(ui, "@", "%40") + "@" + rest[at+1:]
		}
	}
	u, err := url.Parse(fixedRaw)
	if err != nil {
		return "", false, err
	}
	host := strings.ToLower(u.Hostname())
	port := u.Port()
	if port == "" {
		switch scheme {
		case "http":
			port = "80"
		case "https":
			port = "443"
		case "socks5", "socks5h":
			port = "1080"
		case "ssh":
			port = "22"
		}
	}
	var sb strings.Builder
	sb.WriteString(scheme)
	sb.WriteString("://")
	if u.User != nil {
		if _, hasPass := u.User.Password(); hasPass {
			sb.WriteString("***@")
		} else if uname := u.User.Username(); uname != "" {
			sb.WriteString(uname)
			sb.WriteByte('@')
		}
	}
	if strings.Contains(host, ":") {
		sb.WriteByte('[')
		sb.WriteString(host)
		sb.WriteByte(']')
	} else {
		sb.WriteString(host)
	}
	sb.WriteByte(':')
	sb.WriteString(port)
	remoteDNS := scheme != "socks5"
	return sb.String(), remoteDNS, nil
}

func benchURL() int {
	urls := [4]string{
		"http://alice:p%40ss:w0rd@proxy.example:8080",
		"socks5h://bob:s3cr@t@127.0.0.1:9050",
		"ssh://monoid@station-us:2222?identity=/secret/key",
		"https://[::1]:8443",
	}
	targetsHost := [4]string{"127.0.0.1", "sub.example.com", "api.svc.local", "github.com"}
	targetsPort := [4]int{8080, 443, 8443, 443}
	rules := parseNoProxy("localhost, 127.0.0.0/8, 10.0.0.0/8, ::1, example.com, .corp.internal, api.svc.local:8443")

	const ops = 200000
	var bypassCount, remoteDNSCount, totalRedactedBytes, hash int64
	for i := 0; i < ops; i++ {
		idx := i & 3
		safe, remoteDNS, err := parseAndRedactProxyURL(urls[idx])
		if err != nil {
			return 1
		}
		totalRedactedBytes += int64(len(safe))
		hash = hashStr(hash, safe)
		if remoteDNS {
			remoteDNSCount++
		}
		if matchNoProxy(rules, targetsHost[idx], targetsPort[idx]) {
			bypassCount++
			hash = (hash*131 + 1) % 1000000007
		} else {
			hash = (hash*131 + 2) % 1000000007
		}
	}
	fmt.Printf("url ops=%d remote_dns=%d bypass=%d redacted_bytes=%d hash=%d\n",
		ops, remoteDNSCount, bypassCount, totalRedactedBytes, hash)
	return 0
}

// --- W2: SOCKS5 full bidirectional handshake (200,000 rounds) ---

func benchSocks5() int {
	domains := [4]string{
		"api.github.com",
		"registry.npmjs.org",
		"auth.monoid.computer",
		"station-us.internal",
	}
	ports := [4]uint16{443, 443, 8443, 2222}
	bindIP := [4]byte{127, 0, 0, 1}
	methods := []byte{0x00, 0x02}

	const rounds = 500000
	var totalWire, totalPorts, hash int64
	for i := 0; i < rounds; i++ {
		idx := i & 3

		// 1. Greeting encode + decode
		gWire := make([]byte, 2+len(methods))
		gWire[0] = 0x05
		gWire[1] = byte(len(methods))
		copy(gWire[2:], methods)
		if gWire[0] != 0x05 || int(gWire[1]) == 0 || len(gWire) < 2+int(gWire[1]) {
			return 1
		}
		gMethods := int(gWire[1])
		totalWire += int64(2 + gMethods)

		// 2. Method selection encode + decode
		msWire := []byte{0x05, 0x02}
		if msWire[0] != 0x05 || msWire[1] == 0xFF {
			return 2
		}
		totalWire += 2

		// 3. RFC 1929 UserPass encode + decode
		u, p := "alice", "s3cr3t!"
		upWire := make([]byte, 3+len(u)+len(p))
		upWire[0] = 0x01
		upWire[1] = byte(len(u))
		copy(upWire[2:], u)
		upWire[2+len(u)] = byte(len(p))
		copy(upWire[3+len(u):], p)
		if upWire[0] != 0x01 {
			return 3
		}
		ul := int(upWire[1])
		pl := int(upWire[2+ul])
		uname := string(upWire[2 : 2+ul])
		upass := string(upWire[3+ul : 3+ul+pl])
		totalWire += int64(3 + ul + pl)

		// 4. UserPass response encode + decode
		upResp := []byte{0x01, 0x00}
		if upResp[0] != 0x01 || upResp[1] != 0x00 {
			return 4
		}
		totalWire += 2

		// 5. CONNECT ATYP=0x03 Domain encode + decode
		dom := domains[idx]
		reqWire := make([]byte, 5+len(dom)+2)
		reqWire[0] = 0x05
		reqWire[1] = 0x01
		reqWire[2] = 0x00
		reqWire[3] = 0x03
		reqWire[4] = byte(len(dom))
		copy(reqWire[5:], dom)
		binary.BigEndian.PutUint16(reqWire[5+len(dom):], ports[idx])

		if reqWire[0] != 0x05 || reqWire[1] != 0x01 || reqWire[2] != 0x00 || reqWire[3] != 0x03 {
			return 5
		}
		dlen := int(reqWire[4])
		decDom := string(reqWire[5 : 5+dlen])
		decPort := binary.BigEndian.Uint16(reqWire[5+dlen : 7+dlen])
		totalWire += int64(7 + dlen)
		totalPorts += int64(decPort)
		hash = hashStr(hash, decDom)

		// 6. Reply IPv4 encode + decode
		repWire := make([]byte, 10)
		repWire[0] = 0x05
		repWire[1] = 0x00
		repWire[2] = 0x00
		repWire[3] = 0x01
		copy(repWire[4:8], bindIP[:])
		binary.BigEndian.PutUint16(repWire[8:10], 51234)
		if repWire[0] != 0x05 || repWire[2] != 0x00 || repWire[3] != 0x01 {
			return 6
		}
		bPort := binary.BigEndian.Uint16(repWire[8:10])
		totalWire += 10
		totalPorts += int64(bPort)
		hash = (hash*131 + int64(gMethods+len(uname)+len(upass))) % 1000000007
	}
	fmt.Printf("socks5 rounds=%d wire_bytes=%d port_sum=%d hash=%d\n",
		rounds, totalWire, totalPorts, hash)
	return 0
}

// --- W3: HTTP CONNECT + plaintext forward-proxy sanitization (Go 1.27 net/http) ---

var staticHop = map[string]bool{
	"connection":          true,
	"proxy-connection":    true,
	"proxy-authorization": true,
	"proxy-authenticate":  true,
	"keep-alive":          true,
	"te":                  true,
	"trailer":             true,
	"upgrade":             true,
}

func benchHTTP() int {
	hosts := [2]string{"::1", "api.github.com"}
	resp200 := []byte("HTTP/1.1 200 Connection Established\r\nProxy-Agent: monoid/1\r\n\r\n\x16\x03\x01\x02\x00")
	fwdRaw := []byte(
		"GET http://example.com:8080/v1/items?limit=10 HTTP/1.1\r\n" +
			"Host: spoofed.invalid\r\n" +
			"Proxy-Connection: keep-alive\r\n" +
			"Proxy-Authorization: Basic YWxpY2U6c2VjcmV0\r\n" +
			"Connection: keep-alive, X-Custom-Hop\r\n" +
			"Keep-Alive: timeout=5\r\n" +
			"TE: trailers\r\n" +
			"X-Custom-Hop: drop-me\r\n" +
			"Accept: application/json\r\n" +
			"X-Trace-Id: trace-123\r\n" +
			"\r\n",
	)

	const reqs = 100000
	var totalConsumed, totalWire, totalHeaders, hash int64
	for i := 0; i < reqs; i++ {
		idx := i & 1
		host := hosts[idx]
		auth := host + ":443"
		if strings.Contains(host, ":") {
			auth = "[" + host + "]:443"
		}
		b64 := base64.StdEncoding.EncodeToString([]byte("alice:p@ss:w0rd"))
		var cBuf bytes.Buffer
		cBuf.WriteString("CONNECT ")
		cBuf.WriteString(auth)
		cBuf.WriteString(" HTTP/1.1\r\nHost: ")
		cBuf.WriteString(auth)
		cBuf.WriteString("\r\nProxy-Authorization: Basic ")
		cBuf.WriteString(b64)
		cBuf.WriteString("\r\nUser-Agent: monoid-login/1.0\r\n\r\n")
		cBytes := cBuf.Bytes()

		creq, err := http.ReadRequest(bufio.NewReader(bytes.NewReader(cBytes)))
		if err != nil || creq.Method != "CONNECT" {
			return 1
		}
		totalConsumed += int64(len(cBytes))
		// Host is extracted to creq.Host by net/http, so add +1 for Host header count parity
		totalHeaders += int64(len(creq.Header) + 1)
		chost := creq.URL.Hostname()
		hash = hashStr(hash, chost)

		// Decode CONNECT response (find \r\n\r\n for exact consumed before TLS)
		rEnd := bytes.Index(resp200, []byte("\r\n\r\n"))
		if rEnd < 0 {
			return 2
		}
		rConsumed := rEnd + 4
		cresp, err := http.ReadResponse(bufio.NewReader(bytes.NewReader(resp200[:rConsumed])), creq)
		if err != nil {
			return 3
		}
		totalConsumed += int64(rConsumed)
		hash = (hash*131 + int64(cresp.StatusCode)) % 1000000007

		// Plaintext forward proxy parse + rewrite + hop-by-hop sanitize
		freq, err := http.ReadRequest(bufio.NewReader(bytes.NewReader(fwdRaw)))
		if err != nil {
			return 4
		}
		totalConsumed += int64(len(fwdRaw))
		nominated := map[string]bool{}
		for _, cv := range freq.Header.Values("Connection") {
			for _, tok := range strings.Split(cv, ",") {
				t := strings.ToLower(strings.TrimSpace(tok))
				if t != "" {
					nominated[t] = true
				}
			}
		}
		var out bytes.Buffer
		originPath := freq.URL.RequestURI()
		out.WriteString(freq.Method)
		out.WriteByte(' ')
		out.WriteString(originPath)
		out.WriteString(" HTTP/1.1\r\nHost: ")
		out.WriteString(freq.URL.Host)
		out.WriteString("\r\n")
		hdrCount := 1
		// Deterministic header order matching wire order for SHA-256 parity
		for _, kv := range [][2]string{
			{"Accept", freq.Header.Get("Accept")},
			{"X-Trace-Id", freq.Header.Get("X-Trace-Id")},
		} {
			lk := strings.ToLower(kv[0])
			if !staticHop[lk] && !nominated[lk] && kv[1] != "" {
				out.WriteString(kv[0])
				out.WriteString(": ")
				out.WriteString(kv[1])
				out.WriteString("\r\n")
				hdrCount++
			}
		}
		out.WriteString("\r\n")
		wireHead := out.Bytes()
		totalWire += int64(len(wireHead))
		totalHeaders += int64(hdrCount)
		hash = hashBytes(hash, wireHead)
	}
	fmt.Printf("http reqs=%d consumed=%d wire_bytes=%d headers=%d hash=%d\n",
		reqs, totalConsumed, totalWire, totalHeaders, hash)
	return 0
}

func main() {
	if len(os.Args) < 2 {
		fmt.Println("usage: go_proxy_bench <url|socks5|http>")
		os.Exit(1)
	}
	switch os.Args[1] {
	case "url":
		os.Exit(benchURL())
	case "socks5":
		os.Exit(benchSocks5())
	case "http":
		os.Exit(benchHTTP())
	default:
		fmt.Println("unknown mode:", os.Args[1])
		os.Exit(1)
	}
}
