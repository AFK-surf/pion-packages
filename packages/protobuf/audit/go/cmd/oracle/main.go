// Differential oracle for the packages/protobuf red-team audit.
//
// Reference: google.golang.org/protobuf v1.36.6 (protowire, dynamicpb, protojson) with
// github.com/bufbuild/protocompile v0.14.1 as the .proto compiler (protoc-equivalent).
//
// Protocol (same as ../../probe): one output line per input hex line.
//
//	oracle varint <hexfile>                 OK <u64> <consumed> | ERR <msg>
//	oracle tag <hexfile>                    OK <num> <wiretype> | ERR <msg>
//	oracle wire <hexfile>                   OK <fields>          | ERR <msg>   (top-level skip of every field)
//	oracle dyn <x.proto> <Msg> <hexfile>    OK\t<json>\t<hex>    | ERR\t<msg>  (dynamicpb + protojson + deterministic Marshal)
//	oracle dynall <x.proto> <Msg> <hexfile> same, JSON with EmitUnpopulated
//	oracle canon <x.proto> <Msg> <hexfile>  OK <hex>             | ERR <msg>   (Unmarshal + deterministic Marshal)
//	oracle schema <x.proto>                 OK <summary>         | ERR <msg>
//	oracle schemahex <hexfile>              one hex-encoded .proto source per line
//	oracle deepdec <n>                      decode an n-deep Node{child} chain (RecursionLimit = n+10)
//	oracle bench <mode> <x.proto> <Msg> <file.bin> <iters>   modes: dec | decjson | roundtrip
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"

	"github.com/bufbuild/protocompile"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/types/dynamicpb"
)

func readLines(path string) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	var out []string
	for _, l := range strings.Split(string(data), "\n") {
		l = strings.TrimSpace(l)
		if l != "" {
			out = append(out, l)
		}
	}
	return out
}

func compile(path string) (protoreflect.FileDescriptor, error) {
	src, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return compileSource(string(src))
}

func compileSource(src string) (fd protoreflect.FileDescriptor, err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("protocompile panic: %v", r)
		}
	}()
	c := protocompile.Compiler{
		Resolver: protocompile.WithStandardImports(&protocompile.SourceResolver{
			Accessor: protocompile.SourceAccessorFromMap(map[string]string{"input.proto": src}),
		}),
	}
	files, err := c.Compile(context.Background(), "input.proto")
	if err != nil {
		return nil, err
	}
	return files[0], nil
}

func findMsg(fd protoreflect.FileDescriptor, name string) protoreflect.MessageDescriptor {
	full := name
	if pkg := string(fd.Package()); pkg != "" && !strings.HasPrefix(name, pkg+".") {
		full = pkg + "." + name
	}
	var found protoreflect.MessageDescriptor
	var walk func(ms protoreflect.MessageDescriptors)
	walk = func(ms protoreflect.MessageDescriptors) {
		for i := 0; i < ms.Len() && found == nil; i++ {
			m := ms.Get(i)
			if string(m.FullName()) == full {
				found = m
				return
			}
			walk(m.Messages())
		}
	}
	walk(fd.Messages())
	return found
}

func compactJSON(b []byte) string {
	var buf bytes.Buffer
	if err := json.Compact(&buf, b); err != nil {
		return "JSONERR " + err.Error()
	}
	return buf.String()
}

func oneline(s string) string { return strings.ReplaceAll(s, "\n", " ") }

func dyn(md protoreflect.MessageDescriptor, in []byte, emitAll bool) string {
	m := dynamicpb.NewMessage(md)
	if err := proto.Unmarshal(in, m); err != nil {
		return "ERR\t" + oneline(err.Error())
	}
	j, err := protojson.MarshalOptions{EmitUnpopulated: emitAll}.Marshal(m)
	js := ""
	if err != nil {
		js = "JSONERR " + oneline(err.Error())
	} else {
		js = compactJSON(j)
	}
	b, err := proto.MarshalOptions{Deterministic: true}.Marshal(m)
	if err != nil {
		return "OK\t" + js + "\tENCERR " + oneline(err.Error())
	}
	return "OK\t" + js + "\t" + hex.EncodeToString(b)
}

func summarize(fd protoreflect.FileDescriptor) string {
	var parts []string
	var walk func(ms protoreflect.MessageDescriptors)
	walk = func(ms protoreflect.MessageDescriptors) {
		for i := 0; i < ms.Len(); i++ {
			m := ms.Get(i)
			if m.IsMapEntry() {
				continue
			}
			var fs []string
			for j := 0; j < m.Fields().Len(); j++ {
				f := m.Fields().Get(j)
				fs = append(fs, fmt.Sprintf("%s=%d", f.Name(), f.Number()))
			}
			sort.Strings(fs)
			parts = append(parts, string(m.Name())+"{"+strings.Join(fs, ",")+"}")
			walk(m.Messages())
		}
	}
	walk(fd.Messages())
	return strings.Join(parts, ";")
}

func lines(mode, path string, f func([]byte) string) {
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	for _, l := range readLines(path) {
		if l == "-" {
			l = ""
		}
		in, err := hex.DecodeString(l)
		if err != nil {
			fmt.Fprintln(w, "BADHEX")
			continue
		}
		fmt.Fprintln(w, f(in))
	}
}

func wireSkip(in []byte) string {
	n := 0
	for len(in) > 0 {
		num, typ, k := protowire.ConsumeTag(in)
		if k < 0 {
			return "ERR " + protowire.ParseError(k).Error()
		}
		m := protowire.ConsumeFieldValue(num, typ, in[k:])
		if m < 0 {
			return "ERR " + protowire.ParseError(m).Error()
		}
		in = in[k+m:]
		n++
	}
	return fmt.Sprintf("OK %d", n)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: see source")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "varint":
		lines("varint", os.Args[2], func(in []byte) string {
			v, n := protowire.ConsumeVarint(in)
			if n < 0 {
				return "ERR " + protowire.ParseError(n).Error()
			}
			return fmt.Sprintf("OK %d %d", v, n)
		})
	case "tag":
		lines("tag", os.Args[2], func(in []byte) string {
			num, typ, n := protowire.ConsumeTag(in)
			if n < 0 {
				return "ERR " + protowire.ParseError(n).Error()
			}
			return fmt.Sprintf("OK %d %d", num, typ)
		})
	case "wire":
		lines("wire", os.Args[2], wireSkip)
	case "schemahex":
		lines("schemahex", os.Args[2], func(in []byte) string {
			fd, err := compileSource(string(in))
			if err != nil {
				return "ERR " + oneline(err.Error())
			}
			return "OK " + summarize(fd)
		})
	case "dyn", "dynall", "canon":
		fd, err := compile(os.Args[2])
		if err != nil {
			fmt.Println("SCHEMAERR " + oneline(err.Error()))
			os.Exit(0)
		}
		md := findMsg(fd, os.Args[3])
		if md == nil {
			fmt.Println("NOMSG " + os.Args[3])
			os.Exit(0)
		}
		lines(os.Args[1], os.Args[4], func(in []byte) string {
			if os.Args[1] == "canon" {
				m := dynamicpb.NewMessage(md)
				if err := (proto.UnmarshalOptions{AllowPartial: true}).Unmarshal(in, m); err != nil {
					return "ERR " + oneline(err.Error())
				}
				b, err := proto.MarshalOptions{Deterministic: true, AllowPartial: true}.Marshal(m)
				if err != nil {
					return "ERR " + oneline(err.Error())
				}
				return "OK " + hex.EncodeToString(b)
			}
			return dyn(md, in, os.Args[1] == "dynall")
		})
	case "schema":
		fd, err := compile(os.Args[2])
		if err != nil {
			fmt.Println("ERR " + oneline(err.Error()))
			return
		}
		fmt.Println("OK " + summarize(fd))
	case "deepdec":
		n, _ := strconv.Atoi(os.Args[2])
		deepdec(n)
	case "bench":
		iters, _ := strconv.Atoi(os.Args[6])
		bench(os.Args[2], os.Args[3], os.Args[4], os.Args[5], iters)
	default:
		fmt.Fprintln(os.Stderr, "unknown mode")
		os.Exit(2)
	}
}

// deepdec builds Node{child: Node{child: ...}} n levels deep and decodes it with
// RecursionLimit n+10 (Go's own default is 10000).
func deepdec(n int) {
	fd, err := compileSource("syntax = \"proto3\"; message Node { Node child = 1; }")
	if err != nil {
		fmt.Println("ERR", err)
		return
	}
	md := fd.Messages().ByName("Node")
	payload := []byte{}
	for i := 0; i < n; i++ {
		b := protowire.AppendTag(nil, 1, protowire.BytesType)
		b = protowire.AppendBytes(b, payload)
		payload = b
	}
	m := dynamicpb.NewMessage(md)
	if err := (proto.UnmarshalOptions{RecursionLimit: n + 10}).Unmarshal(payload, m); err != nil {
		fmt.Println("ERR", err)
		return
	}
	out, err := proto.Marshal(m)
	if err != nil {
		fmt.Println("ENCERR", err)
		return
	}
	fmt.Printf("OK decoded+reencoded depth=%d len=%d\n", n, len(out))
}

// bench: length-prefixed (4-byte LE) records in file; decode each with dynamicpb.
func bench(mode, protoPath, msgName, dataPath string, iters int) {
	fd, err := compile(protoPath)
	if err != nil {
		fmt.Println("ERR", err)
		os.Exit(1)
	}
	md := findMsg(fd, msgName)
	data, err := os.ReadFile(dataPath)
	if err != nil {
		fmt.Println("ERR", err)
		os.Exit(1)
	}
	var recs [][]byte
	for p := 0; p+4 <= len(data); {
		n := int(data[p]) | int(data[p+1])<<8 | int(data[p+2])<<16 | int(data[p+3])<<24
		recs = append(recs, data[p+4:p+4+n])
		p += 4 + n
	}
	var fields, outBytes int64
	for it := 0; it < iters; it++ {
		for _, r := range recs {
			m := dynamicpb.NewMessage(md)
			if err := proto.Unmarshal(r, m); err != nil {
				fmt.Println("ERR", err)
				os.Exit(1)
			}
			switch mode {
			case "dec":
				m.Range(func(protoreflect.FieldDescriptor, protoreflect.Value) bool { fields++; return true })
			case "decjson":
				j, err := protojson.Marshal(m)
				if err != nil {
					fmt.Println("ERR", err)
					os.Exit(1)
				}
				outBytes += int64(len(j))
				fields++
			case "roundtrip":
				b, err := proto.Marshal(m)
				if err != nil {
					fmt.Println("ERR", err)
					os.Exit(1)
				}
				outBytes += int64(len(b))
				fields++
			}
		}
	}
	if mode == "decjson" {
		// JSON byte counts legitimately differ (whitespace randomisation); print records only.
		fmt.Printf("records=%d\n", fields)
		return
	}
	fmt.Printf("records=%d fields=%d bytes=%d\n", int64(len(recs))*int64(iters), fields, outBytes)
}
