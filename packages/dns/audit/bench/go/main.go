// Adversarial head-to-head benchmark (Go 1.27 + miekg/dns v1.1.63).
//
//	go_bench gen <plain|collide> <n> <out.txt>   write owner names (one per line)
//	go_bench encode <names.txt> <rounds>         build 1 response with len(names) A RRs, Pack() x rounds
//	go_bench decode <names.txt> <rounds>         Unpack() the same response x rounds
//
// "collide" names are brute-forced so that pion's (packages/dns/src/encode.pion)
// unseeded 31-bit suffix hash has identical low 14 bits for every owner, i.e.
// every insert/lookup lands in one open-addressing cluster.
package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/miekg/dns"
)

const zone = "bulk.example."

func lower(b byte) byte {
	if b >= 'A' && b <= 'Z' {
		return b + 32
	}
	return b
}

// pionSuffixHash mirrors WireWriter::write_name's bottom-up hash (32-bit Int wrap).
func pionSuffixHash(labels []string) uint32 {
	acc := uint32(216613626)
	for i := len(labels) - 1; i >= 0; i-- {
		l := labels[i]
		acc = acc*16777619 ^ uint32(len(l))
		for j := 0; j < len(l); j++ {
			acc = acc*16777619 ^ uint32(lower(l[j]))
		}
	}
	h := acc & 0x7FFFFFFF
	if h == 0 {
		h = 1
	}
	return h
}

func gen(kind string, n int, out string) {
	f, err := os.Create(out)
	if err != nil {
		panic(err)
	}
	defer f.Close()
	w := bufio.NewWriter(f)
	defer w.Flush()
	if kind == "plain" {
		for i := 0; i < n; i++ {
			fmt.Fprintf(w, "h%d.%s\n", i, zone)
		}
		return
	}
	const mask = 0x3FFF
	target := pionSuffixHash([]string{"h0", "bulk", "example"}) & mask
	found := 0
	for c := 0; found < n; c++ {
		l := "c" + strconv.FormatInt(int64(c), 36)
		if pionSuffixHash([]string{l, "bulk", "example"})&mask == target {
			fmt.Fprintf(w, "%s.%s\n", l, zone)
			found++
		}
	}
}

func readNames(p string) []string {
	b, err := os.ReadFile(p)
	if err != nil {
		panic(err)
	}
	var out []string
	for _, l := range strings.Split(string(b), "\n") {
		if l != "" {
			out = append(out, l)
		}
	}
	return out
}

func build(names []string) *dns.Msg {
	m := new(dns.Msg)
	m.Id = 0x4242
	m.Response = true
	m.RecursionDesired = true
	m.RecursionAvailable = true
	m.Compress = true
	m.Question = []dns.Question{{Name: "q." + zone, Qtype: dns.TypeA, Qclass: dns.ClassINET}}
	for i, n := range names {
		rr := &dns.A{Hdr: dns.RR_Header{Name: n, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 60}}
		rr.A = []byte{10, byte(i >> 16), byte(i >> 8), byte(i)}
		m.Answer = append(m.Answer, rr)
	}
	return m
}

func fold(h uint64, w []byte) uint64 {
	for _, b := range w {
		h = (h*131 + uint64(b)) % 1000000007
	}
	return h
}

func main() {
	switch os.Args[1] {
	case "gen":
		n, _ := strconv.Atoi(os.Args[3])
		gen(os.Args[2], n, os.Args[4])
	case "encode":
		names := readNames(os.Args[2])
		rounds, _ := strconv.Atoi(os.Args[3])
		m := build(names)
		var total, h uint64
		for r := 0; r < rounds; r++ {
			w, err := m.Pack()
			if err != nil {
				fmt.Println("pack error:", err)
				os.Exit(1)
			}
			total += uint64(len(w))
			if r == 0 {
				h = fold(0, w)
			}
		}
		fmt.Printf("mode=encode\nrrs=%d\nbytes=%d\nwire_hash=%d\n", len(names), total, h)
	case "decode":
		names := readNames(os.Args[2])
		rounds, _ := strconv.Atoi(os.Args[3])
		w, err := build(names).Pack()
		if err != nil {
			os.Exit(1)
		}
		var rrs uint64
		for r := 0; r < rounds; r++ {
			var d dns.Msg
			if err := d.Unpack(w); err != nil {
				fmt.Println("unpack error:", err)
				os.Exit(1)
			}
			rrs += uint64(len(d.Answer))
		}
		fmt.Printf("mode=decode\nrrs=%d\nwire=%d\n", rrs, len(w))
	}
}
