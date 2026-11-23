package main

import (
	"crypto/x509"
	"encoding/asn1"
	"encoding/binary"
	"encoding/pem"
	"fmt"
	"os"
)

func runPemChain(path string) {
	raw, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "read error: %v\n", err)
		os.Exit(1)
	}
	var totalCerts int
	var cnBytes int64
	var sanCount int64
	var caCount int
	var spkiBytes int64
	var sigBytes int64
	var timeSum int64

	for r := 0; r < 100; r++ {
		rest := raw
		for {
			var block *pem.Block
			block, rest = pem.Decode(rest)
			if block == nil {
				break
			}
			if block.Type != "CERTIFICATE" {
				continue
			}
			cert, err := x509.ParseCertificate(block.Bytes)
			if err != nil {
				fmt.Fprintf(os.Stderr, "x509 parse error: %v\n", err)
				os.Exit(2)
			}
			totalCerts++
			cnBytes += int64(len(cert.Subject.CommonName))
			sanCount += int64(len(cert.DNSNames) + len(cert.IPAddresses) + len(cert.URIs) + len(cert.EmailAddresses))
			if cert.IsCA {
				caCount++
			}
			spkiBytes += int64(len(cert.RawSubjectPublicKeyInfo))
			sigBytes += int64(len(cert.Signature))
			timeSum += cert.NotBefore.Unix() + cert.NotAfter.Unix()
		}
	}

	fmt.Printf("certs=%d\n", totalCerts)
	fmt.Printf("cn_bytes=%d\n", cnBytes)
	fmt.Printf("san_count=%d\n", sanCount)
	fmt.Printf("ca_count=%d\n", caCount)
	fmt.Printf("spki_bytes=%d\n", spkiBytes)
	fmt.Printf("sig_bytes=%d\n", sigBytes)
	fmt.Printf("time_sum=%d\n", timeSum)
}

func runDerX509Host(path string) {
	raw, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "read error: %v\n", err)
		os.Exit(1)
	}
	var ders [][]byte
	pos := 0
	for pos+4 <= len(raw) {
		clen := int(binary.BigEndian.Uint32(raw[pos : pos+4]))
		pos += 4
		ders = append(ders, raw[pos:pos+clen])
		pos += clen
	}
	exactHosts := make([]string, len(ders))
	wildHosts := make([]string, len(ders))
	for i := range ders {
		exactHosts[i] = fmt.Sprintf("svc-%03d.pion.dev", i)
		wildHosts[i] = fmt.Sprintf("api.t%03d.pion.dev", i)
	}

	var totalCerts int
	var hostOk int
	var hostFail int
	var tbsBytes int64
	var timeSum int64

	for r := 0; r < 500; r++ {
		for i, der := range ders {
			cert, err := x509.ParseCertificate(der)
			if err != nil {
				fmt.Fprintf(os.Stderr, "x509 parse error: %v\n", err)
				os.Exit(2)
			}
			totalCerts++
			tbsBytes += int64(len(cert.RawTBSCertificate))
			timeSum += cert.NotBefore.Unix()
			if cert.VerifyHostname(exactHosts[i]) == nil {
				hostOk++
			} else {
				hostFail++
			}
			if cert.VerifyHostname(wildHosts[i]) == nil {
				hostOk++
			} else {
				hostFail++
			}
			if cert.VerifyHostname("nope.other.invalid") == nil {
				hostOk++
			} else {
				hostFail++
			}
		}
	}

	fmt.Printf("certs=%d\n", totalCerts)
	fmt.Printf("host_ok=%d\n", hostOk)
	fmt.Printf("host_fail=%d\n", hostFail)
	fmt.Printf("tbs_bytes=%d\n", tbsBytes)
	fmt.Printf("time_sum=%d\n", timeSum)
}

type subInts struct {
	A int64
	B int64
	C int64
}

type derRecord struct {
	ID      int64
	Active  bool
	Payload []byte
	Oid     asn1.ObjectIdentifier
	Label   string `asn1:"utf8"`
	Sub     subInts
}

func runDerTlvRoundtrip() {
	payloads := make([][]byte, 100)
	labels := make([]string, 100)
	for i := 0; i < 100; i++ {
		p := make([]byte, 24)
		for k := 0; k < 24; k++ {
			p[k] = byte((i + k*7) & 0xFF)
		}
		payloads[i] = p
		labels[i] = fmt.Sprintf("asn1-record-%d", i)
	}
	oid := asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 1, 11}

	var ops int
	var encodedBytes int64
	var intSum int64
	var boolTrue int
	var payloadSum int64
	var strBytes int64

	for r := 0; r < 1000; r++ {
		for i := 0; i < 100; i++ {
			rec := derRecord{
				ID:      int64(i)*100003 + 7,
				Active:  (i & 1) == 0,
				Payload: payloads[i],
				Oid:     oid,
				Label:   labels[i],
				Sub: subInts{
					A: int64(i) * 3,
					B: -(int64(i) * 5) - 1,
					C: int64(i)*17 + 128,
				},
			}
			der, err := asn1.Marshal(rec)
			if err != nil {
				fmt.Fprintf(os.Stderr, "marshal error: %v\n", err)
				os.Exit(3)
			}
			encodedBytes += int64(len(der))
			var dec derRecord
			rest, err := asn1.Unmarshal(der, &dec)
			if err != nil || len(rest) != 0 {
				fmt.Fprintf(os.Stderr, "unmarshal error: %v\n", err)
				os.Exit(4)
			}
			intSum += dec.ID + dec.Sub.A + dec.Sub.B + dec.Sub.C
			if dec.Active {
				boolTrue++
			}
			for _, b := range dec.Payload {
				payloadSum += int64(b)
			}
			strBytes += int64(len(dec.Label))
			ops++
		}
	}

	fmt.Printf("ops=%d\n", ops)
	fmt.Printf("encoded_bytes=%d\n", encodedBytes)
	fmt.Printf("int_sum=%d\n", intSum)
	fmt.Printf("bool_true=%d\n", boolTrue)
	fmt.Printf("payload_sum=%d\n", payloadSum)
	fmt.Printf("str_bytes=%d\n", strBytes)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: go_bench <pem_chain|der_x509_host|der_tlv_roundtrip> [corpus]")
		os.Exit(1)
	}
	switch os.Args[1] {
	case "pem_chain":
		runPemChain(os.Args[2])
	case "der_x509_host":
		runDerX509Host(os.Args[2])
	case "der_tlv_roundtrip":
		runDerTlvRoundtrip()
	default:
		fmt.Fprintf(os.Stderr, "unknown cmd: %s\n", os.Args[1])
		os.Exit(1)
	}
}
