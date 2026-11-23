// webpdiff: reference oracle, corpus generator and mutator for the packages/webp red-team audit.
//
//	webpdiff digest <file>...               one line per file: "<file> OK <w> <h> <sha256(RGBA8888)>" | "<file> ERR <msg>"
//	webpdiff dwebp <file>...                same format, decoded by libwebp's `dwebp -pam` (third opinion)
//	webpdiff ref <file>...                  libwebp adjudication: -pam verdict/alpha, lossy RGB via -yuv + Go conversion
//	webpdiff dwebp-yuv <file>...            lossy only: libwebp's raw YUV through Go's YCbCrToRGB (alpha = 255)
//	webpdiff gen <dir> <seed> <n_random>    deterministic corpus: cwebp matrix + VP8X/ALPH composites +
//	                                        random syntax-valid VP8 keyframes + random syntax-valid VP8L streams
//	webpdiff mutate <corpus> <out> <seed> <n>  deterministic byte-level mutants of every corpus file
//
// The oracle is golang.org/x/image/webp (the implementation packages/webp says it is byte-identical to).
// Before decoding, DecodeConfig is checked against packages/webp's DecodeLimits::default() so that
// mutated headers announcing 16k x 16k images do not make the oracle allocate gigabytes; those lines
// read "ERR limit" and are compared with Pion's LimitExceeded.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"golang.org/x/image/webp"
)

// ---------------------------------------------------------------------------------------------
// digest

func rgbaOf(img image.Image) ([]byte, int, int, error) {
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	out := make([]byte, 4*w*h)
	switch m := img.(type) {
	case *image.NRGBA:
		for y := 0; y < h; y++ {
			copy(out[y*w*4:(y+1)*w*4], m.Pix[y*m.Stride:y*m.Stride+w*4])
		}
	case *image.YCbCr:
		i := 0
		for y := 0; y < h; y++ {
			for x := 0; x < w; x++ {
				r, g, bl := color.YCbCrToRGB(m.Y[m.YOffset(x, y)], m.Cb[m.COffset(x, y)], m.Cr[m.COffset(x, y)])
				out[i], out[i+1], out[i+2], out[i+3] = r, g, bl, 255
				i += 4
			}
		}
	case *image.NYCbCrA:
		i := 0
		for y := 0; y < h; y++ {
			for x := 0; x < w; x++ {
				r, g, bl := color.YCbCrToRGB(m.Y[m.YOffset(x, y)], m.Cb[m.COffset(x, y)], m.Cr[m.COffset(x, y)])
				out[i], out[i+1], out[i+2], out[i+3] = r, g, bl, m.A[m.AOffset(x, y)]
				i += 4
			}
		}
	default:
		return nil, 0, 0, fmt.Errorf("unexpected image type %T", img)
	}
	return out, w, h, nil
}

func goDigest(data []byte) (line string) {
	defer func() {
		if r := recover(); r != nil {
			line = "ERR go-panic"
		}
	}()
	cfg, err := webp.DecodeConfig(bytes.NewReader(data))
	if err == nil {
		w, h := int64(cfg.Width), int64(cfg.Height)
		if w > 16384 || h > 16384 || w*h > 16777216 {
			return "ERR limit"
		}
	}
	img, err := webp.Decode(bytes.NewReader(data))
	if err != nil {
		return "ERR " + strings.ReplaceAll(err.Error(), " ", "_")
	}
	px, w, h, err := rgbaOf(img)
	if err != nil {
		return "ERR " + err.Error()
	}
	s := sha256.Sum256(px)
	return fmt.Sprintf("OK %d %d %s", w, h, hex.EncodeToString(s[:]))
}

// dwebpYUVDigest decodes a lossy file with libwebp (`dwebp -yuv`: raw Y, U, V planes, no colour conversion)
// and converts it with Go's color.YCbCrToRGB, so libwebp's reconstruction is comparable byte for byte with
// x/image/webp and packages/webp (which both use that conversion). Alpha (if any) is not included: 255.
func dwebpYUVDigest(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return "ERR read"
	}
	cfg, err := webp.DecodeConfig(bytes.NewReader(b))
	if err != nil {
		return "ERR config"
	}
	tmp, err := os.CreateTemp("", "webpdiff-*.yuv")
	if err != nil {
		return "ERR tmp"
	}
	tmp.Close()
	defer os.Remove(tmp.Name())
	if err := exec.Command("dwebp", "-quiet", "-yuv", path, "-o", tmp.Name()).Run(); err != nil {
		return "ERR dwebp"
	}
	raw, err := os.ReadFile(tmp.Name())
	if err != nil {
		return "ERR read"
	}
	w, h := cfg.Width, cfg.Height
	cw, ch := (w+1)/2, (h+1)/2
	if len(raw) < w*h+2*cw*ch {
		return "ERR yuv-size"
	}
	Y, U, V := raw[:w*h], raw[w*h:w*h+cw*ch], raw[w*h+cw*ch:w*h+2*cw*ch]
	px := make([]byte, 4*w*h)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			r, g, bl := color.YCbCrToRGB(Y[y*w+x], U[(y/2)*cw+x/2], V[(y/2)*cw+x/2])
			i := 4 * (y*w + x)
			px[i], px[i+1], px[i+2], px[i+3] = r, g, bl, 255
		}
	}
	s := sha256.Sum256(px)
	return fmt.Sprintf("OK %d %d %s", w, h, hex.EncodeToString(s[:]))
}

// refDigest is libwebp's verdict and pixels in the oracle's colour conversion: `dwebp -pam` gives the
// verdict, the alpha channel and (lossless) the RGB; for files carrying a "VP8 " chunk the RGB comes from
// `dwebp -yuv` through Go's YCbCrToRGB instead (libwebp's own YUV->RGB differs from x/image/webp's).
func refDigest(path string) string {
	pam := dwebpPAM(path)
	if pam == nil {
		return "ERR dwebp"
	}
	b, _ := os.ReadFile(path)
	if bytes.Contains(b, []byte("VP8 ")) {
		y := dwebpYUV(path, pam.w, pam.h)
		if y == nil {
			return "ERR dwebp-yuv"
		}
		for i := 0; i < pam.w*pam.h; i++ {
			y[4*i+3] = pam.px[4*i+3]
		}
		pam.px = y
	}
	s := sha256.Sum256(pam.px)
	return fmt.Sprintf("OK %d %d %s", pam.w, pam.h, hex.EncodeToString(s[:]))
}

type pamImg struct {
	w, h int
	px   []byte
}

func dwebpPAM(path string) *pamImg {
	tmp, err := os.CreateTemp("", "webpdiff-*.pam")
	if err != nil {
		return nil
	}
	tmp.Close()
	defer os.Remove(tmp.Name())
	if exec.Command("dwebp", "-quiet", "-pam", path, "-o", tmp.Name()).Run() != nil {
		return nil
	}
	b, err := os.ReadFile(tmp.Name())
	if err != nil {
		return nil
	}
	idx := bytes.Index(b, []byte("ENDHDR\n"))
	if idx < 0 {
		return nil
	}
	m := &pamImg{}
	for _, ln := range strings.Split(string(b[:idx]), "\n") {
		f := strings.Fields(ln)
		if len(f) == 2 && f[0] == "WIDTH" {
			m.w, _ = strconv.Atoi(f[1])
		}
		if len(f) == 2 && f[0] == "HEIGHT" {
			m.h, _ = strconv.Atoi(f[1])
		}
	}
	m.px = b[idx+7:]
	if len(m.px) != 4*m.w*m.h {
		return nil
	}
	return m
}

func dwebpYUV(path string, w, h int) []byte {
	tmp, err := os.CreateTemp("", "webpdiff-*.yuv")
	if err != nil {
		return nil
	}
	tmp.Close()
	defer os.Remove(tmp.Name())
	if exec.Command("dwebp", "-quiet", "-yuv", path, "-o", tmp.Name()).Run() != nil {
		return nil
	}
	raw, err := os.ReadFile(tmp.Name())
	if err != nil {
		return nil
	}
	cw, ch := (w+1)/2, (h+1)/2
	if len(raw) < w*h+2*cw*ch {
		return nil
	}
	Y, U, V := raw[:w*h], raw[w*h:w*h+cw*ch], raw[w*h+cw*ch:w*h+2*cw*ch]
	px := make([]byte, 4*w*h)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			r, g, bl := color.YCbCrToRGB(Y[y*w+x], U[(y/2)*cw+x/2], V[(y/2)*cw+x/2])
			i := 4 * (y*w + x)
			px[i], px[i+1], px[i+2], px[i+3] = r, g, bl, 255
		}
	}
	return px
}

func dwebpDigest(path string) string {
	tmp, err := os.CreateTemp("", "webpdiff-*.pam")
	if err != nil {
		return "ERR tmp"
	}
	tmp.Close()
	defer os.Remove(tmp.Name())
	cmd := exec.Command("dwebp", "-quiet", "-pam", path, "-o", tmp.Name())
	if err := cmd.Run(); err != nil {
		return "ERR dwebp"
	}
	b, err := os.ReadFile(tmp.Name())
	if err != nil {
		return "ERR read"
	}
	// PAM: header lines until ENDHDR
	idx := bytes.Index(b, []byte("ENDHDR\n"))
	if idx < 0 {
		return "ERR pam"
	}
	var w, h int
	for _, ln := range strings.Split(string(b[:idx]), "\n") {
		f := strings.Fields(ln)
		if len(f) == 2 && f[0] == "WIDTH" {
			w, _ = strconv.Atoi(f[1])
		}
		if len(f) == 2 && f[0] == "HEIGHT" {
			h, _ = strconv.Atoi(f[1])
		}
	}
	px := b[idx+7:]
	s := sha256.Sum256(px)
	return fmt.Sprintf("OK %d %d %s", w, h, hex.EncodeToString(s[:]))
}

// ---------------------------------------------------------------------------------------------
// containers

func chunk(fourcc string, payload []byte) []byte {
	out := append([]byte(fourcc), 0, 0, 0, 0)
	binary.LittleEndian.PutUint32(out[4:], uint32(len(payload)))
	out = append(out, payload...)
	if len(payload)&1 == 1 {
		out = append(out, 0)
	}
	return out
}

func riff(chunks ...[]byte) []byte {
	body := []byte("WEBP")
	for _, c := range chunks {
		body = append(body, c...)
	}
	out := append([]byte("RIFF"), 0, 0, 0, 0)
	binary.LittleEndian.PutUint32(out[4:], uint32(len(body)))
	return append(out, body...)
}

func vp8x(flags byte, w, h int) []byte {
	p := make([]byte, 10)
	p[0] = flags
	p[4], p[5], p[6] = byte(w-1), byte((w-1)>>8), byte((w-1)>>16)
	p[7], p[8], p[9] = byte(h-1), byte((h-1)>>8), byte((h-1)>>16)
	return chunk("VP8X", p)
}

// first chunk payload of a simple-format file
func firstChunk(b []byte) (string, []byte) {
	if len(b) < 20 {
		return "", nil
	}
	n := int(binary.LittleEndian.Uint32(b[16:20]))
	if 20+n > len(b) {
		return "", nil
	}
	return string(b[12:16]), b[20 : 20+n]
}

// ---------------------------------------------------------------------------------------------
// synthetic source images

type src struct {
	name string
	img  *image.NRGBA
}

func mkImg(r *rand.Rand, w, h int, pattern string, alpha string) *image.NRGBA {
	m := image.NewNRGBA(image.Rect(0, 0, w, h))
	ncol := 0
	switch pattern {
	case "pal2":
		ncol = 2
	case "pal3":
		ncol = 3
	case "pal4":
		ncol = 4
	case "pal5":
		ncol = 5
	case "pal16":
		ncol = 16
	case "pal17":
		ncol = 17
	case "pal256":
		ncol = 256
	}
	pal := make([]color.NRGBA, ncol)
	for i := range pal {
		pal[i] = color.NRGBA{uint8(r.Intn(256)), uint8(r.Intn(256)), uint8(r.Intn(256)), 255}
	}
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			var c color.NRGBA
			switch {
			case ncol > 0:
				c = pal[(x*7+y*13+r.Intn(3))%ncol]
			case pattern == "noise":
				c = color.NRGBA{uint8(r.Intn(256)), uint8(r.Intn(256)), uint8(r.Intn(256)), 255}
			case pattern == "grad":
				c = color.NRGBA{uint8(x * 255 / max(1, w-1)), uint8(y * 255 / max(1, h-1)), uint8((x + y) * 3), 255}
			default: // "smooth" photo-like with edges
				v := (x*x + y*3) % 251
				c = color.NRGBA{uint8(v), uint8((v * 3) & 255), uint8(255 - v), 255}
				if (x/8+y/8)%2 == 0 {
					c.G ^= 0x40
				}
			}
			switch alpha {
			case "binary":
				if (x+y)%3 == 0 {
					c.A = 0
				}
			case "grad":
				c.A = uint8((x*255/max(1, w) + y*7) & 255)
			case "noise":
				c.A = uint8(r.Intn(256))
			}
			m.SetNRGBA(x, y, c)
		}
	}
	return m
}

func writePNG(path string, m image.Image) {
	f, err := os.Create(path)
	if err != nil {
		panic(err)
	}
	if err := png.Encode(f, m); err != nil {
		panic(err)
	}
	f.Close()
}

func cwebp(in, out string, args ...string) bool {
	a := append([]string{"-quiet"}, args...)
	a = append(a, in, "-o", out)
	return exec.Command("cwebp", a...).Run() == nil
}

// ---------------------------------------------------------------------------------------------
// ALPH forward filters (RFC 9649 5.2.3), applied to a plane before raw/VP8L compression.

func filterAlpha(a []byte, w, h, filter int) []byte {
	out := make([]byte, len(a))
	at := func(x, y int) int { return int(a[y*w+x]) }
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			var pred int
			switch {
			case filter == 0:
				pred = 0
			case x == 0 && y == 0:
				pred = 0
			case y == 0:
				pred = at(x-1, 0)
			case x == 0:
				pred = at(0, y-1)
			case filter == 1:
				pred = at(x-1, y)
			case filter == 2:
				pred = at(x, y-1)
			default:
				pred = at(x-1, y) + at(x, y-1) - at(x-1, y-1)
				if pred < 0 {
					pred = 0
				} else if pred > 255 {
					pred = 255
				}
			}
			out[y*w+x] = byte(at(x, y) - pred)
		}
	}
	return out
}

// ---------------------------------------------------------------------------------------------
// VP8 boolean encoder (RFC 6386 7.3) and random syntax-valid keyframes.

type boolEnc struct {
	out    []byte
	rng    uint32
	bottom uint32
	bitCnt int
}

func newBoolEnc() *boolEnc { return &boolEnc{rng: 255, bitCnt: 24} }

func (e *boolEnc) addOne() {
	i := len(e.out) - 1
	for i >= 0 && e.out[i] == 255 {
		e.out[i] = 0
		i--
	}
	if i >= 0 {
		e.out[i]++
	}
}

func (e *boolEnc) put(prob int, bit bool) {
	split := 1 + (((e.rng - 1) * uint32(prob)) >> 8)
	if bit {
		e.bottom += split
		e.rng -= split
	} else {
		e.rng = split
	}
	for e.rng < 128 {
		e.rng <<= 1
		if e.bottom&(1<<31) != 0 {
			e.addOne()
		}
		e.bottom <<= 1
		e.bitCnt--
		if e.bitCnt == 0 {
			e.out = append(e.out, byte(e.bottom>>24))
			e.bottom &= (1 << 24) - 1
			e.bitCnt = 8
		}
	}
}

func (e *boolEnc) flush() []byte {
	c := e.bitCnt
	v := e.bottom
	if v&(1<<uint(32-c)) != 0 {
		e.addOne()
	}
	v <<= uint(c & 7)
	c >>= 3
	for c--; c >= 0; c-- {
		v <<= 8
	}
	for i := 0; i < 4; i++ {
		e.out = append(e.out, byte(v>>24))
		v <<= 8
	}
	return e.out
}

func (e *boolEnc) lit(n int, v int) {
	for i := n - 1; i >= 0; i-- {
		e.put(128, (v>>uint(i))&1 == 1)
	}
}

func (e *boolEnc) optSigned(r *rand.Rand, n int, p float64) {
	if r.Float64() < p {
		e.put(128, true)
		e.lit(n, r.Intn(1<<uint(n)))
		e.put(128, r.Intn(2) == 1)
	} else {
		e.put(128, false)
	}
}

// randVP8 returns a VP8 keyframe payload whose first-partition header is chosen explicitly and whose
// macroblock/token data is random (every byte string is a decodable boolean-coded stream).
func randVP8(r *rand.Rand, w, h int, version int, log2parts int, bias int, truncate bool) []byte {
	e := newBoolEnc()
	e.put(128, false) // color space
	e.put(128, r.Intn(2) == 1)
	seg := r.Intn(2) == 1
	e.put(128, seg)
	if seg {
		e.put(128, r.Intn(3) != 0) // update map
		upd := r.Intn(4) != 0
		e.put(128, upd)
		if upd {
			e.put(128, r.Intn(2) == 1) // 1 = absolute
			for i := 0; i < 4; i++ {
				e.optSigned(r, 7, 0.8)
			}
			for i := 0; i < 4; i++ {
				e.optSigned(r, 6, 0.6)
			}
		}
		// map probs are only read when update_map=1; the random tail covers that path either way.
	}
	e.put(128, r.Intn(2) == 1) // simple filter
	e.lit(6, r.Intn(64))       // level
	e.lit(3, r.Intn(8))        // sharpness
	delta := r.Intn(2) == 1
	e.put(128, delta)
	if delta {
		upd := r.Intn(2) == 1
		e.put(128, upd)
		if upd {
			for i := 0; i < 8; i++ {
				e.optSigned(r, 6, 0.5)
			}
		}
	}
	e.lit(2, log2parts)
	if off("quant") { // debugging aid: base q 0 and no deltas -> every dequantized coefficient fits int16
		e.lit(7, 0)
		for i := 0; i < 5; i++ {
			e.put(128, false)
		}
	} else {
		e.lit(7, r.Intn(128)) // base q
		for i := 0; i < 5; i++ {
			e.optSigned(r, 4, 0.3)
		}
	}
	e.put(128, false) // refresh entropy probs
	mbs := ((w + 15) >> 4) * ((h + 15) >> 4)
	for i := 0; i < 3000+mbs*80; i++ { // token-prob updates, skip prob, modes: random decisions
		e.put(128, r.Intn(2) == 1)
	}
	fp := e.flush()
	nparts := 1 << uint(log2parts)
	parts := make([][]byte, nparts)
	for i := range parts {
		n := 32 + r.Intn(64*mbs+64)
		if truncate {
			n = r.Intn(8)
		}
		if bias == 3 {
			// a well-formed (normalized) boolean-coded partition whose decisions are mostly 1: large DCT
			// tokens (cat3..cat6 escapes) without ever leaving the coder's valid value < range state
			pe := newBoolEnc()
			for j := 0; j < 8*n; j++ {
				pe.put(128, r.Intn(10) != 0)
			}
			parts[i] = pe.flush()
			continue
		}
		p := make([]byte, n)
		for j := range p {
			switch bias {
			case 0:
				p[j] = byte(r.Intn(256))
			case 1:
				p[j] = byte(r.Intn(256) & r.Intn(256) & r.Intn(256)) // mostly-zero: EOB-heavy
			default:
				// mostly-one raw bytes: large coefficients, and a coder value that exceeds its range
				// (not producible by an encoder; every decoder still handles it deterministically)
				p[j] = byte(r.Intn(256) | r.Intn(256) | r.Intn(256))
			}
		}
		parts[i] = p
	}
	hdr := make([]byte, 10)
	tag := uint32(len(fp))<<5 | 1<<4 | uint32(version&7)<<1 // keyframe (bit0=0), show_frame=1
	hdr[0], hdr[1], hdr[2] = byte(tag), byte(tag>>8), byte(tag>>16)
	hdr[3], hdr[4], hdr[5] = 0x9d, 0x01, 0x2a
	hdr[6], hdr[7] = byte(w), byte(w>>8)&0x3f
	hdr[8], hdr[9] = byte(h), byte(h>>8)&0x3f
	out := append(hdr, fp...)
	for i := 0; i < nparts-1; i++ {
		n := len(parts[i])
		out = append(out, byte(n), byte(n>>8), byte(n>>16))
	}
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

// ---------------------------------------------------------------------------------------------
// VP8L bit writer and random syntax-valid lossless streams (RFC 9649 section 3).

type bw struct {
	out  []byte
	acc  uint64
	nacc uint
}

func (b *bw) put(n uint, v uint32) {
	b.acc |= uint64(v&((1<<n)-1)) << b.nacc
	b.nacc += n
	for b.nacc >= 8 {
		b.out = append(b.out, byte(b.acc))
		b.acc >>= 8
		b.nacc -= 8
	}
}

func (b *bw) bytes() []byte {
	o := append([]byte(nil), b.out...)
	if b.nacc > 0 {
		o = append(o, byte(b.acc))
	}
	return o
}

// prefix code: symbol, extra bits count, extra value for a value v >= 1
func prefixEncode(v int) (sym int, nbits uint, extra uint32) {
	x := v - 1
	if x < 4 {
		return x, 0, 0
	}
	hb := 0
	for (x >> uint(hb+1)) != 0 {
		hb++
	}
	second := (x >> uint(hb-1)) & 1
	return 2*hb + second, uint(hb - 1), uint32(x & ((1 << uint(hb-1)) - 1))
}

func prefixDecode(sym int, extra int) int {
	if sym < 4 {
		return sym + 1
	}
	eb := uint((sym - 2) >> 1)
	return ((2 + (sym & 1)) << eb) + extra + 1
}

var distMap = [120]int{
	0x18, 0x07, 0x17, 0x19, 0x28, 0x06, 0x27, 0x29, 0x16, 0x1a,
	0x26, 0x2a, 0x38, 0x05, 0x37, 0x39, 0x15, 0x1b, 0x36, 0x3a,
	0x25, 0x2b, 0x48, 0x04, 0x47, 0x49, 0x14, 0x1c, 0x35, 0x3b,
	0x46, 0x4a, 0x24, 0x2c, 0x58, 0x45, 0x4b, 0x34, 0x3c, 0x03,
	0x57, 0x59, 0x13, 0x1d, 0x56, 0x5a, 0x23, 0x2d, 0x44, 0x4c,
	0x55, 0x5b, 0x33, 0x3d, 0x68, 0x02, 0x67, 0x69, 0x12, 0x1e,
	0x66, 0x6a, 0x22, 0x2e, 0x54, 0x5c, 0x43, 0x4d, 0x65, 0x6b,
	0x32, 0x3e, 0x78, 0x01, 0x77, 0x79, 0x53, 0x5d, 0x11, 0x1f,
	0x64, 0x6c, 0x42, 0x4e, 0x76, 0x7a, 0x21, 0x2f, 0x75, 0x7b,
	0x31, 0x3f, 0x63, 0x6d, 0x52, 0x5e, 0x00, 0x74, 0x7c, 0x41,
	0x4f, 0x10, 0x20, 0x62, 0x6e, 0x30, 0x73, 0x7d, 0x51, 0x5f,
	0x40, 0x72, 0x7e, 0x61, 0x6f, 0x50, 0x71, 0x7f, 0x60, 0x70,
}

func planeDist(w, code int) int {
	if code > 120 {
		return code - 120
	}
	dc := distMap[code-1]
	d := (dc>>4)*w + (8 - (dc & 0xf))
	if d < 1 {
		d = 1
	}
	return d
}

// huffCode: canonical code with lengths[sym] (0 = unused); codes are bit-reversed for LSB-first output.
type huffCode struct {
	lengths []int
	codes   []uint32
	syms    []int // used symbols
	simple  int   // 0 normal; 1/2 simple code with that many symbols
}

func canonical(lengths []int) []uint32 {
	var count [16]int
	for _, l := range lengths {
		if l > 0 {
			count[l]++
		}
	}
	var next [16]int
	code := 0
	for b := 1; b <= 15; b++ {
		code = (code + count[b-1]) << 1
		next[b] = code
	}
	codes := make([]uint32, len(lengths))
	for s, l := range lengths {
		if l > 0 {
			c := next[l]
			next[l]++
			rev := 0
			for i := 0; i < l; i++ {
				rev = (rev << 1) | ((c >> uint(i)) & 1)
			}
			codes[s] = uint32(rev)
		}
	}
	return codes
}

// randLengths: a complete prefix code over syms with max length maxLen (random binary tree splitting).
func randLengths(r *rand.Rand, n int, maxLen int) []int {
	// start with one leaf at depth 0, split random leaves until n leaves
	depths := []int{0}
	for len(depths) < n {
		// pick a splittable leaf
		cand := []int{}
		for i, d := range depths {
			if d < maxLen {
				cand = append(cand, i)
			}
		}
		if len(cand) == 0 {
			break
		}
		var i int
		if r.Intn(3) == 0 {
			// deepest splittable leaf: produces long (up to 15-bit) codes
			best := cand[0]
			for _, c := range cand {
				if depths[c] > depths[best] {
					best = c
				}
			}
			i = best
		} else {
			i = cand[r.Intn(len(cand))]
		}
		d := depths[i] + 1
		depths[i] = d
		depths = append(depths, d)
	}
	r.Shuffle(len(depths), func(a, b int) { depths[a], depths[b] = depths[b], depths[a] })
	return depths
}

func newCode(r *rand.Rand, alphabet int, want []int, nsyms int) *huffCode {
	set := map[int]bool{}
	for _, s := range want {
		if s < alphabet {
			set[s] = true
		}
	}
	for len(set) < nsyms && len(set) < alphabet {
		set[r.Intn(alphabet)] = true
	}
	syms := make([]int, 0, len(set))
	for s := range set {
		syms = append(syms, s)
	}
	sort.Ints(syms)
	hc := &huffCode{lengths: make([]int, alphabet), syms: syms}
	if len(syms) == 1 {
		hc.lengths[syms[0]] = 1 // single symbol: zero bits per symbol
		if syms[0] < 256 && r.Intn(2) == 0 && !off("simple") {
			hc.simple = 1
		}
		hc.codes = make([]uint32, alphabet)
		return hc
	}
	if len(syms) == 2 && syms[1] < 256 && syms[0] != syms[1] && r.Intn(2) == 0 && !off("simple") {
		hc.simple = 2
		hc.lengths[syms[0]] = 1
		hc.lengths[syms[1]] = 1
		hc.codes = make([]uint32, alphabet)
		hc.codes[syms[0]] = 0
		hc.codes[syms[1]] = 1
		return hc
	}
	ls := randLengths(r, len(syms), 15)
	for i, s := range syms {
		hc.lengths[s] = ls[i]
	}
	hc.codes = canonical(hc.lengths)
	return hc
}

func (hc *huffCode) emit(b *bw, sym int) {
	if len(hc.syms) == 1 {
		return
	}
	b.put(uint(hc.lengths[sym]), hc.codes[sym])
}

var clOrder = [19]int{17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}

func (hc *huffCode) write(r *rand.Rand, b *bw) {
	if hc.simple > 0 {
		b.put(1, 1)
		b.put(1, uint32(hc.simple-1))
		s0 := hc.syms[0]
		if hc.simple == 2 {
			// ascending order, as libwebp writes them: RFC 9649 derives the codes canonically from the code
			// lengths (smaller symbol = code 0), while x/image/webp assigns code 0 to the first symbol read.
			// Descending order is a known oracle disagreement exercised by a dedicated red-team case.
			s1 := hc.syms[1]
			if off("ascending") {
				s0, s1 = s1, s0
			}
			hc.codes[s0], hc.codes[s1] = 0, 1
			if s0 < 2 && r.Intn(2) == 0 {
				b.put(1, 0)
				b.put(1, uint32(s0))
			} else {
				b.put(1, 1)
				b.put(8, uint32(s0))
			}
			b.put(8, uint32(s1))
			return
		}
		if s0 < 2 && r.Intn(2) == 0 {
			b.put(1, 0)
			b.put(1, uint32(s0))
		} else {
			b.put(1, 1)
			b.put(8, uint32(s0))
		}
		return
	}
	b.put(1, 0)
	// tokenize code lengths with optional RLE (16 repeat previous, 17 short zero run, 18 long zero run)
	type tok struct{ sym, nbits, extra int }
	L := hc.lengths
	// trailing zeros may be dropped via max_symbol (which counts tokens and must be >= 2)
	last := len(L) - 1
	for last >= 0 && L[last] == 0 {
		last--
	}
	useMax := r.Intn(2) == 0 && !off("max")
	var toks []tok
	for {
		toks = toks[:0]
		end := len(L)
		if useMax {
			end = last + 1
		}
		prev := 8
		for i := 0; i < end; {
			l := L[i]
			run := 1
			for i+run < end && L[i+run] == l {
				run++
			}
			switch {
			case l == 0 && run >= 11 && r.Intn(4) != 0 && !off("rle"):
				n := min(run, 138)
				toks = append(toks, tok{18, 7, n - 11})
				i += n
			case l == 0 && run >= 3 && r.Intn(4) != 0 && !off("rle"):
				n := min(run, 10)
				toks = append(toks, tok{17, 3, n - 3})
				i += n
			case l != 0 && l == prev && run >= 3 && r.Intn(3) != 0 && !off("rle"):
				n := min(run, 6)
				toks = append(toks, tok{16, 2, n - 3})
				i += n
			default:
				toks = append(toks, tok{l, 0, 0})
				if l != 0 {
					prev = l
				}
				i++
			}
		}
		if useMax && len(toks) < 2 {
			useMax = false
			continue
		}
		break
	}
	// code-length code over token symbols, lengths <= 7
	used := map[int]bool{}
	for _, t := range toks {
		used[t.sym] = true
	}
	usyms := []int{}
	for s := range used {
		usyms = append(usyms, s)
	}
	sort.Ints(usyms)
	cl := make([]int, 19)
	if len(usyms) == 1 {
		cl[usyms[0]] = 1 + r.Intn(7)
	} else {
		ls := randLengths(r, len(usyms), 7)
		for i, s := range usyms {
			cl[s] = ls[i]
		}
	}
	clCodes := canonical(cl)
	n := 19
	for n > 4 && cl[clOrder[n-1]] == 0 {
		n--
	}
	b.put(4, uint32(n-4))
	for i := 0; i < n; i++ {
		b.put(3, uint32(cl[clOrder[i]]))
	}
	if useMax {
		b.put(1, 1)
		ms := len(toks)
		v := ms - 2
		nb := 0
		for (v >> uint(nb)) != 0 {
			nb++
		}
		nbc := 0
		if nb > 2 {
			nbc = (nb - 2 + 1) / 2
		}
		b.put(3, uint32(nbc))
		b.put(uint(2+2*nbc), uint32(v))
	} else {
		b.put(1, 0)
	}
	for _, t := range toks {
		if len(usyms) > 1 {
			b.put(uint(cl[t.sym]), clCodes[t.sym])
		}
		if t.nbits > 0 {
			b.put(uint(t.nbits), uint32(t.extra))
		}
	}
}

type group struct{ g, rr, bb, a, d *huffCode }

// writeImage writes an entropy-coded image of w x h with random content that obeys the codes.
// For sub-images, content is driven by `pick` when non-nil (e.g. entropy-image group indices).
func writeImage(r *rand.Rand, b *bw, w, h int, top bool, maxGroups int, pick func(i int) (int, int)) {
	ccBits := 0
	if r.Intn(3) == 0 && pick == nil && !off("cc") {
		ccBits = 1 + r.Intn(11)
		b.put(1, 1)
		b.put(4, uint32(ccBits))
	} else {
		b.put(1, 0)
	}
	hbits := 0
	var groupOf []int
	ngroups := 1
	if top {
		if maxGroups > 1 && r.Intn(2) == 0 && !off("meta") {
			b.put(1, 1)
			hbits = 2 + r.Intn(4)
			b.put(3, uint32(hbits-2))
			tw, th := (w+(1<<uint(hbits))-1)>>uint(hbits), (h+(1<<uint(hbits))-1)>>uint(hbits)
			ng := 1 + r.Intn(maxGroups)
			base := 0
			if r.Intn(4) == 0 {
				base = 1000 + r.Intn(1500) // exercise the remapping path and unused groups
			}
			groupOf = make([]int, tw*th)
			for i := range groupOf {
				groupOf[i] = base + r.Intn(ng)
			}
			writeImage(r, b, tw, th, false, 0, func(i int) (int, int) { return groupOf[i] >> 8, groupOf[i] & 255 })
			mx := 0
			for _, g := range groupOf {
				mx = max(mx, g)
			}
			ngroups = mx + 1
		} else {
			b.put(1, 0)
		}
	}
	usedGroup := map[int]bool{0: true}
	for _, g := range groupOf {
		usedGroup[g] = true
	}
	gs := make([]group, ngroups)
	gAlpha := 256 + 24
	if ccBits > 0 {
		gAlpha += 1 << uint(ccBits)
	}
	for i := range gs {
		if !usedGroup[i] {
			// unused group (allowed by the spec): still parsed by every decoder, keep it tiny
			gs[i] = group{g: newCode(r, gAlpha, []int{r.Intn(256)}, 1), rr: newCode(r, 256, nil, 1), bb: newCode(r, 256, nil, 1),
				a: newCode(r, 256, nil, 1), d: newCode(r, 40, nil, 1)}
			continue
		}
		if pick != nil {
			// sub-image driven by pick(): literal-only codes covering every needed value
			gs[i] = group{
				g:  newCode(r, gAlpha, []int{}, 0),
				rr: newCode(r, 256, []int{}, 0),
				bb: newCode(r, 256, []int{r.Intn(256)}, 1),
				a:  newCode(r, 256, []int{r.Intn(256)}, 1),
				d:  newCode(r, 40, []int{0}, 1),
			}
			continue
		}
		wantG := []int{r.Intn(256)}
		ng := 1 + r.Intn(40)
		if r.Intn(3) == 0 {
			wantG = append(wantG, 256+r.Intn(24), 256+r.Intn(24))
		}
		if ccBits > 0 {
			wantG = append(wantG, 280+r.Intn(1<<uint(ccBits)))
		}
		if r.Intn(5) == 0 {
			ng = 200 + r.Intn(1000) // large alphabets -> long codes / secondary tables
		}
		gs[i] = group{
			g:  newCode(r, gAlpha, wantG, ng),
			rr: newCode(r, 256, nil, 1+r.Intn(1+r.Intn(256))),
			bb: newCode(r, 256, nil, 1+r.Intn(1+r.Intn(256))),
			a:  newCode(r, 256, nil, 1+r.Intn(1+r.Intn(256))),
			d:  newCode(r, 40, nil, 1+r.Intn(40)),
		}
	}
	if pick != nil {
		// rebuild codes so that every picked (red, green) is encodable
		needR, needG := map[int]bool{}, map[int]bool{}
		for i := 0; i < w*h; i++ {
			rv, gv := pick(i)
			needR[rv], needG[gv] = true, true
		}
		keys := func(m map[int]bool) []int {
			o := []int{}
			for k := range m {
				o = append(o, k)
			}
			sort.Ints(o)
			return o
		}
		gs[0].rr = newCode(r, 256, keys(needR), len(needR))
		gs[0].g = newCode(r, 280, keys(needG), len(needG))
	}
	for i := range gs {
		gs[i].g.write(r, b)
		gs[i].rr.write(r, b)
		gs[i].bb.write(r, b)
		gs[i].a.write(r, b)
		gs[i].d.write(r, b)
	}
	tilesPerRow := 0
	if hbits > 0 {
		tilesPerRow = (w + (1 << uint(hbits)) - 1) >> uint(hbits)
	}
	total := w * h
	pos := 0
	for pos < total {
		x, y := pos%w, pos/w
		gi := 0
		if hbits > 0 {
			gi = groupOf[(y>>uint(hbits))*tilesPerRow+(x>>uint(hbits))]
		}
		g := gs[gi]
		if pick != nil {
			rv, gv := pick(pos)
			g.g.emit(b, gv)
			g.rr.emit(b, rv)
			g.bb.emit(b, g.bb.syms[0])
			g.a.emit(b, g.a.syms[0])
			pos++
			continue
		}
		emitted := false
		for try := 0; try < 4 && !emitted; try++ {
			s := g.g.syms[r.Intn(len(g.g.syms))]
			switch {
			case s < 256:
				g.g.emit(b, s)
				g.rr.emit(b, g.rr.syms[r.Intn(len(g.rr.syms))])
				g.bb.emit(b, g.bb.syms[r.Intn(len(g.bb.syms))])
				g.a.emit(b, g.a.syms[r.Intn(len(g.a.syms))])
				pos++
				emitted = true
			case s < 280:
				lsym := s - 256
				leb := uint(0)
				if lsym >= 4 {
					leb = uint((lsym - 2) >> 1)
				}
				lextra := 0
				if leb > 0 {
					lextra = r.Intn(1 << leb)
				}
				length := prefixDecode(lsym, lextra)
				if pos+length > total {
					continue
				}
				dsym := g.d.syms[r.Intn(len(g.d.syms))]
				deb := uint(0)
				if dsym >= 4 {
					deb = uint((dsym - 2) >> 1)
				}
				dextra := 0
				if deb > 0 {
					dextra = r.Intn(1 << deb)
				}
				code := prefixDecode(dsym, dextra)
				if planeDist(w, code) > pos {
					continue
				}
				g.g.emit(b, s)
				if leb > 0 {
					b.put(leb, uint32(lextra))
				}
				g.d.emit(b, dsym)
				if deb > 0 {
					b.put(deb, uint32(dextra))
				}
				pos += length
				emitted = true
			default:
				g.g.emit(b, s)
				pos++
				emitted = true
			}
		}
		if !emitted {
			// force a literal: every green code built by writeImage contains a literal symbol
			for _, s := range g.g.syms {
				if s < 256 {
					g.g.emit(b, s)
					g.rr.emit(b, g.rr.syms[0])
					g.bb.emit(b, g.bb.syms[0])
					g.a.emit(b, g.a.syms[0])
					pos++
					break
				}
			}
		}
	}
}

func randVP8L(r *rand.Rand, w, h int, withHeader bool) []byte {
	b := &bw{}
	if withHeader {
		b.put(8, 0x2f)
		b.put(14, uint32(w-1))
		b.put(14, uint32(h-1))
		b.put(1, uint32(r.Intn(2)))
		b.put(3, 0)
	}
	order := r.Perm(4)
	nt := r.Intn(5)
	if off("trans") {
		nt = 0
	}
	cw := w
	for i := 0; i < nt; i++ {
		t := order[i]
		b.put(1, 1)
		b.put(2, uint32(t))
		switch t {
		case 0, 1:
			bits := 2 + r.Intn(4)
			b.put(3, uint32(bits-2))
			tw, th := (cw+(1<<uint(bits))-1)>>uint(bits), (h+(1<<uint(bits))-1)>>uint(bits)
			vals := make([]int, tw*th)
			for k := range vals {
				vals[k] = r.Intn(256)
				if t == 0 {
					vals[k] = r.Intn(14) | (r.Intn(16) << 4)
				}
			}
			reds := make([]int, tw*th)
			for k := range reds {
				reds[k] = r.Intn(256)
			}
			writeImage(r, b, tw, th, false, 0, func(k int) (int, int) { return reds[k], vals[k] })
		case 2:
		case 3:
			n := 1 + r.Intn(256)
			if r.Intn(2) == 0 {
				n = []int{1, 2, 3, 4, 5, 16, 17}[r.Intn(7)]
			}
			b.put(8, uint32(n-1))
			pr, pg := make([]int, n), make([]int, n)
			for k := range pr {
				pr[k], pg[k] = r.Intn(256), r.Intn(256)
			}
			writeImage(r, b, n, 1, false, 0, func(k int) (int, int) { return pr[k], pg[k] })
			bits := 0
			switch {
			case n <= 2:
				bits = 3
			case n <= 4:
				bits = 2
			case n <= 16:
				bits = 1
			}
			cw = (cw + (1 << uint(bits)) - 1) >> uint(bits)
		}
	}
	b.put(1, 0)
	writeImage(r, b, cw, h, true, 12, nil)
	return b.bytes()
}

// off reports whether a generator feature is disabled through WEBPDIFF_OFF (comma list; debugging aid).
func off(name string) bool {
	for _, f := range strings.Split(os.Getenv("WEBPDIFF_OFF"), ",") {
		if f == name {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------------------------
// corpus generation

var sizes = [][2]int{{1, 1}, {2, 2}, {3, 5}, {5, 3}, {7, 1}, {1, 9}, {15, 15}, {15, 17}, {16, 16}, {17, 13},
	{31, 33}, {33, 31}, {64, 48}, {100, 75}, {129, 67}}

func gen(dir string, seed int64, nRandom int) {
	os.MkdirAll(dir, 0o755)
	tmp, _ := os.MkdirTemp("", "webpdiff-src")
	defer os.RemoveAll(tmp)
	r := rand.New(rand.NewSource(seed))
	n := 0
	write := func(name string, b []byte) {
		os.WriteFile(filepath.Join(dir, name+".webp"), b, 0o644)
		n++
	}
	patterns := []string{"smooth", "grad", "noise", "pal2", "pal3", "pal4", "pal5", "pal16", "pal17", "pal256"}
	alphas := []string{"opaque", "binary", "grad", "noise"}
	lossless := [][]string{
		{"-lossless", "-z", "0"}, {"-lossless", "-z", "3"}, {"-lossless", "-z", "6"}, {"-lossless", "-z", "9"},
		{"-lossless", "-q", "100", "-m", "6"}, {"-lossless", "-q", "0", "-m", "0"}, {"-lossless", "-exact", "-m", "4"},
		{"-near_lossless", "40"}, {"-lossless", "-alpha_cleanup"},
	}
	lossy := [][]string{
		{"-q", "1"}, {"-q", "50"}, {"-q", "95"}, {"-q", "100", "-m", "6"}, {"-q", "75", "-f", "0"},
		{"-q", "75", "-nostrong", "-f", "60"}, {"-q", "75", "-strong", "-f", "100", "-sharpness", "7"},
		{"-q", "60", "-segments", "1"}, {"-q", "60", "-segments", "4", "-sns", "100"},
		{"-q", "40", "-sharpness", "3", "-f", "40"}, {"-q", "85", "-af"},
	}
	alphaOpts := [][]string{
		{"-alpha_method", "0"}, {"-alpha_method", "1", "-alpha_filter", "none"},
		{"-alpha_method", "1", "-alpha_filter", "fast"}, {"-alpha_method", "1", "-alpha_filter", "best"},
		{"-alpha_q", "50"}, {"-alpha_q", "0"},
	}
	for si, sz := range sizes {
		for k := 0; k < 3; k++ {
			pat := patterns[r.Intn(len(patterns))]
			al := alphas[r.Intn(len(alphas))]
			m := mkImg(r, sz[0], sz[1], pat, al)
			pngPath := filepath.Join(tmp, fmt.Sprintf("s%d_%d.png", si, k))
			writePNG(pngPath, m)
			base := fmt.Sprintf("cw_%dx%d_%s_%s", sz[0], sz[1], pat, al)
			for _, o := range [][]string{lossless[r.Intn(len(lossless))], lossless[r.Intn(len(lossless))]} {
				out := filepath.Join(dir, fmt.Sprintf("%s_L%s.webp", base, strings.Join(o, "")))
				if cwebp(pngPath, out, o...) {
					n++
				}
			}
			for _, o := range [][]string{lossy[r.Intn(len(lossy))], lossy[r.Intn(len(lossy))]} {
				o = append(o, alphaOpts[r.Intn(len(alphaOpts))]...)
				out := filepath.Join(dir, fmt.Sprintf("%s_Y%s.webp", base, strings.Join(o, "")))
				if cwebp(pngPath, out, o...) {
					n++
				}
			}
		}
	}
	// VP8X + ALPH composites: every filter x {raw, VP8L} on odd sizes, VP8 from cwebp.
	for _, sz := range [][2]int{{1, 1}, {3, 5}, {17, 13}, {15, 17}, {31, 33}, {64, 3}} {
		w, h := sz[0], sz[1]
		m := mkImg(r, w, h, "smooth", "noise")
		pngPath := filepath.Join(tmp, "alph.png")
		writePNG(pngPath, m)
		lossyPath := filepath.Join(tmp, "alph_lossy.webp")
		if !cwebp(pngPath, lossyPath, "-q", "70", "-noalpha") {
			continue
		}
		lb, _ := os.ReadFile(lossyPath)
		id, vp8 := firstChunk(lb)
		if id != "VP8 " {
			continue
		}
		plane := make([]byte, w*h)
		for i := range plane {
			plane[i] = m.Pix[4*i+3]
		}
		for f := 0; f < 4; f++ {
			fp := filterAlpha(plane, w, h, f)
			raw := append([]byte{byte(f << 2)}, fp...)
			write(fmt.Sprintf("alph_raw_f%d_%dx%d", f, w, h), riff(vp8x(0x10, w, h), chunk("ALPH", raw), chunk("VP8 ", vp8)))
			g := image.NewNRGBA(image.Rect(0, 0, w, h))
			for i := range fp {
				g.Pix[4*i+1] = fp[i]
				g.Pix[4*i+3] = 255
			}
			gp := filepath.Join(tmp, "alph_g.png")
			writePNG(gp, g)
			for _, z := range []string{"0", "9"} {
				lp := filepath.Join(tmp, "alph_g.webp")
				if !cwebp(gp, lp, "-lossless", "-exact", "-z", z) {
					continue
				}
				gb, _ := os.ReadFile(lp)
				gid, gl := firstChunk(gb)
				if gid != "VP8L" || len(gl) < 5 {
					continue
				}
				// the ALPH VP8L stream is the VP8L bitstream without its 5-byte header (40 bits, byte aligned)
				payload := append([]byte{byte(f<<2 | 1)}, gl[5:]...)
				write(fmt.Sprintf("alph_vp8l_f%d_z%s_%dx%d", f, z, w, h), riff(vp8x(0x10, w, h), chunk("ALPH", payload), chunk("VP8 ", vp8)))
			}
		}
		// metadata chunks with odd lengths around the image data
		write(fmt.Sprintf("meta_odd_%dx%d", w, h), riff(vp8x(0x2c, w, h), chunk("ICCP", []byte{1, 2, 3}), chunk("VP8 ", vp8),
			chunk("EXIF", []byte{9}), chunk("XMP ", []byte("<x/>!"))))
		write(fmt.Sprintf("unknown_chunks_%dx%d", w, h), riff(chunk("ZZZZ", []byte{7, 7, 7}), chunk("VP8 ", vp8)))
	}
	// random syntax-valid VP8 keyframes
	vp8Sizes := [][2]int{{1, 1}, {15, 15}, {16, 16}, {17, 13}, {31, 33}, {48, 32}, {65, 17}}
	for i := 0; i < nRandom; i++ {
		sz := vp8Sizes[r.Intn(len(vp8Sizes))]
		ver := r.Intn(4)
		lp := r.Intn(4)
		bias := r.Intn(4)
		write(fmt.Sprintf("rvp8_%04d_%dx%d_p%d_b%d", i, sz[0], sz[1], 1<<uint(lp), bias), riff(chunk("VP8 ", randVP8(r, sz[0], sz[1], ver, lp, bias, false))))
	}
	// random syntax-valid VP8L streams (transform combinations, color cache, meta-Huffman, LZ77, long codes)
	vp8lSizes := [][2]int{{1, 1}, {1, 7}, {3, 1}, {3, 5}, {5, 9}, {7, 3}, {9, 2}, {17, 13}, {15, 17}, {33, 20}, {64, 64}}
	for i := 0; i < nRandom; i++ {
		sz := vp8lSizes[r.Intn(len(vp8lSizes))]
		write(fmt.Sprintf("rvp8l_%04d_%dx%d", i, sz[0], sz[1]), riff(chunk("VP8L", randVP8L(r, sz[0], sz[1], true))))
	}
	// random VP8L-compressed ALPH planes (no VP8L header) over a cwebp VP8 frame
	for i := 0; i < nRandom/4; i++ {
		sz := [][2]int{{1, 1}, {3, 5}, {17, 13}, {15, 17}}[r.Intn(4)]
		w, h := sz[0], sz[1]
		m := mkImg(r, w, h, "grad", "opaque")
		pngPath := filepath.Join(tmp, "ra.png")
		writePNG(pngPath, m)
		lossyPath := filepath.Join(tmp, "ra.webp")
		if !cwebp(pngPath, lossyPath, "-q", "50") {
			continue
		}
		lb, _ := os.ReadFile(lossyPath)
		id, vp8 := firstChunk(lb)
		if id != "VP8 " {
			continue
		}
		f := r.Intn(4)
		payload := append([]byte{byte(f<<2 | 1)}, randVP8L(r, w, h, false)...)
		write(fmt.Sprintf("ralph_%04d_f%d_%dx%d", i, f, w, h), riff(vp8x(0x10, w, h), chunk("ALPH", payload), chunk("VP8 ", vp8)))
	}
	fmt.Printf("generated %d files in %s\n", n, dir)
}

// ---------------------------------------------------------------------------------------------
// mutation

func mutate(corpus, out string, seed int64, n int) {
	os.MkdirAll(out, 0o755)
	files, _ := filepath.Glob(filepath.Join(corpus, "*.webp"))
	sort.Strings(files)
	if len(files) == 0 {
		fmt.Println("empty corpus")
		return
	}
	datas := make([][]byte, len(files))
	for i, f := range files {
		datas[i], _ = os.ReadFile(f)
	}
	r := rand.New(rand.NewSource(seed))
	for i := 0; i < n; i++ {
		k := r.Intn(len(files))
		b := append([]byte(nil), datas[k]...)
		ops := 1 + r.Intn(4)
		for o := 0; o < ops && len(b) > 0; o++ {
			switch r.Intn(10) {
			case 0, 1, 2: // bit flip, biased into the bitstream region
				p := r.Intn(len(b))
				if len(b) > 30 && r.Intn(2) == 0 {
					p = 20 + r.Intn(len(b)-20)
				}
				b[p] ^= 1 << uint(r.Intn(8))
			case 3: // random byte
				b[r.Intn(len(b))] = byte(r.Intn(256))
			case 4: // truncate
				b = b[:r.Intn(len(b))]
			case 5: // chunk/RIFF size field tweak
				p := []int{4, 16}[r.Intn(2)]
				if p+4 <= len(b) {
					v := binary.LittleEndian.Uint32(b[p:])
					switch r.Intn(4) {
					case 0:
						v++
					case 1:
						v--
					case 2:
						v = 0xffffffff
					default:
						v = uint32(r.Intn(64))
					}
					binary.LittleEndian.PutUint32(b[p:], v)
				}
			case 6: // header bytes (VP8/VP8L dims, VP8X flags/canvas)
				if len(b) > 30 {
					b[20+r.Intn(10)] = byte(r.Intn(256))
				}
			case 7: // insert junk
				p := r.Intn(len(b))
				junk := make([]byte, 1+r.Intn(8))
				r.Read(junk)
				b = append(b[:p], append(junk, b[p:]...)...)
			case 8: // delete a span
				p := r.Intn(len(b))
				q := min(len(b), p+1+r.Intn(16))
				b = append(b[:p], b[q:]...)
			default: // splice tail from another file
				o2 := datas[r.Intn(len(datas))]
				if len(o2) > 0 {
					p := r.Intn(len(b))
					q := r.Intn(len(o2))
					b = append(b[:p], o2[q:]...)
				}
			}
		}
		os.WriteFile(filepath.Join(out, fmt.Sprintf("m%05d.webp", i)), b, 0o644)
	}
	fmt.Printf("mutated %d files from %d seeds into %s\n", n, len(files), out)
}

// ---------------------------------------------------------------------------------------------

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: webpdiff digest|dwebp|gen|mutate ...")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "digest":
		for _, f := range os.Args[2:] {
			b, err := os.ReadFile(f)
			if err != nil {
				fmt.Println(f, "READFAIL")
				continue
			}
			fmt.Println(f, goDigest(b))
		}
	case "rgba": // webpdiff rgba <file> <out>: decoded RGBA8888 bytes (evidence / bisection)
		b, _ := os.ReadFile(os.Args[2])
		img, err := webp.Decode(bytes.NewReader(b))
		if err != nil {
			fmt.Println("ERR", err)
			return
		}
		px, _, _, _ := rgbaOf(img)
		os.WriteFile(os.Args[3], px, 0o644)
	case "dwebp":
		for _, f := range os.Args[2:] {
			fmt.Println(f, dwebpDigest(f))
		}
	case "ref":
		for _, f := range os.Args[2:] {
			fmt.Println(f, refDigest(f))
		}
	case "dwebp-yuv":
		for _, f := range os.Args[2:] {
			fmt.Println(f, dwebpYUVDigest(f))
		}
	case "gen":
		seed, _ := strconv.ParseInt(os.Args[3], 10, 64)
		nr, _ := strconv.Atoi(os.Args[4])
		gen(os.Args[2], seed, nr)
	case "mutate":
		seed, _ := strconv.ParseInt(os.Args[4], 10, 64)
		nm, _ := strconv.Atoi(os.Args[5])
		mutate(os.Args[2], os.Args[3], seed, nm)
	default:
		os.Exit(2)
	}
}
