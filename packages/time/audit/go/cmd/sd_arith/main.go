// W5: duration add/sub/mul/div + time.Time Add/Sub (time.Duration is int64 ns; no overflow at these magnitudes).
package main

import (
	"fmt"
	"time"
)

func main() {
	const ops int64 = 5000000
	base := time.Unix(1700000000, 123456789)
	var accS, accN int64
	for i := int64(0); i < ops; i++ {
		a := time.Duration((i%100000)-50000)*time.Second + time.Duration((i*7919)%1000000000-500000000)
		b := time.Duration(i%86400000) * time.Millisecond
		c := a + b
		d := c * 3
		e := d / 7
		f := e - a
		t := base.Add(f)
		g := t.Sub(base)
		accS += int64(g / time.Second)
		accN += int64(g % time.Second)
	}
	fmt.Printf("ops=%d\nacc_s=%d\nacc_n=%d\n", ops, accS, accN)
}
