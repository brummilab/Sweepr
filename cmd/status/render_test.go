package main

// The rendered frame as plain text (ST-16, ST-19, ST-20, ST-21). Labels,
// layout, bars and colours are free; the tests look for values, their order,
// the line count and the line width only.

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// tstBaseDoc is a complete document whose values are distinct strings in the
// frame, so that each value identifies its section.
func tstBaseDoc() map[string]any {
	return map[string]any{
		"collected_at":   "2026-10-28T12:00:00+02:00",
		"platform":       "windows 10.0.26100",
		"uptime_seconds": 93784,
		"procs":          123,
		"cpu": map[string]any{
			"usage":       41.7,
			"per_core":    []any{83.4, 12.6, 57.2, 29.8},
			"core_count":  4,
			"logical_cpu": 4,
		},
		"memory": map[string]any{
			"used": int64(4294967296), "total": int64(17179869184), "available": int64(12884901888),
			"used_percent": 25.0,
			"swap_used":    int64(536870912), "swap_total": int64(3221225472),
		},
		"disks": []any{
			map[string]any{"mount": `C:\`, "fstype": "NTFS", "used": int64(42949672960), "total": int64(107374182400), "used_percent": 40.0, "external": false},
			map[string]any{"mount": `D:\`, "fstype": "exFAT", "used": int64(21474836480), "total": int64(68719476736), "used_percent": 31.25, "external": true},
		},
		"disk_io": map[string]any{"read_rate": 3.5, "write_rate": 0.25},
		"network": []any{
			map[string]any{"name": "Ethernet", "rx_rate_mbs": 7.5, "tx_rate_mbs": 0.75},
		},
		"network_total": map[string]any{"rx_rate_mbs": 7.5, "tx_rate_mbs": 0.75},
		"top_processes": []any{
			map[string]any{"pid": 100, "name": "chrome", "cpu": 22.5, "memory_bytes": int64(524288000)},
			map[string]any{"pid": 200, "name": "Code", "cpu": 9.5, "memory_bytes": int64(314572800)},
			map[string]any{"pid": 300, "name": "svchost", "cpu": 3.5, "memory_bytes": int64(52428800)},
			map[string]any{"pid": 400, "name": "explorer", "cpu": 1.5, "memory_bytes": int64(104857600)},
			map[string]any{"pid": 500, "name": "System", "cpu": 0.5, "memory_bytes": int64(16777216)},
		},
	}
}

// Tokens that only one area produces in tstBaseDoc (settings: two core rows).
var tstAreaTokens = map[string][]string{
	"uptime":    {"1d 2h"},
	"cpu":       {"41.7%", "83.4%", "57.2%"},
	"memory":    {"25.0%", "12.0GB", "16.0GB", "512.0MB", "3.0GB"},
	"disks":     {`C:\`, `D:\`, "40.0%", "31.3%", "60.0GB", "44.0GB"},
	"disk_io":   {"3.5MB/s", "0.25MB/s"},
	"network":   {"7.5MB/s", "0.75MB/s"},
	"processes": {"chrome", "22.5%", "500.0MB", "svchost"},
}

func tstCopyDoc(doc map[string]any) map[string]any {
	b, _ := json.Marshal(doc)
	var out map[string]any
	_ = json.Unmarshal(b, &out)
	return out
}

func tstSet(doc map[string]any, value any, path ...string) {
	cur := doc
	for _, p := range path[:len(path)-1] {
		cur = cur[p].(map[string]any)
	}
	cur[path[len(path)-1]] = value
}

// tstRenderDoc renders the base document changed by mut.
func tstRenderDoc(t *testing.T, mut func(doc map[string]any), cores, width, height int) string {
	t.Helper()
	doc := tstCopyDoc(tstBaseDoc())
	if mut != nil {
		mut(doc)
	}
	return tstRenderFrame(tstSnapshotFromDoc(t, doc), cores, width, height, false)
}

func tstFrameLines(frame string) []string { return strings.Split(frame, "\n") }

// tstAssertFits checks the bounds of ST-20 (0 means 80 or 24).
func tstAssertFits(t *testing.T, frame string, width, height int) {
	t.Helper()
	if width <= 0 {
		width = 80
	}
	if height <= 0 {
		height = 24
	}
	lines := tstFrameLines(frame)
	if len(lines) > height {
		t.Errorf("frame has %d lines, window height is %d", len(lines), height)
	}
	for i, l := range lines {
		if w := ansi.StringWidth(l); w > width {
			t.Errorf("line %d is %d cells wide, window width is %d: %q", i, w, width, l)
		}
	}
}

func tstStandalone(text, number string) bool {
	return regexp.MustCompile(`(^|[^0-9.])` + number + `([^0-9.%]|$)`).MatchString(text)
}

func tstCountStandalone(text, number string) int {
	return len(regexp.MustCompile(`(^|[^0-9.])`+number+`([^0-9.%]|$)`).FindAllString(text, -1))
}

func tstIndexAfter(t *testing.T, frame, token string, from int) int {
	t.Helper()
	i := strings.Index(frame[from:], token)
	if i < 0 {
		t.Fatalf("token %q not found in\n%s", token, frame)
	}
	return from + i
}

func tstLineOf(frame string, offset int) string {
	start := strings.LastIndex(frame[:offset], "\n") + 1
	end := strings.Index(frame[offset:], "\n")
	if end < 0 {
		return frame[start:]
	}
	return frame[start : offset+end]
}

// ---------------------------------------------------------------------------
// ST-16: structure

func TestFrameShowsEveryValueOfACompleteDocument(t *testing.T) {
	frame := tstRenderDoc(t, nil, 2, 100, 60)
	for area, tokens := range tstAreaTokens {
		for _, tok := range tokens {
			if !strings.Contains(frame, tok) {
				t.Errorf("%s: frame does not contain %q:\n%s", area, tok, frame)
			}
		}
	}
	for _, absent := range []string{"12.6%", "29.8%"} {
		if strings.Contains(frame, absent) {
			t.Errorf("frame lists %q, a core beyond the two most loaded", absent)
		}
	}
}

func TestFrameTitleLineNamesTheToolAndShowsTheUptime(t *testing.T) {
	frame := tstRenderDoc(t, nil, 2, 80, 40)
	var first string
	for _, l := range tstFrameLines(frame) {
		if strings.TrimSpace(l) != "" {
			first = l
			break
		}
	}
	if !strings.Contains(first, "Status") || !strings.Contains(first, "1d 2h") {
		t.Errorf("first line %q should contain the name \"Status\" and the uptime 1d 2h", first)
	}
}

func TestFrameSectionsAppearInTheDocumentedOrder(t *testing.T) {
	frame := tstRenderDoc(t, nil, 2, 60, 80)
	order := []struct {
		name   string
		tokens []string
	}{
		{"title", tstAreaTokens["uptime"]},
		{"cpu", tstAreaTokens["cpu"]},
		{"memory", tstAreaTokens["memory"]},
		{"disks", append(append([]string{}, tstAreaTokens["disks"]...), tstAreaTokens["disk_io"]...)},
		{"network", tstAreaTokens["network"]},
		{"processes", tstAreaTokens["processes"]},
	}
	prevEnd := -1
	for _, sec := range order {
		first, last := len(frame), -1
		for _, tok := range sec.tokens {
			i := strings.Index(frame, tok)
			if i < 0 {
				t.Fatalf("%s: token %q missing", sec.name, tok)
			}
			if i < first {
				first = i
			}
			if i > last {
				last = i
			}
		}
		if first < prevEnd {
			t.Errorf("section %s starts before the previous section ended; expected order: title, CPU, memory, disks, network, processes", sec.name)
		}
		prevEnd = last
	}
}

func TestFrameDiskIOFollowsTheDriveRows(t *testing.T) {
	frame := tstRenderDoc(t, nil, 2, 60, 80)
	lastDrive := strings.Index(frame, `D:\`)
	if io := strings.Index(frame, "3.5MB/s"); io < lastDrive {
		t.Errorf("read rate appears before the last drive row")
	}
	if io := strings.Index(frame, "0.25MB/s"); io < lastDrive {
		t.Errorf("write rate appears before the last drive row")
	}
}

func TestFrameListsTheMostLoadedCoresWithNumbersStartingAtOne(t *testing.T) {
	mut := func(doc map[string]any) {
		tstSet(doc, []any{80.0, 10.0, 55.0, 55.0}, "cpu", "per_core")
		tstSet(doc, 50.0, "cpu", "usage")
	}
	type row struct{ token, number string }
	cases := []struct {
		cores int
		rows  []row
	}{
		{2, []row{{"80.0%", "1"}, {"55.0%", "3"}}},
		{3, []row{{"80.0%", "1"}, {"55.0%", "3"}, {"55.0%", "4"}}},
		{0, []row{{"80.0%", "1"}, {"55.0%", "3"}, {"55.0%", "4"}, {"10.0%", "2"}}},
		{8, []row{{"80.0%", "1"}, {"55.0%", "3"}, {"55.0%", "4"}, {"10.0%", "2"}}},
	}
	for _, c := range cases {
		frame := tstRenderDoc(t, mut, c.cores, 60, 60)
		cursor := 0
		counts := map[string]int{}
		for _, r := range c.rows {
			off := tstIndexAfter(t, frame, r.token, cursor)
			cursor = off + 1
			counts[r.token]++
			line := tstLineOf(frame, off)
			if !tstStandalone(line, r.number) {
				t.Errorf("cpu_cores=%d: the row of %s should carry the core number %s, line %q", c.cores, r.token, r.number, line)
			}
		}
		for _, token := range []string{"80.0%", "55.0%", "10.0%"} {
			if got := strings.Count(frame, token); got != counts[token] {
				t.Errorf("cpu_cores=%d: %q appears %d times, want %d", c.cores, token, got, counts[token])
			}
		}
	}
}

func TestFrameCoreRowsFollowLoadDescendingThenCoreNumber(t *testing.T) {
	mut := func(doc map[string]any) {
		tstSet(doc, []any{10.0, 55.0, 80.0, 55.0}, "cpu", "per_core")
		tstSet(doc, 50.0, "cpu", "usage")
	}
	frame := tstRenderDoc(t, mut, 0, 60, 60)
	a := strings.Index(frame, "80.0%")
	first55 := strings.Index(frame, "55.0%")
	second55 := tstIndexAfter(t, frame, "55.0%", first55+1)
	last := strings.Index(frame, "10.0%")
	if !(a < first55 && first55 < second55 && second55 < last) {
		t.Fatalf("core rows are not ordered 80, 55, 55, 10: offsets %d %d %d %d", a, first55, second55, last)
	}
	if line := tstLineOf(frame, first55); !tstStandalone(line, "2") || tstStandalone(line, "4") {
		t.Errorf("the first 55%% row is core 2: %q", line)
	}
	if line := tstLineOf(frame, second55); !tstStandalone(line, "4") || tstStandalone(line, "2") {
		t.Errorf("the second 55%% row is core 4: %q", line)
	}
}

func TestFrameCPUCountsShowPhysicalCoresOnlyWhenKnownAndDifferent(t *testing.T) {
	cores := func(doc map[string]any, physical any) {
		per := []any{90.1, 80.2}
		for i := 0; i < 10; i++ {
			per = append(per, 5.1)
		}
		tstSet(doc, per, "cpu", "per_core")
		tstSet(doc, 12, "cpu", "logical_cpu")
		tstSet(doc, physical, "cpu", "core_count")
	}
	frame := tstRenderDoc(t, func(d map[string]any) { cores(d, 6) }, 2, 100, 60)
	if !tstStandalone(frame, "12") || !tstStandalone(frame, "6") {
		t.Errorf("6 physical cores and 12 logical processors should both be shown:\n%s", frame)
	}
	frame = tstRenderDoc(t, func(d map[string]any) { cores(d, 12) }, 2, 100, 60)
	if n := tstCountStandalone(frame, "12"); n != 1 {
		t.Errorf("equal counts: the number 12 appears %d times, want once", n)
	}
	frame = tstRenderDoc(t, func(d map[string]any) { cores(d, nil) }, 2, 100, 60)
	if !tstStandalone(frame, "12") {
		t.Errorf("unknown physical count: the 12 logical processors should be shown")
	}
	if tstStandalone(frame, "6") {
		t.Errorf("unknown physical count: no second number may be shown")
	}
}

func TestFrameShowsPageFileOnlyWhenOneExists(t *testing.T) {
	frame := tstRenderDoc(t, func(d map[string]any) {
		tstSet(d, 0, "memory", "swap_used")
		tstSet(d, 0, "memory", "swap_total")
	}, 2, 100, 60)
	if regexp.MustCompile(`(^|[^0-9.])0B`).MatchString(frame) || strings.Contains(frame, "512.0MB") || strings.Contains(frame, "3.0GB") {
		t.Errorf("a page file section is shown although swap_total is 0:\n%s", frame)
	}
	frame = tstRenderDoc(t, func(d map[string]any) {
		tstSet(d, nil, "memory", "swap_used")
		tstSet(d, nil, "memory", "swap_total")
	}, 2, 100, 60)
	if strings.Contains(frame, "512.0MB") || regexp.MustCompile(`(^|[^0-9.])0B`).MatchString(frame) {
		t.Errorf("page file values are shown although they are unknown:\n%s", frame)
	}
	if !strings.Contains(frame, "12.0GB") {
		t.Errorf("the rest of the memory section disappeared")
	}
}

// ---------------------------------------------------------------------------
// ST-6, ST-16: unavailable areas

var tstZeroLooking = regexp.MustCompile(`(^|[^0-9.])0(\.0+)?(%|B\b|KB|MB|GB|TB)`)

func TestFrameShowsAPlaceholderInsteadOfNumbersForUnavailableAreas(t *testing.T) {
	cases := []struct {
		name  string
		mut   func(doc map[string]any)
		areas []string // areas whose tokens must disappear
	}{
		{"uptime", func(d map[string]any) { d["uptime_seconds"] = nil }, []string{"uptime"}},
		{"cpu", func(d map[string]any) { d["cpu"] = nil }, []string{"cpu"}},
		{"memory", func(d map[string]any) { d["memory"] = nil }, []string{"memory"}},
		{"disks", func(d map[string]any) { d["disks"] = nil }, []string{"disks"}},
		{"disk io", func(d map[string]any) { d["disk_io"] = nil }, []string{"disk_io"}},
		{"network", func(d map[string]any) { d["network_total"] = nil; d["network"] = nil }, []string{"network"}},
		{"processes", func(d map[string]any) { d["top_processes"] = nil; d["procs"] = nil }, []string{"processes"}},
	}
	for _, c := range cases {
		c := c
		t.Run(c.name, func(t *testing.T) {
			frame := tstRenderDoc(t, c.mut, 2, 100, 60)
			gone := map[string]bool{}
			for _, a := range c.areas {
				gone[a] = true
				for _, tok := range tstAreaTokens[a] {
					if strings.Contains(frame, tok) {
						t.Errorf("unavailable %s: frame still contains %q", c.name, tok)
					}
				}
			}
			for area, tokens := range tstAreaTokens {
				if gone[area] {
					continue
				}
				for _, tok := range tokens {
					if !strings.Contains(frame, tok) {
						t.Errorf("unavailable %s changed another area: %q missing", c.name, tok)
					}
				}
			}
			if m := tstZeroLooking.FindString(frame); m != "" {
				t.Errorf("unavailable %s is shown as a zero value %q:\n%s", c.name, m, frame)
			}
		})
	}
}

func TestFrameKeepsEverySectionWhenNothingIsAvailable(t *testing.T) {
	frame := tstRenderDoc(t, func(d map[string]any) {
		for _, k := range tstTopLevelKeys[1:] {
			d[k] = nil
		}
	}, 2, 80, 24)
	tstAssertFits(t, frame, 80, 24)
	nonBlank := 0
	for _, l := range tstFrameLines(frame) {
		if strings.TrimSpace(l) != "" {
			nonBlank++
		}
	}
	if nonBlank < 6 {
		t.Errorf("only %d non-blank lines; the title and the five sections must stay visible:\n%s", nonBlank, frame)
	}
	if regexp.MustCompile(`[0-9]%`).MatchString(frame) || regexp.MustCompile(`[0-9](B|KB|MB|GB|TB)\b`).MatchString(frame) {
		t.Errorf("a placeholder must not look like a measured value:\n%s", frame)
	}
	if !strings.Contains(frame, "Status") {
		t.Errorf("the title is missing:\n%s", frame)
	}
}

func TestFrameWithEmptyProcessListShowsNoProcess(t *testing.T) {
	frame := tstRenderDoc(t, func(d map[string]any) { d["top_processes"] = []any{} }, 2, 80, 40)
	for _, tok := range tstAreaTokens["processes"] {
		if strings.Contains(frame, tok) {
			t.Errorf("frame contains %q although no process has a measurement window", tok)
		}
	}
	tstAssertFits(t, frame, 80, 40)
}

// ---------------------------------------------------------------------------
// ST-19: number formats

func TestFrameFormatsBytesWithOneDecimalAndBinaryUnits(t *testing.T) {
	cases := []struct {
		total, available uint64
		used, tot, avail string
	}{
		{1024, 512, "512B", "1.0KB", "512B"},
		{1536 * 1024, 512 * 1024, "1.0MB", "1.5MB", "512.0KB"},
		{16 * tstGiB, 12 * tstGiB, "4.0GB", "16.0GB", "12.0GB"},
		{2 * 1024 * tstGiB, 1024 * tstGiB, "1.0TB", "2.0TB", "1.0TB"},
		{3 * tstGiB / 2, tstGiB / 2, "1.0GB", "1.5GB", "512.0MB"},
	}
	for _, c := range cases {
		frame := tstRenderDoc(t, func(d map[string]any) {
			tstSet(d, int64(c.total), "memory", "total")
			tstSet(d, int64(c.available), "memory", "available")
			tstSet(d, int64(c.total-c.available), "memory", "used")
			tstSet(d, 100*float64(c.total-c.available)/float64(c.total), "memory", "used_percent")
			tstSet(d, nil, "memory", "swap_used")
			tstSet(d, nil, "memory", "swap_total")
			d["disks"] = nil // drive sizes would hide missing matches
		}, 2, 100, 60)
		for _, want := range []string{c.used, c.tot, c.avail} {
			if !strings.Contains(frame, want) {
				t.Errorf("total=%d available=%d: frame does not contain %q:\n%s", c.total, c.available, want, frame)
			}
		}
	}
}

func TestFrameFormatsPercentWithOneDecimalRoundingHalfUp(t *testing.T) {
	cases := []struct {
		value float64
		want  string
	}{
		{12.3, "12.3%"},
		{100, "100.0%"},
		{12.25, "12.3%"},
		{7, "7.0%"},
		{99.5, "99.5%"},
	}
	for _, c := range cases {
		frame := tstRenderDoc(t, func(d map[string]any) { tstSet(d, c.value, "cpu", "usage") }, 2, 100, 60)
		if !strings.Contains(frame, c.want) {
			t.Errorf("percent %v: frame does not contain %q:\n%s", c.value, c.want, frame)
		}
	}
	frame := tstRenderDoc(t, func(d map[string]any) { tstSet(d, 0.0, "cpu", "usage") }, 2, 100, 60)
	if !regexp.MustCompile(`(^|[^0-9.])0\.0%`).MatchString(frame) {
		t.Errorf("a measured 0 percent is shown as 0.0%%:\n%s", frame)
	}
}

func TestFrameFormatsRatesInMegabytesPerSecond(t *testing.T) {
	cases := []struct {
		value  float64
		want   string // literal text, or a regexp when it starts with ^
		absent string
	}{
		{0, `^(^|[^0-9.])0MB/s`, ""},
		{0.004, `^(^|[^0-9.])0MB/s`, ""},
		{0.0099, `^(^|[^0-9.])0MB/s`, ""},
		{0.01, "0.01MB/s", ""},
		{0.25, "0.25MB/s", ""},
		{0.125, "0.13MB/s", "0.12MB/s"},
		{1, "1.0MB/s", ""},
		{3.5, "3.5MB/s", ""},
		{3.25, "3.3MB/s", "3.2MB/s"},
		{9.5, "9.5MB/s", ""},
		{10, "10MB/s", "10.0MB/s"},
		{42, "42MB/s", ""},
		{42.5, "43MB/s", "42MB/s"},
	}
	for _, c := range cases {
		frame := tstRenderDoc(t, func(d map[string]any) {
			tstSet(d, c.value, "disk_io", "read_rate")
			tstSet(d, 1.5, "disk_io", "write_rate")
			tstSet(d, 5.5, "network_total", "rx_rate_mbs")
			tstSet(d, 6.5, "network_total", "tx_rate_mbs")
		}, 2, 100, 60)
		if strings.HasPrefix(c.want, "^") {
			if !regexp.MustCompile(c.want[1:]).MatchString(frame) {
				t.Errorf("rate %v: frame has no %s:\n%s", c.value, c.want, frame)
			}
			if strings.Contains(frame, "0.00MB/s") || strings.Contains(frame, "0.0MB/s") {
				t.Errorf("rate %v: a zero rate carries decimals", c.value)
			}
		} else if !strings.Contains(frame, c.want) {
			t.Errorf("rate %v: frame does not contain %q:\n%s", c.value, c.want, frame)
		}
		if c.absent != "" && strings.Contains(frame, c.absent) {
			t.Errorf("rate %v: frame contains %q, rounding must be half up", c.value, c.absent)
		}
	}
}

func TestFrameFormatsUptime(t *testing.T) {
	cases := []struct {
		seconds int
		want    string
	}{
		{93784, "1d 2h"},
		{3700, "1h 1m"},
		{59, "0m"},
		{60, "1m"},
		{119, "1m"},
		{3600, "1h 0m"},
		{86400, "1d 0h"},
		{2*86400 + 3599, "2d 0h"},
		{10*86400 + 23*3600 + 59*60, "10d 23h"},
	}
	for _, c := range cases {
		frame := tstRenderDoc(t, func(d map[string]any) { d["uptime_seconds"] = c.seconds }, 2, 100, 60)
		first := ""
		for _, l := range tstFrameLines(frame) {
			if strings.TrimSpace(l) != "" {
				first = l
				break
			}
		}
		ok := strings.Contains(first, c.want)
		if c.want == "0m" {
			ok = regexp.MustCompile(`(^|[^0-9])0m`).MatchString(first)
		}
		if !ok {
			t.Errorf("uptime %d s: title line %q does not contain %q", c.seconds, first, c.want)
		}
	}
}

// ---------------------------------------------------------------------------
// ST-20: bounds

func tstHeavyDoc() map[string]any {
	doc := tstCopyDoc(tstBaseDoc())
	var per []any
	for i := 0; i < 16; i++ {
		per = append(per, 97.3-5*float64(i))
	}
	tstSet(doc, per, "cpu", "per_core")
	tstSet(doc, 16, "cpu", "logical_cpu")
	tstSet(doc, 8, "cpu", "core_count")
	tstSet(doc, 60.0, "cpu", "usage")
	disks := doc["disks"].([]any)
	for _, m := range []string{`E:\`, `F:\`} {
		disks = append(disks, map[string]any{"mount": m, "fstype": "NTFS", "used": int64(1 << 30), "total": int64(2 << 30), "used_percent": 50.0, "external": false})
	}
	doc["disks"] = disks
	var procs []any
	for i := 0; i < 5; i++ {
		procs = append(procs, map[string]any{"pid": 10 + i, "name": fmt.Sprintf("procname%d", i+1), "cpu": 9.5 - float64(i), "memory_bytes": int64(1<<20) * int64(i+1)})
	}
	doc["top_processes"] = procs
	return doc
}

func TestFrameNeverExceedsTheWindow(t *testing.T) {
	sizes := [][2]int{{80, 24}, {80, 40}, {120, 30}, {60, 24}, {40, 20}, {100, 50}, {30, 12}, {200, 60}, {20, 10}, {80, 8}, {80, 3}, {80, 1}, {0, 0}, {0, 24}, {80, 0}, {-5, -5}}
	for _, cores := range []int{0, 2, 4, 8} {
		for _, sz := range sizes {
			for _, color := range []bool{false, true} {
				snap := tstSnapshotFromDoc(t, tstHeavyDoc())
				frame := tstRenderFrame(snap, cores, sz[0], sz[1], color)
				tstAssertFits(t, frame, sz[0], sz[1])
			}
		}
	}
}

func TestFrameWithUnavailableAreasNeverExceedsTheWindow(t *testing.T) {
	for _, sz := range [][2]int{{80, 24}, {40, 12}, {0, 0}} {
		doc := tstHeavyDoc()
		for _, k := range tstTopLevelKeys[1:] {
			doc[k] = nil
		}
		frame := tstRenderFrame(tstSnapshotFromDoc(t, doc), 0, sz[0], sz[1], false)
		tstAssertFits(t, frame, sz[0], sz[1])
	}
}

func tstCoreRows(frame string) int {
	n := 0
	for i := 0; i < 16; i++ {
		n += strings.Count(frame, fmt.Sprintf("%.1f%%", 97.3-5*float64(i)))
	}
	return n
}

func tstProcessRows(frame string) int {
	n := 0
	for i := 1; i <= 5; i++ {
		if strings.Contains(frame, fmt.Sprintf("procname%d", i)) {
			n++
		}
	}
	return n
}

func TestFrameShrinksCoreListThenProcessesThenCutsTheBottom(t *testing.T) {
	snap := tstSnapshotFromDoc(t, tstHeavyDoc())
	prevCores, prevProcs := 0, 0
	for h := 1; h <= 100; h++ {
		frame := tstRenderFrame(snap, 0, 80, h, false)
		tstAssertFits(t, frame, 80, h)
		c, p := tstCoreRows(frame), tstProcessRows(frame)
		if c > 2 && p != 5 {
			t.Errorf("height %d: %d core rows but only %d process rows; cores shrink to 2 before processes shrink", h, c, p)
		}
		if p != 5 && p != 3 && p != 1 && p != 0 {
			t.Errorf("height %d: %d process rows, want 5, 3 or 1", h, p)
		}
		if p == 5 && c != 16 && c != 8 && c != 4 && c != 2 {
			t.Errorf("height %d: %d core rows with all processes shown, want a step of 16, 8, 4 or 2", h, c)
		}
		if c < prevCores || p < prevProcs {
			t.Errorf("height %d: core rows %d -> %d, process rows %d -> %d; a taller window never shows less", h, prevCores, c, prevProcs, p)
		}
		prevCores, prevProcs = c, p
	}
	frame := tstRenderFrame(snap, 0, 80, 100, false)
	if c, p := tstCoreRows(frame), tstProcessRows(frame); c != 16 || p != 5 {
		t.Errorf("in a tall window the full setting returns: %d core rows (want 16), %d process rows (want 5)", c, p)
	}
}

func TestFrameShrinksTheCoreListToTwoBeforeAnythingElse(t *testing.T) {
	snap := tstSnapshotFromDoc(t, tstHeavyDoc())
	sawTwoCores := false
	for h := 1; h <= 100; h++ {
		frame := tstRenderFrame(snap, 0, 80, h, false)
		if c, p := tstCoreRows(frame), tstProcessRows(frame); c == 2 && p == 5 {
			sawTwoCores = true
		}
	}
	if !sawTwoCores {
		t.Errorf("no window height shows two core rows together with all five processes")
	}
}

func TestFrameShortensLongProcessNamesWithAnEllipsis(t *testing.T) {
	name := strings.Repeat("A", 30) + strings.Repeat("B", 30)
	for _, width := range []int{40, 50} {
		frame := tstRenderDoc(t, func(d map[string]any) {
			procs := d["top_processes"].([]any)
			procs[0].(map[string]any)["name"] = name
		}, 2, width, 40)
		tstAssertFits(t, frame, width, 40)
		found := false
		for _, l := range tstFrameLines(frame) {
			if strings.Contains(l, "AAAAAA") {
				found = true
				if !strings.Contains(l, "…") {
					t.Errorf("width %d: shortened name without an ellipsis: %q", width, l)
				}
				if strings.Contains(l, name) {
					t.Errorf("width %d: the full 60-character name is shown: %q", width, l)
				}
			}
		}
		if !found {
			t.Errorf("width %d: the process name is not shown at all:\n%s", width, frame)
		}
	}
}

func TestFrameKeepsAShortProcessNameWhole(t *testing.T) {
	frame := tstRenderDoc(t, nil, 2, 80, 40)
	if !strings.Contains(frame, "explorer") || strings.Contains(frame, "explor…") {
		t.Errorf("a short name must not be shortened:\n%s", frame)
	}
}

// ---------------------------------------------------------------------------
// ST-21: colour

var tstSGR = regexp.MustCompile("\x1b\\[([0-9;:]*)m")

func tstAssertNoColor(t *testing.T, frame string) {
	t.Helper()
	allowed := map[string]bool{"": true, "0": true, "1": true, "7": true, "22": true, "27": true}
	for _, m := range tstSGR.FindAllStringSubmatch(frame, -1) {
		for _, p := range strings.FieldsFunc(m[1], func(r rune) bool { return r == ';' || r == ':' }) {
			if !allowed[p] {
				t.Errorf("colour instruction %q in a frame rendered without colour", m[0])
			}
		}
	}
}

func TestFrameWithoutColorHasNoColorInstructions(t *testing.T) {
	for _, h := range []int{24, 60} {
		frame := tstRenderFrame(tstSnapshotFromDoc(t, tstHeavyDoc()), 0, 100, h, false)
		tstAssertNoColor(t, frame)
		tstAssertFits(t, frame, 100, h)
	}
	doc := tstCopyDoc(tstBaseDoc())
	for _, k := range tstTopLevelKeys[1:] {
		doc[k] = nil
	}
	tstAssertNoColor(t, tstRenderFrame(tstSnapshotFromDoc(t, doc), 2, 80, 24, false))
}

func TestFrameWithoutColorStaysReadable(t *testing.T) {
	frame := tstRenderDoc(t, nil, 2, 80, 60)
	plain := ansi.Strip(frame)
	for area, tokens := range tstAreaTokens {
		for _, tok := range tokens {
			if !strings.Contains(plain, tok) {
				t.Errorf("%s: %q is missing without colour", area, tok)
			}
		}
	}
}
