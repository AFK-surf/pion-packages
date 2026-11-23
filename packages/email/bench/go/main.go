package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"net/mail"
	"os"
	"strconv"
	"strings"

	"github.com/emersion/go-msgauth/dkim"
)

func mix(h, v int64) int64 {
	return (h*131 + v) % 1000000007
}

func hashBytes(h0 int64, b []byte) int64 {
	h := mix(h0, int64(len(b)))
	for _, x := range b {
		h = mix(h, int64(x))
	}
	return h
}

func hashStr(h0 int64, s string) int64 {
	return hashBytes(h0, []byte(s))
}

func benchW2AddrDate(data []byte) int {
	lines := strings.Split(strings.TrimRight(string(data), "\r\n"), "\n")
	addrs := make([]string, 0, len(lines))
	dates := make([]string, 0, len(lines))
	for _, line := range lines {
		line = strings.TrimRight(line, "\r")
		idx := strings.IndexByte(line, '\t')
		if idx > 0 {
			addrs = append(addrs, line[:idx])
			dates = append(dates, line[idx+1:])
		}
	}

	var ops int64
	var checksum int64
	for round := 0; round < 200; round++ {
		for i := range addrs {
			list, err := mail.ParseAddressList(addrs[i])
			if err != nil {
				fmt.Fprintf(os.Stderr, "addr err: %v\n", err)
				return 3
			}
			for _, a := range list {
				checksum = hashStr(checksum, a.Address)
			}
			t, err := mail.ParseDate(dates[i])
			if err != nil {
				fmt.Fprintf(os.Stderr, "date err: %v\n", err)
				return 4
			}
			checksum = mix(checksum, t.Unix()%1000000007)
			ops++
		}
	}

	fmt.Println("mode=w2_addr_date")
	fmt.Printf("ops=%d\n", ops)
	fmt.Printf("checksum=%d\n", checksum)
	return 0
}

func benchW3Dkim() int {
	seed := make([]byte, 32)
	for i := 0; i < 32; i++ {
		seed[i] = byte(i + 1)
	}
	priv := ed25519.NewKeyFromSeed(seed)
	pub := priv.Public().(ed25519.PublicKey)
	pubTxt := "v=DKIM1; k=ed25519; p=" + base64.StdEncoding.EncodeToString(pub)

	signOpts := &dkim.SignOptions{
		Domain:                 "example.com",
		Selector:               "ed2026",
		Signer:                 priv,
		HeaderCanonicalization: dkim.CanonicalizationRelaxed,
		BodyCanonicalization:   dkim.CanonicalizationRelaxed,
		HeaderKeys:             []string{"From", "To", "Subject", "Date"},
	}
	verifyOpts := &dkim.VerifyOptions{
		LookupTXT: func(domain string) ([]string, error) {
			if domain == "ed2026._domainkey.example.com" {
				return []string{pubTxt}, nil
			}
			return nil, fmt.Errorf("unknown domain: %s", domain)
		},
	}

	var ops int64
	var verified int64
	var checksum int64

	for i := 0; i < 2000; i++ {
		subj := "DKIM Bench #" + strconv.Itoa(i)
		bodyTxt := "Benchmark body line " + strconv.Itoa(i) + " with payload."
		b64Body := base64.StdEncoding.EncodeToString([]byte(bodyTxt))

		var rawBuf bytes.Buffer
		rawBuf.WriteString("From: Sender <sender@example.com>\r\n")
		rawBuf.WriteString("To: Recipient <recv@example.com>\r\n")
		rawBuf.WriteString("Subject: ")
		rawBuf.WriteString(subj)
		rawBuf.WriteString("\r\n")
		rawBuf.WriteString("Date: Mon, 23 Nov 2026 12:00:00 +0000\r\n")
		rawBuf.WriteString("MIME-Version: 1.0\r\n")
		rawBuf.WriteString("Content-Type: text/plain; charset=\"utf-8\"\r\n")
		rawBuf.WriteString("Content-Transfer-Encoding: base64\r\n\r\n")
		rawBuf.WriteString(b64Body)
		rawBytes := rawBuf.Bytes()

		// Full RFC 6376/8463 DKIM signing via emersion/go-msgauth v0.7.0
		var signedBuf bytes.Buffer
		if err := dkim.Sign(&signedBuf, bytes.NewReader(rawBytes), signOpts); err != nil {
			fmt.Fprintf(os.Stderr, "dkim sign err: %v\n", err)
			return 10
		}
		signedBytes := signedBuf.Bytes()

		// Full RFC 6376/8463 DKIM re-parse, re-canonicalization, and Ed25519 verify
		verifications, err := dkim.VerifyWithOptions(bytes.NewReader(signedBytes), verifyOpts)
		if err != nil || len(verifications) != 1 || verifications[0].Err != nil {
			fmt.Fprintf(os.Stderr, "dkim verify err: %v\n", err)
			return 11
		}
		v := verifications[0]
		if v.Domain != "example.com" {
			return 12
		}

		// Hash the exact built message bytes, verified domain, signed header count, and canonicalized body SHA-256
		sep := bytes.Index(signedBytes, []byte("\r\n\r\n"))
		if sep < 0 {
			return 13
		}
		bh := sha256.Sum256(append(append([]byte{}, signedBytes[sep+4:]...), '\r', '\n'))
		verified++
		checksum = hashBytes(checksum, rawBytes)
		checksum = hashStr(checksum, v.Domain)
		checksum = mix(checksum, int64(len(v.HeaderKeys)))
		checksum = hashBytes(checksum, bh[:])
		ops++
	}

	fmt.Println("mode=w3_dkim")
	fmt.Printf("ops=%d\n", ops)
	fmt.Printf("verified=%d\n", verified)
	fmt.Printf("checksum=%d\n", checksum)
	return 0
}

func main() {
	if len(os.Args) < 2 {
		os.Exit(1)
	}
	mode := os.Args[1]
	if mode == "w3_dkim" {
		os.Exit(benchW3Dkim())
	}
	if len(os.Args) < 3 {
		os.Exit(1)
	}
	data, err := os.ReadFile(os.Args[2])
	if err != nil {
		os.Exit(1)
	}
	switch mode {
	case "w2_addr_date":
		os.Exit(benchW2AddrDate(data))
	default:
		os.Exit(1)
	}
}
