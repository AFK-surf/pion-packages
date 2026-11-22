// Command go_tar is the Go 1.27 archive/tar reference side of the packages/tar red-team audit.
//
//	go_tar dump <file>                 canonical dump (same format as tools/pion_tar)
//	go_tar trunc <file> <stride>       dump every prefix -> "<len> <fnv> <last line>"
//	go_tar mutate <file> <seed> <n>    deterministic byte mutations (xorshift64, same as Pion)
//	go_tar writespec <spec> <out>      encode a header spec with archive/tar.Writer
//	go_tar genspec <spec>              write the writer-differential header spec
//	go_tar gencorpus <dir>             write the adversarial reader corpus
//	go_tar readbench <file> <rounds>   full-payload read benchmark
//	go_tar writebench <spec> <rounds>  write benchmark (spec entries, in memory)
//	go_tar scanbench <file> <rounds>   header-only scan benchmark (payloads skipped)
//	go_tar genbenchspec <kind> <out>   benchmark specs: tiny | big | xattr | sparse
package main

import (
	"archive/tar"
	"bufio"
	"bytes"
	"encoding/hex"
	"fmt"
	"hash/fnv"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

const dataCap = 64 << 20

// noFmt hides the Format field (set by a trailing `nofmt` argument) so format-reporting
// differences do not mask everything else in trunc/mutate sweeps.
var noFmt bool

func hexs(s string) string { return hex.EncodeToString([]byte(s)) }

func fmtTime(t time.Time) string {
	if t.IsZero() {
		return "-"
	}
	return fmt.Sprintf("%d.%09d", t.Unix(), t.Nanosecond())
}

func fmtKV(m map[string]string) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var parts []string
	for _, k := range keys {
		parts = append(parts, hexs(k)+"="+hexs(m[k]))
	}
	return strings.Join(parts, ",")
}

func dump(data []byte) string {
	var sb strings.Builder
	tr := tar.NewReader(bytes.NewReader(data))
	for {
		h, err := tr.Next()
		if err == io.EOF {
			sb.WriteString("EOF\n")
			return sb.String()
		}
		if err != nil {
			sb.WriteString("ERR next\n")
			return sb.String()
		}
		//lint:ignore SA1019 Xattrs is what the Pion API mirrors
		xattrs := h.Xattrs //nolint:staticcheck
		fmt.Fprintf(&sb, "E tf=%d name=%s link=%s size=%d mode=%d uid=%d gid=%d uname=%s gname=%s mtime=%s atime=%s ctime=%s dev=%d,%d fmt=%s pax=%s xattr=%s\n",
			h.Typeflag, hexs(h.Name), hexs(h.Linkname), h.Size, h.Mode, h.Uid, h.Gid, hexs(h.Uname), hexs(h.Gname),
			fmtTime(h.ModTime), fmtTime(h.AccessTime), fmtTime(h.ChangeTime), h.Devmajor, h.Devminor, fmtName(h.Format),
			fmtKV(h.PAXRecords), fmtKV(xattrs))
		if h.Size > dataCap {
			sb.WriteString("D skip\n")
			continue
		}
		hh := fnv.New64a()
		n, err := io.Copy(hh, tr)
		if err != nil {
			sb.WriteString("ERR data\n")
			return sb.String()
		}
		fmt.Fprintf(&sb, "D len=%d fnv=%016x\n", n, hh.Sum64())
	}
}

func fmtName(f tar.Format) string {
	if noFmt {
		return "?"
	}
	return f.String()
}

func fnvStr(s string) string {
	h := fnv.New64a()
	h.Write([]byte(s))
	return fmt.Sprintf("%016x", h.Sum64())
}

func lastLine(s string) string {
	s = strings.TrimSuffix(s, "\n")
	if i := strings.LastIndexByte(s, '\n'); i >= 0 {
		return s[i+1:]
	}
	return s
}

func xorshift(x uint64) uint64 {
	x ^= x << 13
	x ^= x >> 7
	x ^= x << 17
	return x
}

func fixChecksum(b []byte) {
	sum := 0
	for i := 0; i < 512; i++ {
		if i >= 148 && i < 156 {
			sum += 32
		} else {
			sum += int(b[i])
		}
	}
	for pos := 153; pos >= 148; pos-- {
		b[pos] = byte('0' + sum&7)
		sum >>= 3
	}
	b[154] = 0
	b[155] = ' '
}

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
}

func atoi(s string) int64 {
	v, err := strconv.ParseInt(s, 10, 64)
	must(err)
	return v
}

func unhex(s string) string {
	if s == "-" {
		return ""
	}
	b, err := hex.DecodeString(s)
	must(err)
	return string(b)
}

func parseTime(s string) time.Time {
	if s == "-" {
		return time.Time{}
	}
	sec, ns, _ := strings.Cut(s, ":")
	return time.Unix(atoi(sec), atoi(ns))
}

func parseKV(s string) map[string]string {
	if s == "-" {
		return nil
	}
	m := map[string]string{}
	for _, it := range strings.Split(s, ",") {
		k, v, _ := strings.Cut(it, "=")
		m[unhex(k)] = unhex(v)
	}
	return m
}

func parseFmt(s string) tar.Format {
	switch s {
	case "ustar":
		return tar.FormatUSTAR
	case "pax":
		return tar.FormatPAX
	case "gnu":
		return tar.FormatGNU
	}
	return tar.FormatUnknown
}

func patternData(n, seed int) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte((i*131 + seed) & 255)
	}
	return b
}

type specEntry struct {
	hdr  tar.Header
	data []byte
}

func readSpec(path string) []specEntry {
	f, err := os.Open(path)
	must(err)
	defer f.Close()
	var out []specEntry
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<26)
	for sc.Scan() {
		line := sc.Text()
		if !strings.HasPrefix(line, "H ") {
			continue
		}
		t := strings.Split(line, " ")
		h := tar.Header{
			Typeflag:   byte(atoi(t[1])),
			Name:       unhex(t[2]),
			Linkname:   unhex(t[3]),
			Size:       atoi(t[4]),
			Mode:       atoi(t[5]),
			Uid:        int(atoi(t[6])),
			Gid:        int(atoi(t[7])),
			Uname:      unhex(t[8]),
			Gname:      unhex(t[9]),
			ModTime:    parseTime(t[10]),
			AccessTime: parseTime(t[11]),
			ChangeTime: parseTime(t[12]),
			Devmajor:   atoi(t[13]),
			Devminor:   atoi(t[14]),
			Format:     parseFmt(t[15]),
			PAXRecords: parseKV(t[16]),
			Xattrs:     parseKV(t[17]), //nolint:staticcheck
		}
		out = append(out, specEntry{h, patternData(int(atoi(t[18])), int(atoi(t[19])))})
	}
	must(sc.Err())
	return out
}

func writeSpec(entries []specEntry, log io.Writer) []byte {
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	for i, e := range entries {
		h := e.hdr
		if err := tw.WriteHeader(&h); err != nil {
			fmt.Fprintf(log, "W %d ERR\n", i)
			continue
		}
		if len(e.data) > 0 {
			if _, err := tw.Write(e.data); err != nil {
				fmt.Fprintf(log, "W %d DATAERR\n", i)
				continue
			}
		}
		fmt.Fprintf(log, "W %d OK\n", i)
	}
	if err := tw.Close(); err != nil {
		fmt.Fprintf(log, "FINISH ERR\n")
		return nil
	}
	fmt.Fprintf(log, "FINISH OK\n")
	return buf.Bytes()
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: go_tar dump|trunc|mutate|writespec|genspec|gencorpus|readbench|writebench ...")
		os.Exit(2)
	}
	if os.Args[len(os.Args)-1] == "nofmt" {
		noFmt = true
		os.Args = os.Args[:len(os.Args)-1]
	}
	mode, path := os.Args[1], os.Args[2]
	switch mode {
	case "genspec":
		must(os.WriteFile(path, []byte(genSpec()), 0o644))
		return
	case "gencorpus":
		genCorpus(path)
		return
	case "writespec":
		out := writeSpec(readSpec(path), os.Stdout)
		if out != nil {
			must(os.WriteFile(os.Args[3], out, 0o644))
		}
		return
	case "genbenchspec":
		must(os.WriteFile(os.Args[3], []byte(genBenchSpec(path)), 0o644))
		return
	case "writebench":
		entries := readSpec(path)
		rounds := int(atoi(os.Args[3]))
		var total int
		for r := 0; r < rounds; r++ {
			out := writeSpec(entries, io.Discard)
			total += len(out)
		}
		fmt.Printf("bytes=%d\n", total)
		return
	}
	data, err := os.ReadFile(path)
	must(err)
	switch mode {
	case "dump":
		fmt.Print(dump(data))
	case "trunc":
		stride := int(atoi(os.Args[3]))
		w := bufio.NewWriter(os.Stdout)
		for l := 0; ; {
			d := dump(data[:l:l])
			fmt.Fprintf(w, "%d %s %s\n", l, fnvStr(d), lastLine(d))
			if l == len(data) {
				break
			}
			l += stride
			if l > len(data) {
				l = len(data)
			}
		}
		w.Flush()
	case "mutate":
		st, err := strconv.ParseUint(os.Args[3], 10, 64)
		must(err)
		if st == 0 {
			st = 88172645463325252
		}
		count := int(atoi(os.Args[4]))
		n := len(data)
		w := bufio.NewWriter(os.Stdout)
		for i := 0; i < count && n > 0; i++ {
			m := append([]byte(nil), data...)
			st = xorshift(st)
			k := int(st%4) + 1
			for j := 0; j < k; j++ {
				st = xorshift(st)
				pos := int(st % uint64(n))
				st = xorshift(st)
				m[pos] = byte(st & 255)
				st = xorshift(st)
				if st%3 != 0 && (pos/512+1)*512 <= n {
					fixChecksum(m[pos/512*512:])
				}
			}
			d := dump(m)
			fmt.Fprintf(w, "%d %s %s\n", i, fnvStr(d), lastLine(d))
		}
		w.Flush()
	case "scanbench":
		rounds := int(atoi(os.Args[3]))
		var entries, sizes int64
		h := fnv.New64a()
		for r := 0; r < rounds; r++ {
			tr := tar.NewReader(bytes.NewReader(data))
			for {
				hdr, err := tr.Next()
				if err == io.EOF {
					break
				}
				must(err)
				entries++
				sizes += hdr.Size
				h.Write([]byte(hdr.Name))
			}
		}
		fmt.Printf("entries=%d sizes=%d fnv=%016x\n", entries, sizes, h.Sum64())
	case "readbench":
		rounds := int(atoi(os.Args[3]))
		var entries, payload int64
		h := fnv.New64a()
		buf := make([]byte, 64<<10)
		for r := 0; r < rounds; r++ {
			tr := tar.NewReader(bytes.NewReader(data))
			for {
				hdr, err := tr.Next()
				if err == io.EOF {
					break
				}
				must(err)
				entries++
				h.Write([]byte(hdr.Name))
				n, err := io.CopyBuffer(h, tr, buf)
				must(err)
				payload += n
			}
		}
		fmt.Printf("entries=%d payload=%d fnv=%016x\n", entries, payload, h.Sum64())
	default:
		fmt.Fprintln(os.Stderr, "unknown mode", mode)
		os.Exit(2)
	}
}
