// Differential oracle for packages/gif: Go 1.2x standard library image/gif + a browser-semantics compositor.
//
//	gifdiff gen <dir> <seed> <nrandom>      write the structured + random corpus (all inputs Go accepts)
//	gifdiff mutate <srcdir> <outdir> <seed> <n>  write n byte-level mutants of the corpus
//	gifdiff digest <file>...                one line per file, same format as `gif_audit digest`:
//	                                         "<file> OK <frames> <loop> <sha256>" | "<file> ERR <msg>" | "<file> SKIP <quirk>"
//
// sha256 is taken over, per frame: u16le delay, u8 disposal (4..7 -> 0), RGBA8888 full canvas.
// The GIF writer here is independent of both image/gif's encoder and packages/gif: it has its own LZW
// compressor (full-table Clear, Deferred Clear, literal-only, no-EOI, no leading Clear, random sub-block
// sizes) and writes interlaced frames, LCTs, GCEs and loop extensions explicitly.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"image"
	"image/color"
	"image/gif"
	"math/rand"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// ---------------------------------------------------------------------------
// LZW encoder (GIF flavour, LSB-first)
// ---------------------------------------------------------------------------

type lzwMode int

const (
	lzwNormal      lzwMode = iota // Clear at start, Clear when the table is full, EOI
	lzwDeferred                   // never Clear after the start: table stays full at 12 bits
	lzwLiteral                    // only literal codes (+ Clear when full)
	lzwNoLeadClear                // no leading Clear code
	lzwNoEOI                      // no EOI (pixels fill the frame exactly; Go and giflib accept this)
	lzwEarlyClears                // Clear every few hundred codes
)

type bitWriter struct {
	out   []byte
	acc   uint64
	nbits uint
}

func (w *bitWriter) put(code int, width uint) {
	w.acc |= uint64(code) << w.nbits
	w.nbits += width
	for w.nbits >= 8 {
		w.out = append(w.out, byte(w.acc))
		w.acc >>= 8
		w.nbits -= 8
	}
}

func (w *bitWriter) flush() []byte {
	if w.nbits > 0 {
		w.out = append(w.out, byte(w.acc))
	}
	return w.out
}

// lzwEncode is a classic greedy GIF LZW compressor. The encoder defines entry `hi` after every emitted code
// (the decoder defines the same entry one code later), so the decoder's read width for the next code is the
// encoder width after `if hi-1 >= 1<<width { width++ }`.
func lzwEncode(pix []byte, litWidth int, mode lzwMode, rng *rand.Rand) []byte {
	clear := 1 << litWidth
	eoi := clear + 1
	w := &bitWriter{}
	width := uint(litWidth + 1)
	hi := eoi + 1
	dict := map[[2]int]int{}
	sinceClear := 0
	reset := func() {
		w.put(clear, width)
		width = uint(litWidth + 1)
		hi = eoi + 1
		dict = map[[2]int]int{}
		sinceClear = 0
	}
	if mode != lzwNoLeadClear {
		w.put(clear, width)
	}
	emitted := 0
	cur := -1
	for _, pb := range pix {
		c := int(pb)
		if cur < 0 {
			cur = c
			continue
		}
		if mode != lzwLiteral {
			if code, ok := dict[[2]int{cur, c}]; ok {
				cur = code
				continue
			}
		}
		w.put(cur, width)
		emitted++
		sinceClear++
		if hi < 4096 {
			dict[[2]int{cur, c}] = hi
			hi++
			if hi-1 >= 1<<width && width < 12 {
				width++
			}
		}
		if hi >= 4096 && mode != lzwDeferred {
			reset()
		} else if mode == lzwEarlyClears && emitted%300 == 299 {
			reset()
		}
		cur = c
	}
	if cur >= 0 {
		w.put(cur, width)
		sinceClear++
		if sinceClear > 1 && hi < 4096 && hi >= 1<<width && width < 12 {
			width++
		}
	}
	// Without EOI, image/gif reads the final byte's zero padding as one more code when the padding is at least
	// one code wide ("too much image data"), so only omit EOI when the padding is narrower than a code.
	if mode != lzwNoEOI || (w.nbits > 0 && 8-w.nbits >= width) {
		w.put(eoi, width)
	}
	return w.flush()
}

func subBlocks(payload []byte, rng *rand.Rand, randomSizes bool) []byte {
	var out []byte
	for len(payload) > 0 {
		n := 255
		if randomSizes {
			n = 1 + rng.Intn(255)
		}
		if n > len(payload) {
			n = len(payload)
		}
		out = append(out, byte(n))
		out = append(out, payload[:n]...)
		payload = payload[n:]
	}
	return append(out, 0)
}

// ---------------------------------------------------------------------------
// GIF writer
// ---------------------------------------------------------------------------

type frameSpec struct {
	left, top, w, h int
	disposal        int
	hasTrans        bool
	trans           int
	delay           int
	interlaced      bool
	lct             []byte // RGB triples, len = 3 * 2^(bits+1)
	lctBits         int
	minCode         int
	pix             []byte // linear rows
	mode            lzwMode
	randomBlocks    bool
}

type gifSpec struct {
	w, h    int
	gct     []byte
	gctBits int
	loop    int // -1 = no NETSCAPE extension
	frames  []frameSpec
	comment bool
}

func interlaceRows(pix []byte, w, h int) []byte {
	out := make([]byte, 0, len(pix))
	for _, p := range [][2]int{{0, 8}, {4, 8}, {2, 4}, {1, 2}} {
		for y := p[0]; y < h; y += p[1] {
			out = append(out, pix[y*w:(y+1)*w]...)
		}
	}
	return out
}

func writeGIF(s gifSpec, rng *rand.Rand) []byte {
	var b bytes.Buffer
	b.WriteString("GIF89a")
	binary.Write(&b, binary.LittleEndian, uint16(s.w))
	binary.Write(&b, binary.LittleEndian, uint16(s.h))
	if s.gct != nil {
		b.WriteByte(0x80 | 0x70 | byte(s.gctBits))
	} else {
		b.WriteByte(0x70)
	}
	b.WriteByte(0)
	b.WriteByte(0)
	b.Write(s.gct)
	if s.loop >= 0 {
		b.Write([]byte{0x21, 0xFF, 11})
		b.WriteString("NETSCAPE2.0")
		b.Write([]byte{3, 1, byte(s.loop), byte(s.loop >> 8), 0})
	}
	if s.comment {
		b.Write([]byte{0x21, 0xFE, 5, 'r', 'e', 'd', 't', 'm', 0})
	}
	for _, f := range s.frames {
		packed := byte(f.disposal&7) << 2
		if f.hasTrans {
			packed |= 1
		}
		b.Write([]byte{0x21, 0xF9, 4, packed, byte(f.delay), byte(f.delay >> 8), byte(f.trans), 0})
		b.WriteByte(0x2C)
		for _, v := range []int{f.left, f.top, f.w, f.h} {
			binary.Write(&b, binary.LittleEndian, uint16(v))
		}
		fp := byte(0)
		if f.lct != nil {
			fp |= 0x80 | byte(f.lctBits)
		}
		if f.interlaced {
			fp |= 0x40
		}
		b.WriteByte(fp)
		b.Write(f.lct)
		b.WriteByte(byte(f.minCode))
		stream := f.pix
		if f.interlaced {
			stream = interlaceRows(f.pix, f.w, f.h)
		}
		b.Write(subBlocks(lzwEncode(stream, f.minCode, f.mode, rng), rng, f.randomBlocks))
	}
	b.WriteByte(0x3B)
	return b.Bytes()
}

func randTable(rng *rand.Rand, bits int) []byte {
	t := make([]byte, 3*(1<<(bits+1)))
	rng.Read(t)
	return t
}

func randFrame(rng *rand.Rand, cw, ch, gctBits int, hasGCT bool, big bool) frameSpec {
	var f frameSpec
	f.w = 1 + rng.Intn(cw)
	f.h = 1 + rng.Intn(ch)
	if rng.Intn(12) == 0 {
		f.w, f.h = 0, rng.Intn(ch+1)
	}
	if f.w > 0 {
		f.left = rng.Intn(cw - f.w + 1)
	}
	if f.h > 0 && f.h <= ch {
		f.top = rng.Intn(ch - f.h + 1)
	}
	f.disposal = rng.Intn(8)
	f.delay = rng.Intn(65536)
	f.interlaced = rng.Intn(3) == 0
	ncol := 1 << (gctBits + 1)
	if !hasGCT || rng.Intn(3) == 0 {
		f.lctBits = rng.Intn(8)
		f.lct = randTable(rng, f.lctBits)
		ncol = 1 << (f.lctBits + 1)
	}
	f.hasTrans = rng.Intn(2) == 0
	f.trans = rng.Intn(256)
	if rng.Intn(2) == 0 {
		f.trans = rng.Intn(ncol)
	}
	f.minCode = 2
	for 1<<f.minCode < ncol {
		f.minCode++
	}
	if rng.Intn(6) == 0 {
		f.minCode += rng.Intn(9 - f.minCode)
	}
	f.pix = make([]byte, f.w*f.h)
	style := rng.Intn(4)
	for i := range f.pix {
		switch style {
		case 0:
			f.pix[i] = byte(rng.Intn(ncol))
		case 1:
			f.pix[i] = byte((i / (1 + f.w/3)) % ncol)
		case 2:
			f.pix[i] = byte((i*7 + i/(f.w+1)) % ncol)
		default:
			if rng.Intn(10) == 0 {
				f.pix[i] = byte(rng.Intn(ncol))
			} else if i > 0 {
				f.pix[i] = f.pix[i-1]
			}
		}
	}
	f.mode = lzwMode(rng.Intn(6))
	if f.mode == lzwNoLeadClear && rng.Intn(2) == 0 {
		f.mode = lzwNormal
	}
	f.randomBlocks = rng.Intn(3) == 0
	return f
}

func randGIF(rng *rand.Rand, big bool) gifSpec {
	var s gifSpec
	maxDim := 48
	if big {
		maxDim = 400
	}
	s.w = 1 + rng.Intn(maxDim)
	s.h = 1 + rng.Intn(maxDim)
	hasGCT := rng.Intn(5) != 0
	if hasGCT {
		s.gctBits = rng.Intn(8)
		s.gct = randTable(rng, s.gctBits)
	}
	s.loop = -1
	if rng.Intn(2) == 0 {
		s.loop = rng.Intn(4)
	}
	s.comment = rng.Intn(4) == 0
	nf := 1 + rng.Intn(8)
	if big {
		nf = 1 + rng.Intn(3)
	}
	for i := 0; i < nf; i++ {
		s.frames = append(s.frames, randFrame(rng, s.w, s.h, s.gctBits, hasGCT, big))
	}
	return s
}

func structured(rng *rand.Rand) map[string][]byte {
	out := map[string][]byte{}
	pal4 := []byte{0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255}
	solid := func(n int, v byte) []byte { return bytes.Repeat([]byte{v}, n) }
	ramp := func(n, mod int) []byte {
		p := make([]byte, n)
		for i := range p {
			p[i] = byte(i % mod)
		}
		return p
	}
	fr := func(l, t, w, h, disp int, pix []byte, mode lzwMode) frameSpec {
		return frameSpec{left: l, top: t, w: w, h: h, disposal: disp, minCode: 2, pix: pix, mode: mode, delay: 10}
	}
	// disposal matrix
	for d := 0; d < 8; d++ {
		out[fmt.Sprintf("s_disposal_%d", d)] = writeGIF(gifSpec{w: 8, h: 6, gct: pal4, gctBits: 1, loop: 0, frames: []frameSpec{
			fr(0, 0, 8, 6, 1, ramp(48, 4), lzwNormal),
			fr(2, 1, 4, 4, d, solid(16, 2), lzwNormal),
			fr(3, 2, 5, 4, 1, ramp(20, 3), lzwNormal),
		}}, rng)
	}
	out["s_frame0_restore_previous"] = writeGIF(gifSpec{w: 5, h: 5, gct: pal4, gctBits: 1, loop: -1, frames: []frameSpec{
		fr(0, 0, 5, 5, 3, ramp(25, 4), lzwNormal), fr(1, 1, 2, 2, 3, solid(4, 3), lzwNormal), fr(0, 0, 1, 1, 0, []byte{1}, lzwNormal),
	}}, rng)
	tr := fr(0, 0, 4, 4, 2, ramp(16, 4), lzwNormal)
	tr.hasTrans, tr.trans = true, 1
	tr2 := fr(1, 1, 3, 3, 1, ramp(9, 4), lzwNormal)
	tr2.hasTrans, tr2.trans = true, 9 // transparent index outside the 4-colour palette
	out["s_transparency"] = writeGIF(gifSpec{w: 4, h: 4, gct: pal4, gctBits: 1, loop: 3, frames: []frameSpec{fr(0, 0, 4, 4, 1, solid(16, 3), lzwNormal), tr, tr2}}, rng)
	for _, sz := range [][2]int{{1, 1}, {1, 5}, {2, 2}, {3, 7}, {5, 9}, {8, 17}, {33, 2}} {
		f := fr(0, 0, sz[0], sz[1], 1, ramp(sz[0]*sz[1], 4), lzwNormal)
		f.interlaced = true
		out[fmt.Sprintf("s_interlace_%dx%d", sz[0], sz[1])] = writeGIF(gifSpec{w: sz[0], h: sz[1], gct: pal4, gctBits: 1, loop: -1, frames: []frameSpec{f}}, rng)
	}
	// LZW stress: 12-bit width, full table with Clear, Deferred Clear, literal-only, KwKwK runs, no EOI
	pal256 := randTable(rng, 7)
	noise := make([]byte, 256*256)
	rng.Read(noise)
	runs := make([]byte, 300*300)
	for i := range runs {
		runs[i] = byte((i / 97) % 256)
	}
	modes := []struct {
		name string
		m    lzwMode
	}{{"normal", lzwNormal}, {"deferred", lzwDeferred}, {"literal", lzwLiteral}, {"nolead", lzwNoLeadClear}, {"noeoi", lzwNoEOI}, {"earlyclear", lzwEarlyClears}}
	for _, nm := range modes { // fixed order: the corpus must be reproducible from the seed
		name, m := nm.name, nm.m
		f := frameSpec{w: 256, h: 256, minCode: 8, pix: noise, mode: m, disposal: 1}
		out["s_lzw_noise_"+name] = writeGIF(gifSpec{w: 256, h: 256, gct: pal256, gctBits: 7, loop: -1, frames: []frameSpec{f}}, rng)
		g := frameSpec{w: 300, h: 300, minCode: 8, pix: runs, mode: m, disposal: 1, randomBlocks: true}
		out["s_lzw_runs_"+name] = writeGIF(gifSpec{w: 300, h: 300, gct: pal256, gctBits: 7, loop: -1, frames: []frameSpec{g}}, rng)
	}
	zeros := make([]byte, 512*512)
	out["s_lzw_kwkwk_zeros_512"] = writeGIF(gifSpec{w: 512, h: 512, gct: pal4, gctBits: 1, loop: -1, frames: []frameSpec{{w: 512, h: 512, minCode: 2, pix: zeros, mode: lzwDeferred, disposal: 1}}}, rng)
	for mc := 2; mc <= 8; mc++ {
		p := make([]byte, 40*30)
		for i := range p {
			p[i] = byte(i % 4)
		}
		out[fmt.Sprintf("s_min_code_size_%d", mc)] = writeGIF(gifSpec{w: 40, h: 30, gct: pal4, gctBits: 1, loop: -1, frames: []frameSpec{{w: 40, h: 30, minCode: mc, pix: p, mode: lzwNormal, disposal: 1}}}, rng)
	}
	// LCT-only GIF, max-size tables
	lf := frameSpec{w: 16, h: 16, minCode: 8, lct: randTable(rng, 7), lctBits: 7, pix: ramp(256, 256), mode: lzwNormal, disposal: 1}
	out["s_lct_only"] = writeGIF(gifSpec{w: 16, h: 16, loop: -1, frames: []frameSpec{lf, fr(4, 4, 2, 2, 1, []byte{0, 1, 2, 3}, lzwNormal)}}, rng)
	out["s_lct_only"] = writeGIF(gifSpec{w: 16, h: 16, loop: -1, frames: []frameSpec{lf, func() frameSpec {
		f := fr(4, 4, 2, 2, 1, []byte{0, 1, 2, 3}, lzwNormal)
		f.lct, f.lctBits = pal4, 1
		return f
	}()}}, rng)
	// image/gif's own encoder (a third, independent LZW writer)
	{
		pal := make(color.Palette, 256)
		for i := range pal {
			pal[i] = color.RGBA{byte(i * 3), byte(255 - i), byte(i * 7), 255}
		}
		g := &gif.GIF{LoopCount: 2, Config: image.Config{ColorModel: pal, Width: 200, Height: 150}}
		for f := 0; f < 6; f++ {
			r := image.Rect(f*10, f*7, f*10+120, f*7+90)
			m := image.NewPaletted(r, pal)
			for i := range m.Pix {
				m.Pix[i] = byte((i/(3+f) + f*31) % 256)
			}
			g.Image = append(g.Image, m)
			g.Delay = append(g.Delay, 3+f)
			g.Disposal = append(g.Disposal, byte([]int{1, 2, 3, 1, 3, 2}[f]))
		}
		var eb bytes.Buffer
		if err := gif.EncodeAll(&eb, g); err == nil {
			out["s_go_encoder_anim"] = eb.Bytes()
		}
	}
	return out
}

// ---------------------------------------------------------------------------
// Mutation
// ---------------------------------------------------------------------------

func mutate(src []byte, rng *rand.Rand) []byte {
	d := append([]byte(nil), src...)
	n := 1 + rng.Intn(4)
	for k := 0; k < n && len(d) > 13; k++ {
		p := 13 + rng.Intn(len(d)-13)
		switch rng.Intn(9) {
		case 0:
			d[p] ^= 1 << uint(rng.Intn(8))
		case 1:
			d[p] = byte(rng.Intn(256))
		case 2:
			d[p] = []byte{0, 1, 0xFF, 0x2C, 0x21, 0x3B, 0xF9, 4, 5, 0x80}[rng.Intn(10)]
		case 3:
			d = d[:p]
		case 4:
			d = append(d[:p], d[p+1+rng.Intn(min(8, len(d)-p)):]...)
		case 5:
			ins := make([]byte, 1+rng.Intn(6))
			rng.Read(ins)
			d = append(d[:p], append(ins, d[p:]...)...)
		case 6:
			q := 13 + rng.Intn(len(d)-13)
			l := 1 + rng.Intn(40)
			if q+l > len(d) {
				l = len(d) - q
			}
			chunk := append([]byte(nil), d[q:q+l]...)
			d = append(d[:p], append(chunk, d[p:]...)...)
		case 7:
			// header fields: canvas size / packed
			h := 6 + rng.Intn(7)
			d[h] = byte(rng.Intn(256))
		case 8:
			if len(d) > 1 {
				d = d[:len(d)-1-rng.Intn(min(3, len(d)-1))]
			}
		}
	}
	return d
}

// ---------------------------------------------------------------------------
// Go reference decode + composite
// ---------------------------------------------------------------------------

// quirks walks the block structure and reports constructs where image/gif deliberately deviates from
// GIF89a / browser behaviour, so the digest is not comparable:
//   - an image without its own GCE (image/gif carries the previous disposal method forward)
//   - a Plain Text extension (image/gif does not reset a pending GCE on it)
//   - a NETSCAPE2.0 loop sub-block whose length is not 3
//
// It also returns the colour-table size in effect for each image, used to spot out-of-range indices.
func quirks(d []byte) (string, []int) {
	var tables []int
	if len(d) < 13 {
		return "", tables
	}
	p := 13
	gctSize := 0
	if d[10]&0x80 != 0 {
		gctSize = 1 << (uint(d[10]&7) + 1)
		p += 3 * gctSize
	}
	gce := false
	skip := func(p int) int {
		for p < len(d) {
			n := int(d[p])
			p++
			if n == 0 {
				return p
			}
			p += n
		}
		return p
	}
	for p < len(d) {
		c := d[p]
		p++
		switch c {
		case 0x21:
			if p >= len(d) {
				return "", tables
			}
			label := d[p]
			p++
			if label == 0xF9 {
				gce = true
			}
			if label == 0x01 {
				return "plain-text-gce", tables
			}
			if label == 0xFF && p+12 <= len(d) && d[p] == 11 && string(d[p+1:p+12]) == "NETSCAPE2.0" {
				if p+12 < len(d) && d[p+12] != 3 {
					return "netscape-subblock-len", tables
				}
			}
			p = skip(p)
		case 0x2C:
			if !gce {
				return "image-without-gce", tables
			}
			gce = false
			if p+9 > len(d) {
				return "", tables
			}
			fl := d[p+8]
			p += 9
			if fl&0x80 != 0 {
				n := 1 << (uint(fl&7) + 1)
				tables = append(tables, n)
				p += 3 * n
			} else {
				tables = append(tables, gctSize)
			}
			p++ // min code size
			p = skip(p)
		default:
			return "", tables
		}
	}
	return "", tables
}

func digest(data []byte) string {
	q, tables := quirks(data)
	if q != "" {
		return "SKIP " + q
	}
	g, buf, err := digestBuf(data)
	if err != nil {
		return "ERR " + strings.ReplaceAll(err.Error(), " ", "_")
	}
	// image/gif pads the palette with *transparent* entries up to an out-of-range transparent index, so
	// indices between the table size and that index decode as transparent instead of errBadPixel.
	// Out-of-range indices have no defined colour (packages/gif paints opaque black): not comparable.
	for i, m := range g.Image {
		if i < len(tables) {
			for _, px := range m.Pix {
				if int(px) >= tables[i] {
					return "SKIP oob-palette-index"
				}
			}
		}
	}
	sum := sha256.Sum256(buf)
	return fmt.Sprintf("OK %d %d %s %dx%d", len(g.Image), g.LoopCount, hex.EncodeToString(sum[:]), g.Config.Width, g.Config.Height)
}

// digestBuf returns the digested stream: per frame u16le delay, u8 disposal, RGBA8888 canvas.
func digestBuf(data []byte) (*gif.GIF, []byte, error) {
	g, err := gif.DecodeAll(bytes.NewReader(data))
	if err != nil {
		return nil, nil, err
	}
	cw, ch := g.Config.Width, g.Config.Height
	canvas := make([]byte, cw*ch*4)
	h := &bytes.Buffer{}
	for fi, m := range g.Image {
		b := m.Bounds()
		disp := 0
		if fi < len(g.Disposal) {
			disp = int(g.Disposal[fi])
		}
		var saved []byte
		if disp == 3 {
			saved = append([]byte(nil), canvas...)
		}
		var pal [256][4]byte
		for i, c := range m.Palette {
			if i >= 256 {
				break
			}
			r, gg, bb, a := c.RGBA()
			pal[i] = [4]byte{byte(r >> 8), byte(gg >> 8), byte(bb >> 8), byte(a >> 8)}
		}
		for y := b.Min.Y; y < b.Max.Y; y++ {
			for x := b.Min.X; x < b.Max.X; x++ {
				ci := m.Pix[(y-b.Min.Y)*m.Stride+(x-b.Min.X)]
				c := pal[ci]
				if c[3] == 0 {
					continue
				}
				o := (y*cw + x) * 4
				canvas[o], canvas[o+1], canvas[o+2], canvas[o+3] = c[0], c[1], c[2], 255
			}
		}
		dd := disp
		if dd > 3 {
			dd = 0
		}
		delay := g.Delay[fi]
		h.Write([]byte{byte(delay), byte(delay >> 8), byte(dd)})
		h.Write(canvas)
		if disp == 2 {
			for y := b.Min.Y; y < b.Max.Y; y++ {
				for x := b.Min.X; x < b.Max.X; x++ {
					o := (y*cw + x) * 4
					copy(canvas[o:o+4], []byte{0, 0, 0, 0})
				}
			}
		} else if disp == 3 {
			copy(canvas, saved)
		}
	}
	return g, h.Bytes(), nil
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: gifdiff gen|mutate|digest ...")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "gen":
		dir := os.Args[2]
		seed, _ := strconv.ParseInt(os.Args[3], 10, 64)
		n, _ := strconv.Atoi(os.Args[4])
		rng := rand.New(rand.NewSource(seed))
		os.MkdirAll(dir, 0o755)
		files := structured(rng)
		for i := 0; i < n; i++ {
			files[fmt.Sprintf("r_%05d", i)] = writeGIF(randGIF(rng, i%25 == 0), rng)
		}
		names := make([]string, 0, len(files))
		for k := range files {
			names = append(names, k)
		}
		sort.Strings(names)
		for _, k := range names {
			if err := os.WriteFile(filepath.Join(dir, k+".gif"), files[k], 0o644); err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
		}
		fmt.Printf("gen: %d files\n", len(names))
	case "mutate":
		src, dst := os.Args[2], os.Args[3]
		seed, _ := strconv.ParseInt(os.Args[4], 10, 64)
		n, _ := strconv.Atoi(os.Args[5])
		rng := rand.New(rand.NewSource(seed))
		ents, _ := filepath.Glob(filepath.Join(src, "*.gif"))
		sort.Strings(ents)
		var corpus [][]byte
		for _, e := range ents {
			b, _ := os.ReadFile(e)
			if len(b) < 200000 {
				corpus = append(corpus, b)
			}
		}
		os.MkdirAll(dst, 0o755)
		for i := 0; i < n; i++ {
			m := mutate(corpus[rng.Intn(len(corpus))], rng)
			os.WriteFile(filepath.Join(dst, fmt.Sprintf("m_%06d.gif", i)), m, 0o644)
		}
		fmt.Printf("mutate: %d files\n", n)
	case "dump":
		b, _ := os.ReadFile(os.Args[2])
		_, buf, err := digestBuf(b)
		if err != nil {
			fmt.Println("ERR", err)
			return
		}
		os.WriteFile(os.Args[3], buf, 0o644)
	case "digest":
		for _, f := range os.Args[2:] {
			b, err := os.ReadFile(f)
			if err != nil {
				fmt.Printf("%s READFAIL\n", f)
				continue
			}
			fmt.Printf("%s %s\n", f, digest(b))
		}
	default:
		os.Exit(2)
	}
}
