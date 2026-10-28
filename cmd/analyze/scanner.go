package main

import "context"

// ScanEvent is one step of a measurement as the display sees it.
type ScanEvent struct {
	// Item is a child that just finished.
	Item *Item
	// Listing is the final result; no event follows it.
	Listing *Listing
	// Err ends the measurement without a result; no event follows it.
	Err error
	// Ready and Pending come first when the scanner knows the children before
	// it has measured them: Ready are children that are already final
	// (files, links), Pending are folders whose size is still being worked
	// out. The display shows those as "scanning".
	Ready   []Item
	Pending []Item
}

// Scanner measures a folder in the background. It sends one event per
// finished child and ends with the Listing or an error, then closes the
// channel. When the context ends the channel is closed without a final event.
type Scanner interface {
	Scan(ctx context.Context, root string, c *Counters) <-chan ScanEvent
}

// fsScanner is the scanner used unless one is injected. It reads the children
// of the root first, so that they can be listed at once, and then measures
// the folders among them.
type fsScanner struct{ fs FS }

func (s fsScanner) Scan(ctx context.Context, root string, c *Counters) <-chan ScanEvent {
	ch := make(chan ScanEvent, 256)
	send := func(ev ScanEvent) {
		select {
		case ch <- ev:
		case <-ctx.Done():
		}
	}
	go func() {
		defer close(ch)
		l, err := measureTree(ctx, s.fs, root, c, measureHooks{
			onList: func(ready, pending []Item) {
				send(ScanEvent{Ready: ready, Pending: pending})
			},
			onChild: func(it Item) {
				send(ScanEvent{Item: &it})
			},
		})
		if ctx.Err() != nil {
			return
		}
		if err != nil {
			send(ScanEvent{Err: err})
			return
		}
		send(ScanEvent{Listing: &l})
	}()
	return ch
}
