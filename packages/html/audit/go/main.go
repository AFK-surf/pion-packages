// Red-team oracle for packages/html: Go golang.org/x/net/html v0.35.0.
// Same length-framed batch protocol as audit/probe:
//   go_oracle tree <in> <out> doc|frag   html5lib-format dump
//   go_oracle html <in> <out> doc|frag   html.Render
//   go_oracle one  <in> parse [reps]     timing driver
package main

import (
	"bytes"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"

	"golang.org/x/net/html"
	"golang.org/x/net/html/atom"
)

func readRecords(b []byte) [][]byte {
	var out [][]byte
	i := 0
	for i < len(b) {
		ls := i
		for b[i] != '\n' {
			i++
		}
		n, _ := strconv.Atoi(string(b[ls:i]))
		i++
		out = append(out, b[i:i+n])
		i += n
	}
	return out
}

func emit(out *bytes.Buffer, s string) {
	out.WriteString(strconv.Itoa(len(s)))
	out.WriteByte('\n')
	out.WriteString(s)
}

func dump(n *html.Node, d int, sb *strings.Builder) {
	ind := "| " + strings.Repeat("  ", d)
	switch n.Type {
	case html.ElementNode:
		ns := ""
		if n.Namespace != "" {
			ns = n.Namespace + " "
		}
		fmt.Fprintf(sb, "%s<%s%s>\n", ind, ns, n.Data)
		attrs := append([]html.Attribute(nil), n.Attr...)
		sort.Slice(attrs, func(i, j int) bool { return attrs[i].Key < attrs[j].Key })
		for _, a := range attrs {
			k := a.Key
			if a.Namespace != "" {
				k = a.Namespace + " " + a.Key
			}
			fmt.Fprintf(sb, "| %s%s=\"%s\"\n", strings.Repeat("  ", d+1), k, a.Val)
		}
		if n.Data == "template" && n.Namespace == "" {
			fmt.Fprintf(sb, "| %scontent\n", strings.Repeat("  ", d+1))
			for c := n.FirstChild; c != nil; c = c.NextSibling {
				dump(c, d+2, sb)
			}
			return
		}
	case html.TextNode:
		fmt.Fprintf(sb, "%s\"%s\"\n", ind, n.Data)
	case html.CommentNode:
		fmt.Fprintf(sb, "%s<!-- %s -->\n", ind, n.Data)
	case html.DoctypeNode:
		fmt.Fprintf(sb, "%s<!DOCTYPE %s>\n", ind, n.Data)
	}
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		dump(c, d+1, sb)
	}
}

func parse(s string, frag bool) ([]*html.Node, error) {
	if frag {
		ctx := &html.Node{Type: html.ElementNode, Data: "body", DataAtom: atom.Body}
		return html.ParseFragment(strings.NewReader(s), ctx)
	}
	doc, err := html.Parse(strings.NewReader(s))
	if err != nil {
		return nil, err
	}
	var out []*html.Node
	for c := doc.FirstChild; c != nil; c = c.NextSibling {
		out = append(out, c)
	}
	return out, nil
}

func main() {
	mode := os.Args[1]
	b, err := os.ReadFile(os.Args[2])
	if err != nil {
		panic(err)
	}
	if mode == "one" {
		reps := 1
		if len(os.Args) > 4 {
			reps, _ = strconv.Atoi(os.Args[4])
		}
		total := 0
		for r := 0; r < reps; r++ {
			ns, err := parse(string(b), os.Args[3] == "frag")
			if err != nil {
				fmt.Println("ERR", err)
				return
			}
			total += len(ns)
		}
		fmt.Println("ok", total)
		return
	}
	frag := len(os.Args) > 4 && os.Args[4] == "frag"
	var out bytes.Buffer
	for _, r := range readRecords(b) {
		ns, err := parse(string(r), frag)
		if err != nil {
			emit(&out, "ERR "+err.Error())
			continue
		}
		var sb strings.Builder
		for _, n := range ns {
			if mode == "tree" {
				dump(n, 0, &sb)
			} else {
				html.Render(&sb, n)
			}
		}
		emit(&out, sb.String())
	}
	os.WriteFile(os.Args[3], out.Bytes(), 0o644)
}
