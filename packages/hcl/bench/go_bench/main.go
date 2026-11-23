package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"

	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/hclsyntax"
	"github.com/hashicorp/hcl/v2/hclwrite"
	"github.com/zclconf/go-cty/cty"
	"github.com/zclconf/go-cty/cty/function"
	"github.com/zclconf/go-cty/cty/function/stdlib"
	ctyjson "github.com/zclconf/go-cty/cty/json"
)

func fnv1aStr(seed uint32, s string) uint32 {
	h := seed
	for i := 0; i < len(s); i++ {
		h = (h ^ uint32(s[i])) * 16777619
	}
	return h
}

func buildLargeTFConfig(numResources int) string {
	var sb strings.Builder
	for i := 0; i < 10; i++ {
		fmt.Fprintf(&sb, "variable \"region_%d\" {\n  default = \"us-west-%d\"\n}\n\n", i, (i%2)+1)
	}
	sb.WriteString("locals {\n  env_tag = \"prod-${var.region_0}\"\n  ports   = [for p in [80, 443, 8080] : p + 1000 if p > 80]\n}\n\n")
	for i := 0; i < numResources; i++ {
		fmt.Fprintf(&sb, "resource \"aws_instance\" \"node_%d\" {\n", i)
		sb.WriteString("  ami           = \"ami-0c55b159cbfafe1f0\"\n")
		sb.WriteString("  instance_type = \"t3.medium\"\n")
		fmt.Fprintf(&sb, "  subnet_id     = \"subnet-%d\"\n", i%16)
		fmt.Fprintf(&sb, "  tags = {\n    Name = \"web-${local.env_tag}-%d\"\n    Tier = \"app\"\n  }\n", i)
		sb.WriteString("  user_data = <<-EOF\n")
		sb.WriteString("    #!/bin/sh\n")
		fmt.Fprintf(&sb, "    echo \"node=%d env=${local.env_tag}\"\n", i)
		sb.WriteString("  EOF\n")
		fmt.Fprintf(&sb, "  root_block_device {\n    volume_size = %d\n    encrypted   = true\n  }\n", 20+(i%5)*10)
		sb.WriteString("}\n\n")
	}
	for i := 0; i < 100; i++ {
		fmt.Fprintf(&sb, "module \"svc_%d\" {\n  source = \"./modules/service\"\n  count  = %d\n}\n\n", i, (i%4)+1)
	}
	return sb.String()
}

func countBody(body *hclsyntax.Body) (int, int, int, uint32) {
	blocks := len(body.Blocks)
	labels := 0
	attrs := len(body.Attributes)
	h := uint32(2166136261)

	// Sort attributes by source offset to match declaration order
	type attrEntry struct {
		name   string
		offset int
	}
	attrList := make([]attrEntry, 0, len(body.Attributes))
	for name, a := range body.Attributes {
		attrList = append(attrList, attrEntry{name: name, offset: a.SrcRange.Start.Byte})
	}
	sort.Slice(attrList, func(i, j int) bool { return attrList[i].offset < attrList[j].offset })
	for _, a := range attrList {
		h = fnv1aStr(h, a.name)
	}
	for _, b := range body.Blocks {
		h = fnv1aStr(h, b.Type)
		labels += len(b.Labels)
		for _, l := range b.Labels {
			h = fnv1aStr(h, l)
		}
		sb, sl, sa, sh := countBody(b.Body)
		blocks += sb
		labels += sl
		attrs += sa
		h = (h ^ sh) * 16777619
	}
	return blocks, labels, attrs, h
}

func runW1(iters int) int {
	src := buildLargeTFConfig(1000)
	srcBytes := []byte(src)
	totalBlocks := 0
	totalLabels := 0
	totalAttrs := 0
	checksum := uint32(2166136261)

	for i := 0; i < iters; i++ {
		file, diags := hclsyntax.ParseConfig(srcBytes, "bench.tf", hcl.Pos{Line: 1, Column: 1})
		if diags.HasErrors() {
			fmt.Fprintf(os.Stderr, "w1 parse error: %s\n", diags.Error())
			return 2
		}
		bl, lb, at, h := countBody(file.Body.(*hclsyntax.Body))
		totalBlocks += bl
		totalLabels += lb
		totalAttrs += at
		checksum = (checksum ^ h) * 16777619
	}
	fmt.Printf("w1 iters=%d bytes=%d blocks=%d labels=%d attrs=%d checksum=%d\n",
		iters, len(srcBytes), totalBlocks, totalLabels, totalAttrs, checksum)
	return 0
}

func runW2(iters int) int {
	cfg := `service   = "api-${lower(env)}-${replicas}"
endpoint  = "https://${host}:${port}/v1"
is_prod   = env == "PROD" && replicas >= 3 ? true : false
active    = [for s in servers : upper(s.id) if s.active && s.weight > 10]
by_region = {for s in servers : s.region => s.id...}
all_ids   = servers[*].id
joined    = join(",", concat(["seed"], servers[*].id))
merged    = merge(base_tags, { env = lower(env), total = length(servers) })
summary   = "%{for i, s in servers ~}${i}:${s.id}%{if i < 3}|%{endif}%{~ endfor}"
bounds    = [min(10, replicas, 2), max(10, replicas, 2)]
`
	cfgBytes := []byte(cfg)

	evalCtx := &hcl.EvalContext{
		Variables: map[string]cty.Value{
			"env":      cty.StringVal("PROD"),
			"replicas": cty.NumberIntVal(4),
			"host":     cty.StringVal("gateway.internal"),
			"port":     cty.NumberIntVal(8443),
			"base_tags": cty.ObjectVal(map[string]cty.Value{
				"team": cty.StringVal("infra"),
				"tier": cty.StringVal("core"),
			}),
			"servers": cty.TupleVal([]cty.Value{
				cty.ObjectVal(map[string]cty.Value{
					"id":     cty.StringVal("srv-a"),
					"region": cty.StringVal("us-east"),
					"weight": cty.NumberIntVal(25),
					"active": cty.BoolVal(true),
				}),
				cty.ObjectVal(map[string]cty.Value{
					"id":     cty.StringVal("srv-b"),
					"region": cty.StringVal("us-west"),
					"weight": cty.NumberIntVal(5),
					"active": cty.BoolVal(true),
				}),
				cty.ObjectVal(map[string]cty.Value{
					"id":     cty.StringVal("srv-c"),
					"region": cty.StringVal("us-east"),
					"weight": cty.NumberIntVal(40),
					"active": cty.BoolVal(false),
				}),
				cty.ObjectVal(map[string]cty.Value{
					"id":     cty.StringVal("srv-d"),
					"region": cty.StringVal("eu-west"),
					"weight": cty.NumberIntVal(50),
					"active": cty.BoolVal(true),
				}),
			}),
		},
		Functions: map[string]function.Function{
			"lower":  stdlib.LowerFunc,
			"upper":  stdlib.UpperFunc,
			"join":   stdlib.JoinFunc,
			"concat": stdlib.ConcatFunc,
			"merge":  stdlib.MergeFunc,
			"length": stdlib.LengthFunc,
			"min":    stdlib.MinFunc,
			"max":    stdlib.MaxFunc,
		},
	}

	checksum := uint32(2166136261)
	lastJSON := ""

	for i := 0; i < iters; i++ {
		file, diags := hclsyntax.ParseConfig(cfgBytes, "eval.tf", hcl.Pos{Line: 1, Column: 1})
		if diags.HasErrors() {
			fmt.Fprintf(os.Stderr, "w2 parse error: %s\n", diags.Error())
			return 2
		}
		body := file.Body.(*hclsyntax.Body)
		vals := make(map[string]cty.Value, len(body.Attributes))
		for name, attr := range body.Attributes {
			v, ediags := attr.Expr.Value(evalCtx)
			if ediags.HasErrors() {
				fmt.Fprintf(os.Stderr, "w2 eval error (%s): %s\n", name, ediags.Error())
				return 3
			}
			vals[name] = v
		}
		obj := cty.ObjectVal(vals)
		rawJSON, err := json.Marshal(ctyjson.SimpleJSONValue{Value: obj})
		if err != nil {
			fmt.Fprintf(os.Stderr, "w2 json error: %v\n", err)
			return 4
		}
		js := string(rawJSON)
		checksum = fnv1aStr(checksum, js)
		lastJSON = js
	}
	fmt.Printf("w2 iters=%d checksum=%d\n", iters, checksum)
	fmt.Println(lastJSON)
	return 0
}

func runW3(iters int) int {
	raw := `# Cluster configuration
resource   "aws_s3_bucket"   "logs"{
bucket="my-prod-logs" # primary bucket
acl ="private" // access control
force_destroy=true

versioning {
enabled=true
}
}

resource "aws_instance" "web" {
ami="ami-0c55b159"
instance_type ="t3.large"
count=1+2*3
tags = {
Name="web-prod"
Environment="production"
Owner="platform-team"
}
vpc_security_group_ids = [
"sg-0123456789abcdef0",
"sg-fedcba9876543210",
]
user_data=<<EOF
  #!/bin/sh
  echo hello
EOF

lifecycle {
create_before_destroy=true
}
}

locals {
env = "prod"
ports = [for p in [80,443,8080]: p+1000 if p!=80]
}
`
	rawBytes := []byte(raw)
	checksum := uint32(2166136261)
	lastFmt := ""
	for i := 0; i < iters; i++ {
		out := hclwrite.Format(rawBytes)
		s := string(out)
		checksum = fnv1aStr(checksum, s)
		lastFmt = s
	}
	fmt.Printf("w3 iters=%d bytes=%d checksum=%d\n", iters, len(lastFmt), checksum)
	fmt.Println(lastFmt)
	return 0
}

func main() {
	if len(os.Args) < 3 {
		fmt.Println("usage: go_hcl <w1|w2|w3> <iters>")
		os.Exit(1)
	}
	mode := os.Args[1]
	iters, err := strconv.Atoi(os.Args[2])
	if err != nil || iters <= 0 {
		iters = 10
	}
	switch mode {
	case "w1":
		os.Exit(runW1(iters))
	case "w2":
		os.Exit(runW2(iters))
	case "w3":
		os.Exit(runW3(iters))
	default:
		fmt.Printf("unknown mode: %s\n", mode)
		os.Exit(1)
	}
}
