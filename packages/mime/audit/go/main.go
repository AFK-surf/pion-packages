// Go 1.27 stdlib reference side of the packages/mime red-team differential harness.
// Same batch format and output shape as ../src/main.pion (see its header).
package main

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"mime/quotedprintable"
	"net/http"
	"os"
	"sort"
	"strings"
)

func h(b []byte) string  { return "." + hex.EncodeToString(b) }
func hs(s string) string { return h([]byte(s)) }

func fields(line string) [][]byte {
	var out [][]byte
	for _, f := range strings.Split(line, " ") {
		if f == "" {
			continue
		}
		b, _ := hex.DecodeString(f[1:])
		out = append(out, b)
	}
	return out
}

func params(p map[string]string) string {
	keys := make([]string, 0, len(p))
	for k := range p {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var sb strings.Builder
	for _, k := range keys {
		sb.WriteString(" " + hs(k) + "=" + hs(p[k]))
	}
	return sb.String()
}

func runCase(mode string, f [][]byte) string {
	a0 := []byte{}
	if len(f) > 0 {
		a0 = f[0]
	}
	switch mode {
	case "mt", "cd":
		t, p, err := mime.ParseMediaType(string(a0))
		if err != nil {
			return "ERR " + strings.ReplaceAll(err.Error(), " ", "_")
		}
		// Go's ParseMediaType accepts both "type/sub" and bare disposition tokens; keep the shape the mode asks for.
		if (mode == "mt") != strings.Contains(t, "/") {
			return "ERR shape"
		}
		return "OK " + hs(t) + params(p)
	case "mtn":
		_, p, err := mime.ParseMediaType(string(a0))
		if err != nil {
			return "ERR " + strings.ReplaceAll(err.Error(), " ", "_")
		}
		return fmt.Sprintf("OK %d", len(p))
	case "fmt":
		p := map[string]string{}
		for i := 1; i+1 < len(f); i += 2 {
			p[string(f[i])] = string(f[i+1])
		}
		s := mime.FormatMediaType(string(a0), p)
		if s == "" {
			return "ERR empty"
		}
		rt := " RT=same"
		_, p2, err := mime.ParseMediaType(s)
		if err != nil {
			rt = " RT=ERR:" + strings.ReplaceAll(err.Error(), " ", "_")
		} else {
			if len(p2) != len(p) {
				rt = " RT=DIFF"
			}
			for k, v := range p {
				if p2[strings.ToLower(k)] != v {
					rt = " RT=DIFF"
				}
			}
		}
		return "OK " + hs(s) + rt
	case "qpdec":
		out, err := io.ReadAll(quotedprintable.NewReader(bytes.NewReader(a0)))
		if err != nil {
			return "ERR " + strings.ReplaceAll(err.Error(), " ", "_")
		}
		return "OK " + h(out)
	case "qpenc", "qpencb":
		var buf bytes.Buffer
		w := quotedprintable.NewWriter(&buf)
		w.Binary = mode == "qpencb"
		w.Write(a0)
		w.Close()
		return "OK " + h(buf.Bytes())
	case "ewdec":
		var d mime.WordDecoder
		s, err := d.DecodeHeader(string(a0))
		if err != nil {
			return "ERR " + strings.ReplaceAll(err.Error(), " ", "_")
		}
		return "OK " + hs(s)
	case "ewq":
		return "OK " + hs(mime.QEncoding.Encode("utf-8", string(a0)))
	case "ewb":
		return "OK " + hs(mime.BEncoding.Encode("utf-8", string(a0)))
	case "sniff":
		return http.DetectContentType(a0)
	case "mp":
		body := []byte{}
		if len(f) > 1 {
			body = f[1]
		}
		r := multipart.NewReader(bytes.NewReader(body), string(a0))
		var sb strings.Builder
		for {
			p, err := r.NextRawPart()
			if err == io.EOF {
				sb.WriteString("END")
				break
			}
			if err != nil {
				sb.WriteString("ERR " + strings.ReplaceAll(err.Error(), " ", "_"))
				break
			}
			data, err := io.ReadAll(p)
			if err != nil {
				sb.WriteString("ERR body:" + strings.ReplaceAll(err.Error(), " ", "_"))
				break
			}
			sb.WriteString("P " + hs(p.Header.Get("Content-Disposition")) + " " + hs(p.Header.Get("Content-Type")) + " " + h(data) + " | ")
		}
		return sb.String()
	}
	return "BADMODE"
}

func main() {
	mode := os.Args[1]
	if mode == "mpfile" {
		data, _ := os.ReadFile(os.Args[3])
		r := multipart.NewReader(bytes.NewReader(data), os.Args[2])
		n, total := 0, 0
		for {
			p, err := r.NextRawPart()
			if err == io.EOF {
				break
			}
			if err != nil {
				fmt.Printf("ERR %v after parts=%d\n", err, n)
				return
			}
			b, err := io.ReadAll(p)
			if err != nil {
				fmt.Printf("ERR %v after parts=%d\n", err, n)
				return
			}
			n++
			total += len(b) + len(p.FormName())
		}
		fmt.Printf("parts=%d body_bytes=%d\n", n, total)
		return
	}
	data, _ := os.ReadFile(os.Args[2])
	w := bufio.NewWriterSize(os.Stdout, 1<<20)
	defer w.Flush()
	lines := strings.Split(string(data), "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	for _, l := range lines {
		w.WriteString(runCase(mode, fields(l)) + "\n")
	}
}
