// RT-mqtt differential driver: Go github.com/eclipse/paho.golang/packets v0.23.0 (MQTT 5.0 only).
// Reads vectors.bin ([ver u8][len u32 BE][bytes]...) and prints one verdict line per vector:
//
//	id <ok|reject|incomplete|panic|na> <TYPE|-> <used> <pid>
package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/eclipse/paho.golang/packets"
)

var names = map[byte]string{1: "CONNECT", 2: "CONNACK", 3: "PUBLISH", 4: "PUBACK", 5: "PUBREC",
	6: "PUBREL", 7: "PUBCOMP", 8: "SUBSCRIBE", 9: "SUBACK", 10: "UNSUBSCRIBE", 11: "UNSUBACK",
	12: "PINGREQ", 13: "PINGRESP", 14: "DISCONNECT", 15: "AUTH"}

func pidOf(cp *packets.ControlPacket) uint16 {
	switch c := cp.Content.(type) {
	case *packets.Publish:
		return c.PacketID
	case *packets.Puback:
		return c.PacketID
	case *packets.Pubrec:
		return c.PacketID
	case *packets.Pubrel:
		return c.PacketID
	case *packets.Pubcomp:
		return c.PacketID
	case *packets.Subscribe:
		return c.PacketID
	case *packets.Suback:
		return c.PacketID
	case *packets.Unsubscribe:
		return c.PacketID
	case *packets.Unsuback:
		return c.PacketID
	}
	return 0
}

func one(id int, pkt []byte) (line string) {
	defer func() {
		if r := recover(); r != nil {
			line = fmt.Sprintf("%d panic - 0 0 %v", id, r)
		}
	}()
	// Note: paho calls bytes.Buffer.Grow(remainingLength) before reading the body, so the
	// 256 MiB-declared vectors allocate ~256 MiB here (measured as a DoS probe in run_audit.sh).
	rd := bytes.NewReader(pkt)
	cp, err := packets.ReadPacket(rd)
	if err != nil {
		if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
			return fmt.Sprintf("%d incomplete - 0 0", id)
		}
		return fmt.Sprintf("%d reject - 0 0 %v", id, err)
	}
	used := len(pkt) - rd.Len()
	return fmt.Sprintf("%d ok %s %d %d", id, names[cp.Type], used, pidOf(cp))
}

func main() {
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	pos, id := 0, 0
	for pos+5 <= len(data) {
		ver := data[pos]
		n := int(binary.BigEndian.Uint32(data[pos+1:]))
		pkt := data[pos+5 : pos+5+n]
		if ver != 5 {
			fmt.Fprintf(w, "%d na - 0 0\n", id)
		} else {
			fmt.Fprintln(w, one(id, pkt))
		}
		pos += 5 + n
		id++
	}
}
