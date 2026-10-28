package main

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/x/ansi"
)

// Drawing. Widths are cell widths (wide and combining characters count as the
// terminal draws them), no line is wider than the window and no more lines
// are produced than the window has. Colour is only ever a second signal: the
// cursor, a mark, a warning and a refusal also have a character or a word.

const (
	sgrBold    = "1"
	sgrDim     = "2"
	sgrReverse = "7"
	sgrRed     = "31"
	sgrYellow  = "33"
)

func (m *explorerModel) paint(s string, codes ...string) string {
	if s == "" {
		return s
	}
	var use []string
	for _, c := range codes {
		if m.noColor && c != sgrBold && c != sgrDim && c != sgrReverse {
			continue
		}
		use = append(use, c)
	}
	if len(use) == 0 {
		return s
	}
	return "\x1b[" + strings.Join(use, ";") + "m" + s + "\x1b[0m"
}

// fit cuts a text to a width in cells, ending it with an ellipsis.
func fit(s string, w int) string {
	if w <= 0 {
		return ""
	}
	return ansi.Truncate(s, w, "…")
}

func padRight(s string, w int) string {
	if n := ansi.StringWidth(s); n < w {
		return s + strings.Repeat(" ", w-n)
	}
	return s
}

func padLeft(s string, w int) string {
	if n := ansi.StringWidth(s); n < w {
		return strings.Repeat(" ", w-n) + s
	}
	return s
}

// fitLeft keeps the end of a text, which is the informative end of a path.
func fitLeft(s string, w int) string {
	if w <= 0 {
		return ""
	}
	n := ansi.StringWidth(s)
	if n <= w {
		return s
	}
	if w == 1 {
		return "…"
	}
	// Cutting inside a wide character leaves it out whole, which can leave the
	// result a cell too wide: cut one more cell until it fits.
	for cut := n - (w - 1); ; cut++ {
		r := ansi.TruncateLeft(s, cut, "…")
		if ansi.StringWidth(r) <= w || cut >= n {
			return r
		}
	}
}

// clean makes a file name safe to draw: control characters would move the
// cursor or break the line.
func clean(s string) string {
	return strings.Map(func(r rune) rune {
		if r < 0x20 || (r >= 0x7f && r < 0xa0) || r == 0x2028 || r == 0x2029 {
			return '?'
		}
		return r
	}, s)
}

// layoutHeights splits a window height: two lines at the bottom (message,
// keys), one to three header lines, the rest for the list.
func layoutHeights(h int) (headerN, listN int) {
	avail := h - 2
	if avail < 1 {
		return 0, 0
	}
	headerN = avail - 3
	if headerN < 1 {
		headerN = 1
	}
	if headerN > 3 {
		headerN = 3
	}
	return headerN, avail - headerN
}

// View draws the current state. It first brings the rows and the cursor up to
// date; the runtime calls it on the goroutine that runs Update, so this does
// not race.
func (m *explorerModel) View() string {
	m.ensure()
	w, h := m.windowSize()
	headerN, listN := layoutHeights(h)
	var out []string
	out = append(out, m.headerLines(w, headerN)...)
	out = append(out, m.listLines(w, listN)...)
	out = append(out, m.messageLine(w), m.footerLine(w))
	if len(out) > h {
		out = out[:h]
	}
	return strings.Join(out, "\n")
}

// ---------------------------------------------------------------------------
// Header, message, footer

func (m *explorerModel) headerLines(w, n int) []string {
	if n == 0 {
		return nil
	}
	title := m.paint(fit("Sweepr analyze", w), sgrBold)
	var path, info string
	switch m.kind {
	case viewOverview:
		path = "Overview: the profile folder and the fixed drives"
	case viewFiles:
		path = m.root
		info = "Largest files (1.0MB and bigger), biggest first"
	default:
		path = m.root
		info = m.totalLine()
	}
	pathLine := m.paint(fitLeft(clean(path), w), sgrBold)
	infoLine := fit(info, w)
	switch n {
	case 1:
		return []string{pathLine}
	case 2:
		return []string{pathLine, infoLine}
	}
	return []string{title, pathLine, infoLine}
}

// totalLine is the progress while the folder is measured and the total after.
func (m *explorerModel) totalLine() string {
	switch {
	case m.err != nil:
		return ""
	case !m.done:
		c := m.req.counters
		if c == nil {
			return "Measuring..."
		}
		return fmt.Sprintf("Measuring: %d files, %d folders, %s", c.Files(), c.Dirs(), FormatSize(c.Bytes()))
	case m.listing == nil:
		return ""
	}
	l := m.listing
	text := "Total: " + FormatSize(l.TotalSize)
	if l.State != Complete {
		text += "+"
	}
	text += fmt.Sprintf(", %d %s", l.TotalFiles, plural(int(l.TotalFiles), "file", "files"))
	if l.TotalOnlineSize > 0 {
		text += ", " + FormatSize(l.TotalOnlineSize) + " only online"
	}
	return text
}

func (m *explorerModel) messageLine(w int) string {
	if m.mode == modeConfirm {
		return m.paint(fit(m.dialogText(), w), sgrBold, sgrYellow)
	}
	if m.msgWarn {
		return m.paint(fit(clean(m.msg), w), sgrYellow)
	}
	return fit(clean(m.msg), w)
}

// dialogText is the question: what, how many and how big.
func (m *explorerModel) dialogText() string {
	items := m.dialog.items
	size := itemsSizeText(items)
	if len(items) == 1 {
		return fmt.Sprintf(`Move "%s" (%s) to the Recycle Bin?`, clean(items[0].Name), size)
	}
	return fmt.Sprintf("Move %d entries (%s) to the Recycle Bin?", len(items), size)
}

func (m *explorerModel) footerLine(w int) string {
	var keys string
	switch {
	case m.mode == modeConfirm:
		keys = "Enter move   Esc cancel   Ctrl+C quit"
	case m.mode == modeMoving || m.mode == modeChecking:
		keys = "Q quit"
	case m.kind == viewOverview:
		keys = "Up/Down move   Enter open   R rescan   Esc quit"
	case m.kind == viewFiles:
		keys = "Space mark   Del recycle   T folders   R rescan   Esc back   Q quit"
	case m.err != nil:
		keys = "R rescan   Esc back   Q quit"
	default:
		keys = "Enter open   Space mark   Del recycle   T largest files   R rescan   Esc back   Q quit"
	}
	return m.paint(fit(keys, w), sgrDim)
}

// ---------------------------------------------------------------------------
// List

// scrollTop returns the first visible line so that the cursor is visible.
func scrollTop(c *cursorState, total, n int) int {
	if n <= 0 {
		return 0
	}
	top := c.top
	if c.idx < top {
		top = c.idx
	}
	if c.idx >= top+n {
		top = c.idx - n + 1
	}
	if last := total - n; top > last {
		top = last
	}
	if top < 0 {
		top = 0
	}
	return top
}

func (m *explorerModel) listLines(w, n int) []string {
	if n <= 0 {
		return nil
	}
	var lines []string
	rows := m.rowCache
	switch {
	case m.err != nil:
		text := "Cannot read this folder: " + clean(m.err.Error())
		for _, l := range strings.Split(ansi.Wrap(text, w, ""), "\n") {
			lines = append(lines, m.paint(fit(l, w), sgrRed))
		}
		if len(lines) > n {
			lines = lines[:n]
		}
	case len(rows) == 0:
		lines = append(lines, m.emptyHint(w))
	default:
		c := m.c()
		c.top = scrollTop(c, len(rows), n)
		end := c.top + n
		if end > len(rows) {
			end = len(rows)
		}
		visible := rows[c.top:end]
		switch m.kind {
		case viewOverview:
			lines = m.overviewLines(w, visible, c.idx-c.top)
		case viewFiles:
			lines = m.fileLines(w, visible, c.top, c.idx-c.top)
		default:
			lines = m.folderLines(w, rows, visible, c.idx-c.top)
		}
	}
	for len(lines) < n {
		lines = append(lines, "")
	}
	return lines
}

func (m *explorerModel) emptyHint(w int) string {
	switch {
	case m.kind == viewFiles && m.listing == nil:
		return fit("Measuring...", w)
	case m.kind == viewFiles:
		return fit("No files of "+FormatSize(topFileMinimum)+" or more.", w)
	case m.kind == viewFolder && m.done:
		return fit("(empty folder)", w)
	}
	return ""
}

func (m *explorerModel) isMarked(path string) bool { return m.marks[pathKey(path)] }

// prefix is the cursor and mark column: ">" for the cursor, "*" for a mark.
func prefix(cursor, marked bool) string {
	p := []byte("   ")
	if cursor {
		p[0] = '>'
	}
	if marked {
		p[1] = '*'
	}
	return string(p)
}

// style applies the look of a row to a finished line of exactly the window
// width.
func (m *explorerModel) style(line string, cursor, marked, pending bool) string {
	switch {
	case cursor:
		return m.paint(line, sgrReverse)
	case marked:
		return m.paint(line, sgrYellow)
	case pending:
		return m.paint(line, sgrDim)
	}
	return line
}

func sizeText(r listRow) string {
	switch {
	case r.pending:
		return "scanning"
	case r.item.IsLink:
		return "-"
	case !r.item.measured():
		return "not measured"
	case r.item.State == Partial:
		return FormatSize(r.item.Size) + "+"
	}
	return FormatSize(r.item.Size)
}

func flagText(it Item) string {
	switch {
	case it.IsLink:
		return "[link]"
	case it.Cloud && it.OnlineSize > 0:
		return "[cloud " + FormatSize(it.OnlineSize) + " online]"
	case it.Cloud:
		return "[cloud]"
	}
	return ""
}

const (
	sizeColW  = 12
	pctColW   = 6
	barColW   = 12
	flagMaxW  = 24
	driveInfo = 26
)

// folderPercents returns the share of every row, or none: a share is only
// shown when the whole list is measured completely and nothing is still
// running, since otherwise it would look like a result.
func (m *explorerModel) folderPercents(rows []listRow) (show bool, total int64) {
	if !m.done || m.err != nil || m.listing == nil {
		return false, 0
	}
	for _, r := range rows {
		if r.pending || r.item.State != Complete {
			return false, 0
		}
		total += r.item.Size
	}
	return total > 0, total
}

func bar(pct float64) string {
	n := int(pct/10 + 0.5)
	if n > 10 {
		n = 10
	}
	if n < 0 {
		n = 0
	}
	return "[" + strings.Repeat("#", n) + strings.Repeat(" ", 10-n) + "]"
}

func (m *explorerModel) folderLines(w int, all, visible []listRow, cursor int) []string {
	showPct, total := m.folderPercents(all)
	flagsW := 0
	for _, r := range visible {
		if f := ansi.StringWidth(flagText(r.item)); f > flagsW {
			flagsW = f
		}
	}
	if flagsW > flagMaxW {
		flagsW = flagMaxW
	}
	showBar := showPct && w >= 64
	nameW := func() int {
		n := w - 3 - 1 - sizeColW
		if showPct {
			n -= 1 + pctColW
		}
		if showBar {
			n -= 1 + barColW
		}
		if flagsW > 0 {
			n -= 1 + flagsW
		}
		return n
	}
	for nameW() < 12 && (showBar || flagsW > 0 || showPct) {
		switch {
		case showBar:
			showBar = false
		case flagsW > 0:
			flagsW = 0
		default:
			showPct = false
		}
	}
	nw := nameW()
	if nw < 4 {
		nw = 4
	}
	lines := make([]string, len(visible))
	for i, r := range visible {
		name := clean(r.item.Name)
		if r.item.IsDir {
			name += `\`
		}
		marked := m.isMarked(r.path())
		line := prefix(i == cursor, marked) + padRight(fit(name, nw), nw) + " " + padLeft(sizeText(r), sizeColW)
		if showPct {
			pct, b := "", ""
			if !r.pending {
				v := float64(r.item.Size) * 100 / float64(total)
				pct, b = FormatPercent(v), bar(v)
			}
			line += " " + padLeft(pct, pctColW)
			if showBar {
				line += " " + padRight(b, barColW)
			}
		}
		if flagsW > 0 {
			line += " " + fit(flagText(r.item), flagsW)
		}
		line = padRight(fit(line, w), w)
		lines[i] = m.style(line, i == cursor, marked, r.pending)
	}
	return lines
}

func (m *explorerModel) fileLines(w int, visible []listRow, top, cursor int) []string {
	lines := make([]string, len(visible))
	pathW := w - 3 - 3 - 1 - 9 - 1
	for i, r := range visible {
		marked := m.isMarked(r.path())
		line := prefix(i == cursor, marked) + fmt.Sprintf("%2d.", top+i+1) + " " + padLeft(FormatSize(r.item.Size), 9) + " " + fitLeft(clean(r.item.Path), pathW)
		line = padRight(fit(line, w), w)
		lines[i] = m.style(line, i == cursor, marked, false)
	}
	return lines
}

func (m *explorerModel) overviewLines(w int, visible []listRow, cursor int) []string {
	showPct := m.ov.final()
	for _, r := range m.rowCache {
		if r.pending || r.item.State != Complete {
			showPct = false
		}
	}
	showInfo := w >= 80
	nameW := func() int {
		n := w - 3 - 1 - sizeColW
		if showPct {
			n -= 1 + pctColW
		}
		if showInfo {
			n -= 1 + driveInfo
		}
		return n
	}
	if nameW() < 16 {
		showInfo = false
	}
	if nameW() < 16 {
		showPct = false
	}
	nw := nameW()
	if nw < 4 {
		nw = 4
	}
	lines := make([]string, len(visible))
	for i, r := range visible {
		var name, info, pct string
		if r.drive != nil {
			name = r.item.Path
			if r.drive.Label != "" {
				name += "  " + r.drive.Label
			}
			if r.item.State == Complete {
				info = FormatSize(r.drive.Total) + " total, " + FormatSize(r.drive.Free) + " free"
				pct = FormatPercent(float64(r.item.Size) * 100 / float64(r.drive.Total))
			}
		} else {
			name = "Home  " + r.item.Path
			info = flagText(r.item)
		}
		line := prefix(i == cursor, false) + padRight(fit(clean(name), nw), nw) + " " + padLeft(sizeText(r), sizeColW)
		if showPct {
			line += " " + padLeft(pct, pctColW)
		}
		if showInfo {
			line += " " + fit(info, driveInfo)
		}
		line = padRight(fit(line, w), w)
		lines[i] = m.style(line, i == cursor, false, r.pending)
	}
	return lines
}
