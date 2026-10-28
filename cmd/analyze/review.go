package main

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"sync"
	"time"
)

// Refusal says why an entry may not be moved to the Recycle Bin. Code is one
// of: protected, data-folder, outside-root, link, cloud, unmeasured, invalid,
// incomplete, changed.
type Refusal struct {
	Code string
	Text string
}

func (r *Refusal) Error() string { return r.Text }

func refuse(code, format string, args ...any) *Refusal {
	return &Refusal{Code: code, Text: fmt.Sprintf(format, args...)}
}

const (
	// reviewBudget bounds the walk through a folder's tree. A tree that cannot
	// be checked in this time is refused, never assumed to be clean.
	reviewBudget  = 60 * time.Second
	reviewWorkers = 8
)

const cloudAdvice = "files in cloud folders are managed in the cloud app (for example with free up space)"

func protectionRefusal(v protVerdict, what string) *Refusal {
	if v.kind == protData {
		return refuse("data-folder", "%s: %s", what, v.why)
	}
	return refuse("protected", "%s is protected (%s)", what, v.why)
}

// invalidPath checks the text of a path before anything else touches it.
func invalidPath(path string) string {
	switch {
	case path == "":
		return "the path is empty"
	case containsNUL(path):
		return "the path contains a NUL character"
	case hasDotDot(path):
		return "the path contains a .. segment"
	}
	if _, ok := parseWinPath(path); !ok {
		return "the path is not absolute"
	}
	return ""
}

func containsNUL(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] == 0 {
			return true
		}
	}
	return false
}

// reviewSnapshot is what a review bound: the identities of the target and of
// every ancestor.
type reviewSnapshot []FileID

func (a reviewSnapshot) same(b reviewSnapshot) bool {
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

// Review decides whether one entry of the list of root may be moved to the
// Recycle Bin. It returns nil when it may and the reason when it may not.
//
// The entry must lie strictly below root, by its typed path and after the
// folder it lies in is resolved. It must not be protected, a link, a cloud
// placeholder or unmeasured; neither it nor any ancestor may be a reparse
// point; and for a folder every descendant is checked the same way, the whole
// tree being read without following links. Anything that cannot be read or
// finishes too late counts as a refusal.
func Review(ctx context.Context, fs FS, clock Clock, env map[string]string, root, path string, item Item) *Refusal {
	ref, _ := reviewEntry(ctx, fs, clock, env, root, path, item, true)
	return ref
}

func reviewEntry(ctx context.Context, fsys FS, clock Clock, env map[string]string, root, path string, item Item, tree bool) (*Refusal, reviewSnapshot) {
	if why := invalidPath(path); why != "" {
		return refuse("invalid", "%s", why), nil
	}
	wp, _ := parseWinPath(path)
	name := wp.leaf()
	switch {
	case item.IsLink:
		return refuse("link", "%s is a link; links are never moved", name), nil
	case item.Cloud:
		return refuse("cloud", "%s has cloud content: %s", name, cloudAdvice), nil
	case item.State == Unavailable:
		return refuse("unmeasured", "%s could not be read, so its size is unknown", name), nil
	}
	rootP, ok := parseWinPath(root)
	if !ok || !wp.below(rootP) {
		return refuse("outside-root", "%s is not inside the folder shown", name), nil
	}
	if ctx.Err() != nil {
		return refuse("incomplete", "the check was canceled"), nil
	}

	p := newProtector(env, fsys)
	rwp, v := p.byName(wp)
	if v.kind != protNone {
		return protectionRefusal(v, name), nil
	}
	// The folder the entry lies in must lead to a place inside the root as
	// well; a junction in between could lead anywhere.
	resolvedRoot, err := fsys.Resolve(rootP.String())
	if err != nil {
		return refuse("incomplete", "the folder shown cannot be resolved: %v", err), nil
	}
	rr, ok := parseWinPath(resolvedRoot)
	if !ok || !rwp.below(rr) {
		return refuse("outside-root", "%s leads out of the folder shown", name), nil
	}

	chain := readIDChain(fsys, wp)
	for i, l := range chain {
		if l.err != nil {
			what := "the entry"
			if i > 0 {
				what = "a folder above it"
			}
			return refuse("incomplete", "the identity of %s could not be read: %v", what, l.err), nil
		}
	}
	for i, l := range chain {
		switch l.id.Reparse {
		case ReparseLink:
			if i == 0 {
				return refuse("link", "%s is a link; links are never moved", name), nil
			}
			return refuse("link", "%s lies below a link", name), nil
		case ReparseCloud:
			if i == 0 {
				return refuse("cloud", "%s is a cloud placeholder: %s", name, cloudAdvice), nil
			}
			return refuse("cloud", "%s lies in a cloud folder: %s", name, cloudAdvice), nil
		}
	}
	if v := byIdentity(chain, readDataIDs(fsys, p.rs.data)); v.kind != protNone {
		return protectionRefusal(v, name), nil
	}
	snap := make(reviewSnapshot, len(chain))
	for i, l := range chain {
		snap[i] = l.id
	}

	if tree && (item.IsDir || chain[0].id.IsDir) {
		if ref := p.walkTree(ctx, clock, wp, rwp); ref != nil {
			return ref, nil
		}
	}
	return nil, snap
}

// refusalRank orders refusals found in a tree so that the answer does not
// depend on which worker saw what first: what is wrong with the content
// comes before what could not be read.
func refusalRank(code string) int {
	switch code {
	case "protected", "data-folder":
		return 0
	case "link":
		return 1
	case "cloud":
		return 2
	}
	return 3
}

type treeVerdict struct {
	mu  sync.Mutex
	ref *Refusal
}

func (t *treeVerdict) get() *Refusal {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.ref
}

func (t *treeVerdict) offer(r *Refusal) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.ref == nil || refusalRank(r.Code) < refusalRank(t.ref.Code) {
		t.ref = r
	}
}

type walkTask struct {
	typed, resolved winPath
	path            string
}

// walkTree reads every folder below the target, links never entered, and
// refuses at the first protected, linked or cloud entry, at a folder that
// cannot be read, and when the time budget is used up. A canceled walk is a
// refusal as well.
func (p *protector) walkTree(ctx context.Context, clock Clock, typed, resolved winPath) *Refusal {
	start := clock.Now()
	over := func() bool { return clock.Now().Sub(start) >= reviewBudget }
	wctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var tv treeVerdict

	process := func(t walkTask, push func(walkTask)) {
		if wctx.Err() != nil {
			return
		}
		if over() {
			tv.offer(refuse("incomplete", "checking the folder took too long"))
			cancel()
			return
		}
		entries, err := p.fs.ReadDir(t.path)
		if wctx.Err() != nil {
			return
		}
		if err != nil {
			tv.offer(refuse("incomplete", "%s could not be read: %v", t.path, err))
			cancel()
			return
		}
		if over() {
			tv.offer(refuse("incomplete", "checking the folder took too long"))
			cancel()
			return
		}
		for _, e := range entries {
			switch {
			case e.IsDir && e.Reparse == ReparseLink:
				tv.offer(refuse("link", "%s contains a link (%s)", t.path, e.Name))
			case e.Reparse == ReparseCloud || (e.Online && !e.IsDir):
				tv.offer(refuse("cloud", "%s contains cloud content (%s): %s", t.path, e.Name, cloudAdvice))
			}
			if p.rs.suffix[foldSeg(e.Name)] {
				ct, cr := t.typed.child(e.Name), t.resolved.child(e.Name)
				if v := p.rs.rule(ct); v.kind != protNone {
					tv.offer(protectionRefusal(v, ct.String()))
				} else if v := p.rs.rule(cr); v.kind != protNone {
					tv.offer(protectionRefusal(v, ct.String()))
				}
			}
			if e.IsDir && e.Reparse == ReparseNone {
				ct, cr := t.typed.child(e.Name), t.resolved.child(e.Name)
				push(walkTask{typed: ct, resolved: cr, path: joinWin(t.path, e.Name)})
			}
		}
		if tv.get() != nil {
			cancel()
		}
	}
	runPool(wctx, reviewWorkers, []walkTask{{typed: typed, resolved: resolved, path: typed.String()}}, process)
	if ref := tv.get(); ref != nil {
		return ref
	}
	if ctx.Err() != nil {
		return refuse("incomplete", "the check was canceled")
	}
	return nil
}

// isNotExist is errors.Is(err, fs.ErrNotExist) without the name clash with
// the FS parameter used elsewhere.
func isNotExist(err error) bool { return errors.Is(err, fs.ErrNotExist) }
