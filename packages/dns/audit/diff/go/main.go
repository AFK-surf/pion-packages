// Differential driver: Go 1.27 + github.com/miekg/dns v1.1.63.
// Usage: go_driver <msg|name|ip6> <cases.tsv>   (line: <id>\t<hex>)
// Output format mirrors ../pion_driver/src/main.pion exactly.
package main

import (
	"bufio"
	"encoding/hex"
	"fmt"
	"net/netip"
	"os"
	"strings"

	"github.com/miekg/dns"
)

func lowerWire(name string) string {
	buf := make([]byte, 256)
	n, err := dns.PackDomainName(dns.Fqdn(name), buf, 0, nil, false)
	if err != nil {
		return "PACKERR"
	}
	b := buf[:n]
	for i := range b {
		if b[i] >= 'A' && b[i] <= 'Z' {
			b[i] += 32
		}
	}
	return hex.EncodeToString(b)
}

func rrKey(sb *strings.Builder, rr dns.RR) {
	h := rr.Header()
	fmt.Fprintf(sb, " %s/%d/%d/%d", lowerWire(h.Name), h.Rrtype, h.Class, h.Ttl)
	switch v := rr.(type) {
	case *dns.A:
		ip := v.A.To4()
		if ip == nil {
			ip = make([]byte, 4)
		}
		fmt.Fprintf(sb, "/%s", hex.EncodeToString(ip))
	case *dns.AAAA:
		ip := v.AAAA.To16()
		if ip == nil {
			ip = make([]byte, 16)
		}
		fmt.Fprintf(sb, "/%s", hex.EncodeToString(ip))
	case *dns.CNAME:
		fmt.Fprintf(sb, "/%s", lowerWire(v.Target))
	case *dns.NS:
		fmt.Fprintf(sb, "/%s", lowerWire(v.Ns))
	case *dns.PTR:
		fmt.Fprintf(sb, "/%s", lowerWire(v.Ptr))
	case *dns.MX:
		fmt.Fprintf(sb, "/%d,%s", v.Preference, lowerWire(v.Mx))
	}
}

func msgVerdict(b []byte) string {
	m := new(dns.Msg)
	if err := m.Unpack(b); err != nil {
		return "ERR " + err.Error()
	}
	var sb strings.Builder
	opt, ar := 0, 0
	for _, r := range m.Extra {
		if r.Header().Rrtype == dns.TypeOPT {
			opt++
		} else {
			ar++
		}
	}
	fmt.Fprintf(&sb, "OK qd=%d an=%d ns=%d ar=%d opt=%d", len(m.Question), len(m.Answer), len(m.Ns), ar, opt)
	for _, q := range m.Question {
		fmt.Fprintf(&sb, " q:%s/%d/%d", lowerWire(q.Name), q.Qtype, q.Qclass)
	}
	for _, r := range m.Answer {
		rrKey(&sb, r)
	}
	for _, r := range m.Ns {
		rrKey(&sb, r)
	}
	for _, r := range m.Extra {
		if r.Header().Rrtype != dns.TypeOPT {
			rrKey(&sb, r)
		}
	}
	sb.WriteString("\t")
	m.Compress = true
	w, err := m.Pack()
	if err != nil {
		sb.WriteString("enc=ERR")
	} else {
		fmt.Fprintf(&sb, "enc=%d", len(w))
		if err := new(dns.Msg).Unpack(w); err != nil {
			sb.WriteString(" rt=ERR")
		} else {
			sb.WriteString(" rt=ok")
		}
	}
	return sb.String()
}

func nameVerdict(s string) string {
	if s == "" || s == "." {
		return "OK 00 ."
	}
	if _, ok := dns.IsDomainName(s); !ok {
		return "ERR"
	}
	buf := make([]byte, 1024)
	n, err := dns.PackDomainName(dns.Fqdn(s), buf, 0, nil, false)
	if err != nil || n > 255 {
		return "ERR"
	}
	str, _, err := dns.UnpackDomainName(buf[:n], 0)
	if err != nil {
		return "ERR"
	}
	return "OK " + hex.EncodeToString(buf[:n]) + " " + str
}

func ip6Verdict(s string) string {
	a, err := netip.ParseAddr(s)
	if err != nil || !a.Is6() || a.Zone() != "" {
		return "ERR"
	}
	return "OK " + a.String()
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: go_driver <msg|name|ip6> <cases.tsv>")
		os.Exit(2)
	}
	f, err := os.Open(os.Args[2])
	if err != nil {
		os.Exit(2)
	}
	defer f.Close()
	out := bufio.NewWriter(os.Stdout)
	defer out.Flush()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<24)
	for sc.Scan() {
		line := sc.Text()
		tab := strings.IndexByte(line, '\t')
		if tab < 0 {
			continue
		}
		id := line[:tab]
		payload, _ := hex.DecodeString(line[tab+1:])
		var v string
		switch os.Args[1] {
		case "msg":
			v = msgVerdict(payload)
		case "name":
			v = nameVerdict(string(payload))
		case "ip6":
			v = ip6Verdict(string(payload))
		default:
			v = "UNSUPPORTED"
		}
		fmt.Fprintf(out, "%s\t%s\n", id, v)
	}
}
