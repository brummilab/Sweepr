package main

// Fixtures shared by the disk explorer tests.
//
// Everything that depends on the exact shape of the production seams is
// concentrated in this file (the tst* adapter functions, the fake file system,
// clock, recycler and scanner). The tests assume this production surface; the
// names are fixed, the parameter lists and field names were chosen here:
//
//	type Reparse int                          // ReparseNone, ReparseLink, ReparseCloud
//	type FSEntry struct { Name string; IsDir bool; Reparse Reparse; Size int64; Online bool }
//	type FileID struct { Volume, Index uint64; Reparse Reparse; IsDir bool }
//	type Drive struct { Root, Label string; Total, Free int64; Err error }
//	type FS interface {
//		ReadDir(path string) ([]FSEntry, error)  // error per directory; missing path: errors.Is(err, fs.ErrNotExist)
//		Resolve(path string) (string, error)     // final path of an existing path (junctions, 8.3 names, aliases)
//		Identity(path string) (FileID, error)    // own identity, a final link is not followed; missing: ErrNotExist
//		Drives() []Drive                         // fixed drives only, any order
//	}
//	type Clock interface { Now() time.Time; Sleep(d time.Duration) }
//	type State ...                            // Complete, Partial, Unavailable; fmt.Sprint gives "complete" etc.
//	type Item struct { Name, Path string; IsDir, IsLink bool; Size, OnlineSize int64; Cloud bool; State State }
//	type FileItem struct { Name, Path string; Size int64 }
//	type Listing struct { Root string; Items []Item; TopFiles []FileItem; TotalSize, TotalOnlineSize, TotalFiles int64; State State }
//	type Counters struct{ ... }               // zero value usable; Files(), Dirs(), Bytes() int64
//	func Measure(ctx context.Context, fs FS, root string, c *Counters, onChild func(Item)) (Listing, error)
//	type ScanEvent struct { Item *Item; Listing *Listing; Err error }   // one finished child, or the final event
//	type Scanner interface { Scan(ctx context.Context, root string, c *Counters) <-chan ScanEvent }
//	type Refusal struct { Code, Text string }  // *Refusal implements error
//	func IsProtected(path string, env map[string]string, fs FS) bool
//	func Review(ctx context.Context, fs FS, clock Clock, env map[string]string, root, path string, item Item) *Refusal
//	type Recycler interface { Recycle(path string) error }
//	type Outcome int                          // Recycled, Skipped, Failed, Gone
//	type Result struct { Outcome Outcome; Reason string }
//	func RecycleItems(ctx context.Context, deps Deps, env map[string]string, root string, items []Item, log *OpLog) []Result
//	func NewOpLog(env map[string]string, clock Clock, appendFn func(path string, data []byte) error) *OpLog
//	func (*OpLog) Record(action, path, detail string)
//	func FormatRecord(t time.Time, label, action, path, detail string) string
//	func FormatSize(n int64) string
//	func FormatPercent(p float64) string      // p in percent units: 12.3 means 12.3 %
//	type Deps struct { FS FS; Recycler Recycler; Clock Clock; Scanner Scanner; StartUI func(tea.Model) error }
//	func Run(args []string, env map[string]string, stdout, stderr io.Writer, stdoutIsTerminal bool, d Deps) int
//	func newExplorerModel(d Deps, env map[string]string, target string) tea.Model   // target "": overview
//
// Assumed behaviour:
//   - paths are Windows paths on every host: the logic splits on backslash and
//     slash itself and does not use path/filepath for paths of the measured
//     file system (only the log file and the data folder use host paths);
//   - a Deps.Scanner that is nil means the default scanner over Deps.FS;
//   - an OpLog append function reports "access denied" as an error for which
//     errors.Is(err, fs.ErrPermission) holds; every other error is retried;
//   - a nil append function means: append to the real file.
//
// The package must define main(), which exits with the code returned by Run.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode"

	tea "github.com/charmbracelet/bubbletea"
)

const (
	tstKiB = int64(1) << 10
	tstMiB = int64(1) << 20
	tstGiB = int64(1) << 30
	tstTiB = int64(1) << 40
)

var (
	errTstBoom   = errors.New("simulated read failure")
	errTstAccess = fmt.Errorf("open: %w", fs.ErrPermission)
)

// ---------------------------------------------------------------------------
// Artificial clock (local time, so that the expected text does not depend on
// the zone of the test machine)

type fakeClock struct {
	mu     sync.Mutex
	now    time.Time
	sleeps []time.Duration
	frozen bool
}

func newFakeClock() *fakeClock {
	return &fakeClock{now: time.Date(2026, 10, 15, 10, 0, 0, 0, time.Local)}
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

// Sleep records the pause and advances the artificial time without waiting.
func (c *fakeClock) Sleep(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.sleeps = append(c.sleeps, d)
	if d > 0 && !c.frozen {
		c.now = c.now.Add(d)
	}
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

func (c *fakeClock) slept() []time.Duration {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]time.Duration(nil), c.sleeps...)
}

// ---------------------------------------------------------------------------
// Windows-style paths on every host

type tstPath struct {
	root    string // lower-case key, e.g. "c:" or `\\srv\share`
	display string // root text for canonical paths, e.g. `C:\`
	segs    []string
}

func tstSplitSegments(s string) []string {
	var out []string
	for _, seg := range strings.FieldsFunc(s, func(r rune) bool { return r == '\\' || r == '/' }) {
		switch seg {
		case ".":
		case "..":
			if len(out) > 0 {
				out = out[:len(out)-1]
			}
		default:
			out = append(out, seg)
		}
	}
	return out
}

func tstHasPrefixFold(s, prefix string) bool {
	return len(s) >= len(prefix) && strings.EqualFold(s[:len(prefix)], prefix)
}

func tstIsLetter(b byte) bool { return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') }

// tstParse understands X:\..., \\?\X:\..., \\.\X:\..., \??\X:\..., \\host\share\...,
// \\?\UNC\host\share\..., \\localhost\x$\... and \\?\Volume{id}\...
func tstParse(p string) (tstPath, bool) {
	if p == "" || strings.ContainsRune(p, 0) {
		return tstPath{}, false
	}
	rest, verbatim := p, false
	for _, pre := range []string{`\\?\`, `\\.\`, `\??\`} {
		if tstHasPrefixFold(rest, pre) {
			rest, verbatim = rest[len(pre):], true
			break
		}
	}
	unc := func(body string) (tstPath, bool) {
		segs := tstSplitSegments(body)
		if len(segs) < 2 {
			return tstPath{}, false
		}
		host, share := strings.ToLower(segs[0]), strings.ToLower(segs[1])
		if (host == "localhost" || host == "127.0.0.1") && len(share) == 2 && share[1] == '$' && tstIsLetter(share[0]) {
			return tstPath{root: share[:1] + ":", display: strings.ToUpper(share[:1]) + `:\`, segs: segs[2:]}, true
		}
		return tstPath{root: `\\` + host + `\` + share, display: `\\` + segs[0] + `\` + segs[1] + `\`, segs: segs[2:]}, true
	}
	switch {
	case len(rest) >= 2 && tstIsLetter(rest[0]) && rest[1] == ':':
		tail := rest[2:]
		if tail != "" && tail[0] != '\\' && tail[0] != '/' {
			return tstPath{}, false
		}
		return tstPath{root: strings.ToLower(rest[:1]) + ":", display: strings.ToUpper(rest[:1]) + `:\`, segs: tstSplitSegments(tail)}, true
	case verbatim && tstHasPrefixFold(rest, `UNC\`):
		return unc(rest[4:])
	case !verbatim && (strings.HasPrefix(rest, `\\`) || strings.HasPrefix(rest, `//`)):
		return unc(rest)
	case verbatim && (tstHasPrefixFold(rest, "Volume{") || tstHasPrefixFold(rest, "HarddiskVolume")):
		segs := tstSplitSegments(rest)
		return tstPath{root: `\\?\` + strings.ToLower(segs[0]), display: `\\?\` + segs[0] + `\`, segs: segs[1:]}, true
	}
	return tstPath{}, false
}

// tstKey is the comparison form of a path: parsed, cleaned, lower case.
func tstKey(p string) string {
	pp, ok := tstParse(p)
	if !ok {
		return strings.ToLower(p)
	}
	return pp.root + `\` + strings.ToLower(strings.Join(pp.segs, `\`))
}

func tstBase(p string) string {
	pp, ok := tstParse(p)
	if !ok || len(pp.segs) == 0 {
		return p
	}
	return pp.segs[len(pp.segs)-1]
}

func tstParent(p string) string {
	pp, ok := tstParse(p)
	if !ok || len(pp.segs) == 0 {
		return p
	}
	return pp.display + strings.Join(pp.segs[:len(pp.segs)-1], `\`)
}

func tstJoin(dir, name string) string { return strings.TrimRight(dir, `\`) + `\` + name }

// ---------------------------------------------------------------------------
// Artificial file system: a tree in memory with configurable failures,
// reparse kinds, online flags, identities, blocking and a counter of
// simultaneous reads. It has no write function of any kind.

type fakeEdge struct {
	name string
	n    *fakeNode
}

type fakeNode struct {
	name    string
	parent  *fakeNode
	isDir   bool
	size    int64
	reparse Reparse
	online  bool
	edges   []*fakeEdge
	target  *fakeNode // a junction: paths through it continue here
	id      FileID
	readErr error
	idErr   error
	display string // roots only
}

func (n *fakeNode) canon() string {
	var parts []string
	top := n
	for c := n; c.parent != nil; c = c.parent {
		parts = append([]string{c.name}, parts...)
		top = c.parent
	}
	return top.display + strings.Join(parts, `\`)
}

type fakeHold struct {
	ch   chan struct{}
	once bool
	used bool
	n    int
}

type fakeFS struct {
	mu      sync.Mutex
	roots   map[string]*fakeNode
	nextIdx uint64
	nextVol uint64
	drives  []Drive

	reads      map[string]int
	ids        map[string]int
	readLog    []string
	violations []string
	cur, max   int
	delay      time.Duration
	holds      map[string]*fakeHold

	onRead     func(key string, nth int) // before the result is computed; no lock held
	onIdentity func(key string, nth int)

	resolveErr      map[string]error
	noResolve       bool // Resolve returns the typed path (after an existence check)
	verbatimResolve bool // Resolve returns \\?\ spelling
}

func newFakeFS() *fakeFS {
	return &fakeFS{
		roots: map[string]*fakeNode{}, nextIdx: 100, nextVol: 1000,
		reads: map[string]int{}, ids: map[string]int{}, holds: map[string]*fakeHold{},
		resolveErr: map[string]error{},
	}
}

func tstNotExist(p string) error { return &os.PathError{Op: "open", Path: p, Err: fs.ErrNotExist} }

// walk finds the node of a path. Links on the way are followed like the
// operating system does it; traversed tells whether one was crossed.
func (f *fakeFS) walk(p string, followLast bool) (*fakeNode, bool, error) {
	pp, ok := tstParse(p)
	if !ok {
		return nil, false, &os.PathError{Op: "open", Path: p, Err: errors.New("invalid path")}
	}
	cur := f.roots[pp.root]
	if cur == nil {
		return nil, false, tstNotExist(p)
	}
	traversed := false
	for _, seg := range pp.segs {
		if cur.reparse == ReparseLink && cur.target != nil {
			traversed, cur = true, cur.target
		}
		var next *fakeNode
		for _, e := range cur.edges {
			if e.name == seg {
				next = e.n
				break
			}
		}
		if next == nil {
			for _, e := range cur.edges {
				if strings.EqualFold(e.name, seg) {
					next = e.n
					break
				}
			}
		}
		if next == nil {
			return nil, traversed, tstNotExist(p)
		}
		cur = next
	}
	if followLast && cur.reparse == ReparseLink && cur.target != nil {
		traversed, cur = true, cur.target
	}
	return cur, traversed, nil
}

func (f *fakeFS) rootFor(pp tstPath) *fakeNode {
	r := f.roots[pp.root]
	if r == nil {
		f.nextVol++
		r = &fakeNode{name: pp.display, isDir: true, display: pp.display}
		r.id = FileID{Volume: f.nextVol, Index: 5, IsDir: true}
		f.roots[pp.root] = r
	}
	return r
}

// mk creates the path (missing folders on the way); the leaf is a folder or a file.
func (f *fakeFS) mk(p string, isDir bool) *fakeNode {
	pp, ok := tstParse(p)
	if !ok {
		panic("fakeFS: bad path " + p)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	cur := f.rootFor(pp)
	for i, seg := range pp.segs {
		if cur.reparse == ReparseLink && cur.target != nil {
			cur = cur.target
		}
		var next *fakeNode
		for _, e := range cur.edges {
			if strings.EqualFold(e.name, seg) {
				next = e.n
				break
			}
		}
		if next == nil {
			f.nextIdx++
			next = &fakeNode{name: seg, parent: cur, isDir: i < len(pp.segs)-1 || isDir}
			next.id = FileID{Volume: cur.id.Volume, Index: f.nextIdx, IsDir: next.isDir}
			cur.edges = append(cur.edges, &fakeEdge{name: seg, n: next})
		}
		cur = next
	}
	return cur
}

func (f *fakeFS) dir(p string) *fakeNode { return f.mk(p, true) }

func (f *fakeFS) file(p string, size int64) *fakeNode {
	n := f.mk(p, false)
	f.mu.Lock()
	n.size = size
	f.mu.Unlock()
	return n
}

// link makes p a junction to target (created as a folder when missing).
func (f *fakeFS) link(p, target string) *fakeNode {
	n := f.mk(p, true)
	var t *fakeNode
	if target != "" {
		t = f.mk(target, true)
	}
	f.mu.Lock()
	n.reparse, n.target = ReparseLink, t
	f.mu.Unlock()
	return n
}

// fileLink makes p a symbolic link to a file.
func (f *fakeFS) fileLink(p string) *fakeNode {
	n := f.mk(p, false)
	f.mu.Lock()
	n.reparse = ReparseLink
	f.mu.Unlock()
	return n
}

func (f *fakeFS) cloudDir(p string) *fakeNode {
	n := f.mk(p, true)
	f.mu.Lock()
	n.reparse = ReparseCloud
	f.mu.Unlock()
	return n
}

// cloudFile is a placeholder file; online tells that its content is not stored locally.
func (f *fakeFS) cloudFile(p string, size int64, online bool) *fakeNode {
	n := f.mk(p, false)
	f.mu.Lock()
	n.size, n.reparse, n.online = size, ReparseCloud, online
	f.mu.Unlock()
	return n
}

// fileExact adds a file with exactly this name, even if a name that differs only
// in case exists (the real file systems do not allow it, the sort rules must
// still cope).
func (f *fakeFS) fileExact(dir, name string, size int64) {
	d := f.dir(dir)
	f.mu.Lock()
	defer f.mu.Unlock()
	f.nextIdx++
	n := &fakeNode{name: name, parent: d, size: size}
	n.id = FileID{Volume: d.id.Volume, Index: f.nextIdx}
	d.edges = append(d.edges, &fakeEdge{name: name, n: n})
}

func (f *fakeFS) failDir(p string, err error) {
	n := f.mk(p, true)
	f.mu.Lock()
	n.readErr = err
	f.mu.Unlock()
}

func (f *fakeFS) failIdentity(p string, err error) {
	n := f.mk(p, true)
	f.mu.Lock()
	n.idErr = err
	f.mu.Unlock()
}

func (f *fakeFS) clearFailures(p string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if n, _, err := f.walk(p, false); err == nil {
		n.readErr, n.idErr = nil, nil
	}
}

func (f *fakeFS) setSize(p string, size int64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if n, _, err := f.walk(p, false); err == nil {
		n.size = size
	}
}

// bumpIdentity gives the node a new file index, like a replaced folder.
func (f *fakeFS) bumpIdentity(p string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if n, _, err := f.walk(p, false); err == nil {
		f.nextIdx++
		n.id.Index = f.nextIdx
	}
}

// alias lets newPath lead to the very same node as existing (8.3 name, subst
// drive, second spelling): the identity is shared.
func (f *fakeFS) alias(newPath, existing string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	n, _, err := f.walk(existing, false)
	if err != nil {
		panic("fakeFS.alias: " + existing + " does not exist")
	}
	pp, _ := tstParse(newPath)
	parent := f.rootFor(pp)
	for _, seg := range pp.segs[:len(pp.segs)-1] {
		var next *fakeNode
		for _, e := range parent.edges {
			if strings.EqualFold(e.name, seg) {
				next = e.n
			}
		}
		if next == nil {
			panic("fakeFS.alias: parent of " + newPath + " does not exist")
		}
		parent = next
	}
	parent.edges = append(parent.edges, &fakeEdge{name: pp.segs[len(pp.segs)-1], n: n})
}

// rootAlias lets a drive letter lead to an existing folder (a subst drive).
func (f *fakeFS) rootAlias(letter, existing string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	n, _, err := f.walk(existing, false)
	if err != nil {
		panic("fakeFS.rootAlias: " + existing + " does not exist")
	}
	f.roots[strings.ToLower(letter)+":"] = n
}

// remove deletes the leaf (only the recycler fake and the tests call it).
func (f *fakeFS) remove(p string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	pp, ok := tstParse(p)
	if !ok || len(pp.segs) == 0 {
		return tstNotExist(p)
	}
	parent, _, err := f.walk(pp.display+strings.Join(pp.segs[:len(pp.segs)-1], `\`), true)
	if err != nil {
		return err
	}
	leaf := pp.segs[len(pp.segs)-1]
	for i, e := range parent.edges {
		if strings.EqualFold(e.name, leaf) {
			parent.edges = append(parent.edges[:i], parent.edges[i+1:]...)
			return nil
		}
	}
	return tstNotExist(p)
}

func (f *fakeFS) exists(p string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	_, _, err := f.walk(p, false)
	return err == nil
}

// hold blocks every ReadDir of p until release(p); holdOnce only the first one.
func (f *fakeFS) hold(p string)     { f.addHold(p, false) }
func (f *fakeFS) holdOnce(p string) { f.addHold(p, true) }

func (f *fakeFS) addHold(p string, once bool) {
	f.mu.Lock()
	f.holds[tstKey(p)] = &fakeHold{ch: make(chan struct{}), once: once}
	f.mu.Unlock()
}

func (f *fakeFS) release(p string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	k := tstKey(p)
	if h := f.holds[k]; h != nil {
		close(h.ch)
		delete(f.holds, k)
	}
}

func (f *fakeFS) releaseAll() {
	f.mu.Lock()
	defer f.mu.Unlock()
	for k, h := range f.holds {
		close(h.ch)
		delete(f.holds, k)
	}
}

// blockedOn is the number of reads of p waiting for release.
func (f *fakeFS) blockedOn(p string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	if h := f.holds[tstKey(p)]; h != nil {
		return h.n
	}
	return 0
}

func (f *fakeFS) ReadDir(p string) ([]FSEntry, error) {
	key := tstKey(p)
	f.mu.Lock()
	f.reads[key]++
	nth := f.reads[key]
	f.readLog = append(f.readLog, key)
	f.cur++
	if f.cur > f.max {
		f.max = f.cur
	}
	hook, delay := f.onRead, f.delay
	var gate chan struct{}
	h := f.holds[key]
	if h != nil && (!h.once || !h.used) {
		h.used = true
		h.n++
		gate = h.ch
	}
	f.mu.Unlock()
	defer func() {
		f.mu.Lock()
		f.cur--
		f.mu.Unlock()
	}()
	if hook != nil {
		hook(key, nth)
	}
	if delay > 0 {
		time.Sleep(delay)
	}
	if gate != nil {
		<-gate
		f.mu.Lock()
		h.n--
		f.mu.Unlock()
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	n, traversed, err := f.walk(p, true)
	if traversed {
		f.violations = append(f.violations, "ReadDir("+p+") crossed a link")
	}
	if err != nil {
		return nil, err
	}
	if !n.isDir {
		return nil, &os.PathError{Op: "readdir", Path: p, Err: errors.New("not a directory")}
	}
	if n.readErr != nil {
		return nil, n.readErr
	}
	out := make([]FSEntry, 0, len(n.edges))
	for _, e := range n.edges {
		c := e.n
		size := c.size
		if c.reparse == ReparseLink {
			size = 0
		}
		out = append(out, FSEntry{Name: e.name, IsDir: c.isDir, Reparse: c.reparse, Size: size, Online: c.online})
	}
	return out, nil
}

func (f *fakeFS) Resolve(p string) (string, error) {
	key := tstKey(p)
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.resolveErr[key]; err != nil {
		return "", err
	}
	n, _, err := f.walk(p, true)
	if err != nil {
		return "", err
	}
	if f.noResolve {
		return p, nil
	}
	s := n.canon()
	if f.verbatimResolve {
		s = `\\?\` + s
	}
	return s, nil
}

func (f *fakeFS) Identity(p string) (FileID, error) {
	key := tstKey(p)
	f.mu.Lock()
	f.ids[key]++
	nth := f.ids[key]
	hook := f.onIdentity
	f.mu.Unlock()
	if hook != nil {
		hook(key, nth)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	n, _, err := f.walk(p, false)
	if err != nil {
		return FileID{}, err
	}
	if n.idErr != nil {
		return FileID{}, n.idErr
	}
	id := n.id
	id.Reparse, id.IsDir = n.reparse, n.isDir
	return id, nil
}

func (f *fakeFS) Drives() []Drive {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.reads["\x00drives"]++
	return append([]Drive(nil), f.drives...)
}

func (f *fakeFS) readCount(p string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.reads[tstKey(p)]
}

func (f *fakeFS) readTotal() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for k, v := range f.reads {
		if k != "\x00drives" {
			n += v
		}
	}
	return n
}

func (f *fakeFS) driveReads() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.reads["\x00drives"]
}

func (f *fakeFS) identityCount(p string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.ids[tstKey(p)]
}

func (f *fakeFS) identityTotal() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, v := range f.ids {
		n += v
	}
	return n
}

func (f *fakeFS) readOrder() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.readLog...)
}

func (f *fakeFS) maxConcurrent() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.max
}

func (f *fakeFS) linkViolations() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.violations...)
}

func (f *fakeFS) assertNoLinkFollowed(t *testing.T) {
	t.Helper()
	if v := f.linkViolations(); len(v) > 0 {
		t.Errorf("a link was followed: %v", v)
	}
}

// ---------------------------------------------------------------------------
// Artificial recycler

type fakeRecycler struct {
	mu      sync.Mutex
	fs      *fakeFS
	clk     *fakeClock
	calls   []string
	errs    map[string]error
	failAll error
	gate    chan struct{} // every call blocks until it is closed
	entered chan string
	cur     int
	max     int
	step    time.Duration     // advances the artificial clock per call
	keep    bool              // success without removing the path from the fake file system
	onCall  func(path string) // runs inside every call before anything else
}

func newFakeRecycler(f *fakeFS, clk *fakeClock) *fakeRecycler {
	return &fakeRecycler{fs: f, clk: clk, errs: map[string]error{}, entered: make(chan string, 256)}
}

func (r *fakeRecycler) failPath(p string, err error) {
	r.mu.Lock()
	r.errs[tstKey(p)] = err
	r.mu.Unlock()
}

func (r *fakeRecycler) block() {
	r.mu.Lock()
	r.gate = make(chan struct{})
	r.mu.Unlock()
}

func (r *fakeRecycler) unblock() {
	r.mu.Lock()
	if r.gate != nil {
		close(r.gate)
		r.gate = nil
	}
	r.mu.Unlock()
}

func (r *fakeRecycler) Recycle(path string) error {
	r.mu.Lock()
	r.calls = append(r.calls, path)
	r.cur++
	if r.cur > r.max {
		r.max = r.cur
	}
	gate := r.gate
	err := r.errs[tstKey(path)]
	if err == nil {
		err = r.failAll
	}
	step, keep, onCall := r.step, r.keep, r.onCall
	r.mu.Unlock()
	if onCall != nil {
		onCall(path)
	}
	select {
	case r.entered <- path:
	default:
	}
	if gate != nil {
		<-gate
	}
	defer func() {
		r.mu.Lock()
		r.cur--
		r.mu.Unlock()
	}()
	if step > 0 && r.clk != nil {
		r.clk.Advance(step)
	}
	if err != nil {
		return err
	}
	if !keep && r.fs != nil {
		if rerr := r.fs.remove(path); rerr != nil {
			return rerr
		}
	}
	return nil
}

func (r *fakeRecycler) recorded() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.calls...)
}

func (r *fakeRecycler) maxConcurrent() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.max
}

// waitCalls waits until n calls have begun.
func (r *fakeRecycler) waitCalls(t *testing.T, n int) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if len(r.recorded()) >= n {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("recycler: %d calls after 10 s, want %d: %q", len(r.recorded()), n, r.recorded())
}

// ---------------------------------------------------------------------------
// Controllable scanner for the display

type scanCall struct {
	root     string
	ctx      context.Context
	counters *Counters
	ch       chan ScanEvent
}

func (c *scanCall) canceled() bool { return c.ctx.Err() != nil }

func (c *scanCall) child(it Item) { c.ch <- tstChildEvent(it) }
func (c *scanCall) final(l Listing) {
	c.ch <- tstFinalEvent(l)
	close(c.ch)
}
func (c *scanCall) fail(err error) {
	c.ch <- tstFailEvent(err)
	close(c.ch)
}

type fakeScanner struct {
	mu    sync.Mutex
	calls []*scanCall
}

func (s *fakeScanner) Scan(ctx context.Context, root string, c *Counters) <-chan ScanEvent {
	call := &scanCall{root: root, ctx: ctx, counters: c, ch: make(chan ScanEvent, 1024)}
	s.mu.Lock()
	s.calls = append(s.calls, call)
	s.mu.Unlock()
	return call.ch
}

func (s *fakeScanner) all() []*scanCall {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]*scanCall(nil), s.calls...)
}

func (s *fakeScanner) callsFor(root string) []*scanCall {
	var out []*scanCall
	for _, c := range s.all() {
		if tstKey(c.root) == tstKey(root) {
			out = append(out, c)
		}
	}
	return out
}

// ---------------------------------------------------------------------------
// Adapters to the production API

func tstChildEvent(it Item) ScanEvent   { return ScanEvent{Item: &it} }
func tstFinalEvent(l Listing) ScanEvent { return ScanEvent{Listing: &l} }
func tstFailEvent(err error) ScanEvent  { return ScanEvent{Err: err} }
func tstSizeText(n int64) string        { return FormatSize(n) }
func tstStateText(s State) string       { return fmt.Sprint(s) }
func tstNewCounters() *Counters         { return &Counters{} }
func tstCountFiles(c *Counters) int64   { return c.Files() }
func tstCountDirs(c *Counters) int64    { return c.Dirs() }
func tstCountBytes(c *Counters) int64   { return c.Bytes() }
func tstNewOpLog(env map[string]string, clk Clock, app func(string, []byte) error) *OpLog {
	return NewOpLog(env, clk, app)
}
func tstRecord(l *OpLog, action, path, detail string) { l.Record(action, path, detail) }

func tstNewModel(d Deps, env map[string]string, target string) tea.Model {
	return newExplorerModel(d, env, target)
}

func tstMeasureCtx(ctx context.Context, f FS, root string) (Listing, error) {
	return Measure(ctx, f, root, tstNewCounters(), func(Item) {})
}

func tstMeasure(t *testing.T, f FS, root string) Listing {
	t.Helper()
	l, err := tstMeasureCtx(context.Background(), f, root)
	if err != nil {
		t.Fatalf("Measure(%s): %v", root, err)
	}
	return l
}

func tstItemByName(l Listing, name string) (Item, bool) {
	for _, it := range l.Items {
		if it.Name == name {
			return it, true
		}
	}
	return Item{}, false
}

func tstMustItem(t *testing.T, l Listing, name string) Item {
	t.Helper()
	it, ok := tstItemByName(l, name)
	if !ok {
		t.Fatalf("no item %q in %v", name, tstItemNames(l.Items))
	}
	return it
}

func tstItemNames(items []Item) []string {
	out := make([]string, len(items))
	for i, it := range items {
		out[i] = it.Name
	}
	return out
}

func tstFileItem(path string, size int64) Item {
	return Item{Name: tstBase(path), Path: path, Size: size, State: Complete}
}

func tstDirItem(path string, size int64) Item {
	return Item{Name: tstBase(path), Path: path, IsDir: true, Size: size, State: Complete}
}

func tstSameStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// Environments and standard trees

func tstWinEnv() map[string]string {
	return map[string]string{
		"USERPROFILE":  `C:\Users\Example`,
		"LOCALAPPDATA": `C:\Users\Example\AppData\Local`,
		"WINDIR":       `C:\Windows`,
		"SystemRoot":   `C:\Windows`,
		"ProgramFiles": `C:\Program Files`, "ProgramFiles(x86)": `C:\Program Files (x86)`,
		"ProgramW6432": `C:\Program Files`,
		"ProgramData":  `C:\ProgramData`,
	}
}

func tstEnvWith(base map[string]string, kv ...string) map[string]string {
	m := map[string]string{}
	for k, v := range base {
		m[k] = v
	}
	for i := 0; i+1 < len(kv); i += 2 {
		m[kv[i]] = kv[i+1]
	}
	return m
}

// tstWinTree adds the folders every Windows machine has.
func tstWinTree(f *fakeFS) {
	for _, p := range []string{
		`C:\Users\Example\AppData\Local`, `C:\Users\Example\AppData\Roaming`, `C:\Users\Example\Downloads`,
		`C:\Users\Default`, `C:\Users\Public`, `C:\Users\someone`,
		`C:\Windows\System32`, `C:\Program Files`, `C:\Program Files (x86)`, `C:\ProgramData`,
		`D:\`, `E:\`,
	} {
		f.dir(p)
	}
	f.drives = []Drive{
		{Root: `C:\`, Label: "System", Total: 100 * tstGiB, Free: 60 * tstGiB},
		{Root: `D:\`, Label: "Data", Total: 500 * tstGiB, Free: 100 * tstGiB},
	}
}

// tstSimpleTree is the folder C:\Data used by most display tests.
//
//	alpha   5 GiB   deep\d1.bin 3 GiB, a1.bin 2 GiB
//	beta    2 GiB   b1.bin 2 GiB
//	gamma   512 MiB g1.bin 512 MiB
//	notes.txt 4 KiB
func tstSimpleTree(f *fakeFS) {
	f.file(`C:\Data\alpha\deep\d1.bin`, 3*tstGiB)
	f.file(`C:\Data\alpha\a1.bin`, 2*tstGiB)
	f.file(`C:\Data\beta\b1.bin`, 2*tstGiB)
	f.file(`C:\Data\gamma\g1.bin`, 512*tstMiB)
	f.file(`C:\Data\notes.txt`, 4*tstKiB)
}

const tstSimpleTotal = 5*tstGiB + 2*tstGiB + 512*tstMiB + 4*tstKiB

// tstLogEnv returns the environment with a data folder under a temporary folder
// and the path of the log file in it.
func tstLogEnv(t *testing.T, base map[string]string) (map[string]string, string) {
	t.Helper()
	data := filepath.Join(t.TempDir(), "data")
	env := tstEnvWith(base, "SWEEPR_DATA_DIR", data)
	delete(env, "SWEEPR_NO_OPLOG")
	return env, filepath.Join(data, "config", "operations.log")
}

func tstReadLog(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return ""
		}
		t.Fatalf("read log: %v", err)
	}
	return string(b)
}

// Patterns of lib/core/history.ps1 (the reader of the log).
var (
	tstRecordRe = regexp.MustCompile(`(?s)\A\[([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})\] \[([^\s\]]+)(?: run=([^\s\]]+))?\] ([A-Z]+) (.+) \(([^()]*)\)\z`)
	tstMarkerRe = regexp.MustCompile(`(?s)\A# ={10} ([^\s\]]+)(?: run=([^\s\]]+))? session started at (.+?) ={10}\z`)
)

type tstLogLine struct {
	time, command, run, action, path, detail string
}

// tstParseLog splits a log into records and markers; every other non-empty line
// fails the test.
func tstParseLog(t *testing.T, text string) (records []tstLogLine, markers []string) {
	t.Helper()
	if text == "" {
		return nil, nil
	}
	if strings.HasPrefix(text, "\xef\xbb\xbf") {
		t.Errorf("log starts with a byte-order mark")
	}
	for i := 0; i < len(text); i++ {
		if text[i] == '\n' && (i == 0 || text[i-1] != '\r') {
			t.Errorf("log has a bare line feed at offset %d", i)
		}
	}
	for _, line := range strings.Split(text, "\r\n") {
		if line == "" {
			continue
		}
		if m := tstRecordRe.FindStringSubmatch(line); m != nil {
			records = append(records, tstLogLine{m[1], m[2], m[3], m[4], m[5], m[6]})
			continue
		}
		if tstMarkerRe.MatchString(line) {
			markers = append(markers, line)
			continue
		}
		t.Errorf("log line matches neither the record nor the marker pattern: %q", line)
	}
	return records, markers
}

// ---------------------------------------------------------------------------
// Entry point rig

type tstUI struct {
	mu    sync.Mutex
	calls int
	model tea.Model
	err   error
}

func (u *tstUI) start(m tea.Model) error {
	u.mu.Lock()
	defer u.mu.Unlock()
	u.calls++
	u.model = m
	return u.err
}

func (u *tstUI) count() int {
	u.mu.Lock()
	defer u.mu.Unlock()
	return u.calls
}

type tstResult struct {
	code           int
	stdout, stderr string
}

type tstRunRig struct {
	fs  *fakeFS
	rec *fakeRecycler
	clk *fakeClock
	ui  *tstUI
	sc  Scanner
}

func newRunRig() *tstRunRig {
	f := newFakeFS()
	clk := newFakeClock()
	tstWinTree(f)
	return &tstRunRig{fs: f, clk: clk, rec: newFakeRecycler(f, clk), ui: &tstUI{}}
}

func (r *tstRunRig) deps() Deps {
	d := Deps{FS: r.fs, Recycler: r.rec, Clock: r.clk, StartUI: r.ui.start}
	if r.sc != nil {
		d.Scanner = r.sc
	}
	return d
}

func tstRunWith(t *testing.T, d Deps, args []string, env map[string]string, terminal bool, stdout, stderr io.Writer) int {
	t.Helper()
	done := make(chan int, 1)
	go func() { done <- Run(args, env, stdout, stderr, terminal, d) }()
	select {
	case code := <-done:
		return code
	case <-time.After(20 * time.Second):
		t.Fatalf("Run(%q) did not return within 20 s", args)
		return -1
	}
}

func (r *tstRunRig) run(t *testing.T, args []string, env map[string]string, terminal bool) tstResult {
	t.Helper()
	var out, errOut bytes.Buffer
	code := tstRunWith(t, r.deps(), args, env, terminal, &out, &errOut)
	return tstResult{code: code, stdout: out.String(), stderr: errOut.String()}
}

// ---------------------------------------------------------------------------
// JSON helpers

func tstDecode(t *testing.T, out string) map[string]any {
	t.Helper()
	var doc map[string]any
	dec := json.NewDecoder(strings.NewReader(out))
	if err := dec.Decode(&doc); err != nil {
		t.Fatalf("stdout is not a JSON object: %v\n%s", err, out)
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		t.Errorf("stdout holds more than one JSON document")
	}
	return doc
}

func tstAt(v any, path ...string) (any, bool) {
	cur := v
	for _, p := range path {
		m, ok := cur.(map[string]any)
		if !ok {
			return nil, false
		}
		cur, ok = m[p]
		if !ok {
			return nil, false
		}
	}
	return cur, true
}

func tstArr(t *testing.T, doc map[string]any, key string) []any {
	t.Helper()
	v, ok := doc[key]
	a, isArr := v.([]any)
	if !ok || !isArr || a == nil {
		t.Fatalf("%s = %#v, want an array", key, v)
	}
	return a
}

func tstEntryByName(t *testing.T, doc map[string]any, name string) map[string]any {
	t.Helper()
	for _, e := range tstArr(t, doc, "entries") {
		m, _ := e.(map[string]any)
		if m["name"] == name {
			return m
		}
	}
	t.Fatalf("no entry %q in the document", name)
	return nil
}

func tstEntryNames(t *testing.T, doc map[string]any) []string {
	t.Helper()
	var out []string
	for _, e := range tstArr(t, doc, "entries") {
		m, _ := e.(map[string]any)
		s, _ := m["name"].(string)
		out = append(out, s)
	}
	return out
}

// tstNum returns a JSON number as int64 and tells whether it is an integer literal.
func tstNum(v any) (int64, bool) {
	f, ok := v.(float64)
	if !ok {
		return 0, false
	}
	return int64(f), f == float64(int64(f))
}

// ---------------------------------------------------------------------------
// Display driver (no terminal): commands run in goroutines like in the runtime

func tstBatch(msg tea.Msg) (cmds []tea.Cmd, sequential bool) {
	v := reflect.ValueOf(msg)
	if v.Kind() != reflect.Slice || v.Type().Elem() != reflect.TypeOf((tea.Cmd)(nil)) {
		return nil, false
	}
	cmds = make([]tea.Cmd, v.Len())
	for i := range cmds {
		cmds[i], _ = v.Index(i).Interface().(tea.Cmd)
	}
	return cmds, v.Type().Name() == "sequenceMsg"
}

type tstPump struct {
	t     *testing.T
	m     tea.Model
	msgs  chan tea.Msg
	quit  bool
	size  tea.WindowSizeMsg
	nudge func()
}

func newTstPump(t *testing.T, m tea.Model) *tstPump {
	return &tstPump{t: t, m: m, msgs: make(chan tea.Msg, 8192)}
}

func (p *tstPump) start(cmd tea.Cmd) {
	if cmd == nil {
		return
	}
	go func() {
		if msg := cmd(); msg != nil {
			p.msgs <- msg
		}
	}()
}

// feed delivers a message the way the runtime does; call it from one goroutine.
// An Update that does not return within 10 s fails the test.
func (p *tstPump) feed(msg tea.Msg) {
	p.t.Helper()
	if _, ok := msg.(tea.QuitMsg); ok {
		p.quit = true
		return
	}
	if cmds, seq := tstBatch(msg); cmds != nil {
		if seq {
			go func() {
				for _, c := range cmds {
					if c == nil {
						continue
					}
					m := c()
					if m == nil {
						continue
					}
					p.msgs <- m
				}
			}()
			return
		}
		for _, c := range cmds {
			p.start(c)
		}
		return
	}
	type res struct {
		m   tea.Model
		cmd tea.Cmd
	}
	done := make(chan res, 1)
	go func() {
		m, cmd := p.m.Update(msg)
		done <- res{m, cmd}
	}()
	select {
	case r := <-done:
		p.m = r.m
		p.start(r.cmd)
	case <-time.After(10 * time.Second):
		p.t.Fatalf("Update blocked for 10 s on %T %v", msg, msg)
	}
}

// drain delivers results until nothing has arrived for the quiet period.
func (p *tstPump) drain(quiet time.Duration) {
	p.t.Helper()
	for {
		select {
		case msg := <-p.msgs:
			p.feed(msg)
		case <-time.After(quiet):
			return
		}
	}
}

// settle delivers command results until the condition holds. While nothing
// arrives, it sends a message that changes nothing so that a model which only
// refreshes on messages gets the chance to do so.
func (p *tstPump) settle(until func() bool) bool {
	p.t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	lastNudge := time.Now()
	for {
		if until() {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		select {
		case msg := <-p.msgs:
			p.feed(msg)
		case <-time.After(5 * time.Millisecond):
			if time.Since(lastNudge) > 40*time.Millisecond {
				lastNudge = time.Now()
				p.feed(p.size)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Display rig

type tstRigOpts struct {
	scanner *fakeScanner
	env     map[string]string // overlay
	setup   func(f *fakeFS)
	width   int // 0: 100, negative: no size message at all
	height  int
	noTree  bool // do not add the standard folder C:\Data
	noBoot  bool
}

type tstRig struct {
	t       *testing.T
	clk     *fakeClock
	fs      *fakeFS
	rec     *fakeRecycler
	sc      *fakeScanner
	env     map[string]string
	logFile string
	p       *tstPump
	target  string
}

func tstNewRig(t *testing.T, target string, o tstRigOpts) *tstRig {
	t.Helper()
	f := newFakeFS()
	clk := newFakeClock()
	tstWinTree(f)
	if !o.noTree {
		tstSimpleTree(f)
	}
	if o.setup != nil {
		o.setup(f)
	}
	env, logFile := tstLogEnv(t, tstWinEnv())
	for k, v := range o.env {
		env[k] = v
	}
	rec := newFakeRecycler(f, clk)
	d := Deps{FS: f, Recycler: rec, Clock: clk}
	if o.scanner != nil {
		d.Scanner = o.scanner
	}
	if o.width == 0 {
		o.width = 100
	}
	if o.height == 0 {
		o.height = 30
	}
	r := &tstRig{t: t, clk: clk, fs: f, rec: rec, sc: o.scanner, env: env, logFile: logFile, target: target}
	r.p = newTstPump(t, tstNewModel(d, env, target))
	noSize := o.width < 0
	if noSize {
		o.width, o.height = 80, 24
	}
	r.p.size = tea.WindowSizeMsg{Width: o.width, Height: o.height}
	if !o.noBoot {
		r.p.start(r.p.m.Init())
		if !noSize {
			r.p.feed(r.p.size)
		}
	}
	t.Cleanup(func() {
		f.releaseAll()
		rec.unblock()
	})
	return r
}

func (r *tstRig) view() string { return tstStrip(r.p.m.View()) }

func (r *tstRig) rawView() string { return r.p.m.View() }

// until delivers results until the stripped view satisfies the condition.
func (r *tstRig) until(desc string, cond func(view string) bool) {
	r.t.Helper()
	if !r.p.settle(func() bool { return cond(r.view()) }) {
		r.t.Fatalf("timed out waiting for %s; the view is:\n%s", desc, r.view())
	}
}

func (r *tstRig) untilContains(s string) {
	r.t.Helper()
	r.until("the view to contain "+s, func(v string) bool { return strings.Contains(v, s) })
}

// untilMeasured waits for the end of the measurement: the sorted list shows
// the text of the first item size.
func (r *tstRig) untilIdle() {
	r.t.Helper()
	r.p.drain(80 * time.Millisecond)
}

func (r *tstRig) resize(w, h int) {
	r.t.Helper()
	r.p.size = tea.WindowSizeMsg{Width: w, Height: h}
	r.p.feed(r.p.size)
}

func (r *tstRig) press(keys ...string) {
	r.t.Helper()
	for _, k := range keys {
		r.p.feed(tstKeyMsg(k))
		r.p.drain(5 * time.Millisecond)
	}
}

func tstSize(w, h int) tea.WindowSizeMsg { return tea.WindowSizeMsg{Width: w, Height: h} }

func tstKeyMsg(name string) tea.KeyMsg {
	switch name {
	case "up":
		return tea.KeyMsg{Type: tea.KeyUp}
	case "down":
		return tea.KeyMsg{Type: tea.KeyDown}
	case "left":
		return tea.KeyMsg{Type: tea.KeyLeft}
	case "right":
		return tea.KeyMsg{Type: tea.KeyRight}
	case "enter":
		return tea.KeyMsg{Type: tea.KeyEnter}
	case "esc":
		return tea.KeyMsg{Type: tea.KeyEsc}
	case "backspace":
		return tea.KeyMsg{Type: tea.KeyBackspace}
	case "space":
		return tea.KeyMsg{Type: tea.KeySpace, Runes: []rune{' '}}
	case "delete":
		return tea.KeyMsg{Type: tea.KeyDelete}
	case "pgup":
		return tea.KeyMsg{Type: tea.KeyPgUp}
	case "pgdown":
		return tea.KeyMsg{Type: tea.KeyPgDown}
	case "home":
		return tea.KeyMsg{Type: tea.KeyHome}
	case "end":
		return tea.KeyMsg{Type: tea.KeyEnd}
	case "ctrl+c":
		return tea.KeyMsg{Type: tea.KeyCtrlC}
	case "f9":
		return tea.KeyMsg{Type: tea.KeyF9}
	}
	return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(name)}
}

// openFolder boots a rig on the standard folder and waits for the end of the
// measurement (the sorted list is complete).
func tstOpenSimple(t *testing.T, o tstRigOpts) *tstRig {
	t.Helper()
	r := tstNewRig(t, `C:\Data`, o)
	r.untilContains(tstPct(5*tstGiB, tstSimpleTotal)) // percentages show only when every entry is measured
	r.untilIdle()
	r.press("home") // the cursor follows the row it was on while the list was still unsorted
	return r
}

func tstPct(size, total int64) string { return FormatPercent(float64(size) * 100 / float64(total)) }

var tstSimpleNames = []string{"alpha", "beta", "gamma", "notes.txt"}

// cursor returns the name of the row under the cursor (no row may be marked).
func (r *tstRig) cursor(names []string) string {
	sp := tstSpecial(r.view(), names)
	if len(sp) != 1 {
		return ""
	}
	return sp[0]
}

// rows lists the visible rows in the order of the view.
func (r *tstRig) rows(names []string) []string { return tstRowNames(r.view(), names) }

// goTo puts the cursor on the named row by counting rows from the top; marks
// do not matter.
func (r *tstRig) goTo(name string, names []string) {
	r.t.Helper()
	order := r.rows(names)
	for i, n := range order {
		if n == name {
			r.press("home")
			for k := 0; k < i; k++ {
				r.press("down")
			}
			return
		}
	}
	r.t.Fatalf("row %q is not shown; the view is:\n%s", name, r.view())
}

func (r *tstRig) waitQuit() bool {
	r.t.Helper()
	return r.p.settle(func() bool { return r.p.quit })
}

// ---------------------------------------------------------------------------
// Reading the view

var tstAnsiRe = regexp.MustCompile("\x1b\\[[0-9;:?<=>]*[ -/]*[@-~]|\x1b\\][^\x07\x1b]*(?:\x07|\x1b\\\\)")

func tstStrip(s string) string { return tstAnsiRe.ReplaceAllString(s, "") }

// tstRowOf returns the first line of the view that contains the text.
func tstRowOf(view, text string) string {
	for _, l := range strings.Split(view, "\n") {
		if strings.Contains(l, text) {
			return l
		}
	}
	return ""
}

// tstRowHas tells whether the row of the name contains the text.
func tstRowHas(view, name, text string) bool { return strings.Contains(tstRowOf(view, name), text) }

// tstPrefixes returns, per name, the marker characters at the start of its line:
// the symbols (neither letters, digits nor blanks) before the first letter or
// digit. Padding does not count. Names that are not shown are missing from the
// result.
func tstPrefixes(view string, names []string) map[string]string {
	out := map[string]string{}
	for _, n := range names {
		for _, l := range strings.Split(view, "\n") {
			if strings.Contains(l, n) {
				var marks []rune
				for _, r := range l {
					if unicode.IsLetter(r) || unicode.IsDigit(r) {
						break
					}
					if !unicode.IsSpace(r) {
						marks = append(marks, r)
					}
				}
				out[n] = string(marks)
				break
			}
		}
	}
	return out
}

// tstSpecial returns the names of the rows whose prefix differs from the most
// common prefix: the cursor and the marked rows.
func tstSpecial(view string, names []string) []string {
	pre := tstPrefixes(view, names)
	count := map[string]int{}
	for _, p := range pre {
		count[p]++
	}
	common, best := "", 0
	for p, c := range count {
		if c > best || (c == best && p < common) {
			common, best = p, c
		}
	}
	var out []string
	for _, n := range names {
		if p, ok := pre[n]; ok && p != common {
			out = append(out, n)
		}
	}
	return out
}

// tstRowNames lists, in order of appearance, the names that are shown.
func tstRowNames(view string, names []string) []string {
	type pos struct {
		name string
		line int
	}
	var found []pos
	lines := strings.Split(view, "\n")
	for _, n := range names {
		for i, l := range lines {
			if strings.Contains(l, n) {
				found = append(found, pos{n, i})
				break
			}
		}
	}
	for i := 1; i < len(found); i++ {
		for j := i; j > 0 && found[j].line < found[j-1].line; j-- {
			found[j], found[j-1] = found[j-1], found[j]
		}
	}
	out := make([]string, len(found))
	for i, f := range found {
		out[i] = f.name
	}
	return out
}

// ---------------------------------------------------------------------------
// Test binary as child process: the test program calls itself.

const tstModeEnv = "SWEEPR_ANALYZE_TEST_MODE"

func TestMain(m *testing.M) {
	if os.Getenv(tstModeEnv) == "main" {
		main()
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// tstChildMain runs the main function of the program in a child process of the
// test binary. stdout and stderr are pipes (not terminals).
func tstChildMain(t *testing.T, args []string, extraEnv ...string) tstResult {
	t.Helper()
	cmd := exec.Command(os.Args[0], args...)
	cmd.Env = append(os.Environ(), tstModeEnv+"=main", "SWEEPR_NO_OPLOG=1")
	cmd.Env = append(cmd.Env, extraEnv...)
	var out, errOut bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errOut
	err := cmd.Run()
	code := 0
	if err != nil {
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			t.Fatalf("start child: %v", err)
		}
		code = ee.ExitCode()
	}
	return tstResult{code: code, stdout: out.String(), stderr: errOut.String()}
}
