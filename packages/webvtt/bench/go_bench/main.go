package main

import (
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
)

type CueSettings struct {
	Vertical      string
	Line          string
	Position      string
	Size          float64
	Align         string
	Region        string
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

func parseTimestamp(s string) (int64, error) {
	if len(s) < 9 {
		return 0, fmt.Errorf("short timestamp")
	}
	dot := strings.LastIndexByte(s, '.')
	if dot < 0 || len(s)-dot != 4 {
		return 0, fmt.Errorf("bad ms")
	}
	ms, err := strconv.ParseInt(s[dot+1:], 10, 64)
	if err != nil {
		return 0, err
	}
	parts := strings.Split(s[:dot], ":")
	var h, m, sec int64
	if len(parts) == 2 {
		if len(parts[0]) != 2 || len(parts[1]) != 2 {
			return 0, fmt.Errorf("bad mm:ss")
		}
		m, err = strconv.ParseInt(parts[0], 10, 64)
		if err != nil {
			return 0, err
		}
		sec, err = strconv.ParseInt(parts[1], 10, 64)
		if err != nil {
			return 0, err
		}
	} else if len(parts) == 3 {
		if len(parts[0]) < 2 || len(parts[1]) != 2 || len(parts[2]) != 2 {
			return 0, fmt.Errorf("bad hh:mm:ss")
		}
		h, err = strconv.ParseInt(parts[0], 10, 64)
		if err != nil {
			return 0, err
		}
		m, err = strconv.ParseInt(parts[1], 10, 64)
		if err != nil {
			return 0, err
		}
		sec, err = strconv.ParseInt(parts[2], 10, 64)
		if err != nil {
			return 0, err
		}
	} else {
		return 0, fmt.Errorf("bad ts parts")
	}
	if m >= 60 || sec >= 60 {
		return 0, fmt.Errorf("range")
	}
	return h*3600000 + m*60000 + sec*1000 + ms, nil
}

func parseSettings(s string) CueSettings {
	cs := CueSettings{Size: 100.0, Align: "center"}
	for _, tok := range strings.Fields(s) {
		k, v, ok := strings.Cut(tok, ":")
		if !ok || v == "" {
			continue
		}
		switch k {
		case "vertical":
			if v == "rl" || v == "lr" {
				cs.Vertical = v
			}
		case "line":
			cs.Line = v
		case "position":
			cs.Position = v
		case "size":
			if strings.HasSuffix(v, "%") {
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
	// Normalize CRLF/CR to LF
	if strings.IndexByte(input, '\r') >= 0 {
		input = strings.ReplaceAll(input, "\r\n", "\n")
		input = strings.ReplaceAll(input, "\r", "\n")
	}
	lines := strings.Split(input, "\n")
	if len(lines) == 0 || !strings.HasPrefix(lines[0], "WEBVTT") {
		return nil, fmt.Errorf("invalid header")
	}
	t := &Track{}
	if len(lines[0]) > 6 {
		if lines[0][6] != ' ' && lines[0][6] != '\t' {
			return nil, fmt.Errorf("invalid header separator")
		}
		t.HeaderTitle = strings.Trim(lines[0][7:], " \t")
	}

	i := 1
	for i < len(lines) && lines[i] != "" {
		if strings.Contains(lines[i], "-->") {
			break
		}
		if k, v, ok := strings.Cut(lines[i], ":"); ok {
			t.HeaderMetadata = append(t.HeaderMetadata, [2]string{strings.TrimSpace(k), strings.TrimSpace(v)})
		}
		i++
	}
	if i < len(lines) && lines[i] == "" {
		i++
	}

	for i < len(lines) {
		for i < len(lines) && lines[i] == "" {
			i++
		}
		if i >= len(lines) {
			break
		}
		line := lines[i]
		if line == "NOTE" || strings.HasPrefix(line, "NOTE ") || strings.HasPrefix(line, "NOTE\t") {
			var noteLines []string
			rest := strings.TrimLeft(line[4:], " \t")
			if rest != "" {
				noteLines = append(noteLines, rest)
			}
			i++
			for i < len(lines) && lines[i] != "" {
				noteLines = append(noteLines, lines[i])
				i++
			}
			t.Notes = append(t.Notes, strings.Join(noteLines, "\n"))
			continue
		}
		trimmed := strings.TrimRight(line, " \t")
		if trimmed == "STYLE" {
			i++
			var body []string
			aborted := false
			for i < len(lines) && lines[i] != "" {
				if strings.Contains(lines[i], "-->") {
					aborted = true
				}
				body = append(body, lines[i])
				i++
			}
			if !aborted && len(t.Cues) == 0 && len(body) > 0 {
				t.Styles = append(t.Styles, strings.Join(body, "\n"))
			}
			continue
		}
		if trimmed == "REGION" {
			i++
			r := Region{Width: 100, Lines: 3, RegionAnchor: [2]float64{0, 100}, ViewportAnchor: [2]float64{0, 100}}
			aborted := false
			for i < len(lines) && lines[i] != "" {
				if strings.Contains(lines[i], "-->") {
					aborted = true
				}
				for _, tok := range strings.Fields(lines[i]) {
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
		timingLine := line
		if !strings.Contains(line, "-->") {
			if i+1 >= len(lines) || !strings.Contains(lines[i+1], "-->") {
				i++
				for i < len(lines) && lines[i] != "" {
					i++
				}
				continue
			}
			cueID = line
			i++
			timingLine = lines[i]
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
		startMs, err := parseTimestamp(startStr)
		if err != nil {
			return nil, err
		}
		endMs, err := parseTimestamp(endStr)
		if err != nil {
			return nil, err
		}
		if endMs < startMs {
			return nil, fmt.Errorf("inverted")
		}
		cs := parseSettings(settingsStr)
		i++
		pStart := i
		for i < len(lines) && lines[i] != "" && !strings.Contains(lines[i], "-->") {
			i++
		}
		payload := strings.Join(lines[pStart:i], "\n")
		t.Cues = append(t.Cues, Cue{
			ID:       cueID,
			StartMs:  startMs,
			EndMs:    endMs,
			Settings: cs,
			Payload:  payload,
		})
	}

	// Build timeline index
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

func activeCueIndicesAt(t *Track, timeMs int64) []int {
	n := len(t.Cues)
	if n == 0 {
		return nil
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
	if top < 0 {
		return nil
	}
	var res []int
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
			idxs := activeCueIndicesAt(track, tm)
			totalQueryHits += int64(len(idxs))
			for _, idx := range idxs {
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
