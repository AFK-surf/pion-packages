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

func canonHeaderRelaxed(name, rawVal string) string {
	var b strings.Builder
	b.WriteString(strings.ToLower(strings.TrimSpace(name)))
	b.WriteByte(':')
	inWsp := false
	wrote := false
	for i := 0; i < len(rawVal); i++ {
		c := rawVal[i]
		if c == '\r' || c == '\n' {
			continue
		}
		if c == ' ' || c == '\t' {
			if wrote {
				inWsp = true
			}
		} else {
			if inWsp {
				b.WriteByte(' ')
				inWsp = false
			}
			b.WriteByte(c)
			wrote = true
		}
	}
	return b.String()
}

func canonBodyRelaxed(body []byte) []byte {
	if len(body) == 0 {
		return nil
	}
	rawLines := bytes.Split(body, []byte("\n"))
	lines := make([][]byte, 0, len(rawLines))
	for idx, l := range rawLines {
		if idx == len(rawLines)-1 && len(l) == 0 {
			break
		}
		l = bytes.TrimSuffix(l, []byte("\r"))
		l = bytes.TrimRight(l, " \t")
		var out []byte
		prevWsp := false
		for _, c := range l {
			if c == ' ' || c == '\t' {
				if !prevWsp {
					out = append(out, ' ')
					prevWsp = true
				}
			} else {
				out = append(out, c)
				prevWsp = false
			}
		}
		lines = append(lines, out)
	}
	for len(lines) > 0 && len(lines[len(lines)-1]) == 0 {
		lines = lines[:len(lines)-1]
	}
	if len(lines) == 0 {
		return nil
	}
	var buf bytes.Buffer
	for _, l := range lines {
		buf.Write(l)
		buf.WriteString("\r\n")
	}
	return buf.Bytes()
}

func benchW3Dkim() int {
	seed := make([]byte, 32)
	for i := 0; i < 32; i++ {
		seed[i] = byte(i + 1)
	}
	priv := ed25519.NewKeyFromSeed(seed)
	pub := priv.Public().(ed25519.PublicKey)

	var ops int64
	var verified int64
	var checksum int64

	for i := 0; i < 2000; i++ {
		subj := "DKIM Bench #" + strconv.Itoa(i)
		bodyTxt := "Benchmark body line " + strconv.Itoa(i) + " with payload."
		b64Body := base64.StdEncoding.EncodeToString([]byte(bodyTxt))
		rawMsg := "From: Sender <sender@example.com>\r\n" +
			"To: Recipient <recv@example.com>\r\n" +
			"Subject: " + subj + "\r\n" +
			"Date: Mon, 23 Nov 2026 12:00:00 +0000\r\n" +
			"MIME-Version: 1.0\r\n" +
			"Content-Type: text/plain; charset=\"utf-8\"\r\n" +
			"Content-Transfer-Encoding: base64\r\n\r\n" +
			b64Body

		// Sign relaxed/relaxed
		sep := strings.Index(rawMsg, "\r\n\r\n")
		bodyBytes := []byte(rawMsg[sep+4:])
		cbody := canonBodyRelaxed(bodyBytes)
		bh := sha256.Sum256(cbody)
		bhB64 := base64.StdEncoding.EncodeToString(bh[:])
		dkimValNoB := " v=1; a=ed25519-sha256; c=relaxed/relaxed; d=example.com; s=ed2026; t=1795435200; h=from:to:subject:date; bh=" + bhB64 + "; b="

		var sigIn bytes.Buffer
		sigIn.WriteString(canonHeaderRelaxed("From", " Sender <sender@example.com>"))
		sigIn.WriteString("\r\n")
		sigIn.WriteString(canonHeaderRelaxed("To", " Recipient <recv@example.com>"))
		sigIn.WriteString("\r\n")
		sigIn.WriteString(canonHeaderRelaxed("Subject", " "+subj))
		sigIn.WriteString("\r\n")
		sigIn.WriteString(canonHeaderRelaxed("Date", " Mon, 23 Nov 2026 12:00:00 +0000"))
		sigIn.WriteString("\r\n")
		sigIn.WriteString(canonHeaderRelaxed("DKIM-Signature", dkimValNoB))

		hDigest := sha256.Sum256(sigIn.Bytes())
		sigBytes := ed25519.Sign(priv, hDigest[:])
		sigB64 := base64.StdEncoding.EncodeToString(sigBytes)
		signedMsg := "DKIM-Signature:" + dkimValNoB + sigB64 + "\r\n" + rawMsg

		// Verify roundtrip from signedMsg
		sep2 := strings.Index(signedMsg, "\r\n\r\n")
		vBody := canonBodyRelaxed([]byte(signedMsg[sep2+4:]))
		vBh := sha256.Sum256(vBody)
		if !bytes.Equal(vBh[:], bh[:]) {
			return 10
		}
		firstEOL := strings.Index(signedMsg, "\r\n")
		dkimLine := signedMsg[:firstEOL]
		bTagIdx := strings.Index(dkimLine, "; b=")
		decSig, err := base64.StdEncoding.DecodeString(dkimLine[bTagIdx+4:])
		if err != nil {
			return 11
		}
		if !ed25519.Verify(pub, hDigest[:], decSig) {
			return 12
		}
		verified++
		checksum = hashBytes(checksum, vBh[:])
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
