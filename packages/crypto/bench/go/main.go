package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/hex"
	"fmt"
	"math/big"
	"os"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/pbkdf2"
	"golang.org/x/crypto/scrypt"
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

func benchX25519() int {
	k, err := hex.DecodeString("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
	if err != nil {
		return 1
	}
	u, err := hex.DecodeString("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
	if err != nil {
		return 1
	}
	curve := ecdh.X25519()
	h := sha256.New()
	for i := 0; i < 200; i++ {
		priv, err := curve.NewPrivateKey(k)
		if err != nil {
			return 2
		}
		pub, err := curve.NewPublicKey(u)
		if err != nil {
			return 2
		}
		shared, err := priv.ECDH(pub)
		if err != nil {
			return 2
		}
		h.Write(shared)
		u = k
		k = shared
	}
	fmt.Printf("x25519_sha256=%s\n", hex.EncodeToString(h.Sum(nil)))
	return 0
}

func benchHkdf256() int {
	salt := []byte("pion-crypto-bench-hkdf-salt-0123456789")
	ikm := makeBuf(32)
	info := "pion-crypto-bench-hkdf-info"
	var acc [64]byte
	for i := 0; i < 20000; i++ {
		ikm[0] = byte(i & 0xFF)
		ikm[1] = byte((i >> 8) & 0xFF)
		okm, err := hkdf.Key(sha256.New, ikm, salt, info, 64)
		if err != nil {
			return 1
		}
		for j := 0; j < 64; j++ {
			acc[j] ^= okm[j]
		}
	}
	fmt.Printf("hkdf256_xor=%s\n", hex.EncodeToString(acc[:]))
	return 0
}

func benchChaCha20() int {
	key, err := hex.DecodeString("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
	if err != nil {
		return 1
	}
	nonce, err := hex.DecodeString("070000004041424344454647")
	if err != nil {
		return 1
	}
	aad := []byte("pion-crypto-bench-aead-aad")
	pt := makeBuf(65536)
	aead, err := chacha20poly1305.New(key)
	if err != nil {
		return 1
	}
	h := sha256.New()
	for i := 0; i < 64; i++ {
		nonce[0] = byte(i & 0xFF)
		sealed := aead.Seal(nil, nonce, pt, aad)
		opened, err := aead.Open(nil, nonce, sealed, aad)
		if err != nil || len(opened) != len(pt) {
			return 2
		}
		h.Write(sealed)
	}
	fmt.Printf("chacha20_sha256=%s\n", hex.EncodeToString(h.Sum(nil)))
	return 0
}

func benchP256() int {
	skBytes, err := hex.DecodeString("c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721")
	if err != nil {
		return 1
	}
	curve := elliptic.P256()
	d := new(big.Int).SetBytes(skBytes)
	x, y := curve.ScalarBaseMult(skBytes)
	priv := &ecdsa.PrivateKey{
		PublicKey: ecdsa.PublicKey{Curve: curve, X: x, Y: y},
		D:         d,
	}
	msg := makeBuf(128)
	okCount := 0
	for i := 0; i < 50; i++ {
		msg[0] = byte(i & 0xFF)
		digest := sha256.Sum256(msg)
		r, s, err := ecdsa.Sign(rand.Reader, priv, digest[:])
		if err != nil {
			return 2
		}
		if ecdsa.Verify(&priv.PublicKey, digest[:], r, s) {
			okCount++
		}
	}
	fmt.Printf("p256_ok=%d\n", okCount)
	if okCount == 50 {
		return 0
	}
	return 3
}

func benchAes256Gcm() int {
	key, err := hex.DecodeString("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
	if err != nil {
		return 1
	}
	nonce, err := hex.DecodeString("070000004041424344454647")
	if err != nil {
		return 1
	}
	aad := []byte("pion-crypto-bench-aead-aad")
	pt := makeBuf(65536)
	blk, err := aes.NewCipher(key)
	if err != nil {
		return 1
	}
	aead, err := cipher.NewGCM(blk)
	if err != nil {
		return 1
	}
	h := sha256.New()
	for i := 0; i < 1000; i++ {
		nonce[0] = byte(i & 0xFF)
		nonce[1] = byte((i >> 8) & 0xFF)
		sealed := aead.Seal(nil, nonce, pt, aad)
		opened, err := aead.Open(nil, nonce, sealed, aad)
		if err != nil || len(opened) != len(pt) {
			return 2
		}
		h.Write(sealed)
	}
	fmt.Printf("aes256gcm_sha256=%s\n", hex.EncodeToString(h.Sum(nil)))
	return 0
}

func benchAes256GcmSmall() int {
	key, err := hex.DecodeString("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
	if err != nil {
		return 1
	}
	nonce, err := hex.DecodeString("070000004041424344454647")
	if err != nil {
		return 1
	}
	aad := []byte("pion-crypto-bench-small-aad")
	pt := makeBuf(256)
	blk, err := aes.NewCipher(key)
	if err != nil {
		return 1
	}
	aead, err := cipher.NewGCM(blk)
	if err != nil {
		return 1
	}
	h := sha256.New()
	for i := 0; i < 150000; i++ {
		nonce[0] = byte(i & 0xFF)
		nonce[1] = byte((i >> 8) & 0xFF)
		nonce[2] = byte((i >> 16) & 0xFF)
		sealed := aead.Seal(nil, nonce, pt, aad)
		opened, err := aead.Open(nil, nonce, sealed, aad)
		if err != nil || len(opened) != len(pt) {
			return 2
		}
		h.Write(sealed)
	}
	fmt.Printf("aes256gcm_small_sha256=%s\n", hex.EncodeToString(h.Sum(nil)))
	return 0
}

func benchP256Ecdh() int {
	sk, err := hex.DecodeString("c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721")
	if err != nil {
		return 1
	}
	peerBytes, err := hex.DecodeString("04c4cfd4dc14471cbc23f68830495857689ad122d899cc9d9726ea006c335a5122bb97ce9aac19a7a577297ad2654c320a1fb909cc0088793a691495d9aae2de08")
	if err != nil {
		return 1
	}
	curve := ecdh.P256()
	h := sha256.New()
	for i := 0; i < 2000; i++ {
		sk[31] = byte((int(sk[31]) + 1) & 0xFF)
		priv, err := curve.NewPrivateKey(sk)
		if err != nil {
			return 2
		}
		pub, err := curve.NewPublicKey(peerBytes)
		if err != nil {
			return 2
		}
		shared, err := priv.ECDH(pub)
		if err != nil {
			return 2
		}
		h.Write(shared)
	}
	fmt.Printf("p256_ecdh_sha256=%s\n", hex.EncodeToString(h.Sum(nil)))
	return 0
}

func benchP256Validate() int {
	pubU, err := hex.DecodeString("04c4cfd4dc14471cbc23f68830495857689ad122d899cc9d9726ea006c335a5122bb97ce9aac19a7a577297ad2654c320a1fb909cc0088793a691495d9aae2de08")
	if err != nil {
		return 1
	}
	pubC, err := hex.DecodeString("02c4cfd4dc14471cbc23f68830495857689ad122d899cc9d9726ea006c335a5122")
	if err != nil {
		return 1
	}
	curveEcdh := ecdh.P256()
	curveEll := elliptic.P256()
	okCount := 0
	for i := 0; i < 20000; i++ {
		if _, err := curveEcdh.NewPublicKey(pubU); err == nil {
			okCount++
		}
		if x, _ := elliptic.UnmarshalCompressed(curveEll, pubC); x != nil {
			okCount++
		}
	}
	fmt.Printf("p256_validate_ok=%d\n", okCount)
	if okCount == 40000 {
		return 0
	}
	return 2
}

func benchPbkdf2Sha256() int {
	pass := []byte("pion-crypto-bench-pbkdf2-passphrase-2026!")
	salt := []byte("pion-crypto-bench-pbkdf2-salt-0123456789")
	dk := pbkdf2.Key(pass, salt, 500000, 32, sha256.New)
	fmt.Printf("pbkdf2_sha256=%s\n", hex.EncodeToString(dk))
	return 0
}

func benchScrypt() int {
	pass := []byte("monoid-login-passphrase-2026!")
	salt, err := hex.DecodeString("0123456789abcdeffedcba9876543210")
	if err != nil {
		return 1
	}
	h := sha256.New()
	for i := 0; i < 4; i++ {
		salt[0] = byte(i & 0xFF)
		dk, err := scrypt.Key(pass, salt, 16384, 8, 1, 32)
		if err != nil {
			return 2
		}
		h.Write(dk)
	}
	fmt.Printf("scrypt_sha256=%s\n", hex.EncodeToString(h.Sum(nil)))
	return 0
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
	case "x25519":
		os.Exit(benchX25519())
	case "hkdf256":
		os.Exit(benchHkdf256())
	case "chacha20":
		os.Exit(benchChaCha20())
	case "p256":
		os.Exit(benchP256())
	case "aes256gcm":
		os.Exit(benchAes256Gcm())
	case "aes256gcm_small":
		os.Exit(benchAes256GcmSmall())
	case "p256_ecdh":
		os.Exit(benchP256Ecdh())
	case "p256_validate":
		os.Exit(benchP256Validate())
	case "pbkdf2_sha256":
		os.Exit(benchPbkdf2Sha256())
	case "scrypt":
		os.Exit(benchScrypt())
	default:
		fmt.Println("usage: crypto_bench_go [sha256|sha512|hmac256|ed25519|x25519|hkdf256|chacha20|p256|aes256gcm|aes256gcm_small|p256_ecdh|p256_validate|pbkdf2_sha256|scrypt]")
		os.Exit(1)
	}
}
