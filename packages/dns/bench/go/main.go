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

func labelCount(name string) int64 {
	return int64(dns.CountLabel(name))
}

func hashRR(h int64, rr dns.RR) int64 {
	hdr := rr.Header()
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
		hi0 := uint16(ip16[0])<<8 | uint16(ip16[1])
		lo7 := uint16(ip16[14])<<8 | uint16(ip16[15])
		h = mix(h, int64(hi0))
		h = mix(h, int64(lo7))
	case *dns.CNAME:
		h = mix(h, labelCount(v.Target))
	case *dns.NS:
		h = mix(h, labelCount(v.Ns))
	case *dns.PTR:
		h = mix(h, labelCount(v.Ptr))
	case *dns.MX:
		h = mix(h, int64(v.Preference))
		h = mix(h, labelCount(v.Mx))
	case *dns.TXT:
		var tlen int64
		for _, s := range v.Txt {
			tlen += int64(len(s))
		}
		h = mix(h, tlen)
	case *dns.SOA:
		h = mix(h, int64(v.Serial))
		h = mix(h, int64(v.Minttl))
	case *dns.SRV:
		h = mix(h, int64(v.Priority))
		h = mix(h, int64(v.Weight))
		h = mix(h, int64(v.Port))
	case *dns.OPT:
		h = mix(h, int64(v.UDPSize()))
	}
	return h
}

func hashMsg(h int64, m *dns.Msg) int64 {
	h = mix(h, int64(m.Id))
	h = mix(h, int64(m.Rcode))
	for _, q := range m.Question {
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
	var encoded, hdrHash, rtHash int64
	for round := 0; round < 200; round++ {
		for _, m := range msgs {
			wire, err := m.Pack()
			if err != nil {
				fmt.Fprintf(os.Stderr, "pack error: %v\n", err)
				os.Exit(1)
			}
			encoded++
			for b := 0; b < 12; b++ {
				hdrHash = mix(hdrHash, int64(wire[b]))
			}
			if round == 0 {
				var rt dns.Msg
				if err := rt.Unpack(wire); err != nil {
					fmt.Fprintf(os.Stderr, "rt error: %v\n", err)
					os.Exit(1)
				}
				rtHash = hashMsg(rtHash, &rt)
			}
		}
	}
	fmt.Printf("mode=encode\nencoded=%d\nhdr_hash=%d\nrt_hash=%d\n", encoded, hdrHash, rtHash)
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
