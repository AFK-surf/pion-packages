package main

import (
	"fmt"
	"os"
	"strconv"

	"github.com/spf13/pflag"
)

func parseW1One(args []string) (int64, int64, int64) {
	root := pflag.NewFlagSet("cloudctl", pflag.ContinueOnError)
	root.SetInterspersed(false)
	verbose := root.CountP("verbose", "v", "Increase verbosity")
	region := root.StringP("region", "r", "us-east-1", "Cloud region")
	root.StringP("output", "o", "text", "Output format")
	root.StringP("config", "c", "config.toml", "Config path")
	root.StringP("format", "f", "json", "Payload format")

	strOpts := make([]*string, 10)
	for i := 0; i < 10; i++ {
		strOpts[i] = root.String("str-"+strconv.Itoa(i), "def"+strconv.Itoa(i), "String option")
	}
	flagOpts := make([]*bool, 10)
	for j := 0; j < 10; j++ {
		flagOpts[j] = root.Bool("flag-"+strconv.Itoa(j), false, "Boolean flag")
	}
	for k := 0; k < 5; k++ {
		root.Int("num-"+strconv.Itoa(k), 10, "Numeric option")
	}

	if err := root.Parse(args); err != nil {
		panic(err)
	}
	rest := root.Args()
	// 5-level subcommand dispatch: cloud -> cluster -> node -> pool -> scale
	if len(rest) < 5 || rest[0] != "cloud" || rest[1] != "cluster" || rest[2] != "node" || rest[3] != "pool" || rest[4] != "scale" {
		panic("missing 5-level subcommand")
	}
	scale := pflag.NewFlagSet("scale", pflag.ContinueOnError)
	subVerbose := scale.CountP("verbose", "v", "Increase verbosity")
	subRegion := scale.StringP("region", "r", "", "Cloud region")
	replicas := scale.IntP("replicas", "n", 3, "Desired replicas")
	scale.Bool("dry-run", false, "Dry run")
	if err := scale.Parse(rest[5:]); err != nil {
		panic(err)
	}
	finalRegion := *region
	if *subRegion != "" {
		finalRegion = *subRegion
	}
	finalVerbose := int64(*verbose + *subVerbose)
	target := scale.Args()[0]
	var strLen int64 = int64(len(finalRegion) + len(*strOpts[0]) + len(target))
	if *flagOpts[2] {
		strLen++
	}
	return int64(*replicas), finalVerbose, strLen
}

func benchW1() {
	samples := [][]string{
		{"-vv", "--region", "ap-northeast-1", "--str-0=alpha", "--flag-2", "cloud", "cluster", "node", "pool", "scale", "-n", "12", "--dry-run", "pool-a"},
		{"--region=eu-west-1", "-v", "--str-0", "beta", "--flag-0", "--flag-5", "cloud", "cluster", "node", "pool", "scale", "--replicas=8", "pool-b"},
		{"--str-0=gamma", "cloud", "cluster", "node", "pool", "scale", "-vvv", "-n", "5", "pool-c"},
		{"-r", "us-west-2", "--flag-2", "--num-0=42", "cloud", "cluster", "node", "pool", "scale", "-n", "1", "pool-d"},
		{"-v", "--str-0=delta", "cloud", "cluster", "node", "pool", "scale", "--replicas", "16", "--region=cn-shanghai", "pool-e"},
	}

	var ops, sumReplicas, sumVerbose, sumStrLen int64
	for r := 0; r < 10000; r++ {
		for _, s := range samples {
			rep, v, sl := parseW1One(s)
			sumReplicas += rep
			sumVerbose += v
			sumStrLen += sl
			ops++
		}
	}

	fmt.Println("mode=w1")
	fmt.Printf("ops=%d\n", ops)
	fmt.Printf("sum_replicas=%d\n", sumReplicas)
	fmt.Printf("sum_verbose=%d\n", sumVerbose)
	fmt.Printf("sum_str_len=%d\n", sumStrLen)
}

func benchW2() {
	fs := pflag.NewFlagSet("batch", pflag.ContinueOnError)
	a := fs.BoolP("a", "a", false, "")
	b := fs.BoolP("b", "b", false, "")
	c := fs.BoolP("c", "c", false, "")
	verbose := fs.CountP("verbose", "v", "")
	includes := fs.StringArrayP("include", "I", nil, "")

	argv := make([]string, 0, 100000)
	for i := 0; i < 10000; i++ {
		argv = append(argv, "-abc")
	}
	for j := 0; j < 10000; j++ {
		argv = append(argv, "-vvv")
	}
	for k := 0; k < 15000; k++ {
		argv = append(argv, "-I", "dir_"+strconv.Itoa(k))
	}
	argv = append(argv, "--")
	for p := 0; p < 49999; p++ {
		switch p % 3 {
		case 0:
			argv = append(argv, "--help")
		case 1:
			argv = append(argv, "-x")
		default:
			argv = append(argv, "file_"+strconv.Itoa(p))
		}
	}

	if err := fs.Parse(argv); err != nil {
		panic(err)
	}
	aBit, bBit, cBit := 0, 0, 0
	if *a {
		aBit = 1
	}
	if *b {
		bBit = 1
	}
	if *c {
		cBit = 1
	}

	fmt.Println("mode=w2")
	fmt.Printf("tokens=%d\n", len(argv))
	fmt.Printf("a=%d b=%d c=%d\n", aBit, bBit, cBit)
	fmt.Printf("verbose=%d\n", *verbose)
	fmt.Printf("includes=%d\n", len(*includes))
	fmt.Printf("positionals=%d\n", len(fs.Args()))
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: cli_bench_go <w1|w2>")
		os.Exit(1)
	}
	switch os.Args[1] {
	case "w1":
		benchW1()
	case "w2":
		benchW2()
	default:
		fmt.Fprintf(os.Stderr, "unknown mode: %s\n", os.Args[1])
		os.Exit(1)
	}
}
