// Red-team Go oracle for packages/crypto v0.3.0 (RT-crypto-v030).
//
// Go stdlib only: crypto/aes + crypto/cipher (NewGCMWithNonceSize), crypto/ecdh,
// crypto/elliptic (UnmarshalCompressed / Marshal), math/big.
//
//	oracle gen <corpus.tsv> <expected.out>
//
// writes a deterministic corpus (seeded ChaCha8, no wall clock / OS entropy) and the
// expected Pion oracle output for every line. Corpus line: label \t op \t hex-args...
// Expected / actual line: label \t result. Results: hex, "1"/"0", or "ERR".
package main

import (
	"bufio"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"math/big"
	"math/rand/v2"
	"os"
	"strings"
)

var (
	rng    = rand.New(rand.NewChaCha8([32]byte{'R', 'T', '-', 'c', 'r', 'y', 'p', 't', 'o', '-', 'v', '0', '3', '0'}))
	corpus *bufio.Writer
	expect *bufio.Writer
	nlines int
)

func rbytes(n int) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte(rng.Uint32())
	}
	return b
}

func h(b []byte) string { return hex.EncodeToString(b) }

func emit(label, op, result string, args ...[]byte) {
	parts := []string{label, op}
	for _, a := range args {
		parts = append(parts, h(a))
	}
	fmt.Fprintln(corpus, strings.Join(parts, "\t"))
	fmt.Fprintf(expect, "%s\t%s\n", label, result)
	nlines++
}

func clone(b []byte) []byte { return append([]byte(nil), b...) }

// ---------------------------------------------------------------- AES-GCM

func gcmFor(key []byte, want, nonceLen int) cipher.AEAD {
	if len(key) != want || nonceLen <= 0 {
		return nil
	}
	blk, err := aes.NewCipher(key)
	if err != nil {
		return nil
	}
	g, err := cipher.NewGCMWithNonceSize(blk, nonceLen)
	if err != nil {
		return nil
	}
	return g
}

func goSeal(klen int, key, nonce, aad, pt []byte) string {
	g := gcmFor(key, klen, len(nonce))
	if g == nil {
		return "ERR"
	}
	return h(g.Seal(nil, nonce, pt, aad))
}

func goOpen(klen int, key, nonce, aad, ct []byte) string {
	g := gcmFor(key, klen, len(nonce))
	if g == nil {
		return "ERR"
	}
	pt, err := g.Open(nil, nonce, ct, aad)
	if err != nil {
		return "ERR"
	}
	return h(pt)
}

func sealOp(label string, klen int, key, nonce, aad, pt []byte) {
	op := fmt.Sprintf("S%d", klen*8)
	emit(label, op, goSeal(klen, key, nonce, aad, pt), key, nonce, aad, pt)
}

func openOp(label string, klen int, key, nonce, aad, ct []byte) {
	op := fmt.Sprintf("O%d", klen*8)
	emit(label, op, goOpen(klen, key, nonce, aad, ct), key, nonce, aad, ct)
}

// GF(2^128) per SP 800-38D Algorithm 1, blocks as big-endian (hi, lo).
type gf struct{ hi, lo uint64 }

func gfMul(x, y gf) gf {
	var z gf
	v := y
	for i := 0; i < 128; i++ {
		var bit uint64
		if i < 64 {
			bit = (x.hi >> (63 - i)) & 1
		} else {
			bit = (x.lo >> (127 - i)) & 1
		}
		if bit == 1 {
			z.hi ^= v.hi
			z.lo ^= v.lo
		}
		lsb := v.lo & 1
		v.lo = (v.lo >> 1) | (v.hi << 63)
		v.hi >>= 1
		if lsb == 1 {
			v.hi ^= 0xE100000000000000
		}
	}
	return z
}

func gfInv(x gf) gf { // x^(2^128-2)
	r := gf{0x8000000000000000, 0} // multiplicative identity (x^0 = MSB)
	b := x
	// exponent 2^128-2 = 0b111...110 : bit0 = 0, bits1..127 = 1
	for i := 0; i < 128; i++ {
		if i >= 1 {
			r = gfMul(r, b)
		}
		b = gfMul(b, b)
	}
	return r
}

func gfFrom(b []byte) gf { return gf{binary.BigEndian.Uint64(b), binary.BigEndian.Uint64(b[8:])} }
func gfBytes(x gf) []byte {
	out := make([]byte, 16)
	binary.BigEndian.PutUint64(out, x.hi)
	binary.BigEndian.PutUint64(out[8:], x.lo)
	return out
}

// nonceForJ0 returns a 16-byte nonce N with J0 = GHASH_H(N || 0^64 || [128]_64) == j0:
// J0 = (N*H ^ L)*H  =>  N = (J0*H^-1 ^ L)*H^-1.
func nonceForJ0(key, j0 []byte) []byte {
	blk, _ := aes.NewCipher(key)
	hb := make([]byte, 16)
	blk.Encrypt(hb, hb)
	H := gfFrom(hb)
	hinv := gfInv(H)
	if one := gfMul(H, hinv); one != (gf{0x8000000000000000, 0}) {
		panic("gfInv")
	}
	t := gfMul(gfFrom(j0), hinv)
	t.lo ^= 128
	n := gfBytes(gfMul(t, hinv))
	// Self-check: recompute J0 forwards.
	y := gfMul(gfFrom(n), H)
	y.lo ^= 128
	if got := gfBytes(gfMul(y, H)); h(got) != h(j0) {
		panic("nonceForJ0 self-check")
	}
	return n
}

func genGCM() {
	ptLens := []int{0, 1, 15, 16, 17, 31, 32, 33, 47, 48, 49, 63, 64, 65, 127, 128, 129, 1000}
	aadLens := []int{0, 1, 15, 16, 17, 32, 65}
	nonceLens := []int{0, 1, 8, 11, 12, 13, 16, 32, 64, 128}
	for _, klen := range []int{16, 32} {
		for _, pl := range ptLens {
			for _, al := range aadLens {
				for _, nl := range nonceLens {
					key, nonce, aad, pt := rbytes(klen), rbytes(nl), rbytes(al), rbytes(pl)
					lbl := fmt.Sprintf("gcm%d/grid/pt%d/aad%d/n%d", klen*8, pl, al, nl)
					sealOp(lbl+"/seal", klen, key, nonce, aad, pt)
					g := gcmFor(key, klen, nl)
					if g == nil {
						openOp(lbl+"/open", klen, key, nonce, aad, rbytes(pl+16))
						continue
					}
					ct := g.Seal(nil, nonce, pt, aad)
					openOp(lbl+"/open", klen, key, nonce, aad, ct)
				}
			}
		}

		// Tamper / forgery matrix (per bit class) on a few shapes, including non-96-bit nonces.
		for _, shape := range [][3]int{{0, 0, 12}, {1, 0, 12}, {17, 15, 12}, {65, 17, 13}, {129, 32, 16}, {33, 1, 1}, {64, 65, 64}} {
			pl, al, nl := shape[0], shape[1], shape[2]
			key, nonce, aad, pt := rbytes(klen), rbytes(nl), rbytes(al), rbytes(pl)
			g := gcmFor(key, klen, nl)
			ct := g.Seal(nil, nonce, pt, aad)
			lbl := fmt.Sprintf("gcm%d/tamper/pt%d/aad%d/n%d", klen*8, pl, al, nl)
			openOp(lbl+"/orig", klen, key, nonce, aad, ct)
			for bit := 0; bit < len(ct)*8; bit++ {
				if bit/8 < pl || bit%7 == 0 || bit/8 >= len(ct)-16 { // every tag bit, sampled ct bits
					c := clone(ct)
					c[bit/8] ^= 1 << (bit % 8)
					kind := "ct"
					if bit/8 >= pl {
						kind = "tag"
					}
					openOp(fmt.Sprintf("%s/flip-%s-bit%d", lbl, kind, bit), klen, key, nonce, aad, c)
				}
			}
			for bit := 0; bit < len(aad)*8; bit += 3 {
				a := clone(aad)
				a[bit/8] ^= 1 << (bit % 8)
				openOp(fmt.Sprintf("%s/flip-aad-bit%d", lbl, bit), klen, key, nonce, a, ct)
			}
			for bit := 0; bit < len(nonce)*8; bit += 5 {
				n := clone(nonce)
				n[bit/8] ^= 1 << (bit % 8)
				openOp(fmt.Sprintf("%s/flip-nonce-bit%d", lbl, bit), klen, key, n, aad, ct)
			}
			for bit := 0; bit < klen*8; bit += 11 {
				k := clone(key)
				k[bit/8] ^= 1 << (bit % 8)
				openOp(fmt.Sprintf("%s/flip-key-bit%d", lbl, bit), klen, k, nonce, aad, ct)
			}
			for cut := 1; cut <= 16 && cut <= len(ct); cut++ {
				openOp(fmt.Sprintf("%s/trunc-%d", lbl, cut), klen, key, nonce, aad, ct[:len(ct)-cut])
			}
			openOp(lbl+"/append-byte", klen, key, nonce, clone(aad), append(clone(ct), 0))
			openOp(lbl+"/aad-append-zero", klen, key, nonce, append(clone(aad), 0), ct)
			if al > 0 {
				openOp(lbl+"/aad-drop-last", klen, key, nonce, aad[:al-1], ct)
			}
			// AAD/ciphertext boundary shift: move 1 byte from ct into aad.
			if pl > 0 {
				a2 := append(clone(aad), ct[0])
				openOp(lbl+"/shift-ct-into-aad", klen, key, nonce, a2, ct[1:])
			}
			// nonce 12 vs nonce zero-padded to 16 must not collide.
			if nl == 12 {
				openOp(lbl+"/nonce-pad16", klen, key, append(clone(nonce), 0, 0, 0, 0), aad, ct)
			}
		}

		// Key / nonce / input length edges.
		for _, kl := range []int{0, 1, 15, 16, 17, 24, 31, 32, 33, 64} {
			key := rbytes(kl)
			lbl := fmt.Sprintf("gcm%d/keylen%d", klen*8, kl)
			sealOp(lbl+"/seal", klen, key, rbytes(12), rbytes(3), rbytes(20))
			openOp(lbl+"/open", klen, key, rbytes(12), rbytes(3), rbytes(36))
		}
		for _, tl := range []int{0, 1, 15, 16, 17} {
			key := rbytes(klen)
			openOp(fmt.Sprintf("gcm%d/openlen%d", klen*8, tl), klen, key, rbytes(12), nil, rbytes(tl))
		}
		// Empty ciphertext forgery attempts: all-zero tag / tag = E_K(J0) (GHASH of nothing == 0).
		{
			key, nonce := rbytes(klen), rbytes(12)
			openOp(fmt.Sprintf("gcm%d/forge-zero-tag", klen*8), klen, key, nonce, nil, make([]byte, 16))
			blk, _ := aes.NewCipher(key)
			j0 := append(clone(nonce), 0, 0, 0, 1)
			ek := make([]byte, 16)
			blk.Encrypt(ek, j0)
			openOp(fmt.Sprintf("gcm%d/forge-ekj0-tag-empty", klen*8), klen, key, nonce, nil, ek)
		}
		// All-zero everything.
		for _, nl := range []int{1, 12, 16} {
			z := make([]byte, klen)
			lbl := fmt.Sprintf("gcm%d/allzero/n%d", klen*8, nl)
			sealOp(lbl+"/seal", klen, z, make([]byte, nl), make([]byte, 16), make([]byte, 64))
			g := gcmFor(z, klen, nl)
			openOp(lbl+"/open", klen, z, make([]byte, nl), make([]byte, 16), g.Seal(nil, make([]byte, nl), make([]byte, 64), make([]byte, 16)))
		}

		// Large inputs: multi-KiB plaintext / AAD and long GHASH-derived nonces.
		for _, shape := range [][3]int{{65536 + 5, 4096 + 3, 1000}, {20000, 0, 12}, {4099, 70000, 17}} {
			key, nonce, aad, pt := rbytes(klen), rbytes(shape[2]), rbytes(shape[1]), rbytes(shape[0])
			lbl := fmt.Sprintf("gcm%d/big/pt%d/aad%d/n%d", klen*8, shape[0], shape[1], shape[2])
			sealOp(lbl+"/seal", klen, key, nonce, aad, pt)
			ct := gcmFor(key, klen, shape[2]).Seal(nil, nonce, pt, aad)
			openOp(lbl+"/open", klen, key, nonce, aad, ct)
			ct[len(ct)/2] ^= 0x80
			openOp(lbl+"/open-flip-mid", klen, key, nonce, aad, ct)
		}

		// NIST SP 800-38D §6.5 inc_32 wrap: craft 16-byte nonces whose J0 has low word 0xFFFF_FFxx.
		for _, low := range []uint32{0xFFFFFFFF, 0xFFFFFFFE, 0xFFFFFFFD, 0xFFFFFFFC, 0xFFFFFFF0, 0x7FFFFFFF, 0x00000000} {
			for rep := 0; rep < 3; rep++ {
				key := rbytes(klen)
				j0 := rbytes(16)
				if rep == 1 { // also saturate the upper 96 bits so a 128-bit carry would be visible everywhere
					for i := 0; i < 12; i++ {
						j0[i] = 0xFF
					}
				}
				binary.BigEndian.PutUint32(j0[12:], low)
				nonce := nonceForJ0(key, j0)
				lbl := fmt.Sprintf("gcm%d/inc32wrap/j0lo%08x/r%d", klen*8, low, rep)
				for _, pl := range []int{16, 17, 48, 64, 65, 200} {
					pt, aad := rbytes(pl), rbytes(7)
					sealOp(fmt.Sprintf("%s/pt%d/seal", lbl, pl), klen, key, nonce, aad, pt)
					g := gcmFor(key, klen, 16)
					ct := g.Seal(nil, nonce, pt, aad)
					// Sanity: Go's first keystream block must be E_K(inc32(J0)).
					blk, _ := aes.NewCipher(key)
					c1 := clone(j0)
					binary.BigEndian.PutUint32(c1[12:], low+1)
					ks := make([]byte, 16)
					blk.Encrypt(ks, c1)
					if ct[0]^pt[0] != ks[0] {
						panic("inc32 oracle self-check")
					}
					openOp(fmt.Sprintf("%s/pt%d/open", lbl, pl), klen, key, nonce, aad, ct)
				}
			}
		}
	}
}

// ---------------------------------------------------------------- P-256

var (
	curve = elliptic.P256()
	P     = curve.Params().P
	N     = curve.Params().N
	B     = curve.Params().B
)

func be32(x *big.Int) []byte {
	out := make([]byte, 32)
	x.FillBytes(out)
	return out
}

func rhs(x *big.Int) *big.Int {
	x3 := new(big.Int).Exp(x, big.NewInt(3), P)
	t := new(big.Int).Mul(x, big.NewInt(3))
	x3.Sub(x3, t)
	x3.Add(x3, B)
	return x3.Mod(x3, P)
}

func goParse(pub []byte) ([]byte, bool) {
	switch len(pub) {
	case 65:
		if _, err := ecdh.P256().NewPublicKey(pub); err != nil {
			return nil, false
		}
		return clone(pub), true
	case 33:
		x, y := elliptic.UnmarshalCompressed(curve, pub)
		if x == nil {
			return nil, false
		}
		u := elliptic.Marshal(curve, x, y) //nolint:staticcheck
		if _, err := ecdh.P256().NewPublicKey(u); err != nil {
			return nil, false
		}
		return u, true
	}
	return nil, false
}

func pubOps(label string, pub []byte) {
	u, ok := goParse(pub)
	if ok {
		emit(label+"/PV", "PV", "1", pub)
		emit(label+"/PD", "PD", h(u), pub)
	} else {
		emit(label+"/PV", "PV", "0", pub)
		emit(label+"/PD", "PD", "ERR", pub)
	}
}

func goECDH(d, pub []byte) string {
	if len(d) != 32 {
		return "ERR"
	}
	priv, err := ecdh.P256().NewPrivateKey(d)
	if err != nil {
		return "ERR"
	}
	u, ok := goParse(pub)
	if !ok {
		return "ERR"
	}
	pk, err := ecdh.P256().NewPublicKey(u)
	if err != nil {
		return "ERR"
	}
	s, err := priv.ECDH(pk)
	if err != nil {
		return "ERR"
	}
	return h(s)
}

func dhOp(label string, d, pub []byte) { emit(label, "DH", goECDH(d, pub), d, pub) }

func randScalar() []byte {
	for {
		d := rbytes(32)
		v := new(big.Int).SetBytes(d)
		if v.Sign() > 0 && v.Cmp(N) < 0 {
			return d
		}
	}
}

func pubOf(d []byte) []byte {
	priv, err := ecdh.P256().NewPrivateKey(d)
	if err != nil {
		panic(err)
	}
	return priv.PublicKey().Bytes()
}

func compress(u []byte) []byte {
	c := make([]byte, 33)
	c[0] = 0x02 | (u[64] & 1)
	copy(c[1:], u[1:33])
	return c
}

func uncomp(x, y *big.Int) []byte {
	u := []byte{4}
	u = append(u, be32(x)...)
	return append(u, be32(y)...)
}

func genP256() {
	// Random valid points, both encodings, plus y -> p-y (valid) and y+1 (invalid).
	for i := 0; i < 300; i++ {
		u := pubOf(randScalar())
		lbl := fmt.Sprintf("p256/rand%03d", i)
		pubOps(lbl+"/uncomp", u)
		pubOps(lbl+"/comp", compress(u))
		c := compress(u)
		c[0] ^= 1
		pubOps(lbl+"/comp-flipparity", c) // valid: decodes to (x, p-y)
		x := new(big.Int).SetBytes(u[1:33])
		y := new(big.Int).SetBytes(u[33:])
		pubOps(lbl+"/negy", uncomp(x, new(big.Int).Sub(P, y)))
		pubOps(lbl+"/y+1", uncomp(x, new(big.Int).Add(y, big.NewInt(1))))
		if i < 40 {
			// y + p (>= p, same residue) and x + p when it still fits 256 bits: non-canonical.
			yp := new(big.Int).Add(y, P)
			if yp.BitLen() <= 256 {
				pubOps(lbl+"/y+p", uncomp(x, yp))
			}
			xp := new(big.Int).Add(x, P)
			if xp.BitLen() <= 256 {
				pubOps(lbl+"/x+p-uncomp", uncomp(xp, y))
				cc := []byte{c[0] ^ 1}
				pubOps(lbl+"/x+p-comp", append(cc, be32(xp)...))
			}
			for _, pre := range []byte{0x00, 0x01, 0x05, 0x06, 0x07, 0x08, 0xFF} {
				v := clone(u)
				v[0] = pre
				pubOps(fmt.Sprintf("%s/prefix%02x-65", lbl, pre), v)
				w := compress(u)
				w[0] = pre
				pubOps(fmt.Sprintf("%s/prefix%02x-33", lbl, pre), w)
			}
			// hybrid 0x06/0x07 with the correct parity bit
			hy := clone(u)
			hy[0] = 0x06 | (u[64] & 1)
			pubOps(lbl+"/hybrid-correct-parity", hy)
			pubOps(lbl+"/trailing-byte", append(clone(u), 0))
			pubOps(lbl+"/comp-trailing-byte", append(compress(u), 0))
			pubOps(lbl+"/raw-xy-64", clone(u[1:]))
			pubOps(lbl+"/raw-x-32", clone(u[1:33]))
		}
		if i < 200 {
			// ECDH: random d with peer in both encodings (and flipped-parity compressed peer).
			d := randScalar()
			dhOp(lbl+"/dh-uncomp", d, u)
			dhOp(lbl+"/dh-comp", d, compress(u))
			dhOp(lbl+"/dh-comp-flip", d, c)
		}
	}

	// Twist / invalid-curve: x with non-residue rhs, plus arbitrary off-curve y.
	tw := 0
	for tw < 60 {
		x := new(big.Int).SetBytes(rbytes(32))
		if x.Cmp(P) >= 0 {
			continue
		}
		r := rhs(x)
		if new(big.Int).ModSqrt(r, P) != nil {
			continue
		}
		lbl := fmt.Sprintf("p256/twist%02d", tw)
		pubOps(lbl+"/comp02", append([]byte{2}, be32(x)...))
		pubOps(lbl+"/comp03", append([]byte{3}, be32(x)...))
		pubOps(lbl+"/uncomp-randy", uncomp(x, new(big.Int).SetBytes(rbytes(31))))
		dhOp(lbl+"/dh-comp02", randScalar(), append([]byte{2}, be32(x)...))
		tw++
	}
	for i := 0; i < 40; i++ { // random off-curve (x, y)
		pubOps(fmt.Sprintf("p256/offcurve%02d", i), append([]byte{4}, rbytes(64)...))
	}

	big0 := big.NewInt(0)
	pm1 := new(big.Int).Sub(P, big.NewInt(1))
	pp1 := new(big.Int).Add(P, big.NewInt(1))
	max := new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 256), big.NewInt(1))
	g := uncomp(curve.Params().Gx, curve.Params().Gy)
	gx, gy := curve.Params().Gx, curve.Params().Gy
	special := map[string][]byte{
		"inf-00":        {0x00},
		"empty":         {},
		"zero65":        make([]byte, 65),
		"04-zero-zero":  append([]byte{4}, make([]byte, 64)...),
		"02-zero":       append([]byte{2}, make([]byte, 32)...),
		"03-zero":       append([]byte{3}, make([]byte, 32)...),
		"x=p-comp02":    append([]byte{2}, be32(P)...),
		"x=p-comp03":    append([]byte{3}, be32(P)...),
		"x=p+1-comp02":  append([]byte{2}, be32(pp1)...),
		"x=max-comp02":  append([]byte{2}, be32(max)...),
		"x=p-1-comp02":  append([]byte{2}, be32(pm1)...),
		"x=p-1-comp03":  append([]byte{3}, be32(pm1)...),
		"x=p,y=gy":      uncomp(P, gy),
		"x=p+1,y=gy":    uncomp(pp1, gy),
		"x=gx,y=p":      uncomp(gx, P),
		"x=max,y=max":   uncomp(max, max),
		"x=0,y=0":       uncomp(big0, big0),
		"x=0,y=sqrt(b)": nil,
		"G":             g,
		"G-comp":        compress(g),
		"G-negy":        uncomp(gx, new(big.Int).Sub(P, gy)),
		"G-y+1":         uncomp(gx, new(big.Int).Add(gy, big.NewInt(1))),
		"G-x-1":         uncomp(new(big.Int).Sub(gx, big.NewInt(1)), gy),
		"len64-zero":    make([]byte, 64),
		"len66-G0":      append(clone(g), 0),
		"len34-Gc0":     append(compress(g), 0),
		"len32-Gx":      be32(gx),
		"04only":        {4},
		"02only":        {2},
		"ff65":          append([]byte{4}, bytesOf(64, 0xFF)...),
		"ff33":          append([]byte{2}, bytesOf(32, 0xFF)...),
	}
	if sq := new(big.Int).ModSqrt(B, P); sq != nil {
		special["x=0,y=sqrt(b)"] = uncomp(big0, sq)
		// (0, y) and (p, y): x + p fits in 256 bits only because x = 0 here.
		special["x=p(=0+p),y=sqrt(b)"] = uncomp(P, sq)
		special["x=p(=0+p),y=p-sqrt(b)"] = uncomp(P, new(big.Int).Sub(P, sq))
	} else {
		delete(special, "x=0,y=sqrt(b)")
	}
	// Points with y < 2^256 - p, so that y + p still fits 32 bytes: the only way to test that a
	// validator rejects the non-canonical Y + p (same residue, on the curve mod p).
	for i, pt := range smallYPoints(4) {
		x, y := pt[0], pt[1]
		special[fmt.Sprintf("smally%d", i)] = uncomp(x, y)
		special[fmt.Sprintf("smally%d,y+p", i)] = uncomp(x, new(big.Int).Add(y, P))
	}
	for _, k := range sortedKeys(special) {
		pubOps("p256/special/"+k, special[k])
	}
	for l := 0; l <= 70; l++ {
		b := rbytes(l)
		if l > 0 {
			b[0] = []byte{2, 3, 4}[l%3]
		}
		pubOps(fmt.Sprintf("p256/len%02d", l), b)
	}
	// x = 0 with valid parity markers: Go decides whether b is a QR.
	dhOp("p256/special/dh-x0-02", randScalar(), append([]byte{2}, make([]byte, 32)...))

	// ECDH scalar edges against a random peer and against G.
	peer := pubOf(randScalar())
	one := be32(big.NewInt(1))
	two := be32(big.NewInt(2))
	nm1 := be32(new(big.Int).Sub(N, big.NewInt(1)))
	nm2 := be32(new(big.Int).Sub(N, big.NewInt(2)))
	nn := be32(N)
	np1 := be32(new(big.Int).Add(N, big.NewInt(1)))
	scalars := map[string][]byte{
		"d=0": make([]byte, 32), "d=1": one, "d=2": two, "d=n-2": nm2, "d=n-1": nm1, "d=n": nn, "d=n+1": np1,
		"d=max": bytesOf(32, 0xFF), "d=p": be32(P), "d=2^255": append([]byte{0x80}, make([]byte, 31)...),
		"d=len0": {}, "d=len31": rbytes(31), "d=len33": append([]byte{0}, one...), "d=len64": rbytes(64),
		"d=1-len33-lead0": append([]byte{0}, randScalar()...),
		"d=0x0f":          be32(big.NewInt(15)), "d=16": be32(big.NewInt(16)), "d=n-16": be32(new(big.Int).Sub(N, big.NewInt(16))),
	}
	for _, k := range sortedKeys(scalars) {
		d := scalars[k]
		dhOp("p256/dh-edge/"+k+"/peer-uncomp", d, peer)
		dhOp("p256/dh-edge/"+k+"/peer-comp", d, compress(peer))
		dhOp("p256/dh-edge/"+k+"/G", d, g)
		dhOp("p256/dh-edge/"+k+"/G-comp", d, compress(g))
	}
	for _, k := range sortedKeys(special) {
		dhOp("p256/dh-badpeer/"+k, randScalar(), special[k])
	}
	// Scalars with long runs of zero / 0xF nibbles (window edge cases).
	for i := 0; i < 32; i++ {
		d := make([]byte, 32)
		d[i] = 0x01
		dhOp(fmt.Sprintf("p256/dh-sparse/byte%02d=01", i), d, peer)
		d2 := make([]byte, 32)
		d2[i] = 0x10
		dhOp(fmt.Sprintf("p256/dh-sparse/byte%02d=10", i), d2, compress(peer))
	}
}

// ---- small-Y point search: solve x^3 - 3x + (b - y^2) = 0 over F_p for small y.

type poly []*big.Int // coefficients, low degree first

func pnorm(a poly) poly {
	for len(a) > 0 && a[len(a)-1].Sign() == 0 {
		a = a[:len(a)-1]
	}
	return a
}

func pmod(a, f poly) poly { // f monic or not; F_p coefficients
	a = pnorm(append(poly(nil), a...))
	f = pnorm(f)
	inv := new(big.Int).ModInverse(f[len(f)-1], P)
	for len(a) >= len(f) {
		c := new(big.Int).Mul(a[len(a)-1], inv)
		c.Mod(c, P)
		sh := len(a) - len(f)
		for i := range f {
			t := new(big.Int).Mul(c, f[i])
			a[sh+i] = new(big.Int).Mod(new(big.Int).Sub(a[sh+i], t), P)
		}
		a = pnorm(a)
	}
	return a
}

func pmul(a, b, f poly) poly {
	if len(a) == 0 || len(b) == 0 {
		return nil
	}
	out := make(poly, len(a)+len(b)-1)
	for i := range out {
		out[i] = new(big.Int)
	}
	for i := range a {
		for j := range b {
			out[i+j].Add(out[i+j], new(big.Int).Mul(a[i], b[j]))
		}
	}
	for i := range out {
		out[i].Mod(out[i], P)
	}
	return pmod(out, f)
}

func pgcd(a, b poly) poly {
	a, b = pnorm(a), pnorm(b)
	for len(b) > 0 {
		a, b = b, pmod(a, b)
	}
	return a
}

func smallYPoints(want int) [][2]*big.Int {
	var out [][2]*big.Int
	for y := int64(2); len(out) < want; y++ {
		Y := big.NewInt(y)
		c := new(big.Int).Sub(B, new(big.Int).Mul(Y, Y))
		c.Mod(c, P)
		f := poly{c, new(big.Int).Mod(big.NewInt(-3), P), big.NewInt(0), big.NewInt(1)}
		// X^p mod f by square-and-multiply.
		r := poly{big.NewInt(1)}
		base := poly{big.NewInt(0), big.NewInt(1)}
		for i := P.BitLen() - 1; i >= 0; i-- {
			r = pmul(r, r, f)
			if P.Bit(i) == 1 {
				r = pmul(r, base, f)
			}
		}
		for len(r) < 2 {
			r = append(r, big.NewInt(0))
		}
		r[1] = new(big.Int).Mod(new(big.Int).Sub(r[1], big.NewInt(1)), P)
		g := pgcd(f, r)
		if len(g) != 2 { // exactly one root in F_p
			continue
		}
		x := new(big.Int).ModInverse(g[1], P)
		x.Mul(x, g[0]).Neg(x).Mod(x, P)
		if rhs(x).Cmp(new(big.Int).Mod(new(big.Int).Mul(Y, Y), P)) != 0 {
			panic("small-Y root self-check")
		}
		out = append(out, [2]*big.Int{x, Y})
	}
	return out
}

func bytesOf(n int, v byte) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = v
	}
	return b
}

func sortedKeys(m map[string][]byte) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	for i := 1; i < len(ks); i++ {
		for j := i; j > 0 && ks[j] < ks[j-1]; j-- {
			ks[j], ks[j-1] = ks[j-1], ks[j]
		}
	}
	return ks
}

// kat prints inc_32 wrap known-answer vectors for audit_v030/tests (separate RNG stream):
// klen low key nonce aad pt sealed wrong128, where wrong128 is the ciphertext body a broken
// implementation that carries the counter increment into the upper 96 bits would produce.
func kat() {
	r := rand.New(rand.NewChaCha8([32]byte{'k', 'a', 't'}))
	rb := func(n int) []byte {
		b := make([]byte, n)
		for i := range b {
			b[i] = byte(r.Uint32())
		}
		return b
	}
	for _, klen := range []int{16, 32} {
		for _, low := range []uint32{0xFFFFFFFF, 0xFFFFFFFE} {
			key := rb(klen)
			j0 := rb(16)
			for i := 0; i < 12; i++ {
				j0[i] = 0xFF
			}
			binary.BigEndian.PutUint32(j0[12:], low)
			nonce := nonceForJ0(key, j0)
			aad, pt := rb(5), rb(40)
			sealed := gcmFor(key, klen, 16).Seal(nil, nonce, pt, aad)
			blk, _ := aes.NewCipher(key)
			ctr := clone(j0)
			wrong := make([]byte, len(pt))
			ks := make([]byte, 16)
			for off := 0; off < len(pt); off += 16 {
				for i := 15; i >= 0; i-- { // 128-bit increment (the bug class under test)
					ctr[i]++
					if ctr[i] != 0 {
						break
					}
				}
				blk.Encrypt(ks, ctr)
				for i := 0; i < 16 && off+i < len(pt); i++ {
					wrong[off+i] = pt[off+i] ^ ks[i]
				}
			}
			fmt.Printf("%d\t%08x\t%s\t%s\t%s\t%s\t%s\t%s\n", klen, low, h(key), h(nonce), h(aad), h(pt), h(sealed), h(wrong))
		}
	}
}

// benchMode runs the bench/go workload `mode` n times in-process (same inputs as bench/go/main.go).
func benchMode(mode string, n int) {
	key, _ := hex.DecodeString("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
	pubU, _ := hex.DecodeString("04c4cfd4dc14471cbc23f68830495857689ad122d899cc9d9726ea006c335a5122bb97ce9aac19a7a577297ad2654c320a1fb909cc0088793a691495d9aae2de08")
	pubC, _ := hex.DecodeString("02c4cfd4dc14471cbc23f68830495857689ad122d899cc9d9726ea006c335a5122")
	hs := sha256.New()
	switch mode {
	case "p256_validate":
		ok := 0
		for i := 0; i < n; i++ {
			if _, err := ecdh.P256().NewPublicKey(pubU); err == nil {
				ok++
			}
			if x, _ := elliptic.UnmarshalCompressed(curve, pubC); x != nil {
				ok++
			}
		}
		fmt.Printf("ok=%d\n", ok)
		return
	case "p256_ecdh":
		sk, _ := hex.DecodeString("c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721")
		for i := 0; i < n; i++ {
			sk[31]++
			priv, err := ecdh.P256().NewPrivateKey(sk)
			if err != nil {
				os.Exit(2)
			}
			pub, err := ecdh.P256().NewPublicKey(pubU)
			if err != nil {
				os.Exit(2)
			}
			s, err := priv.ECDH(pub)
			if err != nil {
				os.Exit(2)
			}
			hs.Write(s)
		}
	case "aes256gcm", "aes256gcm_small":
		big := mode == "aes256gcm"
		ptLen, aad := 256, []byte("pion-crypto-bench-small-aad")
		if big {
			ptLen, aad = 65536, []byte("pion-crypto-bench-aead-aad")
		}
		pt := make([]byte, ptLen)
		for i := range pt {
			pt[i] = byte((i*131 + 17) & 0xFF)
		}
		nonce, _ := hex.DecodeString("070000004041424344454647")
		blk, _ := aes.NewCipher(key)
		g, _ := cipher.NewGCM(blk)
		for i := 0; i < n; i++ {
			nonce[0] = byte(i)
			if !big {
				nonce[1] = byte(i >> 8)
			}
			sealed := g.Seal(nil, nonce, pt, aad)
			if o, err := g.Open(nil, nonce, sealed, aad); err != nil || len(o) != len(pt) {
				os.Exit(3)
			}
			hs.Write(sealed)
		}
	default:
		os.Exit(2)
	}
	fmt.Printf("sha256=%s\n", hex.EncodeToString(hs.Sum(nil)))
}

func main() {
	if len(os.Args) == 4 && os.Args[1] == "bench" {
		n := 0
		fmt.Sscan(os.Args[3], &n)
		benchMode(os.Args[2], n)
		return
	}
	if len(os.Args) == 2 && os.Args[1] == "kat" {
		kat()
		return
	}
	if len(os.Args) != 4 || os.Args[1] != "gen" {
		fmt.Fprintln(os.Stderr, "usage: oracle gen <corpus.tsv> <expected.out>")
		os.Exit(2)
	}
	cf, err := os.Create(os.Args[2])
	if err != nil {
		panic(err)
	}
	ef, err := os.Create(os.Args[3])
	if err != nil {
		panic(err)
	}
	corpus = bufio.NewWriter(cf)
	expect = bufio.NewWriter(ef)
	genGCM()
	genP256()
	corpus.Flush()
	expect.Flush()
	cf.Close()
	ef.Close()
	fmt.Fprintf(os.Stderr, "go oracle: %d vectors\n", nlines)
}
