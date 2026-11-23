package main

import (
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/hex"
	"fmt"
	"os"
)

func makeBuf(n int) []byte {
	out := make([]byte, n)
	for i := 0; i < n; i++ {
		out[i] = byte((i*131 + 17) & 0xFF)
	}
	return out
}

func benchSha256() int {
	chunk := makeBuf(65536)
	h := sha256.New()
	for i := 0; i < 256; i++ {
		h.Write(chunk)
	}
	fmt.Printf("sha256=%s\n", hex.EncodeToString(h.Sum(nil)))
	return 0
}

func benchSha512() int {
	chunk := makeBuf(65536)
	h := sha512.New()
	for i := 0; i < 256; i++ {
		h.Write(chunk)
	}
	fmt.Printf("sha512=%s\n", hex.EncodeToString(h.Sum(nil)))
	return 0
}

func benchHmac256() int {
	key := []byte("pion-crypto-bench-hmac-key-0123456789abcdef")
	msg := makeBuf(256)
	var acc [32]byte
	for i := 0; i < 50000; i++ {
		msg[0] = byte(i & 0xFF)
		msg[1] = byte((i >> 8) & 0xFF)
		m := hmac.New(sha256.New, key)
		m.Write(msg)
		mac := m.Sum(nil)
		for j := 0; j < 32; j++ {
			acc[j] ^= mac[j]
		}
	}
	fmt.Printf("hmac256_xor=%s\n", hex.EncodeToString(acc[:]))
	return 0
}

func benchEd25519() int {
	seed, err := hex.DecodeString("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
	if err != nil {
		return 1
	}
	priv := ed25519.NewKeyFromSeed(seed)
	pub := priv.Public().(ed25519.PublicKey)
	msg := makeBuf(128)
	h := sha256.New()
	okCount := 0
	for i := 0; i < 200; i++ {
		msg[0] = byte(i & 0xFF)
		msg[1] = byte((i >> 8) & 0xFF)
		sig := ed25519.Sign(priv, msg)
		if ed25519.Verify(pub, msg, sig) {
			okCount++
		}
		h.Write(sig)
	}
	fmt.Printf("ed25519_ok=%d\n", okCount)
	fmt.Printf("ed25519_sigs_sha256=%s\n", hex.EncodeToString(h.Sum(nil)))
	if okCount == 200 {
		return 0
	}
	return 3
}

func main() {
	mode := "sha256"
	if len(os.Args) > 1 {
		mode = os.Args[1]
	}
	switch mode {
	case "sha256":
		os.Exit(benchSha256())
	case "sha512":
		os.Exit(benchSha512())
	case "hmac256":
		os.Exit(benchHmac256())
	case "ed25519":
		os.Exit(benchEd25519())
	default:
		fmt.Println("usage: crypto_bench_go [sha256|sha512|hmac256|ed25519]")
		os.Exit(1)
	}
}
