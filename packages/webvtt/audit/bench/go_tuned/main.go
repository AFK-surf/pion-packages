// Audit-only "tuned" Go baseline for packages/webvtt/bench.
//
// Same parse rules, same timeline index, same plain_text, same queries and byte-identical stdout as
// packages/webvtt/bench/go_bench/main.go (go_ref). The only differences are the idiomatic Go performance
// choices a competent Go author would make and that the Pion side already enjoys:
//   - one pass of line offsets instead of strings.Split(input, "\n") + strings.Join for payloads
//     (payloads are zero-copy substrings, like the Pion side's slices);
//   - hand-rolled fixed-width timestamp parsing instead of strings.Split(ts, ":") + 4x strconv.ParseInt
//     per timestamp (the Pion side has a hand-rolled 9/12-byte fast path);
//   - manual settings tokenization instead of strings.Fields (no []string per cue).
//
// It additionally parses line/position/regionanchor/viewportanchor into numbers like the Pion side does
// (go_ref only keeps the raw strings), so go_tuned does at least the work the Pion benchmark does.
package main

import (
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
)

type CueSettings struct {
	Vertical string
	Line     string
	Position string
	// Parsed like the Pion side does (so go_tuned does at least the same settings work); not printed.
	LineVal      float64
	LineIsPct    bool
	LineAlign    string
	PositionVal  float64
	PositionAlgn string
	Size         float64
	Align        string
	Region       string
}

type Region struct {
	ID             string
	Width          float64
	Lines          int
	RegionAnchor   [2]float64
	ViewportAnchor [2]float64
	Scroll         string
}

type Cue struct {
	ID       string
	StartMs  int64
	EndMs    int64
	Settings CueSettings
	Payload  string
}

type Track struct {
	HeaderTitle    string
	HeaderMetadata [][2]string
	Styles         []string
	Regions        []Region
	Notes          []string
	Cues           []Cue
	IsIdentity     bool
	SortedOrder    []int
	SortedStarts   []int64
	PrefixMaxEnd   []int64
}

func d2(s string, i int) (int64, bool) {
	a, b := s[i]-'0', s[i+1]-'0'
	if a > 9 || b > 9 {
		return 0, false
	}
	return int64(a)*10 + int64(b), true
}

// Accepts exactly what go_ref.parseTimestamp accepts for digit-only fields: MM:SS.mmm or HH+:MM:SS.mmm.
func parseTimestamp(s string) (int64, bool) {
	n := len(s)
	if n < 9 || s[n-4] != '.' {
		return 0, false
	}
	ms := int64(0)
	for k := n - 3; k < n; k++ {
		c := s[k] - '0'
		if c > 9 {
			return 0, false
		}
		ms = ms*10 + int64(c)
	}
	body := n - 4
	var h, m, sec int64
	var ok bool
	if body == 5 && s[2] == ':' {
		if m, ok = d2(s, 0); !ok {
			return 0, false
		}
		if sec, ok = d2(s, 3); !ok {
			return 0, false
		}
	} else {
		if body < 8 || s[body-3] != ':' || s[body-6] != ':' {
			return 0, false
		}
		hl := body - 6
		if hl < 2 {
			return 0, false
		}
		for k := 0; k < hl; k++ {
			c := s[k] - '0'
			if c > 9 {
				return 0, false
			}
			h = h*10 + int64(c)
		}
		if m, ok = d2(s, body-5); !ok {
			return 0, false
		}
		if sec, ok = d2(s, body-2); !ok {
			return 0, false
		}
	}
	if m >= 60 || sec >= 60 {
		return 0, false
	}
	return h*3600000 + m*60000 + sec*1000 + ms, true
}

func isWS(b byte) bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\r' || b == '\v' || b == '\f'
}

func parseSettings(s string) CueSettings {
	cs := CueSettings{Size: 100.0, Align: "center"}
	i, n := 0, len(s)
	for i < n {
		for i < n && isWS(s[i]) {
			i++
		}
		st := i
		for i < n && !isWS(s[i]) {
			i++
		}
		if st == i {
			continue
		}
		tok := s[st:i]
		c := strings.IndexByte(tok, ':')
		if c < 0 || c == len(tok)-1 {
			continue
		}
		k, v := tok[:c], tok[c+1:]
		switch k {
		case "vertical":
			if v == "rl" || v == "lr" {
				cs.Vertical = v
			}
		case "line":
			cs.Line = v
			num, al, _ := strings.Cut(v, ",")
			if al == "" || al == "start" || al == "center" || al == "end" {
				if strings.HasSuffix(num, "%") {
					if f, err := strconv.ParseFloat(num[:len(num)-1], 64); err == nil && f >= 0 && f <= 100 {
						cs.LineVal, cs.LineIsPct, cs.LineAlign = f, true, al
					}
				} else if f, err := strconv.ParseFloat(num, 64); err == nil {
					cs.LineVal, cs.LineIsPct, cs.LineAlign = f, false, al
				}
			}
		case "position":
			cs.Position = v
			num, al, _ := strings.Cut(v, ",")
			if (al == "" || al == "line-left" || al == "center" || al == "line-right") && strings.HasSuffix(num, "%") {
				if f, err := strconv.ParseFloat(num[:len(num)-1], 64); err == nil && f >= 0 && f <= 100 {
					cs.PositionVal, cs.PositionAlgn = f, al
				}
			}
		case "size":
			if v[len(v)-1] == '%' {
				if f, err := strconv.ParseFloat(v[:len(v)-1], 64); err == nil && f >= 0 && f <= 100 {
					cs.Size = f
				}
			}
		case "align":
			cs.Align = v
		case "region":
			cs.Region = v
		}
	}
	return cs
}

func parseWebVTT(input string) (*Track, error) {
	if strings.HasPrefix(input, "\ufeff") {
		input = input[3:]
	}
	if strings.IndexByte(input, '\r') >= 0 {
		input = strings.ReplaceAll(input, "\r\n", "\n")
		input = strings.ReplaceAll(input, "\r", "\n")
	}
	// Line offsets (same line set as strings.Split(input, "\n")).
	nl := strings.Count(input, "\n") + 1
	starts := make([]int, nl+1)
	{
		p, k := 0, 0
		for {
			starts[k] = p
			k++
			j := strings.IndexByte(input[p:], '\n')
			if j < 0 {
				break
			}
			p += j + 1
		}
		starts[nl] = len(input) + 1
	}
	line := func(i int) string { return input[starts[i] : starts[i+1]-1] }
	empty := func(i int) bool { return starts[i+1]-1 == starts[i] }

	l0 := line(0)
	if !strings.HasPrefix(l0, "WEBVTT") {
		return nil, fmt.Errorf("invalid header")
	}
	t := &Track{}
	if len(l0) > 6 {
		if l0[6] != ' ' && l0[6] != '\t' {
			return nil, fmt.Errorf("invalid header separator")
		}
		t.HeaderTitle = strings.Trim(l0[7:], " \t")
	}
	i := 1
	for i < nl && !empty(i) {
		li := line(i)
		if strings.Contains(li, "-->") {
			break
		}
		if k, v, ok := strings.Cut(li, ":"); ok {
			t.HeaderMetadata = append(t.HeaderMetadata, [2]string{strings.TrimSpace(k), strings.TrimSpace(v)})
		}
		i++
	}
	if i < nl && empty(i) {
		i++
	}
	for i < nl {
		for i < nl && empty(i) {
			i++
		}
		if i >= nl {
			break
		}
		ln := line(i)
		if ln == "NOTE" || strings.HasPrefix(ln, "NOTE ") || strings.HasPrefix(ln, "NOTE\t") {
			var noteLines []string
			rest := strings.TrimLeft(ln[4:], " \t")
			if rest != "" {
				noteLines = append(noteLines, rest)
			}
			i++
			for i < nl && !empty(i) {
				noteLines = append(noteLines, line(i))
				i++
			}
			t.Notes = append(t.Notes, strings.Join(noteLines, "\n"))
			continue
		}
		trimmed := strings.TrimRight(ln, " \t")
		if trimmed == "STYLE" {
			i++
			bs := i
			aborted := false
			for i < nl && !empty(i) {
				if strings.Contains(line(i), "-->") {
					aborted = true
				}
				i++
			}
			if !aborted && len(t.Cues) == 0 && i > bs {
				t.Styles = append(t.Styles, input[starts[bs]:starts[i]-1])
			}
			continue
		}
		if trimmed == "REGION" {
			i++
			r := Region{Width: 100, Lines: 3, RegionAnchor: [2]float64{0, 100}, ViewportAnchor: [2]float64{0, 100}}
			aborted := false
			for i < nl && !empty(i) {
				li := line(i)
				if strings.Contains(li, "-->") {
					aborted = true
				}
				for _, tok := range strings.Fields(li) {
					k, v, ok := strings.Cut(tok, ":")
					if !ok {
						continue
					}
					switch k {
					case "id":
						r.ID = v
					case "width":
						if strings.HasSuffix(v, "%") {
							if f, err := strconv.ParseFloat(v[:len(v)-1], 64); err == nil {
								r.Width = f
							}
						}
					case "lines":
						if n, err := strconv.Atoi(v); err == nil {
							r.Lines = n
						}
					case "scroll":
						r.Scroll = v
					case "regionanchor", "viewportanchor":
						x, y, ok := strings.Cut(v, ",")
						if ok && strings.HasSuffix(x, "%") && strings.HasSuffix(y, "%") {
							fx, e1 := strconv.ParseFloat(x[:len(x)-1], 64)
							fy, e2 := strconv.ParseFloat(y[:len(y)-1], 64)
							if e1 == nil && e2 == nil && fx >= 0 && fx <= 100 && fy >= 0 && fy <= 100 {
								if k == "regionanchor" {
									r.RegionAnchor = [2]float64{fx, fy}
								} else {
									r.ViewportAnchor = [2]float64{fx, fy}
								}
							}
						}
					}
				}
				i++
			}
			if !aborted && len(t.Cues) == 0 && r.ID != "" {
				t.Regions = append(t.Regions, r)
			}
			continue
		}

		cueID := ""
		timingLine := ln
		if strings.Index(ln, "-->") < 0 {
			if i+1 >= nl || strings.Index(line(i+1), "-->") < 0 {
				i++
				for i < nl && !empty(i) {
					i++
				}
				continue
			}
			cueID = ln
			i++
			timingLine = line(i)
		}
		arrowIdx := strings.Index(timingLine, "-->")
		startStr := strings.Trim(timingLine[:arrowIdx], " \t")
		afterArrow := strings.TrimLeft(timingLine[arrowIdx+3:], " \t")
		endEnd := strings.IndexAny(afterArrow, " \t")
		var endStr, settingsStr string
		if endEnd < 0 {
			endStr = afterArrow
		} else {
			endStr = afterArrow[:endEnd]
			settingsStr = afterArrow[endEnd:]
		}
		startMs, ok := parseTimestamp(startStr)
		if !ok {
			return nil, fmt.Errorf("bad timestamp")
		}
		endMs, ok := parseTimestamp(endStr)
		if !ok {
			return nil, fmt.Errorf("bad timestamp")
		}
		if endMs < startMs {
			return nil, fmt.Errorf("inverted")
		}
		cs := parseSettings(settingsStr)
		i++
		pStart := i
		for i < nl && !empty(i) && strings.Index(line(i), "-->") < 0 {
			i++
		}
		payload := ""
		if i > pStart {
			payload = input[starts[pStart] : starts[i]-1]
		}
		t.Cues = append(t.Cues, Cue{ID: cueID, StartMs: startMs, EndMs: endMs, Settings: cs, Payload: payload})
	}

	n := len(t.Cues)
	t.IsIdentity = true
	for k := 1; k < n; k++ {
		if t.Cues[k].StartMs < t.Cues[k-1].StartMs {
			t.IsIdentity = false
			break
		}
	}
	t.SortedStarts = make([]int64, n)
	t.PrefixMaxEnd = make([]int64, n)
	if t.IsIdentity {
		var maxEnd int64 = -1
		for k := 0; k < n; k++ {
			t.SortedStarts[k] = t.Cues[k].StartMs
			if t.Cues[k].EndMs > maxEnd {
				maxEnd = t.Cues[k].EndMs
			}
			t.PrefixMaxEnd[k] = maxEnd
		}
	} else {
		t.SortedOrder = make([]int, n)
		for k := 0; k < n; k++ {
			t.SortedOrder[k] = k
		}
		sort.SliceStable(t.SortedOrder, func(a, b int) bool {
			return t.Cues[t.SortedOrder[a]].StartMs < t.Cues[t.SortedOrder[b]].StartMs
		})
		var maxEnd int64 = -1
		for k := 0; k < n; k++ {
			c := t.Cues[t.SortedOrder[k]]
			t.SortedStarts[k] = c.StartMs
			if c.EndMs > maxEnd {
				maxEnd = c.EndMs
			}
			t.PrefixMaxEnd[k] = maxEnd
		}
	}
	return t, nil
}

func plainText(payload string) string {
	idx := strings.IndexAny(payload, "<&")
	if idx < 0 {
		return payload
	}
	var sb strings.Builder
	sb.Grow(len(payload))
	sb.WriteString(payload[:idx])
	n := len(payload)
	pos := idx
	seg := idx
	for pos < n {
		b := payload[pos]
		if b == '<' {
			if pos > seg {
				sb.WriteString(payload[seg:pos])
			}
			pos++
			for pos < n && payload[pos] != '>' {
				pos++
			}
			if pos < n {
				pos++
			}
			seg = pos
		} else if b == '&' {
			if pos > seg {
				sb.WriteString(payload[seg:pos])
			}
			rem := payload[pos:]
			switch {
			case strings.HasPrefix(rem, "&amp;"):
				sb.WriteByte('&')
				pos += 5
			case strings.HasPrefix(rem, "&lt;"):
				sb.WriteByte('<')
				pos += 4
			case strings.HasPrefix(rem, "&gt;"):
				sb.WriteByte('>')
				pos += 4
			case strings.HasPrefix(rem, "&nbsp;"):
				sb.WriteString("\u00a0")
				pos += 6
			case strings.HasPrefix(rem, "&lrm;"):
				sb.WriteString("\u200e")
				pos += 5
			case strings.HasPrefix(rem, "&rlm;"):
				sb.WriteString("\u200f")
				pos += 5
			default:
				sb.WriteByte('&')
				pos++
			}
			seg = pos
		} else {
			pos++
		}
	}
	if pos > seg {
		sb.WriteString(payload[seg:pos])
	}
	return sb.String()
}

func activeCueIndicesAt(t *Track, timeMs int64, res []int) []int {
	res = res[:0]
	n := len(t.Cues)
	if n == 0 {
		return res
	}
	lo, hi := 0, n
	for lo < hi {
		mid := lo + (hi-lo)/2
		if t.SortedStarts[mid] <= timeMs {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	top := lo - 1
	for i := top; i >= 0; i-- {
		if t.PrefixMaxEnd[i] <= timeMs {
			break
		}
		idx := i
		if !t.IsIdentity {
			idx = t.SortedOrder[i]
		}
		if t.Cues[idx].EndMs > timeMs {
			res = append(res, idx)
		}
	}
	for l, r := 0, len(res)-1; l < r; l, r = l+1, r-1 {
		res[l], res[r] = res[r], res[l]
	}
	return res
}

func polyHash(s string) int64 {
	var h int64 = 17
	for i := 0; i < len(s); i++ {
		h = (h*131 + int64(s[i])) % 1000000007
	}
	return h
}

func main() {
	path := "/tmp/pion-webvtt-bench/corpus.vtt"
	iters := 15
	if len(os.Args) > 1 {
		path = os.Args[1]
	}
	if len(os.Args) > 2 {
		if v, err := strconv.Atoi(os.Args[2]); err == nil {
			iters = v
		}
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "read error: %v\n", err)
		os.Exit(1)
	}
	content := string(raw)

	var totalCues, totalStyles, totalRegions, totalNotes int64
	var totalPlainBytes, totalPlainHash, totalQueryHits, totalQueryStartSum int64
	var buf []int

	for iter := 0; iter < iters; iter++ {
		track, err := parseWebVTT(content)
		if err != nil {
			fmt.Fprintf(os.Stderr, "parse error: %v\n", err)
			os.Exit(1)
		}
		nc := len(track.Cues)
		totalCues += int64(nc)
		totalStyles += int64(len(track.Styles))
		totalRegions += int64(len(track.Regions))
		totalNotes += int64(len(track.Notes))
		for ci := 0; ci < nc; ci++ {
			pt := plainText(track.Cues[ci].Payload)
			totalPlainBytes += int64(len(pt))
			totalPlainHash = (totalPlainHash + polyHash(pt)) % 1000000007
		}
		var maxT int64 = 1000
		if nc > 0 {
			maxT = track.Cues[nc-1].EndMs
		}
		var step int64 = 1
		if maxT > 2000 {
			step = maxT / 2000
		}
		for q := 0; q < 2000; q++ {
			tm := int64(q)*step + 500
			buf = activeCueIndicesAt(track, tm, buf)
			totalQueryHits += int64(len(buf))
			for _, idx := range buf {
				totalQueryStartSum = (totalQueryStartSum + track.Cues[idx].StartMs) % 1000000007
			}
		}
	}

	fmt.Printf("iters=%d\n", iters)
	fmt.Printf("cues=%d\n", totalCues)
	fmt.Printf("styles=%d\n", totalStyles)
	fmt.Printf("regions=%d\n", totalRegions)
	fmt.Printf("notes=%d\n", totalNotes)
	fmt.Printf("plain_bytes=%d\n", totalPlainBytes)
	fmt.Printf("plain_hash=%d\n", totalPlainHash)
	fmt.Printf("query_hits=%d\n", totalQueryHits)
	fmt.Printf("query_start_sum=%d\n", totalQueryStartSum)
}
