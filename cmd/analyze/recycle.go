package main

import (
	"context"
	"fmt"
)

// Outcome is what happened to one entry.
type Outcome int

const (
	// Recycled: the entry is in the Recycle Bin.
	Recycled Outcome = iota
	// Skipped: a check refused the entry; nothing was changed.
	Skipped
	// Failed: the Recycle Bin call failed; the entry is still there.
	Failed
	// Gone: the entry was no longer there; nothing was called.
	Gone
)

func (o Outcome) String() string {
	switch o {
	case Recycled:
		return "recycled"
	case Skipped:
		return "skipped"
	case Failed:
		return "failed"
	case Gone:
		return "gone"
	}
	return fmt.Sprintf("outcome(%d)", int(o))
}

// Result is the outcome of one entry with the reason, when there is one.
type Result struct {
	Outcome Outcome
	Reason  string
}

// dryRun is true only for the exact value 1; anything else is a real run.
func dryRun(env map[string]string) bool { return env["SWEEPR_DRY_RUN"] == "1" }

// RecycleItems moves the entries of the list of root to the Recycle Bin, one
// after the other in the order given. Per entry: the path is checked as text;
// an entry that no longer exists counts as gone, without a call and without a
// log line; the entry is reviewed (identities bound, tree read) and reviewed
// again right before the call, and a changed identity refuses it; then the
// Recycle Bin is called. Every entry that got an outcome gets one log line;
// an interrupted entry gets none.
//
// With the dry-run variable set nothing is checked, called or logged. When
// the context ends, no further call starts; a call that has begun runs to its
// end and its entry is not logged, because nobody saw its result.
func RecycleItems(ctx context.Context, deps Deps, env map[string]string, root string, items []Item, log *OpLog) []Result {
	if deps.Clock == nil {
		deps.Clock = systemClock{}
	}
	results := make([]Result, len(items))
	if dryRun(env) {
		for i := range results {
			results[i] = Result{Skipped, "dry run: nothing was moved"}
		}
		return results
	}
	for i := range results {
		results[i] = Result{Skipped, "canceled"}
	}
	for i, it := range items {
		if ctx.Err() != nil {
			return results
		}
		res, interrupted := recycleOne(ctx, deps, env, root, it, log)
		results[i] = res
		if interrupted {
			return results
		}
	}
	return results
}

func skipEntry(log *OpLog, it Item, text string) Result {
	log.Record("SKIPPED", it.Path, "refused: "+text)
	return Result{Skipped, text}
}

// sizeDetail is the size as the log and the dialogs show it: a trailing plus
// marks a partial measurement, and an entry without a measured size says so.
func sizeDetail(it Item) string {
	switch {
	case !it.measured():
		return "not measured"
	case it.State == Partial:
		return FormatSize(it.Size) + "+"
	}
	return FormatSize(it.Size)
}

func recycleOne(ctx context.Context, deps Deps, env map[string]string, root string, it Item, log *OpLog) (res Result, interrupted bool) {
	if why := invalidPath(it.Path); why != "" {
		return skipEntry(log, it, why), false
	}
	if _, err := deps.FS.Identity(it.Path); err != nil && isNotExist(err) {
		return Result{Gone, "it was already gone"}, false
	}
	// The first review binds the identities; the second, right before the
	// call, must find the same objects and the same tree.
	ref, bound := reviewEntry(ctx, deps.FS, deps.Clock, env, root, it.Path, it, true)
	if ctx.Err() != nil {
		return Result{Skipped, "canceled"}, true
	}
	if ref != nil {
		return skipEntry(log, it, ref.Text), false
	}
	ref, now := reviewEntry(ctx, deps.FS, deps.Clock, env, root, it.Path, it, true)
	if ctx.Err() != nil {
		return Result{Skipped, "canceled"}, true
	}
	if ref == nil && !bound.same(now) {
		ref = refuse("changed", "the folder changed while it was being checked")
	}
	if ref != nil {
		return skipEntry(log, it, ref.Text), false
	}

	err := deps.Recycler.Recycle(it.Path)
	if ctx.Err() != nil {
		return Result{Skipped, "canceled"}, true
	}
	if err != nil {
		reason := err.Error()
		if reason == "" {
			reason = "unknown error"
		}
		log.Record("FAILED", it.Path, sizeDetail(it)+"; "+reason)
		return Result{Failed, reason}, false
	}
	log.Record("RECYCLED", it.Path, sizeDetail(it))
	return Result{Recycled, ""}, false
}
