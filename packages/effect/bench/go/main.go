package main

import (
	"container/heap"
	"fmt"
	"os"
	"runtime"
	"sync"
)

func benchQueue() {
	const n = 50000
	ch := make(chan int, 16)
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < n; i++ {
			ch <- i
		}
		close(ch)
	}()
	acc := 0
	cnt := 0
	for v := range ch {
		acc = (acc*31 + v) & 0x7fffffff
		cnt++
	}
	wg.Wait()
	fmt.Println("mode=queue")
	fmt.Printf("ops=%d\n", cnt)
	fmt.Printf("checksum=%d\n", acc)
}

type timerItem struct {
	at  int
	seq int
	idx int
}

type timerHeap []timerItem

func (h timerHeap) Len() int { return len(h) }
func (h timerHeap) Less(i, j int) bool {
	if h[i].at != h[j].at {
		return h[i].at < h[j].at
	}
	return h[i].seq < h[j].seq
}
func (h timerHeap) Swap(i, j int) { h[i], h[j] = h[j], h[i] }
func (h *timerHeap) Push(x any)   { *h = append(*h, x.(timerItem)) }
func (h *timerHeap) Pop() any {
	old := *h
	n := len(old)
	item := old[n-1]
	*h = old[:n-1]
	return item
}

func benchTimers() {
	const n = 20000
	h := make(timerHeap, 0, n)
	heap.Init(&h)
	for i := 0; i < n; i++ {
		delay := ((i * 7919) % 500) + 1
		heap.Push(&h, timerItem{at: delay, seq: i + 1, idx: i})
	}
	acc := 0
	fired := 0
	for h.Len() > 0 && h[0].at <= 505 {
		t := heap.Pop(&h).(timerItem)
		acc = (acc*31 + t.at*131 + t.idx) & 0x7fffffff
		fired++
	}
	fmt.Println("mode=timers")
	fmt.Printf("ops=%d\n", fired)
	fmt.Println("now=505")
	fmt.Printf("checksum=%d\n", acc)
}

func benchFanout() {
	const batches = 2500
	acc := 0
	total := 0
	for b := 0; b < batches; b++ {
		base := b * 4
		var res [4]int
		var wg sync.WaitGroup
		wg.Add(4)
		for j := 0; j < 4; j++ {
			k := j
			go func() {
				defer wg.Done()
				runtime.Gosched()
				res[k] = base + k + 1
			}()
		}
		wg.Wait()
		s := res[0] + res[1] + res[2] + res[3]
		acc = (acc*31 + s) & 0x7fffffff
		total += 4
	}
	fmt.Println("mode=fanout")
	fmt.Printf("ops=%d\n", total)
	fmt.Printf("checksum=%d\n", acc)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Println("usage: effect_bench_go <queue|timers|fanout>")
		os.Exit(1)
	}
	switch os.Args[1] {
	case "queue":
		benchQueue()
	case "timers":
		benchTimers()
	case "fanout":
		benchFanout()
	default:
		fmt.Printf("unknown mode: %s\n", os.Args[1])
		os.Exit(1)
	}
}
