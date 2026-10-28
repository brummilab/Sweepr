package main

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// The explorer is the interactive display. Everything that can take time (a
// measurement, the check before a question, the moves) runs in a command, and
// the model only receives results. A result is taken over only when it belongs
// to the current request: every request has an identity of its own, so a late
// result of an older request for the very same folder is dropped.

type viewKind int

const (
	viewOverview viewKind = iota
	viewFolder
	viewFiles
)

type uiMode int

const (
	modeBrowse uiMode = iota
	modeChecking
	modeConfirm
	modeMoving
)

const (
	tickInterval = 150 * time.Millisecond
	// checkGrace is how long a key press waits for the check before a
	// question: a small folder is judged at once, a big one in the background.
	checkGrace = 50 * time.Millisecond
)

// listRow is one row of the current list.
type listRow struct {
	item    Item
	pending bool   // a folder whose measurement has not finished
	drive   *Drive // set for a drive row of the overview
}

func (r listRow) path() string { return r.item.Path }

// cursorState is the position in one list. The cursor follows its path, not
// its line number, when rows arrive, are sorted or are removed.
type cursorState struct {
	idx      int
	path     string   // empty until the user or an action has chosen a row
	fallback []string // rows to move to when path is gone, best first
	top      int      // first visible line
}

// overviewState is the data of the overview.
type overviewState struct {
	loaded   bool
	drives   []Drive
	home     string // empty when there is no profile folder
	homeItem Item
	homeDone bool
}

func (o overviewState) final() bool { return o.loaded && (o.home == "" || o.homeDone) }

// snapshot is an earlier folder view, kept for "back".
type snapshot struct {
	kind       viewKind
	root       string
	finished   []Item
	listing    *Listing
	ov         overviewState
	complete   bool
	stale      bool
	cursorPath string
}

type request struct {
	id       int
	ctx      context.Context
	cancel   context.CancelFunc
	counters *Counters
	ch       <-chan ScanEvent
}

type dialogState struct {
	items []Item
}

type explorerModel struct {
	deps    Deps
	env     map[string]string
	noColor bool
	target  string

	width, height int

	kind viewKind
	mode uiMode
	root string

	nextID int
	req    request

	finished   []Item
	pendingAll []Item
	pendingSet map[string]bool
	listing    *Listing
	err        error
	done       bool // the measurement of the folder view has ended
	ov         overviewState

	fc, xc  cursorState // folder/overview list and largest-files list
	marks   map[string]bool
	history []snapshot

	msg     string
	msgWarn bool

	dialog   dialogState
	opID     int
	opCancel context.CancelFunc
	opLog    *OpLog

	// runMu guards the state that the goroutines of the moves share with the
	// goroutine that waits for them when the program ends.
	runMu    sync.Mutex
	runCond  *sync.Cond
	running  int  // moves whose Recycle Bin work has started
	quitting bool // no move may start any more

	rowCache []listRow
	dirty    bool
}

// newExplorerModel creates the display for a folder, or for the overview when
// target is empty. The measurement starts with Init.
func newExplorerModel(d Deps, env map[string]string, target string) tea.Model {
	if d.Clock == nil {
		d.Clock = systemClock{}
	}
	m := &explorerModel{
		deps:    d,
		env:     env,
		noColor: env["NO_COLOR"] != "",
		target:  target,
		kind:    viewFolder,
		dirty:   true,
	}
	m.runCond = sync.NewCond(&m.runMu)
	return m
}

type (
	scanMsg struct {
		id int
		ev ScanEvent
		ok bool
	}
	tickMsg     struct{ id int }
	overviewMsg struct {
		id     int
		drives []Drive
		home   string
	}
	checkMsg struct {
		id      int
		ref     *Refusal
		item    Item
		targets []Item
	}
	moveMsg struct {
		id      int
		items   []Item
		results []Result
	}
)

func (m *explorerModel) scanner() Scanner {
	if m.deps.Scanner != nil {
		return m.deps.Scanner
	}
	return fsScanner{fs: m.deps.FS}
}

func (m *explorerModel) Init() tea.Cmd {
	if m.target == "" {
		return m.startOverview()
	}
	m.kind = viewFolder
	m.root = m.target
	return m.startFolderScan(m.target)
}

// ---------------------------------------------------------------------------
// Requests

// invalidate gives the model a new request identity, so that nothing of an
// older request is taken over any more, and cancels what it was doing.
func (m *explorerModel) invalidate() {
	if m.req.cancel != nil {
		m.req.cancel()
	}
	m.nextID++
	m.req = request{id: m.nextID}
}

// releaseOperation frees the context of a finished check or move.
func (m *explorerModel) releaseOperation() {
	if m.opCancel != nil {
		m.opCancel()
		m.opCancel = nil
	}
}

func (m *explorerModel) cancelOperation() {
	if m.opCancel != nil {
		m.opCancel()
		m.opCancel = nil
	}
	m.nextID++
	m.opID = m.nextID
}

func (m *explorerModel) beginRequest() request {
	m.invalidate()
	ctx, cancel := context.WithCancel(context.Background())
	m.req.ctx, m.req.cancel, m.req.counters = ctx, cancel, &Counters{}
	return m.req
}

func (m *explorerModel) measuring() bool {
	return m.kind != viewOverview && !m.done
}

// startFolderScan measures the root of the folder view in the background.
func (m *explorerModel) startFolderScan(path string) tea.Cmd {
	req := m.beginRequest()
	m.finished, m.pendingAll, m.pendingSet = nil, nil, nil
	m.listing, m.err, m.done = nil, nil, false
	m.dirty = true
	ch := m.scanner().Scan(req.ctx, path, req.counters)
	m.req.ch = ch
	return tea.Batch(waitScan(req.id, req.ctx, ch), tickAfter(req.id))
}

func waitScan(id int, ctx context.Context, ch <-chan ScanEvent) tea.Cmd {
	return func() tea.Msg {
		select {
		case ev, ok := <-ch:
			return scanMsg{id: id, ev: ev, ok: ok}
		case <-ctx.Done():
			return nil
		}
	}
}

func tickAfter(id int) tea.Cmd {
	return tea.Tick(tickInterval, func(time.Time) tea.Msg { return tickMsg{id: id} })
}

// startOverview reads the drives and measures the profile folder.
func (m *explorerModel) startOverview() tea.Cmd {
	m.beginRequest()
	id := m.req.id
	m.kind = viewOverview
	m.ov = overviewState{}
	m.finished, m.pendingAll, m.pendingSet = nil, nil, nil
	m.listing, m.err, m.done = nil, nil, false
	m.marks = nil
	m.dirty = true
	fsys, env := m.deps.FS, m.env
	return func() tea.Msg {
		drives := sortedDrives(fsys)
		home, _ := homeFolder(env, fsys)
		return overviewMsg{id: id, drives: drives, home: home}
	}
}

// ---------------------------------------------------------------------------
// Update

func (m *explorerModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.dirty = true
	case tea.KeyMsg:
		return m, m.onKey(msg)
	case scanMsg:
		if msg.id == m.req.id {
			return m, m.onScan(msg)
		}
	case overviewMsg:
		if msg.id == m.req.id && m.kind == viewOverview {
			return m, m.onOverview(msg)
		}
	case tickMsg:
		if msg.id == m.req.id && m.measuring() {
			return m, tickAfter(msg.id)
		}
	case checkMsg:
		return m, m.onCheck(msg)
	case moveMsg:
		return m, m.onMove(msg)
	}
	return m, nil
}

func (m *explorerModel) onOverview(msg overviewMsg) tea.Cmd {
	m.ov.loaded = true
	m.ov.drives = msg.drives
	m.ov.home = msg.home
	m.dirty = true
	if msg.home == "" {
		return nil
	}
	m.req.ch = m.scanner().Scan(m.req.ctx, msg.home, m.req.counters)
	return waitScan(m.req.id, m.req.ctx, m.req.ch)
}

func (m *explorerModel) onScan(msg scanMsg) tea.Cmd {
	next := waitScan(m.req.id, m.req.ctx, m.req.ch)
	if m.kind == viewOverview {
		return m.onHomeScan(msg, next)
	}
	m.dirty = true
	if !msg.ok {
		if !m.done {
			m.fail(fmt.Errorf("the measurement ended without a result"))
		}
		return nil
	}
	ev := msg.ev
	switch {
	case ev.Err != nil:
		m.fail(ev.Err)
		return nil
	case ev.Listing != nil:
		l := *ev.Listing
		m.listing = &l
		m.finished = append([]Item(nil), l.Items...)
		m.pendingAll, m.pendingSet = nil, nil
		m.done = true
		return nil
	}
	if len(ev.Ready) > 0 || len(ev.Pending) > 0 {
		m.finished = append(m.finished, ev.Ready...)
		m.pendingAll = append([]Item(nil), ev.Pending...)
		m.pendingSet = make(map[string]bool, len(ev.Pending))
		for _, p := range ev.Pending {
			m.pendingSet[pathKey(p.Path)] = true
		}
	}
	if ev.Item != nil {
		delete(m.pendingSet, pathKey(ev.Item.Path))
		m.finished = append(m.finished, *ev.Item)
	}
	return next
}

func (m *explorerModel) fail(err error) {
	m.err = err
	m.done = true
	m.finished, m.pendingAll, m.pendingSet, m.listing = nil, nil, nil, nil
	m.dirty = true
}

func (m *explorerModel) onHomeScan(msg scanMsg, next tea.Cmd) tea.Cmd {
	m.dirty = true
	if !msg.ok {
		if !m.ov.homeDone {
			m.ov.homeDone = true
			m.ov.homeItem = homeItem(m.ov.home, nil, fmt.Errorf("the measurement ended without a result"))
		}
		return nil
	}
	switch {
	case msg.ev.Err != nil:
		m.ov.homeDone = true
		m.ov.homeItem = homeItem(m.ov.home, nil, msg.ev.Err)
		return nil
	case msg.ev.Listing != nil:
		m.ov.homeDone = true
		m.ov.homeItem = homeItem(m.ov.home, msg.ev.Listing, nil)
		return nil
	}
	return next
}

func pathKey(p string) string { return strings.ToLower(p) }

// ---------------------------------------------------------------------------
// Rows and cursor

func (m *explorerModel) c() *cursorState {
	if m.kind == viewFiles {
		return &m.xc
	}
	return &m.fc
}

// buildRows makes the rows of the current list. Finished children come in the
// order they arrived (the listing's own order once the measurement is done),
// the ones still being measured follow.
func (m *explorerModel) buildRows() []listRow {
	switch m.kind {
	case viewOverview:
		var rows []listRow
		if m.ov.home != "" {
			if m.ov.homeDone {
				rows = append(rows, listRow{item: m.ov.homeItem})
			} else {
				rows = append(rows, listRow{item: Item{Name: "Home", Path: m.ov.home, IsDir: true}, pending: true})
			}
		}
		for i := range m.ov.drives {
			d := m.ov.drives[i]
			rows = append(rows, listRow{item: driveItem(d), drive: &d})
		}
		return rows
	case viewFiles:
		if m.listing == nil {
			return nil
		}
		rows := make([]listRow, len(m.listing.TopFiles))
		for i, f := range m.listing.TopFiles {
			rows[i] = listRow{item: Item{Name: f.Name, Path: f.Path, Size: f.Size, State: Complete}}
		}
		return rows
	}
	rows := make([]listRow, 0, len(m.finished)+len(m.pendingSet))
	for _, it := range m.finished {
		rows = append(rows, listRow{item: it})
	}
	for _, p := range m.pendingAll {
		if m.pendingSet[pathKey(p.Path)] {
			rows = append(rows, listRow{item: p, pending: true})
		}
	}
	return rows
}

// listFinal tells whether the current list can no longer change by itself.
func (m *explorerModel) listFinal() bool {
	if m.kind == viewOverview {
		return m.ov.final()
	}
	return m.done
}

// ensure rebuilds the rows when something changed and puts the cursor on the
// right row. It runs before the display is drawn and before a key is handled,
// not once per arriving child, so a big folder costs one rebuild per frame.
func (m *explorerModel) ensure() {
	if !m.dirty {
		return
	}
	m.dirty = false
	m.rowCache = m.buildRows()
	m.settleCursor(m.c(), m.rowCache, m.listFinal())
}

func indexOfPath(rows []listRow, path string) int {
	key := pathKey(path)
	for i, r := range rows {
		if pathKey(r.path()) == key {
			return i
		}
	}
	return -1
}

// settleCursor keeps the cursor on its path. While the list can still change
// a missing path only holds the position; once the list is final the
// fallbacks are tried in order and the result is kept.
func (m *explorerModel) settleCursor(c *cursorState, rows []listRow, final bool) {
	n := len(rows)
	if n == 0 {
		c.idx = 0
		return
	}
	clamp := func() {
		if c.idx >= n {
			c.idx = n - 1
		}
		if c.idx < 0 {
			c.idx = 0
		}
	}
	if c.path == "" {
		clamp()
		return
	}
	if i := indexOfPath(rows, c.path); i >= 0 {
		c.idx = i
		c.fallback = nil
		return
	}
	if !final {
		clamp()
		return
	}
	for _, p := range c.fallback {
		if i := indexOfPath(rows, p); i >= 0 {
			c.idx, c.path = i, rows[i].path()
			c.fallback = nil
			return
		}
	}
	clamp()
	c.path = rows[c.idx].path()
	c.fallback = nil
}

func (m *explorerModel) setCursor(i int) {
	rows := m.rowCache
	if len(rows) == 0 {
		return
	}
	c := m.c()
	if i < 0 {
		i = 0
	}
	if i >= len(rows) {
		i = len(rows) - 1
	}
	c.idx, c.path, c.fallback = i, rows[i].path(), nil
}

func (m *explorerModel) windowSize() (w, h int) {
	w, h = m.width, m.height
	if w <= 0 {
		w = 80
	}
	if h <= 0 {
		h = 24
	}
	return w, h
}

// pageSize is how many list lines the display shows, so PgUp and PgDn move by
// exactly one screenful.
func (m *explorerModel) pageSize() int {
	_, h := m.windowSize()
	_, listN := layoutHeights(h)
	if listN < 1 {
		return 1
	}
	return listN
}

// ---------------------------------------------------------------------------
// Keys

func keyName(k tea.KeyMsg) string {
	if k.Alt {
		return ""
	}
	switch k.Type {
	case tea.KeyRunes:
		if len(k.Runes) != 1 {
			return ""
		}
		if k.Runes[0] == ' ' {
			return "space"
		}
		return strings.ToLower(string(k.Runes))
	case tea.KeySpace:
		return "space"
	case tea.KeyCtrlC:
		return "ctrl+c"
	case tea.KeyEnter:
		return "enter"
	case tea.KeyEsc:
		return "esc"
	case tea.KeyBackspace:
		return "backspace"
	case tea.KeyDelete:
		return "delete"
	case tea.KeyUp:
		return "up"
	case tea.KeyDown:
		return "down"
	case tea.KeyLeft:
		return "left"
	case tea.KeyRight:
		return "right"
	case tea.KeyPgUp:
		return "pgup"
	case tea.KeyPgDown:
		return "pgdown"
	case tea.KeyHome:
		return "home"
	case tea.KeyEnd:
		return "end"
	}
	return ""
}

func (m *explorerModel) quit() tea.Cmd {
	m.runMu.Lock()
	m.quitting = true
	m.runMu.Unlock()
	m.invalidate()
	m.cancelOperation()
	return tea.Quit
}

func (m *explorerModel) say(text string, warn bool) {
	m.msg, m.msgWarn = text, warn
}

func (m *explorerModel) onKey(k tea.KeyMsg) tea.Cmd {
	key := keyName(k)
	if key == "ctrl+c" {
		return m.quit()
	}
	switch m.mode {
	case modeConfirm:
		switch key {
		case "enter":
			return m.confirm()
		case "esc", "q":
			m.mode = modeBrowse
			m.dialog = dialogState{}
			m.releaseOperation()
			m.say("Canceled.", false)
		}
		return nil
	case modeChecking:
		switch key {
		case "q":
			return m.quit()
		case "esc":
			m.cancelOperation()
			m.mode = modeBrowse
			m.say("Canceled.", false)
		}
		return nil
	case modeMoving:
		if key == "q" {
			return m.quit()
		}
		return nil
	}
	m.ensure()
	switch key {
	case "q":
		return m.quit()
	case "up":
		m.setCursor(m.c().idx - 1)
	case "down":
		m.setCursor(m.c().idx + 1)
	case "pgup":
		m.setCursor(m.c().idx - m.pageSize())
	case "pgdown":
		m.setCursor(m.c().idx + m.pageSize())
	case "home":
		m.setCursor(0)
	case "end":
		m.setCursor(len(m.rowCache) - 1)
	case "enter", "right":
		return m.enter()
	case "esc":
		if m.kind == viewOverview {
			return m.quit()
		}
		return m.back()
	case "left", "backspace":
		if m.kind != viewOverview {
			return m.back()
		}
	case "space":
		m.toggleMark()
	case "delete":
		return m.beginDelete()
	case "t":
		m.toggleFiles()
	case "r":
		return m.rescan()
	}
	return nil
}

// ---------------------------------------------------------------------------
// Navigation

func (m *explorerModel) enter() tea.Cmd {
	if m.kind == viewFiles || len(m.rowCache) == 0 {
		return nil
	}
	row := m.rowCache[m.c().idx]
	if !row.item.IsDir || row.item.IsLink {
		return nil
	}
	m.setCursor(m.c().idx)
	m.pushSnapshot()
	m.kind = viewFolder
	m.mode = modeBrowse
	m.root = row.item.Path
	m.marks = nil
	m.fc = cursorState{}
	m.say("", false)
	return m.startFolderScan(row.item.Path)
}

func (m *explorerModel) pushSnapshot() {
	s := snapshot{kind: m.kind, root: m.root, cursorPath: m.fc.path}
	if m.kind == viewOverview {
		s.ov = m.ov
		s.complete = m.ov.final()
	} else {
		s.finished = m.finished
		s.listing = m.listing
		s.complete = m.done && m.err == nil
	}
	m.history = append(m.history, s)
}

// back returns to the earlier view: the largest-files list to its folder, a
// folder to the one it was entered from, and the first folder to the
// overview. A kept view is restored as it was, without measuring again; one
// that was incomplete or expired is measured anew.
func (m *explorerModel) back() tea.Cmd {
	m.marks = nil
	m.say("", false)
	if m.kind == viewFiles {
		m.kind = viewFolder
		m.dirty = true
		return nil
	}
	m.invalidate()
	if n := len(m.history); n > 0 {
		s := m.history[n-1]
		m.history = m.history[:n-1]
		if s.kind == viewOverview {
			if s.complete && !s.stale {
				m.kind, m.ov, m.fc = viewOverview, s.ov, cursorState{path: s.cursorPath}
				m.dirty = true
				return nil
			}
			cmd := m.startOverview()
			m.fc = cursorState{path: s.cursorPath}
			return cmd
		}
		m.kind, m.root = viewFolder, s.root
		m.fc = cursorState{path: s.cursorPath}
		if s.complete && !s.stale {
			m.finished, m.listing, m.err, m.done = s.finished, s.listing, nil, true
			m.pendingAll, m.pendingSet = nil, nil
			m.dirty = true
			return nil
		}
		return m.startFolderScan(s.root)
	}
	return m.startOverview()
}

// expireSnapshots marks every kept view as outdated: after something was
// moved, no earlier list may be shown as it was.
func (m *explorerModel) expireSnapshots() {
	for i := range m.history {
		m.history[i].stale = true
	}
}

func (m *explorerModel) rescan() tea.Cmd {
	m.marks = nil
	m.say("", false)
	if m.kind == viewOverview {
		return m.startOverview()
	}
	keep := m.history[:0]
	for _, s := range m.history {
		if s.kind == viewFolder && pathKey(s.root) == pathKey(m.root) {
			continue
		}
		keep = append(keep, s)
	}
	m.history = keep
	return m.startFolderScan(m.root)
}

func (m *explorerModel) toggleFiles() {
	switch {
	case m.kind == viewOverview:
	case m.kind == viewFiles:
		m.kind = viewFolder
		m.marks = nil
		m.say("", false)
		m.dirty = true
	case m.measuring():
		m.say("The largest files are available when the measurement is done.", true)
	case m.err == nil && m.listing != nil:
		m.kind = viewFiles
		m.marks = nil
		m.xc = cursorState{}
		m.say("", false)
		m.dirty = true
	}
}

// ---------------------------------------------------------------------------
// Marks

func (m *explorerModel) toggleMark() {
	if m.kind == viewOverview || len(m.rowCache) == 0 {
		return
	}
	if m.measuring() {
		m.say("Marking is available when the measurement is done.", true)
		return
	}
	m.setCursor(m.c().idx)
	row := m.rowCache[m.c().idx]
	if row.item.State == Unavailable {
		m.say(row.item.Name+" could not be read and cannot be marked.", true)
		return
	}
	if m.marks == nil {
		m.marks = map[string]bool{}
	}
	key := pathKey(row.path())
	if m.marks[key] {
		delete(m.marks, key)
	} else {
		m.marks[key] = true
	}
	items := m.markedItems()
	if len(items) == 0 {
		m.say("Nothing marked.", false)
		return
	}
	m.say(fmt.Sprintf("%d marked, %s", len(items), itemsSizeText(items)), false)
}

// markedItems lists the marked rows in the order of the list.
func (m *explorerModel) markedItems() []Item {
	var out []Item
	for _, r := range m.rowCache {
		if m.marks[pathKey(r.path())] {
			out = append(out, r.item)
		}
	}
	return out
}

// itemsSizeText is the sum of the sizes that were measured. A plus says that
// not every entry was measured completely; when no entry has a measured size
// there is no sum to show, and the text says so instead of a number.
func itemsSizeText(items []Item) string {
	var sum int64
	known, plus := false, false
	for _, it := range items {
		if it.measured() {
			sum += it.Size
			known = true
		}
		if it.State != Complete {
			plus = true
		}
	}
	if !known {
		return "not measured"
	}
	if plus {
		return FormatSize(sum) + "+"
	}
	return FormatSize(sum)
}

// ---------------------------------------------------------------------------
// Moving to the Recycle Bin

func (m *explorerModel) targets() []Item {
	if items := m.markedItems(); len(items) > 0 {
		return items
	}
	if len(m.rowCache) == 0 {
		return nil
	}
	return []Item{m.rowCache[m.c().idx].item}
}

// beginDelete starts the question: every target is checked first, and only if
// all pass is the dialog shown. Nothing is moved before Enter in the dialog.
func (m *explorerModel) beginDelete() tea.Cmd {
	if m.kind == viewOverview {
		return nil
	}
	if m.measuring() {
		m.say("Moving is available when the measurement is done.", true)
		return nil
	}
	targets := m.targets()
	if len(targets) == 0 || m.err != nil {
		return nil
	}
	m.cancelOperation()
	ctx, cancel := context.WithCancel(context.Background())
	m.opCancel = cancel
	id := m.opID
	deps, env, root := m.deps, m.env, m.root

	done := make(chan checkMsg, 1)
	go func() {
		for _, it := range targets {
			if ref := Review(ctx, deps.FS, deps.Clock, env, root, it.Path, it); ref != nil {
				done <- checkMsg{id: id, ref: ref, item: it, targets: targets}
				return
			}
		}
		done <- checkMsg{id: id, targets: targets}
	}()
	select {
	case r := <-done:
		return m.onCheck(r)
	case <-time.After(checkGrace):
		m.mode = modeChecking
		m.say("Checking what would be moved...", false)
		return func() tea.Msg {
			select {
			case r := <-done:
				return r
			case <-ctx.Done():
				return nil
			}
		}
	}
}

func (m *explorerModel) onCheck(r checkMsg) tea.Cmd {
	if r.id != m.opID {
		return nil
	}
	m.mode = modeBrowse
	if r.ref != nil {
		m.releaseOperation()
		m.say("Nothing moved. "+r.ref.Text, true)
		return nil
	}
	m.dialog = dialogState{items: r.targets}
	m.mode = modeConfirm
	return nil
}

func (m *explorerModel) log() *OpLog {
	if m.opLog == nil {
		m.opLog = NewOpLog(m.env, m.deps.Clock, nil)
	}
	return m.opLog
}

func plural(n int, one, many string) string {
	if n == 1 {
		return one
	}
	return many
}

func (m *explorerModel) confirm() tea.Cmd {
	m.ensure()
	items := m.dialog.items
	m.dialog = dialogState{}
	m.mode = modeBrowse
	if dryRun(m.env) {
		m.marks = nil
		m.say(fmt.Sprintf("Dry run: %d %s would be moved to the Recycle Bin. Nothing was changed.",
			len(items), plural(len(items), "entry", "entries")), false)
		return nil
	}
	if m.deps.Recycler == nil {
		m.say("The Recycle Bin is not available.", true)
		return nil
	}

	// Remember where the cursor goes when its row is gone: the next row, then
	// the ones before it.
	c := m.c()
	if len(m.rowCache) > 0 {
		c.path = m.rowCache[c.idx].path()
		c.fallback = nil
		for i := c.idx + 1; i < len(m.rowCache); i++ {
			c.fallback = append(c.fallback, m.rowCache[i].path())
		}
		for i := c.idx - 1; i >= 0; i-- {
			c.fallback = append(c.fallback, m.rowCache[i].path())
		}
	}

	m.cancelOperation()
	ctx, cancel := context.WithCancel(context.Background())
	m.opCancel = cancel
	id := m.opID
	m.mode = modeMoving
	m.say("Moving to the Recycle Bin... (only Q and Ctrl+C work meanwhile)", false)
	deps, env, root, log := m.deps, m.env, m.root, m.log()
	return func() tea.Msg {
		m.runMu.Lock()
		if m.quitting {
			m.runMu.Unlock()
			return nil // the program is ending: nothing may start now
		}
		m.running++
		m.runMu.Unlock()
		defer func() {
			m.runMu.Lock()
			m.running--
			m.runCond.Broadcast()
			m.runMu.Unlock()
		}()
		return moveMsg{id: id, items: items, results: RecycleItems(ctx, deps, env, root, items, log)}
	}
}

func (m *explorerModel) onMove(r moveMsg) tea.Cmd {
	if r.id != m.opID {
		return nil
	}
	m.mode = modeBrowse
	m.marks = nil
	m.releaseOperation()
	var moved, skipped, failed, gone int
	first := ""
	for _, res := range r.results {
		switch res.Outcome {
		case Recycled:
			moved++
		case Skipped:
			skipped++
		case Failed:
			failed++
		case Gone:
			gone++
		}
		if first == "" && (res.Outcome == Skipped || res.Outcome == Failed) {
			first = res.Reason
		}
	}
	text := fmt.Sprintf("Moved %d, refused %d, failed %d, already gone %d.", moved, skipped, failed, gone)
	if first != "" {
		text += " " + first
	}
	m.say(text, skipped+failed > 0)
	if moved+gone == 0 {
		m.c().fallback = nil
		return nil
	}
	m.expireSnapshots()
	return m.startFolderScan(m.root)
}

// waitIdle blocks until the moves that have started have returned. A call to
// the Recycle Bin that has begun cannot be taken back, so the program waits for
// it instead of ending in the middle; the entries after it are not started
// once the program is quitting, and nothing is logged for an interrupted run.
func (m *explorerModel) waitIdle() {
	m.runMu.Lock()
	defer m.runMu.Unlock()
	for m.running > 0 {
		m.runCond.Wait()
	}
}
