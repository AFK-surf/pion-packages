// Command v2vectors regenerates the v0.2.0 reference-vector tail of
// packages/crypto/redteam_test.pion from independent implementations
// (Go standard library crypto/ecdsa, crypto/rsa, golang.org/x/crypto).
//
// Usage (keeps the worktree clean):
//
//	cp -R packages/crypto/audit/v2vectors /tmp/v2vectors
//	(cd /tmp/v2vectors && go run .) > /tmp/v2_vectors.pion
//
// Every input is derived from rb(tag, i, n) = SHA-256("tag:i:blk") blocks, which the Pion
// tests recompute, so only the expected outputs and the per-family digests are emitted.
package main

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/sha512"
	"crypto/x509"
	"encoding/asn1"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"hash"
	"io"
	"math/big"
	"strconv"
	"strings"

	"golang.org/x/crypto/chacha20"
	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/hkdf"
	"golang.org/x/crypto/poly1305"
)

func rb(tag string, i, n int) []byte {
	out := make([]byte, 0, n)
	for blk := 0; len(out) < n; blk++ {
		h := sha256.Sum256([]byte(tag + ":" + strconv.Itoa(i) + ":" + strconv.Itoa(blk)))
		need := n - len(out)
		if need > 32 {
			need = 32
		}
		out = append(out, h[:need]...)
	}
	return out
}

func hx(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}

func show(b []byte, err error) string {
	if err != nil {
		return "ERR"
	}
	return hex.EncodeToString(b)
}

// digest accumulates "line\n" records exactly as the Pion tests do.
type digest struct{ h hash.Hash }

func newDigest() *digest                      { return &digest{sha256.New()} }
func (d *digest) add(format string, a ...any) { fmt.Fprintf(d.h, format+"\n", a...) }
func (d *digest) hex() string                 { return hex.EncodeToString(d.h.Sum(nil)) }
func arr(name string, xs []string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "///|\nfn %s() -> Array[String] {\n  [\n", name)
	for _, x := range xs {
		fmt.Fprintf(&b, "    %s,\n", strconv.Quote(x))
	}
	b.WriteString("  ]\n}\n\n")
	return b.String()
}

// X25519 u-coordinates: the 7 canonical small-order points (Wycheproof), their non-canonical
// (+p / bit 255) aliases, 0..2 and p-1..p+3 / 2^255-1 field edges, and the base point 9.
var x25519Edges = []string{
	"0000000000000000000000000000000000000000000000000000000000000000",
	"0100000000000000000000000000000000000000000000000000000000000000",
	"e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
	"5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
	"ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
	"edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
	"eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
	"cdeb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b880",
	"4c9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f11d7",
	"d9ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
	"daffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
	"dbffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
	"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
	"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
	"0000000000000000000000000000000000000000000000000000000000000080",
	"0100000000000000000000000000000000000000000000000000000000000080",
	"0200000000000000000000000000000000000000000000000000000000000000",
	"0900000000000000000000000000000000000000000000000000000000000000",
	"efffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
	"f0ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
}

func polySum(key, msg []byte) string {
	var k [32]byte
	copy(k[:], key)
	var out [16]byte
	poly1305.Sum(&out, msg, &k)
	return hex.EncodeToString(out[:])
}

// polyEdgeCase builds the 48 accumulator-boundary cases: r = 1 or r = max clamped, s = 0 or
// s = 2^128-1, and two full 0xFF blocks whose sum lands on 2^130-13 .. 2^130-2 (around p = 2^130-5),
// optionally followed by a 5- or 10-byte partial block.
func polyEdgeCase(i int) ([]byte, []byte) {
	key := make([]byte, 32)
	mode := i % 4
	if mode == 0 || mode == 1 {
		key[0] = 1
	} else {
		copy(key, hx("ffffff0ffcffff0ffcffff0ffcffff0f"))
	}
	if mode == 1 || mode == 3 {
		for c := 16; c < 32; c++ {
			key[c] = 0xff
		}
	}
	delta := i / 4
	msg := make([]byte, 32+(delta%3)*5)
	for c := 0; c < 32; c++ {
		msg[c] = 0xff
	}
	msg[16] = byte(0xff - (11 - delta))
	return key, msg
}

func polyRandCase(i int) ([]byte, []byte) {
	key := rb("pk2", i, 32)
	if i%2 == 0 {
		for c := 0; c < 16; c++ {
			key[c] = 0xff
		}
	}
	if i%3 == 0 {
		return key, rb("pm2", i, i%257)
	}
	msg := make([]byte, i%257)
	for c := range msg {
		msg[c] = 0xff
	}
	return key, msg
}

func p256Secret(i int) []byte {
	switch i {
	case 0:
		return hx("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632550") // n-1
	case 1:
		return hx("0000000000000000000000000000000000000000000000000000000000000001")
	case 2:
		return hx("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551") // n
	case 3:
		return make([]byte, 32)
	}
	return rb("p256sk", i, 32)
}

func main() {
	var out strings.Builder
	out.WriteString("///| Generated v0.2.0 reference vectors (Go crypto/ecdsa, crypto/rsa, golang.org/x/crypto).\n")
	out.WriteString("///| Regenerate with packages/crypto/audit/v2vectors. Do not edit by hand.\n\n")

	// X25519
	out.WriteString(arr("rt2_x25519_u_edges", x25519Edges))
	var xe []string
	dx := newDigest()
	for i := 0; i < 64; i++ {
		sk := rb("x25519sk", i, 32)
		var u []byte
		if i < len(x25519Edges) {
			u = hx(x25519Edges[i])
		} else {
			u = rb("x25519u", i, 32)
		}
		r := show(curve25519.X25519(sk, u))
		if i < len(x25519Edges) {
			xe = append(xe, r)
		}
		dx.add("%d %s", i, r)
	}
	out.WriteString(arr("rt2_x25519_edge_outputs", xe))

	// Poly1305
	var pe []string
	for i := 0; i < 48; i++ {
		k, m := polyEdgeCase(i)
		pe = append(pe, polySum(k, m))
	}
	out.WriteString(arr("rt2_poly1305_edge_tags", pe))
	dp := newDigest()
	for i := 0; i < 3000; i++ {
		k, m := polyRandCase(i)
		dp.add("%d %s", i, polySum(k, m))
	}

	// ChaCha20-Poly1305 AEAD: seal, open, open with one flipped bit.
	da := newDigest()
	for i := 0; i < 64; i++ {
		key := rb("aeadk", i, 32)
		nonce := rb("aeadn", i, 12)
		aad := rb("aeada", i, i%37)
		pt := rb("aeadp", i, i*7%300)
		a, _ := chacha20poly1305.New(key)
		ct := a.Seal(nil, nonce, pt, aad)
		bit := i * 13 % (len(ct) * 8)
		t := append([]byte{}, ct...)
		t[bit/8] ^= 1 << (bit % 8)
		o1, e1 := a.Open(nil, nonce, ct, aad)
		o2, e2 := a.Open(nil, nonce, t, aad)
		da.add("%d %s %s %s", i, hex.EncodeToString(ct), show(o1, e1), show(o2, e2))
	}

	// ChaCha20 32-bit block counter boundary.
	dc := newDigest()
	ck := rb("cck", 0, 32)
	cn := rb("ccn", 0, 12)
	lens := []int{0, 1, 63, 64, 65, 128, 129}
	for i, ctr := range []uint32{0xFFFFFFFF, 0xFFFFFFFE, 0} {
		for j, l := range lens {
			blocks := (l + 63) / 64
			if l > 0 && uint64(ctr)+uint64(blocks)-1 > 0xFFFFFFFF {
				dc.add("%d %d ERR", i, l)
				continue
			}
			c, _ := chacha20.NewUnauthenticatedCipher(ck, cn)
			c.SetCounter(ctr)
			o := make([]byte, l)
			c.XORKeyStream(o, rb("ccd", j, l))
			dc.add("%d %d %s", i, l, hex.EncodeToString(o))
		}
	}

	// HKDF-SHA256 / HKDF-SHA512 output-length boundaries.
	dh := newDigest()
	for i, l := range []int{0, 1, 31, 32, 33, 64, 65, 8160, 8161, 16320, 16321} {
		salt := rb("hs", i, i*5%90)
		ikm := rb("hi", i, i*11%70)
		info := rb("hn", i, i*7%40)
		res := []string{}
		for _, hf := range []func() hash.Hash{sha256.New, sha512.New} {
			o := make([]byte, l)
			if _, err := io.ReadFull(hkdf.New(hf, ikm, salt, info), o); err != nil {
				res = append(res, "ERR")
			} else {
				s := sha256.Sum256(o)
				res = append(res, hex.EncodeToString(s[:]))
			}
		}
		dh.add("%d %s %s", l, res[0], res[1])
	}

	// P-256: RFC 6979 deterministic signatures (Go signs deterministically with a nil rand).
	d256 := newDigest()
	var goDer, goDerPk []string
	for i := 0; i < 24; i++ {
		msg := rb("p256m", i, i*9)
		key, err := ecdsa.ParseRawPrivateKey(elliptic.P256(), p256Secret(i))
		if err != nil {
			d256.add("%d ERR ERR", i)
			continue
		}
		pub, _ := key.PublicKey.Bytes()
		h := sha256.Sum256(msg)
		der, err := key.Sign(nil, h[:], crypto.SHA256)
		if err != nil {
			panic(err)
		}
		var rs struct{ R, S *big.Int }
		if _, err := asn1.Unmarshal(der, &rs); err != nil {
			panic(err)
		}
		sig := make([]byte, 64)
		rs.R.FillBytes(sig[:32])
		rs.S.FillBytes(sig[32:])
		d256.add("%d %s %s", i, hex.EncodeToString(pub), hex.EncodeToString(sig))
		// Randomized (hedged) Go signature in DER for the cross-verification test.
		if i >= 4 && i < 12 {
			rder, err := ecdsa.SignASN1(rand.Reader, key, h[:])
			if err != nil {
				panic(err)
			}
			goDerPk = append(goDerPk, hex.EncodeToString(pub))
			goDer = append(goDer, hex.EncodeToString(rder))
		}
	}
	// Keys 4..11, randomized (hedged) signatures: only acceptance is asserted.
	out.WriteString(arr("rt2_p256_go_der_pks", goDerPk))
	out.WriteString(arr("rt2_p256_go_der_sigs", goDer))

	// RSA PKCS#1 v1.5 SHA-256 with OpenSSL-generated 3072/4096-bit and e = 3 keys.
	pems := []string{pemrsa3072, pemrsa4096, pemrsa2048e3}
	out.WriteString(arr("rt2_rsa_pems", pems))
	dr := newDigest()
	for i, p := range pems {
		blk, _ := pem.Decode([]byte(p))
		k, err := x509.ParsePKCS8PrivateKey(blk.Bytes)
		if err != nil {
			panic(err)
		}
		rk := k.(*rsa.PrivateKey)
		for j := 0; j < 3; j++ {
			h := sha256.Sum256(rb("rsam", i*10+j, j*50))
			sig, err := rsa.SignPKCS1v15(nil, rk, crypto.SHA256, h[:])
			dr.add("%d %d %s", i, j, show(sig, err))
		}
	}

	// Bleichenbacher 2006 e = 3 forgery without the private key: s = ceil(cbrt(00 01 FF{ps} 00 ||
	// DigestInfo || H || 00...)) makes s^3 start with a valid-looking prefix followed by garbage.
	// A parser that stops after the digest would accept it; the strict full-block check must not.
	blk, _ := pem.Decode([]byte(pemrsa2048e3))
	k3, _ := x509.ParsePKCS8PrivateKey(blk.Bytes)
	n3 := k3.(*rsa.PrivateKey).N
	size := (n3.BitLen() + 7) / 8
	fh := sha256.Sum256(rb("rsaforge", 0, 10))
	prefix := hx("3031300d060960864801650304020105000420")
	var forged []string
	for _, ps := range []int{1, 8} {
		em := make([]byte, size)
		em[1] = 1
		for i := 0; i < ps; i++ {
			em[2+i] = 0xff
		}
		copy(em[3+ps:], prefix)
		copy(em[3+ps+len(prefix):], fh[:])
		s := cbrtCeil(new(big.Int).SetBytes(em))
		cube := new(big.Int).Exp(s, big.NewInt(3), nil).FillBytes(make([]byte, size))
		keep := 3 + ps + len(prefix) + len(fh)
		if hex.EncodeToString(cube[:keep]) != hex.EncodeToString(em[:keep]) || s.Cmp(n3) >= 0 {
			panic("forgery prefix mismatch")
		}
		forged = append(forged, hex.EncodeToString(s.FillBytes(make([]byte, size))))
	}
	out.WriteString(arr("rt2_rsa_e3_cube_root_forgeries", forged))

	out.WriteString(arr("rt2_family_digests", []string{
		dx.hex(), dp.hex(), da.hex(), dc.hex(), dh.hex(), d256.hex(), dr.hex(),
	}))
	fmt.Print(strings.TrimRight(out.String(), "\n") + "\n")
}

// cbrtCeil returns the smallest s with s^3 >= t.
func cbrtCeil(t *big.Int) *big.Int {
	lo, hi := big.NewInt(0), new(big.Int).Lsh(big.NewInt(1), uint(t.BitLen()/3+2))
	three := big.NewInt(3)
	for lo.Cmp(hi) < 0 {
		mid := new(big.Int).Rsh(new(big.Int).Add(lo, hi), 1)
		if new(big.Int).Exp(mid, three, nil).Cmp(t) >= 0 {
			hi = mid
		} else {
			lo = mid.Add(mid, big.NewInt(1))
		}
	}
	return lo
}
