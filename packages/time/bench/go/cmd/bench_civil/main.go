package main

import (
	"fmt"
	"time"
)

func main() {
	const ops int64 = 2000000
	var accYmd int64
	var accIwd int64
	var accEd int64

	for i := int64(0); i < ops; i++ {
		day := ((i * 2654435761) % 1000001) - 500000
		delta := int((i % 731) - 365)
		t0 := time.Unix(day*86400, 0).UTC()
		y, m, d := t0.Date()
		iy, iw := t0.ISOWeek()
		wd := int(t0.Weekday())
		if wd == 0 {
			wd = 7
		}
		t1 := t0.AddDate(0, 0, delta)
		ed1 := t1.Unix() / 86400

		accYmd += int64(y)*10000 + int64(m)*100 + int64(d)
		accIwd += int64(iy)*1000 + int64(iw)*10 + int64(wd)
		accEd += ed1
	}

	fmt.Printf("ops=%d\n", ops)
	fmt.Printf("acc_ymd=%d\n", accYmd)
	fmt.Printf("acc_iwd=%d\n", accIwd)
	fmt.Printf("acc_ed=%d\n", accEd)
}
