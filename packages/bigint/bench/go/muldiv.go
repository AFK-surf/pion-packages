package main

import (
	"fmt"
	"math/big"
)

func main() {
	a, _ := new(big.Int).SetString("deadbeefcafebabe0123456789abcdef112233445566778899aabbccddeeff01", 16)
	b, _ := new(big.Int).SetString("80000000ffffffff123456789abcdef0fedcba9876543210", 16)
	a.Mul(a, a)
	a.Add(a, big.NewInt(17))
	b.Mul(b, b)
	b.Add(b, big.NewInt(31))

	acc := new(big.Int)
	prod := new(big.Int)
	div := new(big.Int)
	q := new(big.Int)
	r := new(big.Int)
	inc := new(big.Int)

	for i := int64(0); i < 2000; i++ {
		prod.Mul(a, b)
		inc.SetInt64(i + 1)
		div.Add(b, inc)
		q.QuoRem(prod, div, r)
		acc.Add(acc, q)
		acc.Sub(acc, r)
		if (i & 7) == 0 {
			inc.SetInt64(i*13 + 7)
			a.Add(a, inc)
			inc.SetInt64(i*7 + 3)
			b.Add(b, inc)
		}
	}
	fmt.Println(acc.String())
}
