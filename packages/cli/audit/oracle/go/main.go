// Go spf13/pflag v1.0.6 oracle for the `packages/cli` red-team differential.
// Only the `basic` spec is meaningful for pflag (no env/requires/subcommands); other specs print "SKIP".
// Output line format is identical to audit/probe and oracle/rust.
package main

import (
	"encoding/hex"
	"fmt"
	"io"
	"math"
	"os"
	"strconv"
	"strings"

	"github.com/spf13/pflag"
)

func esc(sb *strings.Builder, s string) {
	for i := 0; i < len(s); i++ {
		b := s[i]
		if b < 0x21 || b > 0x7e || b == '\\' || b == ',' || b == '[' || b == ']' || b == '=' {
			fmt.Fprintf(sb, "\\x%02x", b)
		} else {
			sb.WriteByte(b)
		}
	}
}

func unhex(h string) string { b, _ := hex.DecodeString(h); return string(b) }

func vals(sb *strings.Builder, id string, vs []string) {
	sb.WriteString(" " + id + "=[")
	for k, v := range vs {
		if k > 0 {
			sb.WriteByte(',')
		}
		esc(sb, v)
	}
	sb.WriteString("]@cli")
}

func runBasic(sb *strings.Builder, args []string) {
	fs := pflag.NewFlagSet("app", pflag.ContinueOnError)
	fs.SetOutput(io.Discard)
	verbose := fs.CountP("verbose", "v", "")
	output := fs.StringP("output", "o", "", "")
	pattern := fs.StringP("pattern", "p", "", "")
	num := fs.StringP("num", "n", "", "")
	flag := fs.BoolP("flag", "f", false, "")
	five := fs.BoolP("five", "5", false, "")
	list := fs.StringSliceP("list", "l", nil, "")
	mode := fs.StringP("mode", "m", "", "")
	secret := fs.Bool("secret", false, "")
	_ = fs.MarkHidden("secret")
	err := fs.Parse(args)
	if err != nil {
		msg := err.Error()
		switch {
		case err == pflag.ErrHelp:
			sb.WriteString("HELP Usage:\\x20app")
		case strings.Contains(msg, "unknown"):
			sb.WriteString("ERR unknown_argument sug=-")
		default:
			sb.WriteString("ERR invalid_value")
		}
		return
	}
	sb.WriteString("OK")
	fmt.Fprintf(sb, " verbose=%d", *verbose)
	opt := func(id string, v *string) {
		if fs.Changed(id) {
			vals(sb, id, []string{*v})
		}
	}
	opt("output", output)
	opt("pattern", pattern)
	opt("num", num)
	fmt.Fprintf(sb, " flag=%v five=%v", *flag, *five)
	if fs.Changed("list") {
		vals(sb, "list", *list)
	}
	opt("mode", mode)
	fmt.Fprintf(sb, " uni=false secret=%v", *secret)
	if fs.NArg() > 0 {
		vals(sb, "files", fs.Args())
	}
}

func main() {
	data, _ := os.ReadFile(os.Args[2])
	var sb strings.Builder
	for n, line := range strings.Split(string(data), "\n") {
		if line == "" {
			continue
		}
		if os.Args[1] == "typed" {
			s := unhex(line)
			sb.WriteString("[")
			esc(&sb, s)
			sb.WriteString("] i32=")
			// pflag IntP / Int64P use strconv.ParseInt(s, 0, 64/32)
			if v, err := strconv.ParseInt(s, 0, 32); err == nil {
				sb.WriteString(strconv.FormatInt(v, 10))
			} else {
				sb.WriteString("ERR")
			}
			sb.WriteString(" i64=")
			if v, err := strconv.ParseInt(s, 0, 64); err == nil {
				sb.WriteString(strconv.FormatInt(v, 10))
			} else {
				sb.WriteString("ERR")
			}
			sb.WriteString(" f64=")
			if v, err := strconv.ParseFloat(s, 64); err == nil || (err != nil && strings.Contains(err.Error(), "range") && math.IsInf(v, 0)) {
				if math.IsNaN(v) {
					sb.WriteString("NaN")
				} else {
					fmt.Fprintf(&sb, "%016x", math.Float64bits(v))
				}
			} else {
				sb.WriteString("ERR")
			}
			sb.WriteString("\n")
			continue
		}
		f := strings.Split(line, "\t")
		fmt.Fprintf(&sb, "%d\t", n)
		if f[0] != "basic" {
			sb.WriteString("SKIP\n")
			continue
		}
		args := []string{}
		for _, a := range f[2:] {
			args = append(args, unhex(a))
		}
		runBasic(&sb, args)
		sb.WriteString("\n")
	}
	fmt.Print(sb.String())
}
