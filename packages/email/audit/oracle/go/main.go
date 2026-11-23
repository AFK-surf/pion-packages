// Go oracle for the packages/email red-team audit:
//   - net/mail ParseAddressList / ParseDate differential (stdlib)
//   - emersion/go-msgauth v0.7.0 DKIM sign/verify (independent RFC 6376/8463 implementation)
//   - crypto/ed25519 + crypto/rsa key material
//
// Usage:
//
//	oracle addr <cases.tsv>
//	oracle date <cases.tsv>
//	oracle sign <out_dir>          write Go-signed DKIM fixtures + RFC 8463 vector
//	oracle verify <dir>            verify every pion_*.eml in <dir>, one line per file
package main

import (
	"bufio"
	"bytes"
	"crypto"
	"crypto/ed25519"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"fmt"
	"net/mail"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/emersion/go-msgauth/dkim"
)

// RFC 8032 §7.1 TEST 1 seed (= RFC 8463 Appendix A.1 Ed25519 key).
const ed25519SeedB64 = "nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A="

// Audit-only RSA-2048 key (PKCS#8). Also embedded in the Pion probe.
const rsa2048PEM = `-----BEGIN PRIVATE KEY-----
MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQCSqE101cM7VawG
TDNdrM9IsPO+1Xeb4fNezAheyDsf68JXseejLoQTA6l+I5/NRegr7/45NXcK1I5C
d2sj1itXQ6aUMBVLwxR233skZXENF7M4L73NBz3WMccPMU8KnH5NeaC4v08Onziz
xU2N76cjFxdRrCCT72shI8lF0Cr9RgMOcYLxBpAXaUkZBrWqSom0Ny6wXEwQ1umO
AdPxrG3Jtj0Ut2E0oE9/EYqXcl2EK15F7YL16RiwOQFs1mj5tQ8o/xiPa3Nq91Gv
xAiMWiTzNI0RFCaz/LIAjw+hXcGz/kIX6o0VTuFQMAPyEiPH1ZuCU0k42uSlvF8r
RFfePsg5AgMBAAECggEABCqv+K/SGi928b7cfr7YLNKKOlPKUC19QqY9XqQFugRy
wxcU47gAnKGwARt2ANkJnaX17R4twasEV7MY4i3FkXcklnU/RaXHQRFcaE5RhfO0
bdY9aEPaZ+mGJFJcUorbs8vO2zDkSCAR9lmWuH+kmgSf7vwa+NkGjCx+HXOqpQN7
MyHsrbahS4gWDnztFfB4DRwyTVpXE4UjODMHo4YgNnCF354U9kyC72/NHRAHnpl6
aUipYRP5yhmLvXPxl8/y2KITvOd2f6Vl7u7OS0FubE6OZrnkYf+U6smr1SA/QjQ7
R9zo+FB0rYDlKDIzOOslpbcoVfdDjCVozprNI4GgWQKBgQDG5UciWNUN/hCH7mcR
8DBi2bm8/2RIZpUY5L2KdUkU7KlTVi6GRjbtOL2OFX4hwA/zu4QCwlhcdOw94wD4
YLJXr6R0H4liZMXuQr2YV291NcFdKJP+XhFLhgt69Wl+xAt+Bzc+LvJ08p7KHcGo
xkvfUgC38Eh+74xvonwvDgBNuwKBgQC8w4u+aP45e99F5kuOb17ld72X+XkxVG+i
SCq8n53z3t/GQODEVMYntmp1YIZs5lPr8sEgRYb98Jk6dudxuyuY3z3+fkqjbrJo
mtgS+3wxA273FmF7quQgCN6C9rxjmNoW0bSRjMx52EOXuFsCafofD310zonwp3ts
GF8nq9eomwKBgAK/Hclaoq6LyJyn7SJxR6nFyevTNwZM7FgoqHll/zlbv0bYVNIj
3BRQiUWSBGjg5xd9imgjWOcF8lE0dkn3w960HThBSzthmt4ca9PTuUVMFbx8l/aW
Q/TgB/6NrwRCHsqBvQCN02lMBGdUG92Bx4Bw+HORzN573luYSdC4h8aLAoGAOprP
eRdpznkJ8c61KIylPsL1Rwi6OrmHSy/yrMs1o/BPM2MTJYFYYB3/YV/NfGPqLDgb
A6Tya0bWm9Msuh+tQnIU8j1NeP42P8nLSeFwRltViTsWmumMl/GI+8oU5SsgkrMa
x5GaLj4ZhjJDdzVl5VzOy4QQSXoGFKJgcJWmh/8CgYBGdd58kIX0mURXabzBd+5C
xLZ9QnCDFqmUF67C2MCuK/H2bjVrY81T4+0YIA01sGAHSTkniUJl4lot4Klm7HJg
C9flzEgdpcO1z/n3ZajWyyVGYtRyD22HoiuGsJBMG7osJuMEjYjg1VqPU/jTm242
7qqNDJl4TejNYRC4bGj/YQ==
-----END PRIVATE KEY-----`

// RFC 8463 Appendix A.2 RSA-1024 public key (selector "test").
const rfc8463RSAPub = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDkHlOQoBTzWRiGs5V6NpP3idY6Wk08a5qhdR6wy5bdOKb2jLQiY/J16JYi0Qvx/byYzCNb3W91y3FutACDfzwQ/BC/e/8uBsCR+yz1Lxj+PL6lHvqMKrM3rG4hstT5QjvHO9PzoxZyVYLzBfO2EeC3Ip3G+2kryOTIKT+l/K4w3QIDAQAB"

// RFC 8463 Appendix A.3, verbatim (CRLF line endings applied below).
var rfc8463Msg = strings.Join([]string{
	"DKIM-Signature: v=1; a=ed25519-sha256; c=relaxed/relaxed;",
	" d=football.example.com; i=@football.example.com;",
	" q=dns/txt; s=brisbane; t=1528637909; h=from : to :",
	" subject : date : message-id : from : subject : date;",
	" bh=2jUSOH9NhtVGCQWNr9BrIAPreKQjO6Sn7XIkfJVOzv8=;",
	" b=/gCrinpcQOoIfuHNQIbq4pgh9kyIK3AQUdt9OdqQehSwhEIug4D11Bus",
	" Fa3bT3FY5OsU7ZbnKELq+eXdp1Q1Dw==",
	"DKIM-Signature: v=1; a=rsa-sha256; c=relaxed/relaxed;",
	" d=football.example.com; i=@football.example.com;",
	" q=dns/txt; s=test; t=1528637909; h=from : to : subject :",
	" date : message-id : from : subject : date;",
	" bh=2jUSOH9NhtVGCQWNr9BrIAPreKQjO6Sn7XIkfJVOzv8=;",
	" b=F45dVWDfMbQDGHJFlXUNB2HKfbCeLRyhDXgFpEL8GwpsRe0IeIixNTe3",
	" DhCVlUrSjV4BwcVcOF6+FF3Zo9Rpo1tFOeS9mPYQTnGdaSGsgeefOsk2Jz",
	" dA+L10TeYt9BgDfQNZtKdN1WO//KgIqXP7OdEFE4LjFYNcUxZQ4FADY+8=",
	"From: Joe SixPack <joe@football.example.com>",
	"To: Suzie Q <suzie@shopping.example.net>",
	"Subject: Is dinner ready?",
	"Date: Fri, 11 Jul 2003 21:00:37 -0700 (PDT)",
	"Message-ID: <20030712040037.46341.5F8J@football.example.com>",
	"",
	"Hi.",
	"",
	"We lost the game.  Are you hungry yet?",
	"",
	"Joe.",
	"",
}, "\r\n")

func keys() (ed25519.PrivateKey, *rsa.PrivateKey) {
	seed, _ := base64.StdEncoding.DecodeString(ed25519SeedB64)
	edk := ed25519.NewKeyFromSeed(seed)
	blk, _ := pem.Decode([]byte(rsa2048PEM))
	if blk == nil {
		fmt.Fprintln(os.Stderr, "bad rsa pem")
		os.Exit(2)
	}
	k, err := x509.ParsePKCS8PrivateKey(blk.Bytes)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	return edk, k.(*rsa.PrivateKey)
}

func lookup() func(string) ([]string, error) {
	edk, rk := keys()
	spki, _ := x509.MarshalPKIXPublicKey(&rk.PublicKey)
	recs := map[string]string{
		"brisbane._domainkey.football.example.com": "v=DKIM1; k=ed25519; p=" + base64.StdEncoding.EncodeToString(edk.Public().(ed25519.PublicKey)),
		"test._domainkey.football.example.com":     "v=DKIM1; k=rsa; p=" + rfc8463RSAPub,
		"ed._domainkey.audit.example":              "v=DKIM1; k=ed25519; p=" + base64.StdEncoding.EncodeToString(edk.Public().(ed25519.PublicKey)),
		"rsa._domainkey.audit.example":             "v=DKIM1; k=rsa; p=" + base64.StdEncoding.EncodeToString(spki),
	}
	return func(d string) ([]string, error) {
		if v, ok := recs[d]; ok {
			return []string{v}, nil
		}
		return nil, fmt.Errorf("no record for %s", d)
	}
}

func cases(path string) [][2]string {
	f, err := os.Open(path)
	if err != nil {
		os.Exit(1)
	}
	defer f.Close()
	var out [][2]string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		l := sc.Text()
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		p := strings.SplitN(l, "\t", 3)
		if len(p) >= 2 {
			out = append(out, [2]string{p[0], p[1]})
		}
	}
	return out
}

// Body variants exercising RFC 6376 §3.4.3/§3.4.4 canonicalization edges.
var bodies = []string{
	"",
	"\r\n",
	"Hello.\r\n",
	"Hello.",
	"a  \t b \t\r\n\r\n\r\n\r\n",
	"line1\r\n \r\n\t\r\nline4   \r\n",
	" leading ws\r\n\r\nmid\r\n\r\n",
	"no final crlf  \t",
}

func baseHeaders(i int) string {
	return "From: Audit Sender <sender@audit.example>\r\n" +
		"To:   Recipient\r\n\t<rcpt@audit.example>  \r\n" +
		"SUBJECT:  Canon   case " + fmt.Sprint(i) + " \t\r\n" +
		"Date: Mon, 23 Nov 2026 12:00:00 +0000\r\n" +
		"X-Folded: a\r\n   b\r\n\tc\r\n"
}

func sign(raw []byte, signer crypto.Signer, sel string, hc, bc dkim.Canonicalization) []byte {
	var buf bytes.Buffer
	err := dkim.Sign(&buf, bytes.NewReader(raw), &dkim.SignOptions{
		Domain:                 "audit.example",
		Selector:               sel,
		Signer:                 signer,
		HeaderCanonicalization: hc,
		BodyCanonicalization:   bc,
		HeaderKeys:             []string{"From", "To", "Subject", "Date", "X-Folded"},
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "sign:", err)
		os.Exit(2)
	}
	return buf.Bytes()
}

func cmdSign(out string) {
	edk, rk := keys()
	cs := []dkim.Canonicalization{dkim.CanonicalizationSimple, dkim.CanonicalizationRelaxed}
	for bi, body := range bodies {
		raw := []byte(baseHeaders(bi) + "\r\n" + body)
		for _, hc := range cs {
			for _, bc := range cs {
				tag := fmt.Sprintf("%s_%s_b%02d", hc, bc, bi)
				os.WriteFile(filepath.Join(out, "go_ed_"+tag+".eml"), sign(raw, edk, "ed", hc, bc), 0o644)
				os.WriteFile(filepath.Join(out, "go_rsa_"+tag+".eml"), sign(raw, rk, "rsa", hc, bc), 0o644)
			}
		}
	}
	// Multi-signature messages (common with ESPs): rsa on top / ed25519 on top.
	raw := []byte(baseHeaders(99) + "\r\nmulti\r\n")
	edFirst := sign(sign(raw, rk, "rsa", dkim.CanonicalizationRelaxed, dkim.CanonicalizationRelaxed), edk, "ed", dkim.CanonicalizationRelaxed, dkim.CanonicalizationRelaxed)
	rsaFirst := sign(sign(raw, edk, "ed", dkim.CanonicalizationRelaxed, dkim.CanonicalizationRelaxed), rk, "rsa", dkim.CanonicalizationRelaxed, dkim.CanonicalizationRelaxed)
	os.WriteFile(filepath.Join(out, "multi_ed_top.eml"), edFirst, 0o644)
	os.WriteFile(filepath.Join(out, "multi_rsa_top.eml"), rsaFirst, 0o644)
	os.WriteFile(filepath.Join(out, "rfc8463.eml"), []byte(rfc8463Msg), 0o644)
	der, _ := base64.StdEncoding.DecodeString(rfc8463RSAPub)
	os.WriteFile(filepath.Join(out, "rfc8463_rsa1024.spki.der"), der, 0o644)
}

func cmdVerify(dir string) {
	ents, _ := os.ReadDir(dir)
	var names []string
	for _, e := range ents {
		if strings.HasPrefix(e.Name(), "pion_") && strings.HasSuffix(e.Name(), ".eml") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	opts := &dkim.VerifyOptions{LookupTXT: lookup()}
	for _, n := range names {
		raw, _ := os.ReadFile(filepath.Join(dir, n))
		vs, err := dkim.VerifyWithOptions(bytes.NewReader(raw), opts)
		res := "PASS"
		if err != nil {
			res = "FAIL " + err.Error()
		} else if len(vs) == 0 {
			res = "FAIL no-signature"
		} else {
			for _, v := range vs {
				if v.Err != nil {
					res = "FAIL " + v.Err.Error()
				}
			}
		}
		fmt.Printf("%s\t%s\n", strings.TrimSuffix(n, ".eml"), res)
	}
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: oracle addr|date|sign|verify <path>")
		os.Exit(1)
	}
	switch os.Args[1] {
	case "addr":
		for _, c := range cases(os.Args[2]) {
			l, err := mail.ParseAddressList(c[1])
			if err != nil {
				fmt.Printf("%s\tERR\n", c[0])
				continue
			}
			var parts []string
			for _, a := range l {
				parts = append(parts, a.Name+" <"+a.Address+">")
			}
			if len(parts) == 0 {
				fmt.Printf("%s\tOK\n", c[0])
			} else {
				fmt.Printf("%s\tOK %s\n", c[0], strings.Join(parts, " | "))
			}
		}
	case "date":
		for _, c := range cases(os.Args[2]) {
			t, err := mail.ParseDate(c[1])
			if err != nil {
				fmt.Printf("%s\tERR\n", c[0])
				continue
			}
			_, off := t.Zone()
			fmt.Printf("%s\tOK %d %d\n", c[0], t.Unix(), off)
		}
	case "sign":
		os.MkdirAll(os.Args[2], 0o755)
		cmdSign(os.Args[2])
	case "verify":
		cmdVerify(os.Args[2])
	default:
		os.Exit(1)
	}
}
