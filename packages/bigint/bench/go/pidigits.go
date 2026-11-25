package main

import (
	"bufio"
	"fmt"
	"math/big"
	"os"
	"strconv"
)

func main() {
	n := 2500
	if len(os.Args) > 1 {
		if v, err := strconv.Atoi(os.Args[1]); err == nil && v > 0 {
			n = v
		}
	}
	num := big.NewInt(1)
	acc := big.NewInt(0)
	den := big.NewInt(1)
	tmp1 := new(big.Int)
	tmp2 := new(big.Int)
	three := big.NewInt(3)
	four := big.NewInt(4)
	ten := big.NewInt(10)
	bigK := new(big.Int)
	bigK2 := new(big.Int)
	bigD := new(big.Int)

	out := bufio.NewWriter(os.Stdout)
	var line [10]byte
	col := 0
	var k int64
	for i := 0; i < n; {
		k++
		k2 := k*2 + 1
		bigK.SetInt64(k)
		bigK2.SetInt64(k2)

		tmp1.Lsh(num, 1)
		acc.Add(acc, tmp1)
		acc.Mul(acc, bigK2)
		den.Mul(den, bigK2)
		num.Mul(num, bigK)

		if num.Cmp(acc) > 0 {
			continue
		}

		tmp1.Mul(num, three)
		tmp1.Add(tmp1, acc)
		tmp2.Quo(tmp1, den)
		d3 := tmp2.Int64()

		tmp1.Mul(num, four)
		tmp1.Add(tmp1, acc)
		tmp2.Quo(tmp1, den)
		d4 := tmp2.Int64()

		if d3 != d4 {
			continue
		}

		line[col] = byte('0' + d3)
		col++
		i++
		if col == 10 {
			out.Write(line[:])
			fmt.Fprintf(out, "\t:%d\n", i)
			col = 0
		}

		bigD.SetInt64(d3)
		tmp1.Mul(den, bigD)
		acc.Sub(acc, tmp1)
		acc.Mul(acc, ten)
		num.Mul(num, ten)
	}
	if col > 0 {
		for col < 10 {
			line[col] = ' '
			col++
		}
		out.Write(line[:])
		fmt.Fprintf(out, "\t:%d\n", n)
	}
	out.Flush()
}
