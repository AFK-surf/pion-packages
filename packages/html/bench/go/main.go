package main

import (
	"fmt"
	"os"
	"strings"

	"golang.org/x/net/html"
)

func main() {
	path := "/private/tmp/pion-html-bench/mixed_pages.html"
	if len(os.Args) > 1 {
		path = os.Args[1]
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "read error: %v\n", err)
		os.Exit(1)
	}
	src := string(raw)

	const rounds = 20
	var elements int64
	var links int64
	var hrefBytes int64
	var textBytes int64

	stack := make([]*html.Node, 0, 256)
	for r := 0; r < rounds; r++ {
		doc, err := html.Parse(strings.NewReader(src))
		if err != nil {
			fmt.Fprintf(os.Stderr, "parse error: %v\n", err)
			os.Exit(1)
		}
		stack = stack[:0]
		stack = append(stack, doc)
		for len(stack) > 0 {
			n := stack[len(stack)-1]
			stack = stack[:len(stack)-1]
			if n.Type == html.ElementNode {
				elements++
				if n.Data == "a" {
					for _, a := range n.Attr {
						if a.Key == "href" {
							links++
							hrefBytes += int64(len(a.Val))
							break
						}
					}
				}
			} else if n.Type == html.TextNode {
				textBytes += int64(len(n.Data))
			}
			for c := n.LastChild; c != nil; c = c.PrevSibling {
				stack = append(stack, c)
			}
		}
	}

	fmt.Printf("rounds=%d\n", rounds)
	fmt.Printf("elements=%d\n", elements)
	fmt.Printf("links=%d\n", links)
	fmt.Printf("href_bytes=%d\n", hrefBytes)
	fmt.Printf("text_bytes=%d\n", textBytes)
}
