package main

import (
	"context"
	"sync"
)

// runPool processes tasks with a fixed number of workers. A task may add more
// tasks through push. The queue is last-in first-out, so a deep tree is
// walked depth first and the queue stays small. runPool returns when no task
// is left or when the context ends; tasks still queued then are dropped, and
// a worker that has begun a task finishes it.
func runPool[T any](ctx context.Context, workers int, initial []T, fn func(task T, push func(T))) {
	var mu sync.Mutex
	cond := sync.NewCond(&mu)
	stack := append([]T(nil), initial...)
	active := 0
	stopped := false

	stopWake := context.AfterFunc(ctx, func() {
		mu.Lock()
		stopped = true
		cond.Broadcast()
		mu.Unlock()
	})
	defer stopWake()

	push := func(t T) {
		mu.Lock()
		stack = append(stack, t)
		cond.Signal()
		mu.Unlock()
	}
	worker := func() {
		mu.Lock()
		defer mu.Unlock()
		for {
			for len(stack) == 0 && active > 0 && !stopped {
				cond.Wait()
			}
			if stopped || (len(stack) == 0 && active == 0) {
				cond.Broadcast()
				return
			}
			t := stack[len(stack)-1]
			stack = stack[:len(stack)-1]
			active++
			mu.Unlock()
			fn(t, push)
			mu.Lock()
			active--
			if len(stack) == 0 && active == 0 {
				cond.Broadcast()
			}
		}
	}

	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			worker()
		}()
	}
	wg.Wait()
}
