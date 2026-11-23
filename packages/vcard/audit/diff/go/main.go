// RT-vcard Go oracle: emersion/go-vcard v0.1.0, same canonical dump as audit/driver (`dump` mode).
// usage: go_oracle <cases>          (each line `<id> <hex>`)
//
//	go_oracle parse <file>   decode a whole stream, keep every card (same work as pion `parse`)
package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"

	"github.com/emersion/go-vcard"
)

func vis(s string) string {
	var sb strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < 32 || c == 127 || strings.IndexByte(`\;,=|{}^": `, c) >= 0 {
			fmt.Fprintf(&sb, "\\x%02x", c)
		} else {
			sb.WriteByte(c)
		}
	}
	return sb.String()
}

func joinList(items []string) string {
	out := make([]string, len(items))
	for i, s := range items {
		out[i] = vis(s)
	}
	return strings.Join(out, ",")
}

func comps(v string, n int) string {
	parts := strings.Split(v, ";")
	out := make([]string, n)
	for i := 0; i < n; i++ {
		if i < len(parts) && parts[i] != "" {
			out[i] = joinList(strings.Split(parts[i], ","))
		}
	}
	return strings.Join(out, ";")
}

func valueView(k string, f *vcard.Field) string {
	switch k {
	case "N":
		return comps(f.Value, 5)
	case "ADR":
		return comps(f.Value, 7)
	case "ORG":
		parts := strings.Split(f.Value, ";")
		for i := range parts {
			parts[i] = vis(parts[i])
		}
		return strings.Join(parts, ";")
	case "PHOTO", "LOGO", "KEY", "SOUND":
		enc := strings.ToUpper(f.Params.Get("ENCODING"))
		if enc == "B" || enc == "BASE64" {
			d, err := base64.StdEncoding.DecodeString(strings.TrimSpace(f.Value))
			if err != nil {
				return "!ERR"
			}
			return fmt.Sprintf("bin:%d", len(d))
		}
		if strings.HasPrefix(strings.ToLower(f.Value), "data:") {
			i := strings.IndexByte(f.Value, ',')
			if i < 0 {
				return "!ERR"
			}
			if strings.HasSuffix(strings.ToLower(f.Value[:i]), ";base64") {
				d, err := base64.StdEncoding.DecodeString(f.Value[i+1:])
				if err != nil {
					return "!ERR"
				}
				return fmt.Sprintf("bin:%d", len(d))
			}
			return fmt.Sprintf("bin:%d", len(f.Value)-i-1)
		}
		return "uri:" + vis(f.Value)
	}
	return vis(f.Value)
}

func dump(cards []vcard.Card) string {
	var sb strings.Builder
	for _, c := range cards {
		var keys []string
		for k := range c {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		var views []string
		for _, k := range keys {
			for _, f := range c[k] {
				var p strings.Builder
				if f.Group != "" {
					p.WriteString(vis(f.Group) + ".")
				}
				p.WriteString(vis(k))
				var pk []string
				for n := range f.Params {
					pk = append(pk, n)
				}
				sort.Strings(pk)
				for _, n := range pk {
					p.WriteString(";" + vis(n) + "=" + joinList(f.Params[n]))
				}
				p.WriteString("|" + valueView(k, f))
				views = append(views, p.String())
			}
		}
		sb.WriteString("{" + strings.Join(views, " ") + "}")
	}
	return sb.String()
}

func parseFile(path string) {
	raw, err := os.ReadFile(path)
	if err != nil {
		fmt.Println("ERR", err)
		return
	}
	dec := vcard.NewDecoder(bytes.NewReader(raw))
	var all []vcard.Card
	props := 0
	for {
		c, err := dec.Decode()
		if err == io.EOF {
			break
		}
		if err != nil {
			fmt.Println("ERR", err)
			return
		}
		all = append(all, c)
		for _, f := range c {
			props += len(f)
		}
	}
	fmt.Printf("OK cards=%d props=%d bytes=%d\n", len(all), props, len(raw))
}

func main() {
	if len(os.Args) == 3 && os.Args[1] == "parse" {
		parseFile(os.Args[2])
		return
	}
	fh, err := os.Open(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	sc := bufio.NewScanner(fh)
	sc.Buffer(make([]byte, 1<<20), 1<<26)
	for sc.Scan() {
		parts := strings.SplitN(sc.Text(), " ", 2)
		if len(parts) != 2 {
			continue
		}
		raw, _ := hex.DecodeString(parts[1])
		dec := vcard.NewDecoder(bytes.NewReader(raw))
		var cards []vcard.Card
		var derr error
		for {
			c, err := dec.Decode()
			if err == io.EOF {
				break
			}
			if err != nil {
				derr = err
				break
			}
			cards = append(cards, c)
		}
		if derr != nil {
			fmt.Printf("%s ERR %s\n", parts[0], vis(derr.Error()))
		} else {
			fmt.Printf("%s OK %s\n", parts[0], dump(cards))
		}
	}
}
