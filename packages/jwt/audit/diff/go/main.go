// Red-team differential oracle (Go side): crypto/sha256, crypto/sha512, crypto/hmac,
// encoding/base64 RawURLEncoding.Strict() and github.com/golang-jwt/jwt/v5 v5.3.1.
// Same CLI/output contract as the Pion oracle.
package main

import (
	"bufio"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"hash"
	"math"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const auditNow = 1795400000

func method(s string) jwt.SigningMethod {
	switch s {
	case "HS384":
		return jwt.SigningMethodHS384
	case "HS512":
		return jwt.SigningMethodHS512
	}
	return jwt.SigningMethodHS256
}

func parser(alg string) *jwt.Parser {
	// Aligned with Pion Validation::new: exp/nbf checked when present, nothing required,
	// aud/iss unchecked, zero leeway, fixed clock.
	return jwt.NewParser(
		jwt.WithValidMethods([]string{alg}),
		jwt.WithTimeFunc(func() time.Time { return time.Unix(auditNow, 0) }),
	)
}

func verdict(alg string, key []byte, tok string) string {
	claims := jwt.MapClaims{}
	_, err := parser(alg).ParseWithClaims(tok, claims, func(*jwt.Token) (any, error) { return key, nil })
	if err != nil {
		return "ERR"
	}
	if s, ok := claims["sub"].(string); ok {
		return "OK sub=" + hex.EncodeToString([]byte(s))
	}
	return "OK sub=-"
}

func mac(h func() hash.Hash, key, data []byte) string {
	m := hmac.New(h, key)
	m.Write(data)
	return hex.EncodeToString(m.Sum(nil))
}

func unhex(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}

var strictB64 = base64.RawURLEncoding.Strict()

func runLine(line string) string {
	f := strings.Split(line, "\t")
	var res string
	switch f[0] {
	case "H256":
		d := sha256.Sum256(unhex(f[2]))
		res = hex.EncodeToString(d[:])
	case "H384":
		d := sha512.Sum384(unhex(f[2]))
		res = hex.EncodeToString(d[:])
	case "H512":
		d := sha512.Sum512(unhex(f[2]))
		res = hex.EncodeToString(d[:])
	case "M256":
		res = mac(sha256.New, unhex(f[2]), unhex(f[3]))
	case "M384":
		res = mac(sha512.New384, unhex(f[2]), unhex(f[3]))
	case "M512":
		res = mac(sha512.New, unhex(f[2]), unhex(f[3]))
	case "B64E":
		res = base64.RawURLEncoding.EncodeToString(unhex(f[2]))
	case "B64D":
		// NOTE: Go's decoder silently skips '\r' and '\n' even in Strict mode.
		if b, err := strictB64.DecodeString(string(unhex(f[2]))); err == nil {
			res = "OK " + hex.EncodeToString(b)
		} else {
			res = "ERR"
		}
	case "JWTV":
		res = verdict(f[2], unhex(f[3]), string(unhex(f[4])))
	default:
		res = "UNKNOWN_OP"
	}
	return f[1] + "\t" + res
}

func emit(w *bufio.Writer, label, alg string, key []byte, hdrExtra map[string]any, claims jwt.MapClaims) {
	t := jwt.NewWithClaims(method(alg), claims)
	for k, v := range hdrExtra {
		t.Header[k] = v
	}
	s, err := t.SignedString(key)
	if err != nil {
		fmt.Fprintln(os.Stderr, "encode failed:", label, err)
		return
	}
	fmt.Fprintf(w, "JWTV\t%s\t%s\t%s\t%s\n", label, alg, hex.EncodeToString(key), hex.EncodeToString([]byte(s)))
}

func runSign() {
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	key := []byte("red-team-audit-secret-key-0123456789abcdef")
	subjects := []string{"alice", "用户-é-😀", "quote\"back\\slash", "ctl\x01\t\n\r\x1f", "line sep", "/solidus/", ""}
	for i, sub := range subjects {
		for _, alg := range []string{"HS256", "HS384", "HS512"} {
			emit(w, fmt.Sprintf("go_sign/sub%d/%s", i, alg), alg, key, nil, jwt.MapClaims{
				"iss": "https://issuer.example/é", "sub": sub, "aud": []string{"api", "β-svc"},
				"exp": 4000000000, "nbf": 1000000000, "iat": 1000000000, "jti": fmt.Sprintf("jti-%d", i),
				"nested": map[string]any{"k": []any{1, 2.5, nil, true, map[string]any{"z": "ü"}}, "neg": int64(math.MinInt64)},
				"role": "admin", "f": 0.1,
			})
		}
	}
	longKey := make([]byte, 300)
	for j := range longKey {
		longKey[j] = byte((j*7 + 3) & 255)
	}
	for _, alg := range []string{"HS256", "HS384", "HS512"} {
		emit(w, "go_sign/longkey/"+alg, alg, longKey, map[string]any{"kid": "kid-ключ"},
			jwt.MapClaims{"sub": "long-key", "aud": "api", "exp": 4000000000})
	}
	emit(w, "go_sign/custom_u64_max", "HS256", key, nil, jwt.MapClaims{"sub": "u64", "exp": 4000000000, "id": uint64(math.MaxUint64)})
	// golang-jwt encodes NumericDate with TimePrecision (seconds) but MapClaims passes floats through.
	emit(w, "go_sign/exp_fractional", "HS256", key, nil, jwt.MapClaims{"sub": "frac", "exp": 4000000000.5})
}

func runBench(path string, iters int) {
	data, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}
	type item struct {
		p   *jwt.Parser
		key []byte
		tok string
	}
	var items []item
	for _, line := range strings.Split(string(data), "\n") {
		if line == "" {
			continue
		}
		f := strings.Split(line, "\t")
		items = append(items, item{parser(f[2]), unhex(f[3]), string(unhex(f[4]))})
	}
	ok, bad := 0, 0
	for r := 0; r < iters; r++ {
		for _, it := range items {
			k := it.key
			if _, err := it.p.ParseWithClaims(it.tok, jwt.MapClaims{}, func(*jwt.Token) (any, error) { return k, nil }); err == nil {
				ok++
			} else {
				bad++
			}
		}
	}
	fmt.Printf("tokens=%d\niters=%d\nok=%d\nerr=%d\n", len(items), iters, ok, bad)
}

func runParse(path string, iters int) {
	data, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}
	var pays []string
	for _, line := range strings.Split(string(data), "\n") {
		if line == "" {
			continue
		}
		t := string(unhex(strings.Split(line, "\t")[4]))
		pays = append(pays, strings.Split(t, ".")[1])
	}
	ok, bad := 0, 0
	for r := 0; r < iters; r++ {
		for _, p := range pays {
			raw, err := base64.RawURLEncoding.DecodeString(p)
			var v any
			if err == nil && json.Unmarshal(raw, &v) == nil {
				ok++
			} else {
				bad++
			}
		}
	}
	fmt.Printf("tokens=%d\niters=%d\nok=%d\nerr=%d\n", len(pays), iters, ok, bad)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: oracle_go vectors <file> | sign | bench <file> <iters>")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "vectors":
		data, err := os.ReadFile(os.Args[2])
		if err != nil {
			panic(err)
		}
		w := bufio.NewWriterSize(os.Stdout, 1<<20)
		for _, line := range strings.Split(string(data), "\n") {
			if line != "" {
				w.WriteString(runLine(line))
				w.WriteByte('\n')
			}
		}
		w.Flush()
	case "sign":
		runSign()
	case "bench":
		n, _ := strconv.Atoi(os.Args[3])
		runBench(os.Args[2], n)
	case "parse":
		n, _ := strconv.Atoi(os.Args[3])
		runParse(os.Args[2], n)
	default:
		os.Exit(2)
	}
}
