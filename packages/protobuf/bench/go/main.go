package main

import (
	"encoding/binary"
	"fmt"
	"math"
	"os"

	"google.golang.org/protobuf/encoding/protowire"
)

type KeyValue struct {
	Key      string
	StrValue string
	IntValue int64
}

type SpanEvent struct {
	TimeUnixNano      uint64
	Name              string
	DroppedAttributes int32
}

type Span struct {
	TraceID           []byte
	SpanID            []byte
	Name              string
	Kind              int32
	StartTimeUnixNano uint64
	EndTimeUnixNano   uint64
	Attributes        []KeyValue
	Events            []SpanEvent
	StatusCode        int32
	StatusMessage     string
}

func decodeKV(b []byte) (KeyValue, error) {
	var kv KeyValue
	for len(b) > 0 {
		num, wtype, n := protowire.ConsumeTag(b)
		if n < 0 {
			return kv, protowire.ParseError(n)
		}
		b = b[n:]
		switch num {
		case 1:
			v, m := protowire.ConsumeString(b)
			if m < 0 {
				return kv, protowire.ParseError(m)
			}
			kv.Key = v
			b = b[m:]
		case 2:
			v, m := protowire.ConsumeString(b)
			if m < 0 {
				return kv, protowire.ParseError(m)
			}
			kv.StrValue = v
			b = b[m:]
		case 3:
			v, m := protowire.ConsumeVarint(b)
			if m < 0 {
				return kv, protowire.ParseError(m)
			}
			kv.IntValue = int64(v)
			b = b[m:]
		default:
			m := protowire.ConsumeFieldValue(num, wtype, b)
			if m < 0 {
				return kv, protowire.ParseError(m)
			}
			b = b[m:]
		}
	}
	return kv, nil
}

func decodeEvent(b []byte) (SpanEvent, error) {
	var ev SpanEvent
	for len(b) > 0 {
		num, wtype, n := protowire.ConsumeTag(b)
		if n < 0 {
			return ev, protowire.ParseError(n)
		}
		b = b[n:]
		switch num {
		case 1:
			v, m := protowire.ConsumeVarint(b)
			if m < 0 {
				return ev, protowire.ParseError(m)
			}
			ev.TimeUnixNano = v
			b = b[m:]
		case 2:
			v, m := protowire.ConsumeString(b)
			if m < 0 {
				return ev, protowire.ParseError(m)
			}
			ev.Name = v
			b = b[m:]
		case 3:
			v, m := protowire.ConsumeVarint(b)
			if m < 0 {
				return ev, protowire.ParseError(m)
			}
			ev.DroppedAttributes = int32(v)
			b = b[m:]
		default:
			m := protowire.ConsumeFieldValue(num, wtype, b)
			if m < 0 {
				return ev, protowire.ParseError(m)
			}
			b = b[m:]
		}
	}
	return ev, nil
}

func decodeSpan(b []byte) (Span, error) {
	var sp Span
	for len(b) > 0 {
		num, wtype, n := protowire.ConsumeTag(b)
		if n < 0 {
			return sp, protowire.ParseError(n)
		}
		b = b[n:]
		switch num {
		case 1:
			v, m := protowire.ConsumeBytes(b)
			if m < 0 {
				return sp, protowire.ParseError(m)
			}
			sp.TraceID = v
			b = b[m:]
		case 2:
			v, m := protowire.ConsumeBytes(b)
			if m < 0 {
				return sp, protowire.ParseError(m)
			}
			sp.SpanID = v
			b = b[m:]
		case 3:
			v, m := protowire.ConsumeString(b)
			if m < 0 {
				return sp, protowire.ParseError(m)
			}
			sp.Name = v
			b = b[m:]
		case 4:
			v, m := protowire.ConsumeVarint(b)
			if m < 0 {
				return sp, protowire.ParseError(m)
			}
			sp.Kind = int32(v)
			b = b[m:]
		case 5:
			v, m := protowire.ConsumeVarint(b)
			if m < 0 {
				return sp, protowire.ParseError(m)
			}
			sp.StartTimeUnixNano = v
			b = b[m:]
		case 6:
			v, m := protowire.ConsumeVarint(b)
			if m < 0 {
				return sp, protowire.ParseError(m)
			}
			sp.EndTimeUnixNano = v
			b = b[m:]
		case 7:
			v, m := protowire.ConsumeBytes(b)
			if m < 0 {
				return sp, protowire.ParseError(m)
			}
			kv, err := decodeKV(v)
			if err != nil {
				return sp, err
			}
			sp.Attributes = append(sp.Attributes, kv)
			b = b[m:]
		case 8:
			v, m := protowire.ConsumeBytes(b)
			if m < 0 {
				return sp, protowire.ParseError(m)
			}
			ev, err := decodeEvent(v)
			if err != nil {
				return sp, err
			}
			sp.Events = append(sp.Events, ev)
			b = b[m:]
		case 9:
			v, m := protowire.ConsumeVarint(b)
			if m < 0 {
				return sp, protowire.ParseError(m)
			}
			sp.StatusCode = int32(v)
			b = b[m:]
		case 10:
			v, m := protowire.ConsumeString(b)
			if m < 0 {
				return sp, protowire.ParseError(m)
			}
			sp.StatusMessage = v
			b = b[m:]
		default:
			m := protowire.ConsumeFieldValue(num, wtype, b)
			if m < 0 {
				return sp, protowire.ParseError(m)
			}
			b = b[m:]
		}
	}
	return sp, nil
}

func checksumSpan(sp *Span) uint64 {
	var h uint64
	if len(sp.TraceID) > 0 {
		h += uint64(sp.TraceID[0]) + uint64(sp.TraceID[len(sp.TraceID)-1])
	}
	if len(sp.SpanID) > 0 {
		h += uint64(sp.SpanID[0]) * 3
	}
	h += uint64(len(sp.Name)) * 7
	h += uint64(int64(sp.Kind)) * 11
	h += sp.EndTimeUnixNano - sp.StartTimeUnixNano
	for i := range sp.Attributes {
		kv := &sp.Attributes[i]
		h += uint64(len(kv.Key)) * 13
		h += uint64(len(kv.StrValue)) * 17
		h += uint64(kv.IntValue) * 19
	}
	for i := range sp.Events {
		ev := &sp.Events[i]
		h += uint64(len(ev.Name)) * 23
		h += uint64(int64(ev.DroppedAttributes)) * 29
	}
	h += uint64(int64(sp.StatusCode)) * 31
	h += uint64(len(sp.StatusMessage)) * 37
	return h
}

func encodeSpan(dst, sub []byte, sp *Span) []byte {
	if len(sp.TraceID) > 0 {
		dst = protowire.AppendTag(dst, 1, protowire.BytesType)
		dst = protowire.AppendBytes(dst, sp.TraceID)
	}
	if len(sp.SpanID) > 0 {
		dst = protowire.AppendTag(dst, 2, protowire.BytesType)
		dst = protowire.AppendBytes(dst, sp.SpanID)
	}
	if len(sp.Name) > 0 {
		dst = protowire.AppendTag(dst, 3, protowire.BytesType)
		dst = protowire.AppendString(dst, sp.Name)
	}
	if sp.Kind != 0 {
		dst = protowire.AppendTag(dst, 4, protowire.VarintType)
		dst = protowire.AppendVarint(dst, uint64(sp.Kind))
	}
	if sp.StartTimeUnixNano != 0 {
		dst = protowire.AppendTag(dst, 5, protowire.VarintType)
		dst = protowire.AppendVarint(dst, sp.StartTimeUnixNano)
	}
	if sp.EndTimeUnixNano != 0 {
		dst = protowire.AppendTag(dst, 6, protowire.VarintType)
		dst = protowire.AppendVarint(dst, sp.EndTimeUnixNano)
	}
	for i := range sp.Attributes {
		kv := &sp.Attributes[i]
		sub = sub[:0]
		if len(kv.Key) > 0 {
			sub = protowire.AppendTag(sub, 1, protowire.BytesType)
			sub = protowire.AppendString(sub, kv.Key)
		}
		if len(kv.StrValue) > 0 {
			sub = protowire.AppendTag(sub, 2, protowire.BytesType)
			sub = protowire.AppendString(sub, kv.StrValue)
		}
		if kv.IntValue != 0 {
			sub = protowire.AppendTag(sub, 3, protowire.VarintType)
			sub = protowire.AppendVarint(sub, uint64(kv.IntValue))
		}
		dst = protowire.AppendTag(dst, 7, protowire.BytesType)
		dst = protowire.AppendBytes(dst, sub)
	}
	for i := range sp.Events {
		ev := &sp.Events[i]
		sub = sub[:0]
		if ev.TimeUnixNano != 0 {
			sub = protowire.AppendTag(sub, 1, protowire.VarintType)
			sub = protowire.AppendVarint(sub, ev.TimeUnixNano)
		}
		if len(ev.Name) > 0 {
			sub = protowire.AppendTag(sub, 2, protowire.BytesType)
			sub = protowire.AppendString(sub, ev.Name)
		}
		if ev.DroppedAttributes != 0 {
			sub = protowire.AppendTag(sub, 3, protowire.VarintType)
			sub = protowire.AppendVarint(sub, uint64(ev.DroppedAttributes))
		}
		dst = protowire.AppendTag(dst, 8, protowire.BytesType)
		dst = protowire.AppendBytes(dst, sub)
	}
	if sp.StatusCode != 0 {
		dst = protowire.AppendTag(dst, 9, protowire.VarintType)
		dst = protowire.AppendVarint(dst, uint64(sp.StatusCode))
	}
	if len(sp.StatusMessage) > 0 {
		dst = protowire.AppendTag(dst, 10, protowire.BytesType)
		dst = protowire.AppendString(dst, sp.StatusMessage)
	}
	return dst
}

func buildSampleSpans(count int) []Span {
	names := []string{
		"grpc.order.CreateOrder",
		"grpc.payment.Authorize",
		"http.GET /api/v1/inventory",
		"db.postgres.SELECT orders",
		"redis.HGET session:meta",
		"kafka.produce order-events",
		"auth.VerifyJwtToken",
		"cache.LookupUserProfile",
	}
	services := []string{"checkout-svc", "payment-svc", "inventory-svc", "gateway-edge"}
	regions := []string{"ap-northeast-1", "us-west-2", "eu-central-1", "ap-southeast-1"}
	out := make([]Span, count)
	for idx := 0; idx < count; idx++ {
		tid := make([]byte, 16)
		for k := 0; k < 16; k++ {
			tid[k] = byte((idx*31 + k*17) & 0xFF)
		}
		sid := make([]byte, 8)
		for k := 0; k < 8; k++ {
			sid[k] = byte((idx*13 + k*29 + 7) & 0xFF)
		}
		startNs := uint64(1700000000000000000) + uint64(idx)*125000
		endNs := startNs + 45000 + uint64(idx%997)*100
		statusCode := int32(1)
		statusMsg := ""
		if idx%17 == 0 {
			statusCode = 2
			statusMsg = "upstream deadline exceeded"
		}
		httpStatus := int64(200)
		if idx%17 == 0 {
			httpStatus = 503
		}
		out[idx] = Span{
			TraceID:           tid,
			SpanID:            sid,
			Name:              names[idx%len(names)],
			Kind:              int32(idx%5 + 1),
			StartTimeUnixNano: startNs,
			EndTimeUnixNano:   endNs,
			Attributes: []KeyValue{
				{Key: "service.name", StrValue: services[idx%len(services)]},
				{Key: "cloud.region", StrValue: regions[idx%len(regions)]},
				{Key: "http.status_code", IntValue: httpStatus},
				{Key: "rpc.retry_count", IntValue: int64(idx % 4)},
			},
			Events: []SpanEvent{
				{TimeUnixNano: startNs + 5000, Name: "request.received"},
				{TimeUnixNano: endNs - 2000, Name: "response.flushed", DroppedAttributes: int32(idx % 3)},
			},
			StatusCode:    statusCode,
			StatusMessage: statusMsg,
		}
	}
	return out
}

func fnv1aUpdate(h uint64, b []byte) uint64 {
	for _, c := range b {
		h = (h ^ uint64(c)) * 1099511628211
	}
	return h
}

func runDecodeSpans(path string) {
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	type rng struct{ s, e int }
	var slices []rng
	off := 0
	for off+4 <= len(data) {
		mlen := int(binary.LittleEndian.Uint32(data[off : off+4]))
		off += 4
		slices = append(slices, rng{off, off + mlen})
		off += mlen
	}
	const rounds = 50
	var totalSpans int64
	var totalBytes int64
	var totalChecksum uint64
	for r := 0; r < rounds; r++ {
		for _, sl := range slices {
			sp, err := decodeSpan(data[sl.s:sl.e])
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(2)
			}
			totalSpans++
			totalBytes += int64(sl.e - sl.s)
			totalChecksum += checksumSpan(&sp)
		}
	}
	fmt.Printf("spans=%d\nbytes=%d\nchecksum=%d\n", totalSpans, totalBytes, totalChecksum)
}

func runEncodeSpans() {
	spans := buildSampleSpans(2000)
	const rounds = 50
	buf := make([]byte, 0, 512)
	sub := make([]byte, 0, 128)
	var totalSpans int64
	var totalBytes int64
	var hash uint64 = 14695981039346656037
	for r := 0; r < rounds; r++ {
		for i := range spans {
			buf = encodeSpan(buf[:0], sub, &spans[i])
			totalSpans++
			totalBytes += int64(len(buf))
			if r == 0 {
				hash = fnv1aUpdate(hash, buf)
			}
		}
	}
	fmt.Printf("spans=%d\nencoded_bytes=%d\nhash=%d\n", totalSpans, totalBytes, hash)
}

func runPackedNumeric() {
	const n = 200000
	svals := make([]int64, n)
	dvals := make([]float64, n)
	for i := 0; i < n; i++ {
		sign := int64(1)
		if (i & 1) != 0 {
			sign = -1
		}
		mag := int64(i%1000)*37 + int64(i/1000)*100003
		svals[i] = sign * mag
		dvals[i] = float64(i)*0.125 - 10000.0
	}
	const rounds = 8
	buf := make([]byte, 0, 3000000)
	var totalEncoded int64
	var sint64Sum int64
	var doubleXor uint64
	for r := 0; r < rounds; r++ {
		buf = buf[:0]
		var sLen int
		for _, v := range svals {
			sLen += protowire.SizeVarint(protowire.EncodeZigZag(v))
		}
		buf = protowire.AppendTag(buf, 1, protowire.BytesType)
		buf = protowire.AppendVarint(buf, uint64(sLen))
		for _, v := range svals {
			buf = protowire.AppendVarint(buf, protowire.EncodeZigZag(v))
		}
		buf = protowire.AppendTag(buf, 2, protowire.BytesType)
		buf = protowire.AppendVarint(buf, uint64(len(dvals)*8))
		for _, d := range dvals {
			buf = protowire.AppendFixed64(buf, math.Float64bits(d))
		}
		totalEncoded += int64(len(buf))

		b := buf
		for len(b) > 0 {
			num, wtype, m := protowire.ConsumeTag(b)
			if m < 0 {
				os.Exit(2)
			}
			b = b[m:]
			if num == 1 {
				raw, k := protowire.ConsumeBytes(b)
				if k < 0 {
					os.Exit(3)
				}
				b = b[k:]
				decS := make([]int64, 0, n)
				for len(raw) > 0 {
					v, l := protowire.ConsumeVarint(raw)
					if l < 0 {
						os.Exit(3)
					}
					decS = append(decS, protowire.DecodeZigZag(v))
					raw = raw[l:]
				}
				for _, v := range decS {
					sint64Sum += v
				}
			} else if num == 2 {
				raw, k := protowire.ConsumeBytes(b)
				if k < 0 {
					os.Exit(4)
				}
				b = b[k:]
				decD := make([]float64, 0, len(raw)/8)
				for len(raw) > 0 {
					v, l := protowire.ConsumeFixed64(raw)
					if l < 0 {
						os.Exit(4)
					}
					decD = append(decD, math.Float64frombits(v))
					raw = raw[l:]
				}
				for _, d := range decD {
					doubleXor ^= math.Float64bits(d)
				}
			} else {
				k := protowire.ConsumeFieldValue(num, wtype, b)
				if k < 0 {
					os.Exit(5)
				}
				b = b[k:]
			}
		}
	}
	fmt.Printf("rounds=%d\nencoded_bytes=%d\nsint64_sum=%d\ndouble_bits_xor=%d\n", rounds, totalEncoded, sint64Sum, doubleXor)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: go_bench <decode_spans|encode_spans|packed_numeric> [corpus]")
		os.Exit(1)
	}
	switch os.Args[1] {
	case "decode_spans":
		runDecodeSpans(os.Args[2])
	case "encode_spans":
		runEncodeSpans()
	case "packed_numeric":
		runPackedNumeric()
	default:
		fmt.Fprintf(os.Stderr, "unknown cmd: %s\n", os.Args[1])
		os.Exit(1)
	}
}
