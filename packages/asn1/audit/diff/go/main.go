// Red-team differential oracle for packages/asn1 (Go 1.27 side).
//
//	oracle_go vectors <corpus.tsv>
//	oracle_go certs <file.derbin> <iters>
//
// Typed DER values use the same code paths crypto/x509 uses (golang.org/x/crypto/cryptobyte
// for strict DER headers / times, encoding/asn1 for strings and integers, x509.OID for
// arbitrary-size OIDs). Output: "<label>\t<OK:...|ERR|NA>" per corpus line.
package main

import (
	"bufio"
	"crypto/x509"
	"encoding/asn1"
	"encoding/binary"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"math/big"
	"os"
	"strconv"
	"strings"
	"time"
	"unicode/utf16"

	"golang.org/x/crypto/cryptobyte"
	cbasn1 "golang.org/x/crypto/cryptobyte/asn1"
)

func one(b []byte, tag cbasn1.Tag) ([]byte, bool) {
	s := cryptobyte.String(b)
	var out cryptobyte.String
	if !s.ReadASN1(&out, tag) || !s.Empty() {
		return nil, false
	}
	return out, true
}

func unmarshal(b []byte, v any, params string) bool {
	rest, err := asn1.UnmarshalWithParams(b, v, params)
	return err == nil && len(rest) == 0
}

func typed(kind string, b []byte) string {
	switch kind {
	case "bool":
		var v bool
		if unmarshal(b, &v, "") {
			return fmt.Sprintf("OK:%v", v)
		}
	case "int64":
		var v int64
		if unmarshal(b, &v, "") {
			return fmt.Sprintf("OK:%d", v)
		}
	case "uint64":
		v := new(big.Int)
		if unmarshal(b, &v, "") && v.Sign() >= 0 && v.BitLen() <= 64 {
			return "OK:" + v.String()
		}
	case "bits":
		var v asn1.BitString
		if unmarshal(b, &v, "") {
			return fmt.Sprintf("OK:%d:%x", len(v.Bytes)*8-v.BitLength, v.Bytes)
		}
	case "octet":
		var v []byte
		if unmarshal(b, &v, "") {
			return fmt.Sprintf("OK:%x", v)
		}
	case "null":
		if c, ok := one(b, cbasn1.NULL); ok && len(c) == 0 {
			return "OK:null"
		}
	case "oid":
		if c, ok := one(b, cbasn1.OBJECT_IDENTIFIER); ok {
			var o x509.OID
			if o.UnmarshalBinary(c) == nil {
				return "OK:" + o.String()
			}
		}
	case "utf8", "printable", "ia5":
		var v string
		if unmarshal(b, &v, map[string]string{"utf8": "utf8", "printable": "printable", "ia5": "ia5"}[kind]) {
			return fmt.Sprintf("OK:%x", v)
		}
	case "bmp":
		// encoding/asn1 has no BMPString; reproduce crypto/x509's parseASN1String BMPString branch.
		if c, ok := one(b, cbasn1.Tag(30)); ok {
			if len(c)%2 != 0 {
				return "ERR"
			}
			if len(c) >= 2 && c[0] == 0xfe && c[1] == 0xff { // x509 strips a BOM
				c = c[2:]
			}
			u := make([]uint16, 0, len(c)/2)
			for i := 0; i+1 < len(c); i += 2 {
				u = append(u, uint16(c[i])<<8|uint16(c[i+1]))
			}
			return fmt.Sprintf("OK:%x", string(utf16.Decode(u)))
		}
	case "utc":
		s := cryptobyte.String(b)
		var t = new(timeHolder)
		if s.ReadASN1UTCTime(&t.t) && s.Empty() {
			return fmt.Sprintf("OK:%d", t.t.Unix())
		}
	case "gen":
		s := cryptobyte.String(b)
		var t = new(timeHolder)
		if s.ReadASN1GeneralizedTime(&t.t) && s.Empty() {
			return fmt.Sprintf("OK:%d", t.t.Unix())
		}
	default:
		return "UNKNOWN_KIND"
	}
	return "ERR"
}

// tree walks every TLV recursively with cryptobyte's strict DER header parser.
func tree(b []byte, depth int) (int, bool) {
	if depth > 64 {
		return 0, false
	}
	s := cryptobyte.String(b)
	n := 0
	for !s.Empty() {
		var content cryptobyte.String
		var tag cbasn1.Tag
		if !s.ReadAnyASN1(&content, &tag) {
			return 0, false
		}
		n++
		if tag&0x20 != 0 {
			k, ok := tree(content, depth+1)
			if !ok {
				return 0, false
			}
			n += k
		}
	}
	return n, true
}

func x509sum(c *x509.Certificate) string {
	san := len(c.DNSNames) + len(c.IPAddresses) + len(c.EmailAddresses) + len(c.URIs)
	return fmt.Sprintf("OK:v=%d:tbs=%d:nb=%d:na=%d:ext=%d:san=%d", c.Version, len(c.RawTBSCertificate),
		c.NotBefore.Unix(), c.NotAfter.Unix(), len(c.Extensions), san)
}

func run(kind string, a, b []byte) string {
	switch kind {
	case "tree":
		s := cryptobyte.String(a)
		var el cryptobyte.String
		var tag cbasn1.Tag
		if !s.ReadAnyASN1Element(&el, &tag) || !s.Empty() {
			return "ERR"
		}
		n, ok := tree(a, 1)
		if !ok {
			return "ERR"
		}
		return fmt.Sprintf("OK:%d", n)
	case "x509":
		c, err := x509.ParseCertificate(a)
		if err != nil {
			return "ERR:" + err.Error()
		}
		return x509sum(c)
	case "host":
		c, err := x509.ParseCertificate(a)
		if err != nil {
			return "ERR:" + err.Error()
		}
		return fmt.Sprintf("OK:%v", c.VerifyHostname(string(b)) == nil)
	case "spki":
		if _, err := x509.ParsePKIXPublicKey(a); err != nil {
			return "ERR:" + err.Error()
		}
		return "OK"
	case "pkcs8":
		if _, err := x509.ParsePKCS8PrivateKey(a); err != nil {
			return "ERR:" + err.Error()
		}
		return "OK"
	case "pem":
		blk, _ := pem.Decode(a)
		if blk == nil {
			return "ERR"
		}
		return fmt.Sprintf("OK:%s:%x", blk.Type, blk.Bytes)
	}
	return typed(kind, a)
}

func vectors(path string) {
	f, err := os.Open(path)
	if err != nil {
		panic(err)
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<26)
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	for sc.Scan() {
		parts := strings.Split(sc.Text(), "\t")
		a, _ := hex.DecodeString(parts[2])
		var b []byte
		if len(parts) > 3 {
			b, _ = hex.DecodeString(parts[3])
		}
		fmt.Fprintf(w, "%s\t%s\n", parts[0], run(parts[1], a, b))
	}
}

func certs(path string, iters int) {
	raw, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}
	var ders [][]byte
	for p := 0; p+4 <= len(raw); {
		l := int(binary.BigEndian.Uint32(raw[p:]))
		ders = append(ders, raw[p+4:p+4+l])
		p += 4 + l
	}
	ok, sum := 0, 0
	for it := 0; it < iters; it++ {
		for _, d := range ders {
			c, err := x509.ParseCertificate(d)
			if err == nil {
				ok++
				sum += len(c.RawTBSCertificate) + len(c.Extensions)
			}
		}
	}
	fmt.Printf("ok=%d sum=%d\n", ok, sum)
}

func main() {
	if len(os.Args) > 2 && os.Args[1] == "vectors" {
		vectors(os.Args[2])
		return
	}
	if len(os.Args) > 3 && os.Args[1] == "certs" {
		n, _ := strconv.Atoi(os.Args[3])
		certs(os.Args[2], n)
		return
	}
	fmt.Fprintln(os.Stderr, "usage: oracle_go vectors <corpus.tsv> | certs <file.derbin> <iters>")
	os.Exit(2)
}

type timeHolder struct{ t time.Time }
