package main

import (
	"context"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
)

// State tells how completely an entry was measured.
type State int

const (
	// Complete: every folder and file below the entry could be read.
	Complete State = iota
	// Partial: the entry's own folder was read, but something below it was not.
	Partial
	// Unavailable: the entry itself could not be read.
	Unavailable
)

func (s State) String() string {
	switch s {
	case Partial:
		return "partial"
	case Unavailable:
		return "unavailable"
	}
	return "complete"
}

// Item is one row of a list: a child of the measured folder.
type Item struct {
	Name, Path string
	IsDir      bool
	IsLink     bool
	// Size counts the bytes stored locally. Files whose content lives only in
	// the cloud add to OnlineSize instead, never to Size.
	Size       int64
	OnlineSize int64
	// Cloud is set when the entry is, or contains, a cloud placeholder.
	Cloud bool
	State State
}

// measured tells whether Size is a measured value. An entry that could not be
// read, or that was read only in part and shows nothing, has no size at all;
// it must never be shown or written as zero.
func (it Item) measured() bool {
	return !(it.State == Unavailable || (it.State == Partial && it.Size == 0))
}

// FileItem is one of the largest files below a folder.
type FileItem struct {
	Name, Path string
	Size       int64
}

// Listing is the result of measuring a folder.
type Listing struct {
	Root            string
	Items           []Item
	TopFiles        []FileItem
	TotalSize       int64
	TotalOnlineSize int64
	TotalFiles      int64
	State           State
}

const (
	maxReads       = 16
	maxTopFiles    = 20
	topFileMinimum = int64(1) << 20
)

// Counters are running totals of a measurement that another goroutine may
// read while it runs. The zero value is ready to use.
type Counters struct {
	files, dirs, bytes atomic.Int64
}

func (c *Counters) Files() int64 { return c.files.Load() }
func (c *Counters) Dirs() int64  { return c.dirs.Load() }
func (c *Counters) Bytes() int64 { return c.bytes.Load() }

// measureHooks lets the caller follow a measurement.
type measureHooks struct {
	// onChild receives every finished direct child. When onList is set it
	// receives only the children that need a walk; the others come with onList.
	onChild func(Item)
	// onList is called once after the root folder was read: ready are the
	// children that are already final (files and links), pending the folders
	// that are still to be measured.
	onList func(ready, pending []Item)
}

// Measure walks a folder and returns its direct children with the size of
// everything below each. Only directories and file attributes are read, never
// file contents. Links are listed but not entered. At most maxReads
// directories are read at the same time. When the context ends no further
// read starts and the partial result is dropped.
func Measure(ctx context.Context, fs FS, root string, c *Counters, onChild func(Item)) (Listing, error) {
	return measureTree(ctx, fs, root, c, measureHooks{onChild: onChild})
}

// childAcc collects the totals of one direct child while workers add to it.
type childAcc struct {
	mu          sync.Mutex
	item        Item
	pending     int // directory reads that are queued or running
	online      int64
	size        int64
	files       int64
	partial     bool
	unavailable bool
	cloud       bool
}

type dirTask struct {
	path  string
	child *childAcc
	own   bool // the child's own folder (a failure makes the child unavailable)
}

type topCollector struct {
	mu    sync.Mutex
	files []FileItem
}

// less orders larger files first and equal sizes by path, ignoring case.
func topFileLess(a, b FileItem) bool {
	if a.Size != b.Size {
		return a.Size > b.Size
	}
	la, lb := strings.ToLower(a.Path), strings.ToLower(b.Path)
	if la != lb {
		return la < lb
	}
	return a.Path < b.Path
}

func (t *topCollector) offer(f FileItem) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if len(t.files) == maxTopFiles && !topFileLess(f, t.files[len(t.files)-1]) {
		return
	}
	i := sort.Search(len(t.files), func(i int) bool { return topFileLess(f, t.files[i]) })
	t.files = append(t.files, FileItem{})
	copy(t.files[i+1:], t.files[i:])
	t.files[i] = f
	if len(t.files) > maxTopFiles {
		t.files = t.files[:maxTopFiles]
	}
}

func measureTree(ctx context.Context, fs FS, root string, c *Counters, hooks measureHooks) (Listing, error) {
	if c == nil {
		c = &Counters{}
	}
	if err := ctx.Err(); err != nil {
		return Listing{}, err
	}
	entries, err := fs.ReadDir(root)
	if err != nil {
		return Listing{}, err
	}
	if err := ctx.Err(); err != nil {
		return Listing{}, err
	}

	var top topCollector
	var rootFiles int64
	var ready, pendingItems []Item
	var accs []*childAcc
	for _, e := range entries {
		path := joinWin(root, e.Name)
		it := Item{Name: e.Name, Path: path, IsDir: e.IsDir}
		switch {
		case e.Reparse == ReparseLink:
			it.IsLink = true
			it.State = Complete
			ready = append(ready, it)
		case !e.IsDir:
			rootFiles++
			c.files.Add(1)
			if e.Online {
				it.OnlineSize = e.Size
				it.Cloud = true
			} else {
				it.Size = e.Size
				c.bytes.Add(e.Size)
				if e.Size >= topFileMinimum {
					top.offer(FileItem{Name: e.Name, Path: path, Size: e.Size})
				}
			}
			if e.Reparse == ReparseCloud {
				it.Cloud = true
			}
			it.State = Complete
			ready = append(ready, it)
		default:
			c.dirs.Add(1)
			if e.Reparse == ReparseCloud {
				it.Cloud = true
			}
			a := &childAcc{item: it, pending: 1, cloud: it.Cloud}
			accs = append(accs, a)
			pendingItems = append(pendingItems, Item{Name: e.Name, Path: path, IsDir: true, Cloud: it.Cloud})
		}
	}

	var items []Item
	var itemsMu sync.Mutex
	report := func(it Item) {
		itemsMu.Lock()
		items = append(items, it)
		itemsMu.Unlock()
		if hooks.onChild != nil {
			hooks.onChild(it)
		}
	}
	if hooks.onList != nil {
		itemsMu.Lock()
		items = append(items, ready...)
		itemsMu.Unlock()
		hooks.onList(ready, pendingItems)
	} else {
		for _, it := range ready {
			report(it)
		}
	}

	var tasks []dirTask
	for _, a := range accs {
		tasks = append(tasks, dirTask{path: a.item.Path, child: a, own: true})
	}

	// finish is called when the last read of a child is done.
	finish := func(a *childAcc) {
		it := a.item
		it.Size, it.OnlineSize, it.Cloud = a.size, a.online, a.cloud
		switch {
		case a.unavailable:
			it.State = Unavailable
			it.Size, it.OnlineSize = 0, 0
		case a.partial:
			it.State = Partial
		}
		report(it)
	}

	process := func(t dirTask, push func(dirTask)) {
		if ctx.Err() != nil {
			return
		}
		a := t.child
		list, err := fs.ReadDir(t.path)
		if ctx.Err() != nil {
			return
		}
		a.mu.Lock()
		if err != nil {
			if t.own {
				a.unavailable = true
			} else {
				a.partial = true
			}
		}
		var sub []dirTask
		for _, e := range list {
			switch {
			case e.Reparse == ReparseLink:
				// Never entered, never counted.
			case e.IsDir:
				c.dirs.Add(1)
				if e.Reparse == ReparseCloud {
					a.cloud = true
				}
				a.pending++
				sub = append(sub, dirTask{path: joinWin(t.path, e.Name), child: a})
			default:
				a.files++
				c.files.Add(1)
				if e.Reparse == ReparseCloud {
					a.cloud = true
				}
				if e.Online {
					a.online += e.Size
					a.cloud = true
					continue
				}
				a.size += e.Size
				c.bytes.Add(e.Size)
				if e.Size >= topFileMinimum {
					top.offer(FileItem{Name: e.Name, Path: joinWin(t.path, e.Name), Size: e.Size})
				}
			}
		}
		a.pending--
		last := a.pending == 0
		a.mu.Unlock()
		for _, s := range sub {
			push(s)
		}
		if last {
			finish(a)
		}
	}
	runPool(ctx, maxReads, tasks, process)
	if err := ctx.Err(); err != nil {
		return Listing{}, err
	}

	itemsMu.Lock()
	defer itemsMu.Unlock()
	l := Listing{Root: root, Items: items, TopFiles: top.files, TotalFiles: rootFiles}
	for _, a := range accs {
		l.TotalFiles += a.files
	}
	for _, it := range items {
		l.TotalSize += it.Size
		l.TotalOnlineSize += it.OnlineSize
		if it.State != Complete {
			l.State = Partial
		}
	}
	sortItems(l.Items)
	if l.Items == nil {
		l.Items = []Item{}
	}
	if l.TopFiles == nil {
		l.TopFiles = []FileItem{}
	}
	return l, nil
}

// sortItems orders by known size, largest first, with unmeasured entries at
// the end; ties go by name ignoring case, then by the name as written. The
// result does not depend on the order in which the children finished.
func sortItems(items []Item) {
	sort.SliceStable(items, func(i, j int) bool {
		a, b := items[i], items[j]
		am, bm := a.measured(), b.measured()
		if am != bm {
			return am
		}
		if am && a.Size != b.Size {
			return a.Size > b.Size
		}
		la, lb := strings.ToLower(a.Name), strings.ToLower(b.Name)
		if la != lb {
			return la < lb
		}
		return a.Name < b.Name
	})
}
