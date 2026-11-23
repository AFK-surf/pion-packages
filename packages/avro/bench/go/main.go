package main

import (
	"bytes"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"strconv"

	"github.com/hamba/avro/v2"
	"github.com/hamba/avro/v2/ocf"
)

const schemaV1JSON = `{"name":"com.bench.TelemetryEvent","type":"record","fields":[{"name":"id","type":"int"},{"name":"ts","type":"long"},{"name":"score","type":"float"},{"name":"service","type":"string"},{"name":"tags","type":{"type":"array","items":"string"}},{"name":"metrics","type":{"type":"map","values":"long"}},{"name":"note","type":["null","string"]}]}`

const schemaV2JSON = `{"name":"com.bench.TelemetryEvent","type":"record","fields":[{"name":"service","type":"string"},{"name":"id","type":"long"},{"name":"score","type":"double"},{"name":"tags","type":{"type":"array","items":"string"}},{"name":"note","type":["null","string"]},{"name":"region","type":"string","default":"ap-northeast-1"}]}`

type EventV1 struct {
	ID      int32            `avro:"id"`
	TS      int64            `avro:"ts"`
	Score   float32          `avro:"score"`
	Service string           `avro:"service"`
	Tags    []string         `avro:"tags"`
	Metrics map[string]int64 `avro:"metrics"`
	Note    *string          `avro:"note"`
}

type EventV2 struct {
	Service string   `avro:"service"`
	ID      int64    `avro:"id"`
	Score   float64  `avro:"score"`
	Tags    []string `avro:"tags"`
	Note    *string  `avro:"note"`
	Region  string   `avro:"region"`
}

func makeV1Records(count int) []EventV1 {
	svcs := make([]string, 16)
	for i := range svcs {
		svcs[i] = "svc-" + strconv.Itoa(i)
	}
	tiers := []string{"tier:0", "tier:1", "tier:2", "tier:3"}
	msgs := make([]string, 64)
	for i := range msgs {
		msgs[i] = "msg-" + strconv.Itoa(i)
	}
	recs := make([]EventV1, count)
	for i := 0; i < count; i++ {
		var note *string
		if i%3 != 0 {
			s := msgs[i%64]
			note = &s
		}
		recs[i] = EventV1{
			ID:      int32(i),
			TS:      1700000000000 + int64(i)*13,
			Score:   float32(i%1000) * 0.25,
			Service: svcs[i%16],
			Tags:    []string{"env:prod", tiers[i%4]},
			Metrics: map[string]int64{"cpu": int64(i%100 + 1)},
			Note:    note,
		}
	}
	return recs
}

func summarizeV1(recs []EventV1) string {
	var sumID, sumTS, sumScoreQ4, sumTags, sumMetrics, nonNull int64
	for i := range recs {
		r := &recs[i]
		sumID += int64(r.ID)
		sumTS += r.TS
		sumScoreQ4 += int64(int(r.Score * 4.0))
		sumTags += int64(len(r.Tags))
		for _, v := range r.Metrics {
			sumMetrics += v
		}
		if r.Note != nil {
			nonNull++
		}
	}
	return fmt.Sprintf("count=%d sum_id=%d sum_ts=%d sum_score_q4=%d sum_tags=%d sum_metrics=%d non_null_notes=%d",
		len(recs), sumID, sumTS, sumScoreQ4, sumTags, sumMetrics, nonNull)
}

func summarizeV2(recs []EventV2) string {
	var sumID, sumScoreQ4, sumTags, nonNull, regionOK int64
	for i := range recs {
		r := &recs[i]
		sumID += r.ID
		sumScoreQ4 += int64(int(r.Score * 4.0))
		sumTags += int64(len(r.Tags))
		if r.Note != nil {
			nonNull++
		}
		if r.Region == "ap-northeast-1" {
			regionOK++
		}
	}
	return fmt.Sprintf("count=%d sum_id=%d sum_score_q4=%d sum_tags=%d non_null_notes=%d region_ok=%d",
		len(recs), sumID, sumScoreQ4, sumTags, nonNull, regionOK)
}

func summarizeV1Any(recs []map[string]any) string {
	var sumID, sumTS, sumScoreQ4, sumTags, sumMetrics, nonNull int64
	for _, m := range recs {
		sumID += int64(m["id"].(int))
		sumTS += m["ts"].(int64)
		sumScoreQ4 += int64(int(m["score"].(float32) * 4.0))
		sumTags += int64(len(m["tags"].([]any)))
		for _, v := range m["metrics"].(map[string]any) {
			sumMetrics += v.(int64)
		}
		if m["note"] != nil {
			nonNull++
		}
	}
	return fmt.Sprintf("count=%d sum_id=%d sum_ts=%d sum_score_q4=%d sum_tags=%d sum_metrics=%d non_null_notes=%d",
		len(recs), sumID, sumTS, sumScoreQ4, sumTags, sumMetrics, nonNull)
}

func summarizeV2Any(recs []map[string]any) string {
	var sumID, sumScoreQ4, sumTags, nonNull, regionOK int64
	for _, m := range recs {
		sumID += m["id"].(int64)
		sumScoreQ4 += int64(int(m["score"].(float64) * 4.0))
		sumTags += int64(len(m["tags"].([]any)))
		if m["note"] != nil {
			nonNull++
		}
		if m["region"].(string) == "ap-northeast-1" {
			regionOK++
		}
	}
	return fmt.Sprintf("count=%d sum_id=%d sum_score_q4=%d sum_tags=%d non_null_notes=%d region_ok=%d",
		len(recs), sumID, sumScoreQ4, sumTags, nonNull, regionOK)
}

func makeV1AnyRecords(count int) []map[string]any {
	svcs := make([]string, 16)
	for i := range svcs {
		svcs[i] = "svc-" + strconv.Itoa(i)
	}
	tiers := []string{"tier:0", "tier:1", "tier:2", "tier:3"}
	msgs := make([]string, 64)
	for i := range msgs {
		msgs[i] = "msg-" + strconv.Itoa(i)
	}
	recs := make([]map[string]any, count)
	for i := 0; i < count; i++ {
		var note any
		if i%3 != 0 {
			note = map[string]any{"string": msgs[i%64]}
		}
		recs[i] = map[string]any{
			"id":      i,
			"ts":      1700000000000 + int64(i)*13,
			"score":   float32(i%1000) * 0.25,
			"service": svcs[i%16],
			"tags":    []string{"env:prod", tiers[i%4]},
			"metrics": map[string]int64{"cpu": int64(i%100 + 1)},
			"note":    note,
		}
	}
	return recs
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: go_bench <w1|w2|w3|gen_v1|write_ocf|read_ocf|fp> ...")
		os.Exit(1)
	}
	mode := os.Args[1]
	s1 := avro.MustParse(schemaV1JSON)
	s2 := avro.MustParse(schemaV2JSON)

	switch mode {
	case "fp":
		fp, err := s1.FingerprintUsing(avro.CRC64Avro)
		if err != nil {
			panic(err)
		}
		// hamba/avro returns big-endian 8 bytes for CRC64Avro
		fmt.Printf("fp_v1=%s\n", hex.EncodeToString(fp))
	case "gen_v1":
		outPath := os.Args[2]
		count, _ := strconv.Atoi(os.Args[3])
		recs := makeV1Records(count)
		var buf bytes.Buffer
		enc := avro.NewEncoderForSchema(s1, &buf)
		for i := range recs {
			if err := enc.Encode(&recs[i]); err != nil {
				panic(err)
			}
		}
		if err := os.WriteFile(outPath, buf.Bytes(), 0644); err != nil {
			panic(err)
		}
		fmt.Printf("gen_v1 bytes=%d\n", buf.Len())
	case "decode_v1":
		inPath := os.Args[2]
		count, _ := strconv.Atoi(os.Args[3])
		raw, err := os.ReadFile(inPath)
		if err != nil {
			panic(err)
		}
		dec := avro.NewDecoderForSchema(s1, bytes.NewReader(raw))
		out := make([]EventV1, count)
		for i := 0; i < count; i++ {
			if err := dec.Decode(&out[i]); err != nil {
				panic(err)
			}
		}
		fmt.Printf("interop_v1 %s\n", summarizeV1(out))
	case "w1":
		count, _ := strconv.Atoi(os.Args[2])
		recs := makeV1Records(count)
		var buf bytes.Buffer
		enc := avro.NewEncoderForSchema(s1, &buf)
		for i := range recs {
			if err := enc.Encode(&recs[i]); err != nil {
				panic(err)
			}
		}
		dec := avro.NewDecoderForSchema(s1, bytes.NewReader(buf.Bytes()))
		out := make([]EventV1, count)
		for i := 0; i < count; i++ {
			if err := dec.Decode(&out[i]); err != nil {
				panic(err)
			}
		}
		fmt.Printf("mode=w1 %s\n", summarizeV1(out))
	case "w2":
		inPath := os.Args[2]
		count, _ := strconv.Atoi(os.Args[3])
		raw, err := os.ReadFile(inPath)
		if err != nil {
			panic(err)
		}
		resolved, err := avro.NewSchemaCompatibility().Resolve(s2, s1)
		if err != nil {
			panic(err)
		}
		dec := avro.NewDecoderForSchema(resolved, bytes.NewReader(raw))
		out := make([]EventV2, count)
		for i := 0; i < count; i++ {
			if err := dec.Decode(&out[i]); err != nil {
				panic(err)
			}
		}
		fmt.Printf("mode=w2 %s\n", summarizeV2(out))
	case "w3":
		count, _ := strconv.Atoi(os.Args[2])
		recs := makeV1Records(count)
		var buf bytes.Buffer
		enc, err := ocf.NewEncoder(schemaV1JSON, &buf, ocf.WithCodec(ocf.Deflate), ocf.WithBlockLength(1000))
		if err != nil {
			panic(err)
		}
		for i := range recs {
			if err := enc.Encode(&recs[i]); err != nil {
				panic(err)
			}
		}
		if err := enc.Flush(); err != nil {
			panic(err)
		}
		dec, err := ocf.NewDecoder(bytes.NewReader(buf.Bytes()))
		if err != nil {
			panic(err)
		}
		out := make([]EventV1, 0, count)
		for dec.HasNext() {
			var ev EventV1
			if err := dec.Decode(&ev); err != nil {
				panic(err)
			}
			out = append(out, ev)
		}
		if err := dec.Error(); err != nil && err != io.EOF {
			panic(err)
		}
		fmt.Printf("mode=w3 %s\n", summarizeV1(out))
	case "w1_any":
		count, _ := strconv.Atoi(os.Args[2])
		recs := makeV1AnyRecords(count)
		var buf bytes.Buffer
		enc := avro.NewEncoderForSchema(s1, &buf)
		for i := range recs {
			if err := enc.Encode(recs[i]); err != nil {
				panic(err)
			}
		}
		dec := avro.NewDecoderForSchema(s1, bytes.NewReader(buf.Bytes()))
		out := make([]map[string]any, count)
		for i := 0; i < count; i++ {
			var v any
			if err := dec.Decode(&v); err != nil {
				panic(err)
			}
			out[i] = v.(map[string]any)
		}
		fmt.Printf("mode=w1 %s\n", summarizeV1Any(out))
	case "w2_any":
		inPath := os.Args[2]
		count, _ := strconv.Atoi(os.Args[3])
		raw, err := os.ReadFile(inPath)
		if err != nil {
			panic(err)
		}
		resolved, err := avro.NewSchemaCompatibility().Resolve(s2, s1)
		if err != nil {
			panic(err)
		}
		dec := avro.NewDecoderForSchema(resolved, bytes.NewReader(raw))
		out := make([]map[string]any, count)
		for i := 0; i < count; i++ {
			var v any
			if err := dec.Decode(&v); err != nil {
				panic(err)
			}
			out[i] = v.(map[string]any)
		}
		fmt.Printf("mode=w2 %s\n", summarizeV2Any(out))
	case "w3_any":
		count, _ := strconv.Atoi(os.Args[2])
		recs := makeV1AnyRecords(count)
		var buf bytes.Buffer
		enc, err := ocf.NewEncoder(schemaV1JSON, &buf, ocf.WithCodec(ocf.Deflate), ocf.WithBlockLength(1000))
		if err != nil {
			panic(err)
		}
		for i := range recs {
			if err := enc.Encode(recs[i]); err != nil {
				panic(err)
			}
		}
		if err := enc.Flush(); err != nil {
			panic(err)
		}
		dec, err := ocf.NewDecoder(bytes.NewReader(buf.Bytes()))
		if err != nil {
			panic(err)
		}
		out := make([]map[string]any, 0, count)
		for dec.HasNext() {
			var v any
			if err := dec.Decode(&v); err != nil {
				panic(err)
			}
			out = append(out, v.(map[string]any))
		}
		if err := dec.Error(); err != nil && err != io.EOF {
			panic(err)
		}
		fmt.Printf("mode=w3 %s\n", summarizeV1Any(out))
	case "write_ocf":
		outPath := os.Args[2]
		count, _ := strconv.Atoi(os.Args[3])
		recs := makeV1Records(count)
		var buf bytes.Buffer
		enc, err := ocf.NewEncoder(schemaV1JSON, &buf, ocf.WithCodec(ocf.Deflate), ocf.WithBlockLength(1000))
		if err != nil {
			panic(err)
		}
		for i := range recs {
			if err := enc.Encode(&recs[i]); err != nil {
				panic(err)
			}
		}
		if err := enc.Flush(); err != nil {
			panic(err)
		}
		if err := os.WriteFile(outPath, buf.Bytes(), 0644); err != nil {
			panic(err)
		}
		fmt.Printf("write_ocf bytes=%d\n", buf.Len())
	case "read_ocf":
		inPath := os.Args[2]
		raw, err := os.ReadFile(inPath)
		if err != nil {
			panic(err)
		}
		dec, err := ocf.NewDecoder(bytes.NewReader(raw))
		if err != nil {
			panic(err)
		}
		var out []EventV1
		for dec.HasNext() {
			var ev EventV1
			if err := dec.Decode(&ev); err != nil {
				panic(err)
			}
			out = append(out, ev)
		}
		if err := dec.Error(); err != nil && err != io.EOF {
			panic(err)
		}
		fmt.Printf("interop_ocf %s\n", summarizeV1(out))
	default:
		fmt.Fprintf(os.Stderr, "unknown mode: %s\n", mode)
		os.Exit(1)
	}
}
