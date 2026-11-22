// Differential probe: reference behaviour of Go's standard library for the kinds it covers.
// Kinds it has no equivalent for print "N/A".
package main

import (
	"bufio"
	"fmt"
	"net/http"
	"net/mail"
	"os"
	"strconv"
	"strings"
	"time"
)

func run(kind, in string) string {
	w := strings.Split(in, " ")
	switch kind {
	case "ts":
		t, err := time.Parse(time.RFC3339Nano, in)
		if err != nil {
			return "ERR"
		}
		return fmt.Sprintf("OK %d %d", t.Unix(), t.Nanosecond())
	case "tsfmt":
		s, _ := strconv.ParseInt(w[0], 10, 64)
		n, _ := strconv.ParseInt(w[1], 10, 64)
		o, _ := strconv.Atoi(w[2])
		return "OK " + time.Unix(s, n).In(time.FixedZone("", o)).Format(time.RFC3339Nano)
	case "http":
		t, err := http.ParseTime(in)
		if err != nil {
			return "ERR"
		}
		return fmt.Sprintf("OK %d", t.Unix())
	case "r2822":
		t, err := mail.ParseDate(in)
		if err != nil {
			return "ERR"
		}
		_, off := t.Zone()
		return fmt.Sprintf("OK %d %d", t.Unix(), off)
	case "date":
		t, err := time.Parse("2006-01-02", in)
		if err != nil {
			return "ERR"
		}
		return "OK " + t.Format("2006-01-02")
	}
	return "N/A"
}

func main() {
	f, err := os.Open(os.Args[1])
	if err != nil {
		panic(err)
	}
	out := bufio.NewWriter(os.Stdout)
	defer out.Flush()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		k, in, ok := strings.Cut(sc.Text(), "\t")
		if !ok {
			continue
		}
		fmt.Fprintf(out, "%s\t%s\t%s\n", k, in, run(k, in))
	}
}
