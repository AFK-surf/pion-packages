package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/eclipse/paho.golang/packets"
)

func mix(h, v int64) int64 {
	return ((h * 131) + v) % 1000000007
}

func benchW1() int {
	topics := make([]string, 16)
	respTopics := make([]string, 16)
	payloads := make([][]byte, 16)
	for k := 0; k < 16; k++ {
		z := k / 4
		d := k % 4
		topics[k] = fmt.Sprintf("iot/zone%d/dev%d/telemetry", z, d)
		respTopics[k] = fmt.Sprintf("iot/reply/zone%d/dev%d", z, d)
		payloads[k] = []byte(fmt.Sprintf(`{"zone":%d,"dev":%d,"temp":24.75,"hum":58,"status":"ok"}`, z, d))
	}

	var totalWire, totalPayload, totalUprops, checksum int64
	var buf bytes.Buffer
	buf.Grow(512)
	exp := uint32(300)

	for i := 0; i < 200000; i++ {
		idx := i & 15
		pid := uint16((i % 65000) + 1)
		pub := &packets.Publish{
			QoS:      1,
			Topic:    topics[idx],
			PacketID: pid,
			Properties: &packets.Properties{
				MessageExpiry: &exp,
				ContentType:   "application/json",
				ResponseTopic: respTopics[idx],
				User: []packets.User{
					{Key: "region", Value: "ap-northeast-1"},
					{Key: "tier", Value: "edge"},
				},
			},
			Payload: payloads[idx],
		}
		buf.Reset()
		if _, err := pub.WriteTo(&buf); err != nil {
			fmt.Fprintf(os.Stderr, "w1 encode error: %v\n", err)
			return 1
		}
		totalWire += int64(buf.Len())
		cp, err := packets.ReadPacket(&buf)
		if err != nil {
			fmt.Fprintf(os.Stderr, "w1 decode error: %v\n", err)
			return 1
		}
		d, ok := cp.Content.(*packets.Publish)
		if !ok {
			fmt.Fprintln(os.Stderr, "w1 unexpected packet type")
			return 1
		}
		totalPayload += int64(len(d.Payload))
		if d.Properties != nil {
			totalUprops += int64(len(d.Properties.User))
		}
		checksum = mix(checksum, int64(d.PacketID))
		checksum = mix(checksum, int64(len(d.Topic)))
		checksum = mix(checksum, int64(len(d.Payload)))
	}
	fmt.Println("mode=w1")
	fmt.Println("packets=200000")
	fmt.Printf("wire_bytes=%d\n", totalWire)
	fmt.Printf("payload_bytes=%d\n", totalPayload)
	fmt.Printf("user_props=%d\n", totalUprops)
	fmt.Printf("checksum=%d\n", checksum)
	return 0
}

func digestControlPacket(h0 int64, cp *packets.ControlPacket) int64 {
	switch c := cp.Content.(type) {
	case *packets.Connect:
		return mix(mix(h0, 1), int64(len(c.ClientID)))
	case *packets.Connack:
		return mix(mix(h0, 2), int64(c.ReasonCode))
	case *packets.Publish:
		return mix(mix(mix(h0, 3), int64(c.PacketID)), int64(len(c.Payload)))
	case *packets.Puback:
		return mix(mix(h0, 4), int64(c.PacketID))
	case *packets.Pubrec:
		return mix(mix(h0, 5), int64(c.PacketID))
	case *packets.Pubrel:
		return mix(mix(h0, 6), int64(c.PacketID))
	case *packets.Pubcomp:
		return mix(mix(h0, 7), int64(c.PacketID))
	case *packets.Subscribe:
		return mix(mix(h0, 8), int64(c.PacketID))
	case *packets.Suback:
		return mix(mix(h0, 9), int64(c.PacketID))
	case *packets.Unsubscribe:
		return mix(mix(h0, 10), int64(c.PacketID))
	case *packets.Unsuback:
		return mix(mix(h0, 11), int64(c.PacketID))
	case *packets.Pingreq:
		return mix(h0, 12)
	case *packets.Pingresp:
		return mix(h0, 13)
	case *packets.Disconnect:
		return mix(mix(h0, 14), int64(c.ReasonCode))
	case *packets.Auth:
		return mix(mix(h0, 15), int64(c.ReasonCode))
	default:
		return h0
	}
}

type chunkReader struct {
	data []byte
	pos  int
}

func (r *chunkReader) Read(p []byte) (int, error) {
	if r.pos >= len(r.data) {
		return 0, io.EOF
	}
	rem := len(r.data) - r.pos
	n := len(p)
	if n > 137 {
		n = 137
	}
	if n > rem {
		n = rem
	}
	copy(p[:n], r.data[r.pos:r.pos+n])
	r.pos += n
	return n, nil
}

func benchW2V5(v5Data []byte) int {
	var count, checksum int64
	for r := 0; r < 1000; r++ {
		cr := &chunkReader{data: v5Data}
		for {
			cp, err := packets.ReadPacket(cr)
			if err == io.EOF {
				break
			}
			if err != nil {
				fmt.Fprintf(os.Stderr, "w2_v5 error: %v\n", err)
				return 1
			}
			count++
			checksum = digestControlPacket(checksum, cp)
		}
	}
	fmt.Println("mode=w2_v5")
	fmt.Printf("packets=%d\n", count)
	fmt.Printf("checksum=%d\n", checksum)
	return 0
}

type trieEntry struct {
	key int
	val int
}

type trieNode struct {
	children map[string]*trieNode
	plus     *trieNode
	hash     []trieEntry
	exact    []trieEntry
}

type topicTrie struct {
	root    *trieNode
	count   int
	seenGen map[int]int
	gen     int
}

func newTopicTrie() *topicTrie {
	return &topicTrie{
		root:    &trieNode{},
		seenGen: make(map[int]int, 64),
	}
}

func (t *topicTrie) insert(filter string, key, val int) {
	levels := strings.Split(filter, "/")
	cur := t.root
	for _, seg := range levels {
		if seg == "#" {
			cur.hash = append(cur.hash, trieEntry{key: key, val: val})
			t.count++
			return
		} else if seg == "+" {
			if cur.plus == nil {
				cur.plus = &trieNode{}
			}
			cur = cur.plus
		} else {
			if cur.children == nil {
				cur.children = make(map[string]*trieNode)
			}
			nxt, ok := cur.children[seg]
			if !ok {
				nxt = &trieNode{}
				cur.children[seg] = nxt
			}
			cur = nxt
		}
	}
	cur.exact = append(cur.exact, trieEntry{key: key, val: val})
	t.count++
}

func (t *topicTrie) collect(entries []trieEntry, out *[]int) {
	for _, e := range entries {
		if e.key >= 0 {
			if t.seenGen[e.key] == t.gen {
				continue
			}
			t.seenGen[e.key] = t.gen
		}
		*out = append(*out, e.val)
	}
}

func (t *topicTrie) walk(n *trieNode, isRoot bool, levels []string, idx int, isDollar bool, out *[]int) {
	if !(isRoot && isDollar) && len(n.hash) > 0 {
		t.collect(n.hash, out)
	}
	if idx == len(levels) {
		if len(n.exact) > 0 {
			t.collect(n.exact, out)
		}
		return
	}
	if n.children != nil {
		if ch, ok := n.children[levels[idx]]; ok {
			t.walk(ch, false, levels, idx+1, isDollar, out)
		}
	}
	if !(isRoot && isDollar) && n.plus != nil {
		t.walk(n.plus, false, levels, idx+1, isDollar, out)
	}
}

func (t *topicTrie) matchTopic(topic string) []int {
	t.gen++
	out := make([]int, 0, 8)
	isDollar := len(topic) > 0 && topic[0] == '$'
	levels := strings.Split(topic, "/")
	t.walk(t.root, true, levels, 0, isDollar, &out)
	return out
}

func benchW3() int {
	trie := newTopicTrie()
	for i := 0; i < 10000; i++ {
		var sub string
		switch i % 10 {
		case 0:
			sub = fmt.Sprintf("factory/site%d/+/telemetry", i%50)
		case 1:
			sub = fmt.Sprintf("factory/site%d/line%d/#", i%50, i%20)
		case 2:
			sub = fmt.Sprintf("iot/+/sensor%d/temp", i%200)
		case 3:
			sub = fmt.Sprintf("fleet/region%d/+/+/gps", i%10)
		case 4:
			sub = fmt.Sprintf("$SYS/broker/node%d/#", i%25)
		default:
			sub = fmt.Sprintf("iot/site%d/dev%d/metric", i%100, i%500)
		}
		trie.insert(sub, i, i+1)
	}
	topics := make([]string, 1000)
	for t := 0; t < 1000; t++ {
		switch t % 10 {
		case 0, 1:
			topics[t] = fmt.Sprintf("factory/site%d/line%d/telemetry", t%50, t%20)
		case 2:
			topics[t] = fmt.Sprintf("iot/zone%d/sensor%d/temp", t%10, t%200)
		case 3:
			topics[t] = fmt.Sprintf("fleet/region%d/city%d/truck%d/gps", t%10, t%8, t%30)
		case 4:
			topics[t] = fmt.Sprintf("$SYS/broker/node%d/load/1m", t%25)
		default:
			topics[t] = fmt.Sprintf("iot/site%d/dev%d/metric", t%100, t%500)
		}
	}
	var totalMatches, idSum int64
	for r := 0; r < 100; r++ {
		for j := 0; j < 1000; j++ {
			hits := trie.matchTopic(topics[j])
			totalMatches += int64(len(hits))
			for _, v := range hits {
				idSum = (idSum + int64(v)) % 1000000007
			}
		}
	}
	fmt.Println("mode=w3")
	fmt.Printf("subs=%d\n", trie.count)
	fmt.Println("publishes=100000")
	fmt.Printf("matches=%d\n", totalMatches)
	fmt.Printf("id_sum=%d\n", idSum)
	return 0
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: go_mqtt_bench <w1|w2_v5|w3> [args...]")
		os.Exit(1)
	}
	switch os.Args[1] {
	case "w1":
		os.Exit(benchW1())
	case "w2_v5":
		data, err := os.ReadFile(os.Args[2])
		if err != nil {
			fmt.Fprintf(os.Stderr, "read error: %v\n", err)
			os.Exit(1)
		}
		os.Exit(benchW2V5(data))
	case "w3":
		os.Exit(benchW3())
	default:
		fmt.Fprintf(os.Stderr, "unknown mode: %s\n", os.Args[1])
		os.Exit(1)
	}
}
