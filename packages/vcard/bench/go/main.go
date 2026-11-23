package main

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/emersion/go-vcard"
)

const mod = int64(1000000007)

func mix(h, v int64) int64 {
	return ((h * 131) + (v % mod) + mod) % mod
}

func hashStr(h0 int64, s string) int64 {
	h := mix(h0, int64(len(s)))
	for i := 0; i < len(s); i++ {
		h = mix(h, int64(s[i]))
	}
	return h
}

func hashBytes(h0 int64, b []byte) int64 {
	h := mix(h0, int64(len(b)))
	for _, c := range b {
		h = mix(h, int64(c))
	}
	return h
}

func hashStrArray(h0 int64, arr []string) int64 {
	h := mix(h0, int64(len(arr)))
	for _, s := range arr {
		h = hashStr(h, s)
	}
	return h
}

func unescapeText(s string) string {
	if !strings.ContainsRune(s, '\\') {
		return s
	}
	var sb strings.Builder
	sb.Grow(len(s))
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+1 < len(s) {
			next := s[i+1]
			switch next {
			case 'n', 'N':
				sb.WriteByte('\n')
				i++
				continue
			case ',', ';', '\\':
				sb.WriteByte(next)
				i++
				continue
			}
		}
		sb.WriteByte(s[i])
	}
	return sb.String()
}

func unescapeRFC6868(s string) string {
	if !strings.ContainsRune(s, '^') {
		return s
	}
	var sb strings.Builder
	sb.Grow(len(s))
	for i := 0; i < len(s); i++ {
		if s[i] == '^' && i+1 < len(s) {
			switch s[i+1] {
			case 'n':
				sb.WriteByte('\n')
				i++
				continue
			case '\'':
				sb.WriteByte('"')
				i++
				continue
			case '^':
				sb.WriteByte('^')
				i++
				continue
			}
		}
		sb.WriteByte(s[i])
	}
	return sb.String()
}

func splitEscaped(s string, sep byte) []string {
	var out []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+1 < len(s) {
			i++
			continue
		}
		if s[i] == sep {
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	out = append(out, s[start:])
	return out
}

func splitTextList(s string) []string {
	if len(s) == 0 {
		return nil
	}
	parts := splitEscaped(s, ',')
	out := make([]string, len(parts))
	for i, p := range parts {
		out[i] = unescapeText(p)
	}
	return out
}

func decodeStream(raw []byte) ([]vcard.Card, error) {
	dec := vcard.NewDecoder(bytes.NewReader(raw))
	var cards []vcard.Card
	for {
		c, err := dec.Decode()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		cards = append(cards, c)
	}
	return cards, nil
}

func encodeStream(cards []vcard.Card) ([]byte, error) {
	var buf bytes.Buffer
	enc := vcard.NewEncoder(&buf)
	for _, c := range cards {
		if err := enc.Encode(c); err != nil {
			return nil, err
		}
	}
	return buf.Bytes(), nil
}

func decodePhoto(f *vcard.Field) ([]byte, error) {
	enc := strings.ToUpper(f.Params.Get("ENCODING"))
	if enc == "B" || enc == "BASE64" {
		return base64.StdEncoding.DecodeString(strings.TrimSpace(f.Value))
	}
	if strings.HasPrefix(strings.ToLower(f.Value), "data:") {
		idx := strings.IndexByte(f.Value, ',')
		if idx < 0 {
			return nil, fmt.Errorf("bad data uri")
		}
		return base64.StdEncoding.DecodeString(strings.TrimSpace(f.Value[idx+1:]))
	}
	return []byte(f.Value), nil
}

func benchW1(raw []byte) int {
	cards, err := decodeStream(raw)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	propCount := 0
	checksum := int64(0)
	for _, c := range cards {
		for _, fields := range c {
			propCount += len(fields)
		}
		if fn := c.Get(vcard.FieldFormattedName); fn != nil {
			checksum = hashStr(checksum, fn.Value)
		}
		for _, f := range c[vcard.FieldEmail] {
			checksum = hashStr(checksum, f.Value)
		}
		for _, f := range c[vcard.FieldTelephone] {
			checksum = hashStr(checksum, f.Value)
		}
		for _, f := range c[vcard.FieldAddress] {
			parts := splitEscaped(f.Value, ';')
			var street, locality []string
			if len(parts) > 2 {
				street = splitTextList(parts[2])
			}
			if len(parts) > 3 {
				locality = splitTextList(parts[3])
			}
			checksum = hashStrArray(checksum, street)
			checksum = hashStrArray(checksum, locality)
			if lbl := f.Params.Get("LABEL"); lbl != "" {
				checksum = hashStr(checksum, unescapeRFC6868(lbl))
			}
		}
	}
	fmt.Printf("cards=%d\n", len(cards))
	fmt.Printf("props=%d\n", propCount)
	fmt.Printf("checksum=%d\n", checksum)
	return 0
}

func benchW2(raw []byte) int {
	cards, err := decodeStream(raw)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	encoded, err := encodeStream(cards)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	cards2, err := decodeStream(encoded)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 3
	}
	checksum := int64(0)
	for _, c := range cards2 {
		if fn := c.Get(vcard.FieldFormattedName); fn != nil {
			checksum = hashStr(checksum, fn.Value)
		}
		if nf := c.Get(vcard.FieldName); nf != nil {
			parts := splitEscaped(nf.Value, ';')
			var fam, giv, pre []string
			if len(parts) > 0 {
				fam = splitTextList(parts[0])
			}
			if len(parts) > 1 {
				giv = splitTextList(parts[1])
			}
			if len(parts) > 3 {
				pre = splitTextList(parts[3])
			}
			checksum = hashStrArray(checksum, fam)
			checksum = hashStrArray(checksum, giv)
			checksum = hashStrArray(checksum, pre)
		}
		for _, f := range c[vcard.FieldOrganization] {
			parts := splitEscaped(f.Value, ';')
			units := make([]string, len(parts))
			for i, p := range parts {
				units[i] = unescapeText(p)
			}
			checksum = hashStrArray(checksum, units)
		}
		for _, f := range c[vcard.FieldAddress] {
			parts := splitEscaped(f.Value, ';')
			var street, locality, country []string
			if len(parts) > 2 {
				street = splitTextList(parts[2])
			}
			if len(parts) > 3 {
				locality = splitTextList(parts[3])
			}
			if len(parts) > 6 {
				country = splitTextList(parts[6])
			}
			checksum = hashStrArray(checksum, street)
			checksum = hashStrArray(checksum, locality)
			checksum = hashStrArray(checksum, country)
		}
		for _, f := range c[vcard.FieldEmail] {
			checksum = hashStr(checksum, f.Value)
		}
		for _, f := range c[vcard.FieldTelephone] {
			checksum = hashStr(checksum, f.Value)
		}
	}
	fmt.Printf("cards=%d\n", len(cards2))
	fmt.Printf("checksum=%d\n", checksum)
	return 0
}

func benchW3(raw []byte) int {
	cards, err := decodeStream(raw)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	encoded, err := encodeStream(cards)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	cards2, err := decodeStream(encoded)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 3
	}
	totalPhotoBytes := 0
	checksum := int64(0)
	for _, c := range cards2 {
		if fn := c.Get(vcard.FieldFormattedName); fn != nil {
			checksum = hashStr(checksum, fn.Value)
		}
		if nf := c.Get(vcard.FieldName); nf != nil {
			parts := splitEscaped(nf.Value, ';')
			var fam, giv []string
			if len(parts) > 0 && len(parts[0]) > 0 {
				fam = []string{strings.ReplaceAll(parts[0], `\;`, ";")}
			}
			if len(parts) > 1 && len(parts[1]) > 0 {
				giv = []string{strings.ReplaceAll(parts[1], `\;`, ";")}
			}
			checksum = hashStrArray(checksum, fam)
			checksum = hashStrArray(checksum, giv)
		}
		for _, f := range c[vcard.FieldOrganization] {
			parts := splitEscaped(f.Value, ';')
			units := make([]string, len(parts))
			for i, p := range parts {
				units[i] = strings.ReplaceAll(p, `\;`, ";")
			}
			checksum = hashStrArray(checksum, units)
		}
		for _, f := range c[vcard.FieldNote] {
			checksum = hashStr(checksum, f.Value)
		}
		for _, f := range c[vcard.FieldPhoto] {
			data, err := decodePhoto(f)
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				return 4
			}
			totalPhotoBytes += len(data)
			checksum = hashBytes(checksum, data)
		}
	}
	fmt.Printf("cards=%d\n", len(cards2))
	fmt.Printf("photo_bytes=%d\n", totalPhotoBytes)
	fmt.Printf("checksum=%d\n", checksum)
	return 0
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: go_vcard_bench <mode> <corpus_path>")
		os.Exit(1)
	}
	raw, err := os.ReadFile(os.Args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	switch os.Args[1] {
	case "w1_parse":
		os.Exit(benchW1(raw))
	case "w2_roundtrip":
		os.Exit(benchW2(raw))
	case "w3_escaped_binary":
		os.Exit(benchW3(raw))
	default:
		fmt.Fprintf(os.Stderr, "unknown mode: %s\n", os.Args[1])
		os.Exit(1)
	}
}
