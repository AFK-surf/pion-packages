package main

import (
	"bytes"
	"encoding/csv"
	"fmt"
	"strconv"
)

func buildTemplateRows() [][]string {
	cities := []string{
		"Tokyo", "San Francisco", "New York", "London", "Paris",
		"Berlin", "Shanghai", "Zürich", "São Paulo", "München",
	}
	depts := []string{
		"Engineering", "Research & Dev", "Sales, EMEA", "Product \"Core\"",
		"Operations", "Finance", "Security", "Design",
	}
	notes := []string{
		"Active account",
		"VIP, priority support",
		"Quoted \"nickname\" inside",
		"Multi-line\naddress note",
		"UTF-8 备注：东京分部",
		"Standard tier 2026",
		"Needs review, Q4",
		"OK",
	}
	rows := make([][]string, 0, 2000)
	for i := 0; i < 2000; i++ {
		city := cities[i%len(cities)]
		dept := depts[(i*3)%len(depts)]
		note := notes[(i*7)%len(notes)]
		salary := strconv.Itoa(65000 + (i*37)%140000)
		score := strconv.Itoa((i*13)%100) + ".50"
		active := "true"
		if i%3 == 0 {
			active = "false"
		}
		id := strconv.Itoa(i + 1)
		name := "User_" + id
		rows = append(rows, []string{id, name, city, dept, salary, score, active, note})
	}
	return rows
}

func main() {
	rows := buildTemplateRows()
	header := []string{"id", "name", "city", "department", "salary", "score", "active", "note"}
	var totalBytes int64
	var hash int64
	var firstLine string

	for round := 0; round < 2; round++ {
		var buf bytes.Buffer
		buf.Grow(18_000_000)
		w := csv.NewWriter(&buf)
		if err := w.Write(header); err != nil {
			panic(err)
		}
		for rep := 0; rep < 100; rep++ {
			for _, row := range rows {
				if err := w.Write(row); err != nil {
					panic(err)
				}
			}
		}
		w.Flush()
		if err := w.Error(); err != nil {
			panic(err)
		}
		out := buf.Bytes()
		totalBytes += int64(len(out))
		if round == 0 {
			firstLine = string(out[:80])
		}
		for _, b := range out {
			hash = (hash*131 + int64(b)) & 0x7FFFFFFF
		}
	}

	fmt.Printf("bytes=%d\n", totalBytes)
	fmt.Printf("hash=%d\n", hash)
	fmt.Printf("head=%s\n", firstLine)
}
