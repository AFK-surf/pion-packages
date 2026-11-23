package main

import (
	"encoding/binary"
	"fmt"
	"os"

	"github.com/miekg/dns"
)

func mix(h, v int64) int64 {
	return (h*131 + v) % 1000000007
}

func hashName(h int64, name string) int64 {
	if name == "." || name == "" {
		return h
	}
	start := 0
	for i := 0; i < len(name); i++ {
		if name[i] == '.' {
			llen := i - start
			if llen > 0 {
				h = mix(h, int64(llen))
				for j := start; j < i; j++ {
					h = mix(h, int64(name[j]))
				}
			}
			start = i + 1
		}
	}
	if start < len(name) {
		llen := len(name) - start
		h = mix(h, int64(llen))
		for j := start; j < len(name); j++ {
			h = mix(h, int64(name[j]))
		}
	}
	return h
}

func hashRR(h int64, rr dns.RR) int64 {
	hdr := rr.Header()
	h = hashName(h, hdr.Name)
	h = mix(h, int64(hdr.Rrtype))
	h = mix(h, int64(hdr.Ttl))
	switch v := rr.(type) {
	case *dns.A:
		ip4 := v.A.To4()
		h = mix(h, int64(ip4[0]))
		h = mix(h, int64(ip4[1]))
		h = mix(h, int64(ip4[2]))
		h = mix(h, int64(ip4[3]))
	case *dns.AAAA:
		ip16 := v.AAAA.To16()
		for k := 0; k < 16; k += 2 {
			seg := uint16(ip16[k])<<8 | uint16(ip16[k+1])
			h = mix(h, int64(seg))
		}
	case *dns.CNAME:
		h = hashName(h, v.Target)
	case *dns.NS:
		h = hashName(h, v.Ns)
	case *dns.PTR:
		h = hashName(h, v.Ptr)
	case *dns.MX:
		h = mix(h, int64(v.Preference))
		h = hashName(h, v.Mx)
	case *dns.TXT:
		h = mix(h, int64(len(v.Txt)))
		for _, s := range v.Txt {
			h = mix(h, int64(len(s)))
			for j := 0; j < len(s); j++ {
				h = mix(h, int64(s[j]))
			}
		}
	case *dns.SOA:
		h = hashName(h, v.Ns)
		h = hashName(h, v.Mbox)
		h = mix(h, int64(v.Serial))
		h = mix(h, int64(v.Minttl))
	case *dns.SRV:
		h = mix(h, int64(v.Priority))
		h = mix(h, int64(v.Weight))
		h = mix(h, int64(v.Port))
		h = hashName(h, v.Target)
	case *dns.OPT:
		h = mix(h, int64(v.UDPSize()))
	}
	return h
}

func hashMsg(h int64, m *dns.Msg) int64 {
	h = mix(h, int64(m.Id))
	h = mix(h, int64(m.Rcode))
	for _, q := range m.Question {
		h = hashName(h, q.Name)
		h = mix(h, int64(q.Qtype))
	}
	for _, rr := range m.Answer {
		h = hashRR(h, rr)
	}
	for _, rr := range m.Ns {
		h = hashRR(h, rr)
	}
	for _, rr := range m.Extra {
		h = hashRR(h, rr)
	}
	return h
}

func benchDecode(data []byte) {
	var packets, totalRRs, checksum int64
	dlen := len(data)
	for round := 0; round < 200; round++ {
		pos := 0
		for pos+2 <= dlen {
			plen := int(binary.BigEndian.Uint16(data[pos : pos+2]))
			pstart := pos + 2
			pend := pstart + plen
			var m dns.Msg
			if err := m.Unpack(data[pstart:pend]); err != nil {
				fmt.Fprintf(os.Stderr, "unpack error: %v\n", err)
				os.Exit(1)
			}
			packets++
			totalRRs += int64(len(m.Answer) + len(m.Ns) + len(m.Extra))
			checksum = hashMsg(checksum, &m)
			pos = pend
		}
	}
	fmt.Printf("mode=decode\npackets=%d\nrrs=%d\nchecksum=%d\n", packets, totalRRs, checksum)
}

func benchEncode(data []byte) {
	var msgs []*dns.Msg
	dlen := len(data)
	pos := 0
	for pos+2 <= dlen {
		plen := int(binary.BigEndian.Uint16(data[pos : pos+2]))
		pstart := pos + 2
		pend := pstart + plen
		m := new(dns.Msg)
		if err := m.Unpack(data[pstart:pend]); err != nil {
			fmt.Fprintf(os.Stderr, "preload error: %v\n", err)
			os.Exit(1)
		}
		m.Compress = true
		msgs = append(msgs, m)
		pos = pend
	}
	var encoded, wireBytes, wireHash, rtHash int64
	for round := 0; round < 200; round++ {
		for _, m := range msgs {
			wire, err := m.Pack()
			if err != nil {
				fmt.Fprintf(os.Stderr, "pack error: %v\n", err)
				os.Exit(1)
			}
			encoded++
			wireBytes += int64(len(wire))
			if round == 0 {
				for _, b := range wire {
					wireHash = mix(wireHash, int64(b))
				}
				var rt dns.Msg
				if err := rt.Unpack(wire); err != nil {
					fmt.Fprintf(os.Stderr, "rt error: %v\n", err)
					os.Exit(1)
				}
				rtHash = hashMsg(rtHash, &rt)
			}
		}
	}
	fmt.Printf("mode=encode\nencoded=%d\nwire_bytes=%d\nwire_hash=%d\nrt_hash=%d\n", encoded, wireBytes, wireHash, rtHash)
}

func benchQueryRT() {
	names := make([]string, 100)
	for i := 0; i < 100; i++ {
		names[i] = fmt.Sprintf("host%d.api.example.com.", i)
	}
	qtypes := [4]uint16{dns.TypeA, dns.TypeAAAA, dns.TypeMX, dns.TypeTXT}
	var ops, totalBytes, checksum int64
	for i := 0; i < 500000; i++ {
		m := new(dns.Msg)
		m.Id = uint16(i & 0xFFFF)
		m.RecursionDesired = true
		m.Compress = true
		m.Question = []dns.Question{{Name: names[i%100], Qtype: qtypes[i&3], Qclass: dns.ClassINET}}
		wire, err := m.Pack()
		if err != nil {
			os.Exit(1)
		}
		totalBytes += int64(len(wire))
		var dec dns.Msg
		if err := dec.Unpack(wire); err != nil {
			os.Exit(1)
		}
		ops++
		checksum = mix(checksum, int64(dec.Id))
		checksum = mix(checksum, int64(dec.Question[0].Qtype))
		checksum = mix(checksum, int64(len(wire)))
	}
	fmt.Printf("mode=query_rt\nops=%d\nbytes=%d\nchecksum=%d\n", ops, totalBytes, checksum)
}

func main() {
	if len(os.Args) < 2 {
		os.Exit(1)
	}
	mode := os.Args[1]
	if mode == "query_rt" {
		benchQueryRT()
		return
	}
	data, err := os.ReadFile(os.Args[2])
	if err != nil {
		os.Exit(1)
	}
	switch mode {
	case "decode":
		benchDecode(data)
	case "encode":
		benchEncode(data)
	default:
		os.Exit(1)
	}
}
