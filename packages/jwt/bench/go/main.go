package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

var secretKey = []byte("pion-jwt-benchmark-secret-key-2026-0123456789abcdef")

type BenchClaims struct {
	Iss string `json:"iss"`
	Sub string `json:"sub"`
	Aud string `json:"aud"`
	Exp int64  `json:"exp"`
	Nbf int64  `json:"nbf"`
	Iat int64  `json:"iat"`
	Jti string `json:"jti"`
}

func (c BenchClaims) GetExpirationTime() (*jwt.NumericDate, error) {
	return jwt.NewNumericDate(time.Unix(c.Exp, 0)), nil
}

func (c BenchClaims) GetIssuedAt() (*jwt.NumericDate, error) {
	return jwt.NewNumericDate(time.Unix(c.Iat, 0)), nil
}

func (c BenchClaims) GetNotBefore() (*jwt.NumericDate, error) {
	return jwt.NewNumericDate(time.Unix(c.Nbf, 0)), nil
}

func (c BenchClaims) GetIssuer() (string, error) {
	return c.Iss, nil
}

func (c BenchClaims) GetSubject() (string, error) {
	return c.Sub, nil
}

func (c BenchClaims) GetAudience() (jwt.ClaimStrings, error) {
	return jwt.ClaimStrings{c.Aud}, nil
}

func fnv1aUpdate(h uint64, s string) uint64 {
	for i := 0; i < len(s); i++ {
		h = (h ^ uint64(s[i])) * 1099511628211
	}
	return h
}

func runSign(count int) {
	var hash uint64 = 14695981039346656037
	var totalBytes int64
	var first, second, last string

	for i := 0; i < count; i++ {
		is256 := (i & 1) == 0
		idxStr := strconv.Itoa(i)
		claims := BenchClaims{
			Iss: "https://auth.pion.dev",
			Sub: "user-" + idxStr,
			Aud: "api-gateway",
			Exp: 2000000000 + int64(i%3600),
			Nbf: 1700000000,
			Iat: 1700000000,
			Jti: "tok-" + idxStr,
		}
		var method jwt.SigningMethod = jwt.SigningMethodHS512
		if is256 {
			method = jwt.SigningMethodHS256
		}
		tokObj := jwt.NewWithClaims(method, claims)
		delete(tokObj.Header, "typ")
		tok, err := tokObj.SignedString(secretKey)
		if err != nil {
			panic(err)
		}
		totalBytes += int64(len(tok))
		hash = fnv1aUpdate(hash, tok)
		if i == 0 {
			first = tok
		} else if i == 1 {
			second = tok
		} else if i == count-1 {
			last = tok
		}
	}

	fmt.Println("mode=sign")
	fmt.Printf("count=%d\n", count)
	fmt.Printf("total_bytes=%d\n", totalBytes)
	fmt.Printf("hash=%d\n", hash)
	fmt.Printf("first=%s\n", first)
	fmt.Printf("second=%s\n", second)
	fmt.Printf("last=%s\n", last)
}

func runVerify(path string) {
	data, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}
	fixedNow := func() time.Time { return time.Unix(1795384400, 0) }
	parser256 := jwt.NewParser(
		jwt.WithValidMethods([]string{"HS256"}),
		jwt.WithIssuer("https://auth.pion.dev"),
		jwt.WithAudience("api-gateway"),
		jwt.WithExpirationRequired(),
		jwt.WithTimeFunc(fixedNow),
	)
	parser512 := jwt.NewParser(
		jwt.WithValidMethods([]string{"HS512"}),
		jwt.WithIssuer("https://auth.pion.dev"),
		jwt.WithAudience("api-gateway"),
		jwt.WithExpirationRequired(),
		jwt.WithTimeFunc(fixedNow),
	)
	keyFunc := func(t *jwt.Token) (any, error) {
		return secretKey, nil
	}

	var count, okCount int
	var expSum int64
	var hash uint64 = 14695981039346656037

	lines := strings.Split(string(data), "\n")
	for _, line := range lines {
		if len(line) <= 4 {
			continue
		}
		is256 := line[0] == '2'
		tokStr := line[4:]
		count++
		var claims BenchClaims
		p := parser512
		if is256 {
			p = parser256
		}
		tok, err := p.ParseWithClaims(tokStr, &claims, keyFunc)
		if err != nil || !tok.Valid {
			panic(fmt.Sprintf("verify failed at line %d: %v", count, err))
		}
		okCount++
		expSum += claims.Exp
		hash = fnv1aUpdate(hash, claims.Sub)
		hash = fnv1aUpdate(hash, claims.Jti)
	}

	fmt.Println("mode=verify")
	fmt.Printf("count=%d\n", count)
	fmt.Printf("ok=%d\n", okCount)
	fmt.Printf("exp_sum=%d\n", expSum)
	fmt.Printf("hash=%d\n", hash)
}

func main() {
	mode := "sign"
	if len(os.Args) > 1 {
		mode = os.Args[1]
	}
	switch mode {
	case "sign":
		runSign(50000)
	case "verify":
		path := "/tmp/pion-jwt-bench/tokens_50000.txt"
		if len(os.Args) > 2 {
			path = os.Args[2]
		}
		runVerify(path)
	default:
		fmt.Fprintln(os.Stderr, "usage: jwt-bench-go [sign|verify <path>]")
		os.Exit(1)
	}
}
