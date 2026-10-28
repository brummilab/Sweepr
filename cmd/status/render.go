package main

import (
	"fmt"
	"math"
	"sort"
	"strings"
	"unicode"

	"github.com/charmbracelet/x/ansi"
)

const (
	defaultWidth  = 80
	defaultHeight = 24

	// defaultCPUCores is the number of core rows when nothing else is saved.
	defaultCPUCores = 2

	// historyLength is the number of network samples the display remembers.
	historyLength = 120

	maxBarWidth = 20
)

// Settings are the user settings that change what the frame shows.
type Settings struct {
	// CPUCores is the number of core rows in the CPU card; 0 lists all.
	CPUCores int
}

// histPoint is one network sample for the history graph. A sample that could
// not be measured is a gap (ok false), never a value of zero.
type histPoint struct {
	v  float64
	ok bool
}

type frameInput struct {
	snap          Snapshot
	set           Settings
	width, height int
	color         bool
	rxHistory     []histPoint
	txHistory     []histPoint
}

// RenderFrame draws a snapshot as text for a window of the given size. It never
// returns a line wider or more lines than the window; a size of 0 or less
// means 80 by 24. With color false the text contains no color instructions.
func RenderFrame(s Snapshot, set Settings, width, height int, color bool) string {
	return renderFrame(frameInput{snap: s, set: set, width: width, height: height, color: color})
}

func windowSize(width, height int) (int, int) {
	if width <= 0 {
		width = defaultWidth
	}
	if height <= 0 {
		height = defaultHeight
	}
	return width, height
}

func renderFrame(in frameInput) string {
	in.width, in.height = windowSize(in.width, in.height)

	// Shrink in the documented order. First the core list steps down (8, 4,
	// 2) while the saved setting stays untouched, then the process list (3,
	// 1), and only at last the bottom is cut off.
	steps := coreSteps(in.coreRows())
	for _, c := range steps {
		if lines := in.build(c, maxTopProcesses); len(lines) <= in.height {
			return in.finish(lines)
		}
	}
	last := steps[len(steps)-1]
	for _, p := range []int{3, 1} {
		if lines := in.build(last, p); len(lines) <= in.height {
			return in.finish(lines)
		}
	}
	return in.finish(in.build(last, 1))
}

// finish cuts the lines to the window and joins them.
func (in frameInput) finish(lines []string) string {
	if len(lines) > in.height {
		lines = lines[:in.height]
	}
	out := make([]string, len(lines))
	for i, l := range lines {
		if ansi.StringWidth(l) > in.width {
			l = ansi.Truncate(l, in.width, "")
			if strings.Contains(l, "\x1b") {
				l += "\x1b[0m"
			}
		}
		out[i] = l
	}
	return strings.Join(out, "\n")
}

// loadingFrame is shown until the first measurement has arrived.
func loadingFrame(width, height int, color bool) string {
	in := frameInput{width: width, height: height, color: color}
	in.width, in.height = windowSize(width, height)
	p := palette{color}
	return in.finish([]string{p.bold("Status"), "", "Loading first measurement..."})
}

// coreRows is the number of core rows the setting asks for, limited to the
// number of processors that were measured.
func (in frameInput) coreRows() int {
	n := 0
	if in.snap.CPU != nil {
		n = len(in.snap.CPU.PerCore)
	}
	want := in.set.CPUCores
	if want < 0 {
		want = defaultCPUCores
	}
	if want == 0 || want > n {
		return n
	}
	return want
}

// coreSteps lists the row counts to try, largest first: the wanted count, then
// 8, 4 and 2 where smaller.
func coreSteps(want int) []int {
	steps := []int{want}
	for _, s := range []int{8, 4, 2} {
		if s < want {
			steps = append(steps, s)
		}
	}
	return steps
}

func (in frameInput) build(cores, procRows int) []string {
	var lines []string
	lines = append(lines, in.titleLines()...)
	lines = append(lines, in.cpuLines(cores)...)
	lines = append(lines, in.memoryLines()...)
	lines = append(lines, in.diskLines()...)
	lines = append(lines, in.networkLines()...)
	lines = append(lines, in.processLines(procRows)...)
	return lines
}

// palette applies the few styles of the display. Without color only bold is
// used, so the display stays readable on any terminal.
type palette struct{ color bool }

func (p palette) bold(s string) string { return "\x1b[1m" + s + "\x1b[22m" }

func (p palette) dim(s string) string {
	if !p.color {
		return s
	}
	return "\x1b[2m" + s + "\x1b[22m"
}

func (p palette) accent(s string) string {
	if !p.color {
		return s
	}
	return "\x1b[36m" + s + "\x1b[0m"
}

// load colors a value by how full it is: green, yellow, red.
func (p palette) load(pct float64, s string) string {
	if !p.color {
		return s
	}
	code := "32"
	switch {
	case pct >= 85:
		code = "31"
	case pct >= 60:
		code = "33"
	}
	return "\x1b[" + code + "m" + s + "\x1b[0m"
}

const placeholder = "n/a"

// printable drops control characters, so that a name read from the system can
// never inject terminal instructions.
func printable(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, s)
}

func padRight(s string, n int) string {
	if w := ansi.StringWidth(s); w < n {
		return s + strings.Repeat(" ", n-w)
	}
	return s
}

func (in frameInput) bar(pct float64, width int) string {
	if pct < 0 || math.IsNaN(pct) {
		pct = 0
	}
	if pct > 100 {
		pct = 100
	}
	filled := int(math.Floor(pct/100*float64(width) + 0.5))
	full := strings.Repeat("█", filled)
	empty := strings.Repeat("░", width-filled)
	return palette{in.color}.load(pct, full) + palette{in.color}.dim(empty)
}

// meter writes prefix, a bar that uses what is left of the width up to
// maxBarWidth, and suffix. The bar is dropped when it would be too small.
func (in frameInput) meter(prefix string, pct float64, suffix string) string {
	room := in.width - ansi.StringWidth(prefix) - ansi.StringWidth(suffix) - 1
	if room > maxBarWidth {
		room = maxBarWidth
	}
	if room < 4 {
		return prefix + suffix
	}
	return prefix + " " + in.bar(pct, room) + suffix
}

func (in frameInput) percentCell(pct float64) string {
	return palette{in.color}.load(pct, fmt.Sprintf("%6s", formatPercent(pct)))
}

func (in frameInput) titleLines() []string {
	p := palette{in.color}
	up := "up " + placeholder
	if in.snap.UptimeSeconds != nil {
		up = "up " + formatUptime(*in.snap.UptimeSeconds)
	}
	lines := []string{p.bold("Status") + "  " + up}
	var missing []string
	for _, a := range unavailableAreas(in.snap) {
		if a != areaPlatform {
			missing = append(missing, a)
		}
	}
	if len(missing) > 0 {
		lines = append(lines, p.dim("not measurable: "+strings.Join(missing, ", ")))
	}
	return lines
}

func (in frameInput) cpuLines(cores int) []string {
	p := palette{in.color}
	head := p.bold(padRight("CPU", 10))
	c := in.snap.CPU
	if c == nil {
		return []string{head + placeholder}
	}
	lines := []string{in.meter(head+in.percentCell(c.Usage), c.Usage, "")}

	type core struct {
		n   int
		pct float64
	}
	ranked := make([]core, len(c.PerCore))
	for i, v := range c.PerCore {
		ranked[i] = core{i + 1, v}
	}
	// Most loaded first; the stable sort keeps equal load in core order.
	sort.SliceStable(ranked, func(i, j int) bool { return ranked[i].pct > ranked[j].pct })
	if cores > len(ranked) {
		cores = len(ranked)
	}
	for _, r := range ranked[:cores] {
		label := padRight(fmt.Sprintf("  Core %d", r.n), 10)
		lines = append(lines, in.meter(label+in.percentCell(r.pct), r.pct, ""))
	}

	count := fmt.Sprintf("  %d logical processors", c.LogicalCPU)
	if c.CoreCount != nil && *c.CoreCount != c.LogicalCPU {
		count = fmt.Sprintf("  %d cores, %d logical processors", *c.CoreCount, c.LogicalCPU)
	}
	return append(lines, p.dim(count))
}

func (in frameInput) memoryLines() []string {
	p := palette{in.color}
	head := p.bold(padRight("Memory", 10))
	m := in.snap.Memory
	if m == nil {
		return []string{head + placeholder}
	}
	lines := []string{
		in.meter(head+in.percentCell(m.UsedPercent), m.UsedPercent, ""),
		fmt.Sprintf("  %s of %s used, %s available", formatBytes(m.Used), formatBytes(m.Total), formatBytes(m.Available)),
	}
	if m.SwapTotal != nil && m.SwapUsed != nil && *m.SwapTotal > 0 {
		lines = append(lines, fmt.Sprintf("  Swap %s of %s", formatBytes(*m.SwapUsed), formatBytes(*m.SwapTotal)))
	}
	return lines
}

func (in frameInput) diskLines() []string {
	p := palette{in.color}
	lines := []string{p.bold("Disks")}
	if in.snap.Disks == nil {
		lines = append(lines, "  "+placeholder)
	}
	for _, d := range in.snap.Disks {
		free := uint64(0)
		if d.Total > d.Used {
			free = d.Total - d.Used
		}
		suffix := fmt.Sprintf("  %s used, %s free", formatBytes(d.Used), formatBytes(free))
		if d.External {
			suffix += "  removable"
		}
		prefix := padRight("  "+printable(d.Mount), 8) + in.percentCell(d.UsedPercent)
		lines = append(lines, in.meter(prefix, d.UsedPercent, suffix))
	}
	io := "  " + padRight("I/O", 8) + placeholder
	if r := in.snap.DiskIO; r != nil {
		io = "  " + padRight("I/O", 8) + "Read " + formatRate(r.ReadRate) + "  Write " + formatRate(r.WriteRate)
	}
	return append(lines, io)
}

func (in frameInput) networkLines() []string {
	p := palette{in.color}
	head := p.bold(padRight("Network", 10))
	if t := in.snap.NetworkTotal; t != nil {
		head += "Down " + formatRate(t.RxRateMBs) + "  Up " + formatRate(t.TxRateMBs)
	} else {
		head += placeholder
	}
	if in.snap.defaultIPv4 != "" {
		head += "  " + in.snap.defaultIPv4
	}
	lines := []string{head}
	if anyMeasured(in.rxHistory) || anyMeasured(in.txHistory) {
		lines = append(lines,
			"  "+padRight("Down", 6)+p.accent(in.spark(in.rxHistory)),
			"  "+padRight("Up", 6)+p.accent(in.spark(in.txHistory)))
	}
	return lines
}

// anyMeasured tells whether the history holds at least one measured point; a
// history of gaps only is not drawn.
func anyMeasured(points []histPoint) bool {
	for _, pt := range points {
		if pt.ok {
			return true
		}
	}
	return false
}

// spark draws the most recent points that fit as block characters scaled to
// the largest value shown. A gap stays blank.
func (in frameInput) spark(points []histPoint) string {
	room := in.width - 8
	if room > historyLength {
		room = historyLength
	}
	if room < 1 {
		return ""
	}
	if len(points) > room {
		points = points[len(points)-room:]
	}
	peak := 0.0
	for _, pt := range points {
		if pt.ok && pt.v > peak {
			peak = pt.v
		}
	}
	levels := []rune("▁▂▃▄▅▆▇█")
	var b strings.Builder
	for _, pt := range points {
		if !pt.ok {
			b.WriteByte(' ')
			continue
		}
		i := 0
		if peak > 0 {
			i = int(pt.v / peak * float64(len(levels)-1))
		}
		b.WriteRune(levels[i])
	}
	return b.String()
}

func (in frameInput) processLines(rows int) []string {
	p := palette{in.color}
	head := "Processes"
	if in.snap.Procs != nil {
		head += fmt.Sprintf(" (%d)", *in.snap.Procs)
	}
	lines := []string{p.bold(head)}
	list := in.snap.TopProcesses
	if list == nil {
		return append(lines, "  "+placeholder)
	}
	if len(list) == 0 {
		return append(lines, "  nothing to rank yet")
	}
	if rows > len(list) {
		rows = len(list)
	}
	for i, pr := range list[:rows] {
		prefix := fmt.Sprintf("  %d ", i+1)
		cpu := p.load(pr.CPU, fmt.Sprintf("%6s", formatPercent(pr.CPU)))
		line := prefix + cpu + fmt.Sprintf(" %9s  ", formatBytes(pr.MemoryBytes))
		room := in.width - ansi.StringWidth(line)
		name := printable(pr.Name)
		if room < 1 {
			name = ""
		} else if ansi.StringWidth(name) > room {
			name = ansi.Truncate(name, room, "…")
		}
		lines = append(lines, line+name)
	}
	return lines
}
