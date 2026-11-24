// Red-team Go oracle for packages/crypto v0.4.0 (RT-crypto-v040): PBKDF2-HMAC-SHA256/512 + scrypt.
//
// References: golang.org/x/crypto/pbkdf2 and golang.org/x/crypto/scrypt v0.58.0 (byte values),
// Go stdlib crypto/aes + crypto/cipher (the scrypt + AES-256-GCM envelope). The Node.js
// oracle (../node/oracle.mjs) recomputes every valid row with crypto.pbkdf2Sync / crypto.scryptSync
// and checks the maxmem boundary rows against OpenSSL's EVP_PBE_scrypt memory rule.
//
//	go_oracle gen <corpus.tsv> <expected.out>   deterministic corpus (seeded ChaCha8) + expected lines
//	go_oracle one <op> <args...>                one result (used for the crash-isolated probes)
//	go_oracle tail <P256|P512> pass salt iters dk  last 32 bytes of a (huge) PBKDF2 output
//	go_oracle bench <pbkdf2_sha256|scrypt> <n>  scaled in-process copy of the repository benchmark
//
// Corpus line: label \t op \t args...   (byte strings in hex, integers in decimal)
//
//	P256 / P512 pass salt iters dkLen
//	SC   pass salt N r p dkLen maxmem      (maxmem "D" = scrypt() with its 256 MiB default)
//	ML   pass salt16 N iv12 pt             (scrypt + AES-256-GCM envelope: scrypt(N, 8, 1, 32) + AES-256-GCM, empty AAD;
//	                                        maxmem 64 MiB for N <= 32768, scrypt() default above)
//
// Expected line: label \t result, result = lowercase hex | ERR:<CryptoError kind> | alternatives
// joined with " || " (rows that violate several rules at once accept any of the violated kinds).
//
// Error contract (README v0.4.0 + RFC 7914 §2/§6 + RFC 8018 §5.2):
//
//	PBKDF2: iterations <= 0 -> InvalidParam (checked first), dkLen <= 0 -> InvalidLength(dkLen)
//	scrypt: N <= 1 or not a power of 2, r <= 0, p <= 0, max_mem <= 0, r*p >= 2^30, and
//	        N >= 2^(16 r) (RFC 7914 §2 "less than 2^(128 * r / 8)", enforced by OpenSSL / Node.js)
//	        -> InvalidParam; dkLen <= 0 -> InvalidLength(dkLen); 128 r (N + p + 2) > max_mem ->
//	        MemoryLimitExceeded.
package main

import (
	"bufio"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"hash"
	"math"
	"math/bits"
	"math/rand/v2"
	"os"
	"strconv"
	"strings"

	"golang.org/x/crypto/pbkdf2"
	"golang.org/x/crypto/scrypt"
)

var (
	rng    = rand.New(rand.NewChaCha8([32]byte{'R', 'T', '-', 'c', 'r', 'y', 'p', 't', 'o', '-', 'v', '0', '4', '0'}))
	corpus *bufio.Writer
	expect *bufio.Writer
	nlines int
)

const defaultMaxMem = int64(268435456)

func h(b []byte) string { return hex.EncodeToString(b) }

func rbytes(n int) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte(rng.Uint32())
	}
	return b
}

// pw returns a password/salt of exactly n bytes in one of three flavours: random bytes, bytes with
// embedded NULs, or non-ASCII UTF-8 (cut to n bytes, so a code point may be split: still bytes).
func pw(n, flavour int) []byte {
	switch flavour % 3 {
	case 0:
		return rbytes(n)
	case 1:
		b := rbytes(n)
		for i := 0; i < n; i += 7 {
			b[i] = 0
		}
		return b
	default:
		const u = "pässwörd-密码-🔑\x00ключ-"
		b := make([]byte, 0, n)
		for len(b) < n {
			b = append(b, u...)
		}
		return b[:n]
	}
}

func emit(label, op string, args []string, result string) {
	fmt.Fprintln(corpus, label+"\t"+op+"\t"+strings.Join(args, "\t"))
	fmt.Fprintf(expect, "%s\t%s\n", label, result)
	nlines++
}

func itoa(v int64) string { return strconv.FormatInt(v, 10) }

// ------------------------------------------------------------------ PBKDF2

func pbkdf2Contract(iters, dk int64) string {
	if iters <= 0 {
		return "ERR:InvalidParam"
	}
	if dk <= 0 {
		return fmt.Sprintf("ERR:InvalidLength(%d)", dk)
	}
	return ""
}

func goPbkdf2(op string, pass, salt []byte, iters, dk int64) string {
	if e := pbkdf2Contract(iters, dk); e != "" {
		return e
	}
	if op == "P256" {
		return h(pbkdf2.Key(pass, salt, int(iters), int(dk), sha256.New))
	}
	return h(pbkdf2.Key(pass, salt, int(iters), int(dk), sha512.New))
}

func emitP(label, op string, pass, salt []byte, iters, dk int64) {
	emit(label, op, []string{h(pass), h(salt), itoa(iters), itoa(dk)}, goPbkdf2(op, pass, salt, iters, dk))
}

// ------------------------------------------------------------------ scrypt

// scryptViolations returns every CryptoError kind the parameters violate (empty = valid).
func scryptViolations(n, r, p, dk, maxmem int64) []string {
	var out []string
	add := func(s string) {
		for _, x := range out {
			if x == s {
				return
			}
		}
		out = append(out, s)
	}
	if n <= 1 || n&(n-1) != 0 {
		add("ERR:InvalidParam")
	}
	if r <= 0 || p <= 0 {
		add("ERR:InvalidParam")
	}
	if dk <= 0 {
		add(fmt.Sprintf("ERR:InvalidLength(%d)", dk))
	}
	if maxmem <= 0 {
		add("ERR:InvalidParam")
	}
	if r > 0 && p > 0 && r*p >= 1<<30 {
		add("ERR:InvalidParam")
	}
	if r > 0 && 16*r < 63 && n >= int64(1)<<(16*r) {
		add("ERR:InvalidParam")
	}
	if r > 0 && n > 1 && new(bigInt).mul(128*r, n).gt(1<<31) {
		add("ERR:MemoryLimitExceeded") // implementation ceiling on the V table (see goScrypt)
	}
	if r > 0 && p > 0 && n > 1 && maxmem > 0 {
		// 128 r (N + p + 2) > maxmem, overflow-free (big r is already InvalidParam above)
		need := new(bigInt).mul(128*r, n+p+2)
		if need.gt(maxmem) {
			add("ERR:MemoryLimitExceeded")
		}
	}
	return out
}

// bigInt is an exact 128-bit unsigned product, enough for 128 r (N + p + 2) with int64 inputs.
type bigInt struct{ hi, lo uint64 }

func (b *bigInt) mul(x, y int64) *bigInt {
	if x <= 0 || y <= 0 {
		return &bigInt{}
	}
	hi, lo := bits.Mul64(uint64(x), uint64(y))
	return &bigInt{hi: hi, lo: lo}
}

func (b *bigInt) gt(v int64) bool { return b.hi > 0 || b.lo > uint64(v) }

func goScrypt(pass, salt []byte, n, r, p, dk, maxmem int64) string {
	if v := scryptViolations(n, r, p, dk, maxmem); len(v) > 0 {
		return strings.Join(v, " || ")
	}
	// Implementation ceiling: a V table of more than 2 GiB is refused (MemoryLimitExceeded) on every
	// target (wasm32 cannot address it, see REPORT P2-2); between 1 and 2 GiB either answer is fine
	// as long as all four build modes agree.
	vBytes := new(bigInt).mul(128*r, n)
	if vBytes.gt(1 << 31) {
		return "ERR:MemoryLimitExceeded"
	}
	out, err := scrypt.Key(pass, salt, int(n), int(r), int(p), int(dk))
	if err != nil {
		return "GO_ERROR:" + err.Error()
	}
	if vBytes.gt(1 << 30) {
		return "ERR:MemoryLimitExceeded || " + h(out)
	}
	return h(out)
}

func emitS(label string, pass, salt []byte, n, r, p, dk int64, maxmem string) {
	mm := defaultMaxMem
	if maxmem != "D" {
		mm, _ = strconv.ParseInt(maxmem, 10, 64)
	}
	emit(label, "SC", []string{h(pass), h(salt), itoa(n), itoa(r), itoa(p), itoa(dk), maxmem},
		goScrypt(pass, salt, n, r, p, dk, mm))
}

func sealEnvV1(pass, salt []byte, n int64, iv, pt []byte) string {
	mm := defaultMaxMem
	if n <= 32768 {
		mm = 64 << 20
	}
	if v := scryptViolations(n, 8, 1, 32, mm); len(v) > 0 {
		return strings.Join(v, " || ")
	}
	key, err := scrypt.Key(pass, salt, int(n), 8, 1, 32)
	if err != nil {
		return "GO_ERROR"
	}
	blk, _ := aes.NewCipher(key)
	g, _ := cipher.NewGCM(blk)
	return h(g.Seal(nil, iv, pt, nil))
}

// ------------------------------------------------------------------ corpus

var (
	passLens = []int{0, 1, 31, 32, 63, 64, 65, 127, 128, 129, 200, 1000}
	// The task's list plus the real SHA-256 / SHA-512 padding boundaries of `salt || INT(i)`
	// after the 64 / 128-byte ipad block: salt+4 = 55/56/57, 63/64/65 (SHA-256) and
	// 111/112/113, 127/128/129 (SHA-512).
	saltLens = []int{0, 1, 16, 51, 52, 53, 55, 56, 59, 60, 61, 64, 107, 108, 109, 111, 112, 119, 120, 123, 124, 125, 128, 256}
	dkLens   = []int64{1, 15, 16, 31, 32, 33, 63, 64, 65, 95, 96, 100, 128, 255, 256}
)

func gen(corpusPath, expectPath string) {
	cf, _ := os.Create(corpusPath)
	ef, _ := os.Create(expectPath)
	corpus, expect = bufio.NewWriter(cf), bufio.NewWriter(ef)
	defer func() { corpus.Flush(); expect.Flush(); cf.Close(); ef.Close() }()

	for _, op := range []string{"P256", "P512"} {
		fam := strings.ToLower(op)
		// password x salt length matrix (HMAC key folding 64/128 B, salt||INT(i) padding blocks)
		k := 0
		for _, pl := range passLens {
			for _, sl := range saltLens {
				iters := []int64{1, 2, 3}[k%3]
				dk := []int64{32, 64, 20, 65}[k%4]
				emitP(fmt.Sprintf("%s/lens/p%d_s%d_f%d", fam, pl, sl, k%3), op, pw(pl, k), pw(sl, k+1), iters, dk)
				k++
			}
		}
		// dkLen multi-block / truncation sweep
		for i, dk := range dkLens {
			for _, iters := range []int64{1, 2, 1000} {
				emitP(fmt.Sprintf("%s/dk/dk%d_i%d", fam, dk, iters), op, pw(1+i*9, i), pw(16, i+1), iters, dk)
			}
		}
		// iteration counts
		for _, iters := range []int64{4, 17, 4096, 10000} {
			emitP(fmt.Sprintf("%s/iters/i%d", fam, iters), op, []byte("password"), []byte("salt"), iters, 64)
		}
		// hostile parameters (Int edge values, both invalid at once)
		for _, it := range []int64{0, -1, math.MinInt32, 1} {
			for _, dk := range []int64{0, -1, math.MinInt32, 32} {
				emitP(fmt.Sprintf("%s/bad/i%d_dk%d", fam, it, dk), op, []byte("p"), []byte("s"), it, dk)
			}
		}
	}

	// scrypt N x r x p matrix (BlockMix even/odd interleave and Integerify offset 2r-1 for r > 1,
	// independent ROMix lanes for p > 1)
	k := 0
	for _, n := range []int64{2, 4, 8, 16, 64, 1024, 16384, 32768} {
		for _, r := range []int64{1, 2, 4, 8, 16} {
			for _, p := range []int64{1, 2, 3, 4} {
				heavy := ""
				if n*r*p >= 1<<17 {
					heavy = "heavy/"
				}
				dk := dkLens[k%len(dkLens)]
				emitS(fmt.Sprintf("sc/%smatrix/N%d_r%d_p%d", heavy, n, r, p), pw(k%40, k), pw((k*7)%70, k+1), n, r, p, dk, "D")
				k++
			}
		}
	}
	// scrypt password / salt length boundaries (the two PBKDF2-HMAC-SHA256 calls)
	for i, pl := range passLens {
		for j, sl := range []int{0, 1, 16, 51, 52, 55, 56, 59, 60, 64, 128, 256} {
			emitS(fmt.Sprintf("sc/lens/p%d_s%d", pl, sl), pw(pl, i+j), pw(sl, i+j+1), 4, int64(1+(i+j)%3), int64(1+(i*j)%2), 32, "D")
		}
	}
	// scrypt dkLen sweep
	for i, dk := range dkLens {
		emitS(fmt.Sprintf("sc/dk/dk%d", dk), pw(8+i, i), pw(16, i), 16, 2, 2, dk, "D")
	}
	// exact max_mem boundaries 128 r (N + p + 2) (and one byte below), confirmed with Node's maxmem
	for _, c := range [][3]int64{{2, 1, 1}, {16, 1, 1}, {16, 2, 3}, {1024, 8, 1}, {1024, 8, 16}, {16384, 8, 1}, {32768, 8, 1}, {16, 16, 4}, {4, 4, 3}} {
		need := 128 * c[1] * (c[0] + c[2] + 2)
		for _, mm := range []int64{need, need - 1} {
			heavy := ""
			if c[0]*c[1]*c[2] >= 1<<17 {
				heavy = "heavy/"
			}
			emitS(fmt.Sprintf("sc/%smaxmem/N%d_r%d_p%d_m%d", heavy, c[0], c[1], c[2], mm), []byte("pw"), []byte("NaCl"), c[0], c[1], c[2], 32, itoa(mm))
		}
	}
	// scrypt + AES-256-GCM envelope default write params under 64 MiB, and N=65536 must be refused under 64 MiB
	emitS("sc/heavy/env64/N32768", []byte("pion-kdf-test-passphrase-2026!"), mustHex("0123456789abcdeffedcba9876543210"), 32768, 8, 1, 32, "67108864")
	emitS("sc/env64/N65536", []byte("pion-kdf-test-passphrase-2026!"), mustHex("0123456789abcdeffedcba9876543210"), 65536, 8, 1, 32, "67108864")
	emitS("sc/env64/N131072", []byte("pion-kdf-test-passphrase-2026!"), mustHex("0123456789abcdeffedcba9876543210"), 131072, 8, 1, 32, "67108864")
	// RFC 7914 §2: N < 2^(16 r)  (OpenSSL / Node.js refuse, Go x/crypto accepts)
	for _, c := range [][2]int64{{32768, 1}, {65536, 1}, {131072, 1}, {65536, 2}} {
		emitS(fmt.Sprintf("sc/nbound/N%d_r%d", c[0], c[1]), []byte("pw"), []byte("salt"), c[0], c[1], 1, 32, "D")
	}

	// scrypt + AES-256-GCM envelopes, N = 1024 .. 131072 (Node.js cross-checks every byte)
	for i, n := range []int64{1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072} {
		for j := 0; j < 2; j++ {
			pass := pw(5+17*i+j, i+j)
			salt := rbytes(16)
			iv := rbytes(12)
			pt := rbytes((i*37 + j*101) % 211)
			label := fmt.Sprintf("ml/N%d_%d", n, j)
			if n >= 16384 {
				label = fmt.Sprintf("ml/heavy/N%d_%d", n, j)
			}
			emit(label, "ML", []string{h(pass), h(salt), itoa(n), h(iv), h(pt)}, sealEnvV1(pass, salt, n, iv, pt))
		}
	}
	// hostile scrypt parameters (each must be a clean Err, never panic / OOM / trap)
	type bad struct {
		n, r, p, dk int64
		mm          string
	}
	bads := []bad{}
	for _, n := range []int64{0, -1, 1, 3, 6, 15, 1023, 0x40000000, math.MinInt32, math.MaxInt32} {
		bads = append(bads, bad{n, 1, 1, 32, "D"})
	}
	for _, r := range []int64{0, -1, math.MaxInt32} {
		bads = append(bads, bad{16, r, 1, 32, "D"})
	}
	for _, p := range []int64{0, -1, math.MaxInt32} {
		bads = append(bads, bad{16, 1, p, 32, "D"})
	}
	bads = append(bads,
		bad{16, 65536, 65536, 32, "D"}, bad{16, 1073741824, 1, 32, "D"}, bad{16, 1, 1073741824, 32, "D"},
		bad{2, 16384, 65536, 32, "D"}, bad{2, 32768, 32767, 32, "D"},
		bad{0x40000000, 0x7fffffff, 1, 32, "D"}, bad{0x40000000, 0x7fffffff, 1, 32, itoa(math.MaxInt64)},
		bad{0x40000000, 1, 1, 32, "D"}, bad{0x40000000, 1, 1, 32, itoa(math.MaxInt64)},
		bad{0x40000000, 8, 1, 32, itoa(math.MaxInt64)}, bad{1048576, 8, 1, 64, "D"},
		bad{2, 1, 1073741823, 32, "D"}, bad{2, 1073741823, 1, 32, "D"},
		bad{16, 1, 1, 0, "D"}, bad{16, 1, 1, -1, "D"}, bad{16, 1, 1, math.MinInt32, "D"},
		bad{16, 1, 1, 32, "0"}, bad{16, 1, 1, 32, "-1"}, bad{16, 1, 1, 32, itoa(math.MinInt64)},
		bad{0, 0, 0, 0, "0"}, bad{math.MinInt32, math.MinInt32, math.MinInt32, math.MinInt32, itoa(math.MinInt64)},
	)
	for i, b := range bads {
		emitS(fmt.Sprintf("sc/bad/%02d_N%d_r%d_p%d_dk%d_m%s", i, b.n, b.r, b.p, b.dk, b.mm), []byte("p"), []byte("s"), b.n, b.r, b.p, b.dk, b.mm)
	}

	fmt.Fprintf(os.Stderr, "go_oracle: %d corpus lines\n", nlines)
}

func mustHex(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}

// pbkdf2Tail returns the last 32 bytes of PBKDF2(pass, salt, iters, dk) without materialising the
// whole (up to 2 GiB) output: only the one or two blocks T_i that cover [dk-32, dk) are computed.
func pbkdf2Tail(op string, pass, salt []byte, iters, dk int64) string {
	hf, hl := sha256.New, int64(32)
	if op == "P512" {
		hf, hl = sha512.New, 64
	}
	block := func(i int64) []byte {
		prf := hmac.New(func() hash.Hash { return hf() }, pass)
		prf.Write(salt)
		var ctr [4]byte
		binary.BigEndian.PutUint32(ctr[:], uint32(i))
		prf.Write(ctr[:])
		u := prf.Sum(nil)
		t := append([]byte(nil), u...)
		for n := int64(1); n < iters; n++ {
			prf.Reset()
			prf.Write(u)
			u = prf.Sum(u[:0])
			for k := range t {
				t[k] ^= u[k]
			}
		}
		return t
	}
	start := dk - 32
	first := start/hl + 1
	last := (dk-1)/hl + 1
	var buf []byte
	for i := first; i <= last; i++ {
		buf = append(buf, block(i)...)
	}
	off := start - (first-1)*hl
	return h(buf[off : off+32])
}

// one computes one result from the same op/arg syntax as a corpus line.
func one(args []string) string {
	num := func(s string) int64 { v, _ := strconv.ParseInt(s, 10, 64); return v }
	switch args[0] {
	case "P256", "P512":
		return goPbkdf2(args[0], mustHex(args[1]), mustHex(args[2]), num(args[3]), num(args[4]))
	case "SC":
		mm := defaultMaxMem
		if args[7] != "D" {
			mm = num(args[7])
		}
		return goScrypt(mustHex(args[1]), mustHex(args[2]), num(args[3]), num(args[4]), num(args[5]), num(args[6]), mm)
	}
	return "UNKNOWN_OP"
}

// bench mirrors bench/go (same inputs, same stdout) with a scaled op count n.
func bench(mode string, n int) int {
	switch mode {
	case "pbkdf2_sha256":
		pass := []byte("pion-crypto-bench-pbkdf2-passphrase-2026!")
		salt := []byte("pion-crypto-bench-pbkdf2-salt-0123456789")
		fmt.Printf("pbkdf2_sha256=%s\n", hex.EncodeToString(pbkdf2.Key(pass, salt, n, 32, sha256.New)))
		return 0
	case "scrypt":
		pass := []byte("pion-kdf-test-passphrase-2026!")
		salt := mustHex("0123456789abcdeffedcba9876543210")
		hh := sha256.New()
		for i := 0; i < n; i++ {
			salt[0] = byte(i & 0xFF)
			dk, err := scrypt.Key(pass, salt, 16384, 8, 1, 32)
			if err != nil {
				return 2
			}
			hh.Write(dk)
		}
		fmt.Printf("scrypt_sha256=%s\n", hex.EncodeToString(hh.Sum(nil)))
		return 0
	}
	return 2
}

func main() {
	if len(os.Args) >= 4 && os.Args[1] == "gen" {
		gen(os.Args[2], os.Args[3])
		return
	}
	if len(os.Args) >= 7 && os.Args[1] == "tail" {
		num := func(s string) int64 { v, _ := strconv.ParseInt(s, 10, 64); return v }
		fmt.Println(pbkdf2Tail(os.Args[2], mustHex(os.Args[3]), mustHex(os.Args[4]), num(os.Args[5]), num(os.Args[6])))
		return
	}
	if len(os.Args) >= 3 && os.Args[1] == "one" {
		fmt.Println(one(os.Args[2:]))
		return
	}
	if len(os.Args) >= 4 && os.Args[1] == "bench" {
		n, _ := strconv.Atoi(os.Args[3])
		os.Exit(bench(os.Args[2], n))
	}
	fmt.Fprintln(os.Stderr, "usage: go_oracle gen <corpus> <expected> | one <op> <args...> | bench <mode> <n>")
	os.Exit(2)
}
