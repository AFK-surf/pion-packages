package main

import (
	"bytes"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// ---------------------------------------------------------------------------
// Writer-differential spec
// ---------------------------------------------------------------------------

type sh struct {
	tf                   byte
	name, link           string
	size, mode, uid, gid int64
	uname, gname         string
	mtime, atime, ctime  string // "-" or "sec:nsec"
	devmaj, devmin       int64
	format               string
	pax, xattr           [][2]string
	datalen              int
}

func hx(s string) string {
	if s == "" {
		return "-"
	}
	return hex.EncodeToString([]byte(s))
}

func kvs(p [][2]string) string {
	if len(p) == 0 {
		return "-"
	}
	var parts []string
	for _, kv := range p {
		parts = append(parts, hex.EncodeToString([]byte(kv[0]))+"="+hex.EncodeToString([]byte(kv[1])))
	}
	return strings.Join(parts, ",")
}

func (h sh) line(i int) string {
	f := h.format
	if f == "" {
		f = "unknown"
	}
	t := func(s string) string {
		if s == "" {
			return "-"
		}
		return s
	}
	return fmt.Sprintf("H %d %s %s %d %d %d %d %s %s %s %s %s %d %d %s %s %s %d %d",
		h.tf, hx(h.name), hx(h.link), h.size, h.mode, h.uid, h.gid, hx(h.uname), hx(h.gname),
		t(h.mtime), t(h.atime), t(h.ctime), h.devmaj, h.devmin, f, kvs(h.pax), kvs(h.xattr), h.datalen, i)
}

func reg(name string, size int) sh {
	return sh{tf: '0', name: name, size: int64(size), mode: 0o644, datalen: size, mtime: "1700000000:0"}
}

func rep(s string, n int) string { return strings.Repeat(s, n) }

// genSpec returns a header spec exercising every Writer format decision of Go's allowedFormats.
func genSpec() string {
	var hs []sh
	add := func(h sh) { hs = append(hs, h) }

	// --- USTAR name / prefix splitting boundaries ---
	for _, n := range []int{1, 99, 100, 101, 154, 155, 156, 254, 255, 256, 257, 300} {
		add(reg(rep("a", n), 3))                                     // no slash at all
		add(reg(rep("d", n/2)+"/"+rep("f", n-n/2-1), 5))             // one slash in the middle
		add(reg(rep("p", 155)+"/"+rep("f", max(1, n-156)), 7))       // prefix exactly 155
		add(reg(rep("p", 154)+"/"+rep("f", max(1, n-155)), 7))       // prefix 154
		add(reg(rep("p", 156)+"/"+rep("f", max(1, n-157)), 7))       // prefix 156 (cannot split)
		add(reg(rep("p", 50)+"/"+rep("q", 50)+"/"+rep("f", 100), 1)) // two slashes, suffix 100
		add(reg(rep("p", 50)+"/"+rep("q", 50)+"/"+rep("f", 101), 1)) // suffix 101
		d := sh{tf: '5', name: rep("d", n) + "/", mode: 0o755, mtime: "1700000000:0"}
		add(d) // directory trailing slash at every boundary
		d2 := sh{tf: '5', name: rep("x", 60) + "/" + rep("y", max(1, n-62)) + "/", mode: 0o755}
		add(d2)
	}
	add(reg("/"+rep("a", 120), 1))                                          // leading slash (prefix would be empty)
	add(reg(rep("a", 100)+"/b", 1))                                         // slash at index 100
	add(reg("dir//"+rep("f", 120), 1))                                      // double slash
	add(reg("./"+rep("f", 120), 1))                                         // dot prefix -> PaxHeaders name cleaning
	add(reg("a/../"+rep("f", 120), 1))                                      // dotdot -> PaxHeaders name cleaning
	add(reg("日本語/ファイル.txt", 4))                                             // UTF-8 short
	add(reg(rep("日本", 30)+"/x", 4))                                         // UTF-8 long
	add(reg("raw\xff\xfe\x80name", 2))                                      // invalid UTF-8 short
	add(reg(rep("\xff", 120), 2))                                           // invalid UTF-8 long
	add(sh{tf: '0', name: "trailing/", size: 0, mode: 0o644})               // regular + trailing slash: error
	add(sh{tf: 0, name: "rega-dir/", mode: 0o755})                          // TypeRegA promoted to dir
	add(sh{tf: 0, name: "rega-file", size: 3, mode: 0o644, datalen: 3})     // TypeRegA promoted to reg
	add(sh{tf: '7', name: "contig", size: 9, mode: 0o644, datalen: 9})      // contiguous file
	add(sh{tf: 'A', name: "vendor-type", size: 9, mode: 0o644, datalen: 9}) // unknown vendor typeflag
	add(sh{tf: 'x', name: "manual-x", mode: 0o644})                         // must error
	add(sh{tf: 'L', name: "manual-L", mode: 0o644})                         // must error
	add(sh{tf: 'K', name: "manual-K", mode: 0o644})                         // must error
	add(sh{tf: '0', name: "neg", size: -1, mode: 0o644})                    // negative size: error
	add(sh{tf: '5', name: "dir-neg-size", size: -1, mode: 0o755})           // header-only negative size

	// --- links ---
	add(sh{tf: '2', name: "sym", link: rep("t", 100), mode: 0o777})
	add(sh{tf: '2', name: "sym2", link: rep("t", 101), mode: 0o777})
	add(sh{tf: '2', name: "sym3", link: "目标", mode: 0o777})
	add(sh{tf: '1', name: "hard", link: rep("h", 300), mode: 0o644})
	add(sh{tf: '2', name: "symgnu", link: rep("t", 150), mode: 0o777, format: "gnu"})
	add(sh{tf: '2', name: "symustar", link: rep("t", 150), mode: 0o777, format: "ustar"})

	// --- numeric boundaries ---
	for _, v := range []int64{0, 2097151, 2097152, 1 << 32, 1 << 40, -1, -2097152} {
		add(sh{tf: '0', name: "uid" + strconv.FormatInt(v, 10), uid: v, gid: v, mode: 0o644, size: 1, datalen: 1})
	}
	for _, v := range []int64{0o7777, 0o777777, 0o7777777, 0o10000000, -1, 1 << 40} {
		add(sh{tf: '0', name: "mode" + strconv.FormatInt(v, 8), mode: v, size: 1, datalen: 1})
	}
	for _, v := range []int64{0, 2097151, 2097152, -1, 1 << 40} {
		add(sh{tf: '3', name: "chr" + strconv.FormatInt(v, 10), devmaj: v, devmin: v / 2, mode: 0o600})
		add(sh{tf: '4', name: "blk" + strconv.FormatInt(v, 10), devmaj: v, devmin: v, mode: 0o600, format: "gnu"})
	}
	add(sh{tf: '5', name: "bigdir", size: 1 << 34, mode: 0o755}) // header-only with >8GiB size
	add(sh{tf: '5', name: "bigdir-ustar", size: 1 << 34, mode: 0o755, format: "ustar"})
	add(sh{tf: '2', name: "bigsym", link: "x", size: 1 << 40, mode: 0o777, format: "gnu"})
	add(sh{tf: '0', name: "u32", uname: rep("u", 32), gname: rep("g", 32), mode: 0o644})
	add(sh{tf: '0', name: "u33", uname: rep("u", 33), gname: rep("g", 33), mode: 0o644})
	add(sh{tf: '0', name: "u33gnu", uname: rep("u", 33), mode: 0o644, format: "gnu"}) // must error
	add(sh{tf: '0', name: "uutf8", uname: "用户", gname: "组", mode: 0o644})

	// --- timestamps (the sign traps) ---
	times := []string{"0:0", "1:0", "-1:0", "1:500000000", "-1:500000000", "-2:500000000", "-2:750000000",
		"0:-500000000", "0:-1250000000", "1700000000:999999999", "-1700000000:1", "8589934591:0",
		"8589934592:0", "-8589934592:0", "1099511627776:123", "-1099511627776:0"}
	for i, ts := range times {
		for _, f := range []string{"unknown", "ustar", "pax", "gnu"} {
			add(sh{tf: '0', name: fmt.Sprintf("t%02d-%s", i, f), mtime: ts, mode: 0o644, format: f, size: 1, datalen: 1})
		}
		add(sh{tf: '0', name: fmt.Sprintf("tac%02d-pax", i), mtime: ts, atime: ts, ctime: ts, mode: 0o644, format: "pax"})
		add(sh{tf: '0', name: fmt.Sprintf("tac%02d-gnu", i), mtime: ts, atime: ts, ctime: ts, mode: 0o644, format: "gnu"})
		add(sh{tf: '0', name: fmt.Sprintf("tac%02d-unk", i), mtime: ts, atime: ts, ctime: ts, mode: 0o644})
	}

	// --- explicit formats with things they cannot encode ---
	add(sh{tf: '0', name: rep("u", 300), mode: 0o644, format: "ustar"}) // error
	add(sh{tf: '0', name: rep("g", 300), mode: 0o644, format: "gnu", size: 2, datalen: 2})
	add(sh{tf: '0', name: rep("p", 300), mode: 0o644, format: "pax", size: 2, datalen: 2})
	add(sh{tf: '0', name: "über", mode: 0o644, format: "ustar"}) // error
	add(sh{tf: '0', name: "über-gnu", mode: 0o644, format: "gnu"})
	add(sh{tf: '0', name: "pax-plain", mode: 0o644, format: "pax", mtime: "5:0"})

	// --- PAX records / xattrs ---
	add(sh{tf: '0', name: "xattr", mode: 0o644, xattr: [][2]string{{"user.a", "1"}, {"security.selinux", "ctx\x00"}}})
	add(sh{tf: '0', name: "paxrec", mode: 0o644, pax: [][2]string{{"comment", "hi"}, {"zz.vendor", "v"}, {"SCHILY.xattr.user.b", "2"}}})
	add(sh{tf: '0', name: "paxpath-match", mode: 0o644, pax: [][2]string{{"path", "paxpath-match"}}})
	add(sh{tf: '0', name: "paxpath-mismatch", mode: 0o644, pax: [][2]string{{"path", "evil/../../x"}}})
	add(sh{tf: '0', name: "paxuid-match", uid: 7, mode: 0o644, pax: [][2]string{{"uid", "7"}, {"gid", "0"}, {"size", "0"}}})
	add(sh{tf: '0', name: "paxmtime-match", mtime: "5:0", mode: 0o644, pax: [][2]string{{"mtime", "5"}}})
	add(sh{tf: '0', name: "paxatime-match", mtime: "5:0", atime: "6:0", mode: 0o644, format: "pax", pax: [][2]string{{"atime", "6"}}})
	add(sh{tf: '0', name: "paxsparse-ignored", mode: 0o644, pax: [][2]string{{"GNU.sparse.map", "0,1"}, {"GNU.sparse.major", "1"}}})
	add(sh{tf: '0', name: "paxbadkey", mode: 0o644, pax: [][2]string{{"a=b", "c"}}})                 // error
	add(sh{tf: '0', name: "paxnulpath", mode: 0o644, pax: [][2]string{{"path", "a\x00b"}}})          // ignored (mismatch)
	add(sh{tf: '0', name: "paxnulkey", mode: 0o644, pax: [][2]string{{"k\x00", "v"}}})               // error
	add(sh{tf: '0', name: "paxemptykey", mode: 0o644, pax: [][2]string{{"", "v"}}})                  // error
	add(sh{tf: '0', name: "paxgnu", mode: 0o644, format: "gnu", pax: [][2]string{{"comment", "x"}}}) // error
	add(sh{tf: '0', name: "paxbig", mode: 0o644, pax: [][2]string{{"comment", rep("c", 70000)}}})
	add(sh{tf: '0', name: "paxlen", mode: 0o644, pax: [][2]string{{"k", rep("v", 993)}, {"k2", rep("v", 89)}, {"k3", rep("w", 9993)}}})

	// --- global headers ---
	add(sh{tf: 'g', pax: [][2]string{{"comment", "global"}, {"mtime", "1.5"}}})
	add(sh{tf: 'g', name: "global-named", pax: [][2]string{{"path", "gp"}}})
	add(sh{tf: 'g'})
	add(sh{tf: 'g', name: "global-with-mode", mode: 0o644, pax: [][2]string{{"a", "b"}}}) // Go: error (only PAXRecords may be set)
	add(sh{tf: 'g', name: "global-with-size", size: 10, pax: [][2]string{{"a", "b"}}})    // Go: error
	add(sh{tf: 'g', name: "global-gnu", format: "gnu", pax: [][2]string{{"a", "b"}}})     // error
	add(sh{tf: 'g', name: "global-xattr", xattr: [][2]string{{"user.g", "1"}}})

	var sb strings.Builder
	for i, h := range hs {
		sb.WriteString(h.line(i))
		sb.WriteByte('\n')
	}
	return sb.String()
}

// ---------------------------------------------------------------------------
// Adversarial reader corpus (raw, hand-crafted blocks)
// ---------------------------------------------------------------------------

type blk [512]byte

func setStr(b []byte, s string) { copy(b, s) }

func setOct(b []byte, v int64) {
	s := strconv.FormatInt(v, 8)
	for len(s) < len(b)-1 {
		s = "0" + s
	}
	copy(b, s)
	b[len(b)-1] = 0
}

func setB256(b []byte, v int64) {
	for i := len(b) - 1; i >= 0; i-- {
		b[i] = byte(v)
		v >>= 8
	}
	b[0] |= 0x80
}

func (b *blk) chk() *blk {
	fixChecksum(b[:])
	return b
}

const (
	mUSTAR = "ustar\x0000"
	mGNU   = "ustar  \x00"
	mV7    = ""
)

func hdr(name string, tf byte, size int64, magic string) *blk {
	var b blk
	setStr(b[0:100], name)
	setOct(b[100:108], 0o644)
	setOct(b[108:116], 1000)
	setOct(b[116:124], 1000)
	setOct(b[124:136], size)
	setOct(b[136:148], 1700000000)
	b[156] = tf
	copy(b[257:265], magic)
	if magic != "" {
		setOct(b[329:337], 0)
		setOct(b[337:345], 0)
	}
	return &b
}

func pad(n int) []byte { return make([]byte, (512-n%512)%512) }

func rec(k, v string) string {
	base := len(k) + len(v) + 3
	n := base + len(strconv.Itoa(base))
	if base+len(strconv.Itoa(n)) != n {
		n = base + len(strconv.Itoa(n))
	}
	return strconv.Itoa(n) + " " + k + "=" + v + "\n"
}

type arc struct{ bytes.Buffer }

func (a *arc) block(b *blk) *arc { a.Write(b.chk()[:]); return a }
func (a *arc) data(d []byte) *arc {
	a.Write(d)
	a.Write(pad(len(d)))
	return a
}
func (a *arc) file(name string, d []byte) *arc {
	return a.block(hdr(name, '0', int64(len(d)), mUSTAR)).data(d)
}
func (a *arc) pax(tf byte, recs string) *arc {
	return a.block(hdr("PaxHeaders.0/x", tf, int64(len(recs)), mUSTAR)).data([]byte(recs))
}
func (a *arc) gnuLong(tf byte, s string) *arc {
	return a.block(hdr("././@LongLink", tf, int64(len(s)), mGNU)).data([]byte(s))
}
func (a *arc) end() []byte { a.Write(make([]byte, 1024)); return a.Bytes() }

func sparseOld(name string, realSize int64, entries [][2]int64, ext [][][2]int64, phys []byte) []byte {
	b := hdr(name, 'S', int64(len(phys)), mGNU)
	for i, e := range entries {
		o := 386 + i*24
		setOct(b[o:o+12], e[0])
		setOct(b[o+12:o+24], e[1])
	}
	if len(ext) > 0 {
		b[482] = 1
	}
	setOct(b[483:495], realSize)
	var a arc
	a.block(b)
	for i, eb := range ext {
		var x blk
		for j, e := range eb {
			o := j * 24
			setOct(x[o:o+12], e[0])
			setOct(x[o+12:o+24], e[1])
		}
		if i+1 < len(ext) {
			x[504] = 1
		}
		a.Write(x[:])
	}
	a.data(phys)
	return a.end()
}

func genCorpus(dir string) {
	must(os.MkdirAll(dir, 0o755))
	cases := map[string][]byte{}
	put := func(name string, b []byte) { cases[name] = b }
	d5 := []byte("hello")

	// --- EOF / trailer semantics ---
	put("eof-none", new(arc).file("a", d5).Bytes())
	put("eof-one-zero-block", append(new(arc).file("a", d5).Bytes(), make([]byte, 512)...))
	put("eof-zero-then-garbage", append(append(new(arc).file("a", d5).Bytes(), make([]byte, 512)...), bytes.Repeat([]byte{7}, 512)...))
	put("eof-two-zero-then-garbage", append(new(arc).file("a", d5).end(), []byte("trailing garbage")...))
	put("eof-zero-then-partial", append(append(new(arc).file("a", d5).Bytes(), make([]byte, 512)...), make([]byte, 100)...))
	put("eof-data-pad-truncated", new(arc).file("a", d5).Bytes()[:512+5+100])
	put("eof-data-pad-truncated-1", new(arc).file("a", d5).Bytes()[:1023])
	put("eof-pax-pad-truncated", func() []byte {
		a := new(arc).pax('x', rec("path", "p"))
		return a.Bytes()[:512+len(rec("path", "p"))+3]
	}())
	put("eof-gnulong-pad-truncated", new(arc).gnuLong('L', "longname\x00").Bytes()[:512+20])
	put("eof-header-partial", new(arc).file("a", d5).Bytes()[:300])

	// --- checksum / numeric parsing ---
	{
		b := hdr("signed", '0', 0, mUSTAR)
		b[0] = 's'
		b[300] = 0xff // high byte -> signed vs unsigned sums differ
		sum := 0
		for i, c := range b {
			if i >= 148 && i < 156 {
				sum += 32
			} else {
				sum += int(int8(c))
			}
		}
		var a arc
		copy(b[148:156], fmt.Sprintf("%06o\x00 ", sum))
		a.Write(b[:])
		put("chk-signed-only", a.end())
	}
	{
		b := hdr("badchk", '0', 0, mUSTAR).chk()
		b[148]++
		var a arc
		a.Write(b[:])
		put("chk-wrong", a.end())
	}
	{
		b := hdr("chkspaces", '0', 0, mUSTAR).chk()
		s := string(b[148:154])
		copy(b[148:156], "  "+strings.TrimLeft(s, "0")+"\x00\x00\x00\x00\x00\x00\x00\x00"[:8-2-len(strings.TrimLeft(s, "0"))])
		var a arc
		a.Write(b[:])
		put("chk-leading-spaces", a.end())
	}
	{
		b := hdr("octsp", '0', 5, mUSTAR)
		copy(b[124:136], "     5      ")
		put("num-octal-space-padded", new(arc).block(b).data(d5).end())
	}
	{
		b := hdr("octembed", '0', 5, mUSTAR)
		copy(b[124:136], "0000 000005\x00")
		put("num-octal-embedded-space", new(arc).block(b).data(d5).end())
	}
	{
		b := hdr("octnul", '0', 5, mUSTAR)
		copy(b[124:136], "5\x00garbage!!\x00")
		put("num-octal-nul-then-garbage", new(arc).block(b).data(d5).end())
	}
	{
		b := hdr("nonul", '0', 5, mUSTAR)
		copy(b[124:136], "000000000005")
		put("num-no-nul-terminator", new(arc).block(b).data(d5).end())
	}
	{
		b := hdr("plus", '0', 5, mUSTAR)
		copy(b[124:136], "+0000000005\x00")
		put("num-octal-plus", new(arc).block(b).data(d5).end())
	}
	{
		b := hdr("b256size", '0', 0, mGNU)
		setB256(b[124:136], 5)
		setB256(b[136:148], -1234567890123)
		setB256(b[108:116], 1<<40)
		put("num-base256-fields", new(arc).block(b).data(d5).end())
	}
	{
		b := hdr("huge", '0', 0, mGNU)
		setB256(b[124:136], 9<<30) // 9 GiB, data truncated
		put("num-base256-9gib-truncated", new(arc).block(b).data(d5).Bytes())
	}
	{
		b := hdr("negmtime", '0', 5, mGNU)
		setB256(b[136:148], -1)
		put("num-negative-mtime", new(arc).block(b).data(d5).end())
	}

	// --- formats ---
	put("fmt-v7", new(arc).block(hdr("v7file", '0', 5, mV7)).data(d5).end())
	put("fmt-v7-dir-rega", new(arc).block(hdr("v7dir/", 0, 0, mV7)).end())
	{
		b := hdr("starfile", '0', 5, mUSTAR)
		copy(b[508:512], "tar\x00")
		setOct(b[476:488], 0)
		setOct(b[488:500], 1700000001)
		put("fmt-star", new(arc).block(b).data(d5).end())
	}
	{
		b := hdr("ustar-nonascii-\xe2\x82\xac", '0', 5, mUSTAR)
		put("fmt-ustar-nonascii", new(arc).block(b).data(d5).end())
	}
	{
		b := hdr("gnu-badtimes", '0', 5, mGNU)
		copy(b[345:357], "prefixdir\x00zz")
		put("fmt-gnu-atime-garbage-prefix-fallback", new(arc).block(b).data(d5).end())
	}
	{
		b := hdr("gnu-atime", '0', 5, mGNU)
		setOct(b[345:357], 1600000000)
		setOct(b[357:369], 1600000001)
		put("fmt-gnu-atime-ctime", new(arc).block(b).data(d5).end())
	}
	{
		b := hdr(rep("n", 100), '0', 5, mUSTAR) // name field with no NUL
		copy(b[345:500], rep("p", 155))         // prefix field with no NUL
		put("ustar-name100-prefix155", new(arc).block(b).data(d5).end())
	}
	{
		b := hdr("name\x00garbage", '0', 5, mUSTAR)
		put("name-nul-garbage", new(arc).block(b).data(d5).end())
	}
	put("typeflag-unknown-Z", new(arc).block(hdr("zz", 'Z', 5, mUSTAR)).data(d5).end())
	put("typeflag-S-in-ustar", new(arc).block(hdr("ss", 'S', 5, mUSTAR)).data(d5).end())
	put("dir-with-size", new(arc).block(hdr("dir/", '5', 5, mUSTAR)).file("after", d5).end())
	put("symlink-with-size", new(arc).block(hdr("sl", '2', 600, mUSTAR)).file("after", d5).end())

	// --- PAX semantics ---
	put("pax-global-then-x-then-file", new(arc).pax('g', rec("path", "gpath")+rec("mtime", "1.5")+rec("comment", "g")).
		pax('x', rec("path", "xpath")).file("raw", d5).file("raw2", d5).end())
	put("pax-x-then-g-then-file", new(arc).pax('x', rec("path", "lost")).pax('g', rec("comment", "g")).file("raw", d5).end())
	put("pax-empty-values", new(arc).pax('x', rec("path", "")+rec("uname", "")+rec("mtime", "")+rec("size", "")).file("keep", d5).end())
	put("pax-duplicate-keys", new(arc).pax('x', rec("path", "first")+rec("path", "second")).file("raw", d5).end())
	put("pax-two-x-headers", new(arc).pax('x', rec("path", "first")+rec("uid", "7")).pax('x', rec("gid", "9")).file("raw", d5).end())
	put("pax-size-override-smaller", new(arc).pax('x', rec("size", "2")).block(hdr("raw", '0', 5, mUSTAR)).data([]byte("he")).end())
	put("pax-size-override-larger", new(arc).pax('x', rec("size", "700")).block(hdr("raw", '0', 5, mUSTAR)).data(bytes.Repeat([]byte("z"), 700)).end())
	put("pax-size-plus-sign", new(arc).pax('x', rec("size", "+5")).file("raw", d5).end())
	put("pax-uid-plus-sign", new(arc).pax('x', rec("uid", "+7")).file("raw", d5).end())
	put("pax-uid-overflow", new(arc).pax('x', rec("uid", "99999999999999999999")).file("raw", d5).end())
	put("pax-uid-negative", new(arc).pax('x', rec("uid", "-1")).file("raw", d5).end())
	put("pax-reclen-plus-sign", new(arc).pax('x', "+13 path=abc\n").file("raw", d5).end())
	put("pax-reclen-leading-zero", new(arc).pax('x', "013 path=abc\n").file("raw", d5).end())
	put("pax-reclen-too-big", new(arc).pax('x', "99 path=abc\n").file("raw", d5).end())
	put("pax-missing-newline", new(arc).pax('x', "12 path=abcX").file("raw", d5).end())
	put("pax-no-equals", new(arc).pax('x', "11 pathabc\n").file("raw", d5).end())
	put("pax-value-with-newline", new(arc).pax('x', rec("comment", "a\nb")).file("raw", d5).end())
	put("pax-key-with-nul", new(arc).pax('x', rec("SCHILY.xattr.a\x00b", "v")).file("raw", d5).end())
	put("pax-path-non-utf8", new(arc).pax('x', rec("path", "bad\xff\xfeutf8")).file("raw", d5).end())
	put("pax-linkpath-symlink", new(arc).pax('x', rec("linkpath", rep("L", 300))).block(hdr("sl", '2', 0, mUSTAR)).end())
	put("pax-xattr-empty-value", new(arc).pax('x', rec("SCHILY.xattr.user.e", "")).file("raw", d5).end())
	for i, ts := range []string{"-0.5", "-1.25", "-1.5", "1.", "+5", "5.0000000009", "-0", "1.5e3", "0.000000001", "-0.000000001", "12345678901234567890", ".5", "1..2", "-1.-5"} {
		put(fmt.Sprintf("pax-mtime-%02d", i), new(arc).pax('x', rec("mtime", ts)+rec("atime", ts)).file("raw", d5).end())
	}
	put("pax-header-1MiB+1", new(arc).pax('x', rec("comment", rep("c", 1<<20))).file("raw", d5).end())
	put("pax-header-exact-1MiB", func() []byte {
		r := rec("comment", rep("c", (1<<20)-17))
		r = rec("comment", rep("c", (1<<20)-17-(len(r)-(1<<20))))
		return new(arc).pax('x', r).file("raw", d5).end()
	}())
	put("pax-many-records-5000", new(arc).pax('x', func() string {
		var sb strings.Builder
		for i := 0; i < 5000; i++ {
			sb.WriteString(rec(fmt.Sprintf("SCHILY.xattr.user.k%05d", i), "v"))
		}
		return sb.String()
	}()).file("raw", d5).end())
	put("pax-negative-size-hdr", func() []byte {
		b := hdr("PaxHeaders.0/x", 'x', 0, mGNU)
		setB256(b[124:136], -5)
		return new(arc).block(b).file("raw", d5).end()
	}())

	// --- GNU long name / link precedence ---
	put("gnu-L-then-x", new(arc).gnuLong('L', "gnu-long\x00").pax('x', rec("path", "pax-path")).file("raw", d5).end())
	put("gnu-x-then-L", new(arc).pax('x', rec("path", "pax-path")).gnuLong('L', "gnu-long\x00").file("raw", d5).end())
	put("gnu-L-empty", new(arc).gnuLong('L', "\x00").file("raw-kept", d5).end())
	put("gnu-L-zero-size", new(arc).gnuLong('L', "").file("raw-kept", d5).end())
	put("gnu-K-empty", new(arc).gnuLong('K', "\x00").block(hdr("sl", '2', 0, mUSTAR)).end())
	put("gnu-L-no-nul", new(arc).gnuLong('L', "no-nul-terminator").file("raw", d5).end())
	put("gnu-L-two", new(arc).gnuLong('L', "first\x00").gnuLong('L', "second\x00").file("raw", d5).end())
	put("gnu-L-then-g", new(arc).gnuLong('L', "lost\x00").pax('g', rec("comment", "g")).file("raw", d5).end())
	put("gnu-L-1MiB+1", new(arc).gnuLong('L', rep("l", 1<<20+1)).file("raw", d5).end())

	// --- sparse: old GNU ---
	put("sparse-old-basic", sparseOld("s1", 100, [][2]int64{{0, 5}, {50, 5}}, nil, []byte("AAAAABBBBB")))
	put("sparse-old-tail-hole", sparseOld("s2", 1<<20, [][2]int64{{0, 5}}, nil, d5))
	put("sparse-old-ext-3", sparseOld("s3", 4000, [][2]int64{{0, 1}, {10, 1}, {20, 1}, {30, 1}},
		[][][2]int64{{{40, 1}, {50, 1}}, {{60, 1}}, {{70, 1}, {80, 1}}}, []byte("abcdefghi")))
	put("sparse-old-overlap", sparseOld("s4", 100, [][2]int64{{0, 10}, {5, 5}}, nil, bytes.Repeat([]byte("x"), 15)))
	put("sparse-old-unordered", sparseOld("s5", 100, [][2]int64{{50, 5}, {0, 5}}, nil, bytes.Repeat([]byte("x"), 10)))
	put("sparse-old-beyond-realsize", sparseOld("s6", 10, [][2]int64{{8, 5}}, nil, d5))
	put("sparse-old-missing-data", sparseOld("s7", 100, [][2]int64{{0, 50}}, nil, d5))
	put("sparse-old-extra-data", sparseOld("s8", 100, [][2]int64{{0, 2}}, nil, d5))
	put("sparse-old-1TiB-realsize-no-data", sparseOld("s9", 1<<40, nil, nil, nil))
	put("sparse-old-256MiB-realsize-no-data", sparseOld("s10", 256<<20, nil, nil, nil))
	put("sparse-old-ext-truncated", sparseOld("s11", 4000, [][2]int64{{0, 1}, {10, 1}, {20, 1}, {30, 1}}, [][][2]int64{{{40, 1}}}, []byte("abcde"))[:1024])
	{
		// 2050 extension blocks: Go (totalSize < 1 MiB) accepts, Pion (ext bytes > max_pax_bytes) rejects
		var ext [][][2]int64
		off := int64(0)
		var first [][2]int64
		for i := 0; i < 4; i++ {
			first = append(first, [2]int64{off, 1})
			off += 2
		}
		for e := 0; e < 2050; e++ {
			var eb [][2]int64
			for j := 0; j < 21; j++ {
				eb = append(eb, [2]int64{off, 1})
				off += 2
			}
			ext = append(ext, eb)
		}
		n := 4 + 2050*21
		put("sparse-old-ext-2050-blocks", sparseOld("s12", off, first, ext, bytes.Repeat([]byte("q"), n)))
	}
	// --- sparse: PAX 0.0 / 0.1 / 1.0 ---
	sp00 := rec("GNU.sparse.size", "100") + rec("GNU.sparse.numblocks", "2") +
		rec("GNU.sparse.offset", "0") + rec("GNU.sparse.numbytes", "5") +
		rec("GNU.sparse.offset", "50") + rec("GNU.sparse.numbytes", "5")
	put("sparse-pax-0.0", new(arc).pax('x', sp00).block(hdr("raw00", '0', 10, mUSTAR)).data([]byte("AAAAABBBBB")).end())
	put("sparse-pax-0.0-bad-order", new(arc).pax('x', rec("GNU.sparse.size", "100")+rec("GNU.sparse.numblocks", "1")+
		rec("GNU.sparse.numbytes", "5")+rec("GNU.sparse.offset", "0")).block(hdr("raw", '0', 5, mUSTAR)).data(d5).end())
	sp01 := rec("GNU.sparse.major", "0") + rec("GNU.sparse.minor", "1") + rec("GNU.sparse.name", "real-name-01") +
		rec("GNU.sparse.realsize", "100") + rec("GNU.sparse.numblocks", "2") + rec("GNU.sparse.map", "0,5,50,5")
	put("sparse-pax-0.1", new(arc).pax('x', sp01).block(hdr("raw01", '0', 10, mUSTAR)).data([]byte("AAAAABBBBB")).end())
	put("sparse-pax-0.1-count-mismatch", new(arc).pax('x', rec("GNU.sparse.major", "0")+rec("GNU.sparse.minor", "1")+
		rec("GNU.sparse.realsize", "100")+rec("GNU.sparse.numblocks", "3")+rec("GNU.sparse.map", "0,5,50,5")).
		block(hdr("raw", '0', 10, mUSTAR)).data([]byte("AAAAABBBBB")).end())
	put("sparse-pax-map-empty-no-version", new(arc).pax('x', rec("GNU.sparse.map", "")).file("raw-regular", d5).end())
	put("sparse-pax-unknown-version-2.0", new(arc).pax('x', rec("GNU.sparse.major", "2")+rec("GNU.sparse.minor", "0")+
		rec("GNU.sparse.map", "0,1")).file("raw-regular", d5).end())
	put("sparse-pax-size-empty-realsize-set", new(arc).pax('x', rec("GNU.sparse.major", "0")+rec("GNU.sparse.minor", "1")+
		rec("GNU.sparse.size", "")+rec("GNU.sparse.realsize", "100")+rec("GNU.sparse.numblocks", "1")+rec("GNU.sparse.map", "0,5")).
		block(hdr("raw", '0', 5, mUSTAR)).data(d5).end())
	sp10 := func(m string, realsize string, phys []byte) []byte {
		body := append([]byte(m), pad(len(m))...)
		body = append(body, phys...)
		return new(arc).pax('x', rec("GNU.sparse.major", "1")+rec("GNU.sparse.minor", "0")+rec("GNU.sparse.name", "real10")+
			rec("GNU.sparse.realsize", realsize)).block(hdr("raw10", '0', int64(len(body)), mUSTAR)).data(body).end()
	}
	put("sparse-pax-1.0", sp10("2\n0\n5\n50\n5\n", "100", []byte("AAAAABBBBB")))
	put("sparse-pax-1.0-multiblock-map", func() []byte {
		var sb strings.Builder
		sb.WriteString("300\n")
		for i := 0; i < 300; i++ {
			fmt.Fprintf(&sb, "%d\n1\n", i*1000)
		}
		return sp10(sb.String(), "300000", bytes.Repeat([]byte("m"), 300))
	}())
	put("sparse-pax-1.0-plus-count", sp10("+2\n0\n5\n50\n5\n", "100", []byte("AAAAABBBBB")))
	put("sparse-pax-1.0-huge-count", sp10("99999999\n0\n5\n", "100", d5))
	put("sparse-pax-1.0-negative-length", sp10("1\n0\n-5\n", "100", nil))
	put("sparse-pax-1.0-map-truncated", sp10("2\n0\n5\n50\n5\n", "100", nil)[:512*3])
	put("sparse-pax-1.0-on-symlink", new(arc).pax('x', rec("GNU.sparse.major", "1")+rec("GNU.sparse.minor", "0")+
		rec("GNU.sparse.realsize", "10")).block(hdr("sl", '2', 0, mUSTAR)).end())
	put("sparse-pax-1.0-realsize-1TiB", sp10("0\n", "1099511627776", nil))
	put("sparse-pax-0.1-overlap", new(arc).pax('x', rec("GNU.sparse.major", "0")+rec("GNU.sparse.minor", "1")+
		rec("GNU.sparse.realsize", "100")+rec("GNU.sparse.numblocks", "2")+rec("GNU.sparse.map", "0,10,5,5")).
		block(hdr("raw", '0', 15, mUSTAR)).data(bytes.Repeat([]byte("o"), 15)).end())
	put("sparse-pax-0.1-70000-entries", func() []byte {
		// 70,000 one-byte fragments: Go limit is 1<<20 entries, Pion default max_sparse_holes is 65,536
		var sb strings.Builder
		for i := 0; i < 70000; i++ {
			if i > 0 {
				sb.WriteByte(',')
			}
			fmt.Fprintf(&sb, "%d,1", i*2)
		}
		return new(arc).pax('x', rec("GNU.sparse.major", "0")+rec("GNU.sparse.minor", "1")+rec("GNU.sparse.realsize", "140000")+
			rec("GNU.sparse.numblocks", "70000")+rec("GNU.sparse.map", sb.String())).
			block(hdr("raw", '0', 70000, mUSTAR)).data(bytes.Repeat([]byte("s"), 70000)).end()
	}())

	for name, b := range cases {
		must(os.WriteFile(filepath.Join(dir, name+".tar"), b, 0o644))
	}
	fmt.Printf("wrote %d corpus files to %s\n", len(cases), dir)
}

// genBenchSpec returns a writer spec for one benchmark workload.
func genBenchSpec(kind string) string {
	var sb strings.Builder
	switch kind {
	case "tiny": // 100,000 x 16-byte files
		for i := 0; i < 100000; i++ {
			h := reg(fmt.Sprintf("tiny/%06d.txt", i), 16)
			sb.WriteString(h.line(i) + "\n")
		}
	case "big": // one 64 MiB file
		sb.WriteString(reg("big.bin", 64<<20).line(1) + "\n")
	case "xattr": // 5,000 files with 32 SCHILY.xattr records each (PAX-heavy)
		for i := 0; i < 5000; i++ {
			h := reg(fmt.Sprintf("x/%05d", i), 100)
			for k := 0; k < 32; k++ {
				h.xattr = append(h.xattr, [2]string{fmt.Sprintf("user.attr%02d", k), strings.Repeat(string(rune('a'+k%26)), 40)})
			}
			sb.WriteString(h.line(i) + "\n")
		}
	case "paxrecs": // 200 files x 4,000 xattr records each (just under Pion's default max_pax_records=4096)
		for i := 0; i < 200; i++ {
			h := reg(fmt.Sprintf("r/%04d", i), 10)
			for k := 0; k < 4000; k++ {
				h.xattr = append(h.xattr, [2]string{fmt.Sprintf("user.k%04d", k), "v"})
			}
			sb.WriteString(h.line(i) + "\n")
		}
	case "longname": // 20,000 PAX long-path files (path > 100 chars, not USTAR-splittable)
		for i := 0; i < 20000; i++ {
			sb.WriteString(reg(fmt.Sprintf("%s-%06d", strings.Repeat("n", 180), i), 64).line(i) + "\n")
		}
	default:
		must(fmt.Errorf("unknown bench kind %q", kind))
	}
	return sb.String()
}
