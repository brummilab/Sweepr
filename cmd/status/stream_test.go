package main

// The JSON stream of --watch (ST-15).

import (
	"bytes"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"
)

// tstLineLimitWriter accepts exactly limit complete lines and fails on every
// byte after that, like a reader that has gone away.
type tstLineLimitWriter struct {
	limit  int
	onLine func(n int) // called after each accepted line

	mu  sync.Mutex
	buf bytes.Buffer
	n   int
}

var errReaderGone = errors.New("reader gone")

func (w *tstLineLimitWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	accepted := 0
	for _, b := range p {
		if w.n >= w.limit {
			return accepted, errReaderGone
		}
		w.buf.WriteByte(b)
		accepted++
		if b == '\n' {
			w.n++
			if w.onLine != nil {
				w.onLine(w.n)
			}
		}
	}
	return accepted, nil
}

// lines returns the accepted lines without their terminator.
func (w *tstLineLimitWriter) lines() []string {
	w.mu.Lock()
	defer w.mu.Unlock()
	s := w.buf.String()
	if s == "" {
		return nil
	}
	return strings.Split(strings.TrimSuffix(s, "\n"), "\n")
}

func (w *tstLineLimitWriter) raw() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.buf.String()
}

func tstWatch(t *testing.T, w *fakeWorld, clk *fakeClock, args []string, e tstEnv, limit int) (*tstLineLimitWriter, string, int) {
	t.Helper()
	out := &tstLineLimitWriter{limit: limit}
	var errOut bytes.Buffer
	code := tstRunWith(t, w, clk, args, e.env, false, out, &errOut)
	return out, errOut.String(), code
}

func TestWatchWritesOneCompactJSONLinePerMeasurement(t *testing.T) {
	e := tstIsolated(t)
	clk := newFakeClock()
	w := newHealthyWorld(clk)
	out, stderr, code := tstWatch(t, w, clk, []string{"--watch"}, e, 3)
	if code != 0 {
		t.Fatalf("exit code %d, want 0 once the reader is gone", code)
	}
	if stderr != "" {
		t.Errorf("stderr = %q, want empty (no message when stdout closes)", stderr)
	}
	raw := out.raw()
	if strings.HasPrefix(raw, "\xef\xbb\xbf") || strings.ContainsRune(raw, 0x1b) || strings.Contains(raw, "\r") {
		t.Errorf("stream contains a byte-order mark, control sequence or carriage return")
	}
	lines := out.lines()
	if len(lines) != 3 {
		t.Fatalf("%d lines, want 3 (and no fourth after the failure)", len(lines))
	}
	for i, l := range lines {
		if l == "" || l[0] == ' ' || l[0] == '\t' || !strings.HasPrefix(l, "{") || !strings.HasSuffix(l, "}") {
			t.Errorf("line %d is not a compact object: %q", i, l)
			continue
		}
		doc := tstDecode(t, []byte(l))
		for _, k := range tstTopLevelKeys {
			if _, ok := doc[k]; !ok {
				t.Errorf("line %d: key %q missing", i, k)
			}
		}
		for _, k := range tstTopLevelKeys {
			tstWantNotNull(t, doc, k)
		}
	}
	e.assertUntouched(t)
}

func TestWatchPrintsTheFirstEntryAfterTheMinimumWindowOnly(t *testing.T) {
	e := tstIsolated(t)
	clk := newFakeClock()
	w := newHealthyWorld(clk)
	var sleptAtFirst time.Duration
	out := &tstLineLimitWriter{limit: 2}
	out.onLine = func(n int) {
		if n == 1 {
			sleptAtFirst = clk.totalSlept()
		}
	}
	var errOut bytes.Buffer
	if code := tstRunWith(t, w, clk, []string{"--watch", "--interval=10s"}, e.env, false, out, &errOut); code != 0 {
		t.Fatalf("exit code %d", code)
	}
	if sleptAtFirst > 300*time.Millisecond {
		t.Errorf("slept %v before the first entry, want only the 250ms window", sleptAtFirst)
	}
}

func TestWatchWaitsTheIntervalAfterEachMeasurementEnds(t *testing.T) {
	cases := []struct {
		name     string
		args     []string
		interval time.Duration
	}{
		{"default of one second", []string{"--watch"}, time.Second},
		{"equals form", []string{"--watch", "--interval=2s"}, 2 * time.Second},
		{"separate form", []string{"--watch", "--interval", "2s"}, 2 * time.Second},
		{"milliseconds", []string{"--watch", "--interval=500ms"}, 500 * time.Millisecond},
		{"single dash", []string{"-watch", "-interval=2m"}, 2 * time.Minute},
	}
	const measurement = 300 * time.Millisecond
	for _, c := range cases {
		c := c
		t.Run(c.name, func(t *testing.T) {
			e := tstIsolated(t)
			clk := newFakeClock()
			w := newHealthyWorld(clk)
			w.cost = measurement // every CPU reading takes 300 ms of artificial time
			_, _, code := tstWatch(t, w, clk, c.args, e, 4)
			if code != 0 {
				t.Fatalf("exit code %d", code)
			}
			reads := w.readTimes("cpu")
			if len(reads) < 5 {
				t.Fatalf("CPU source read %d times, want one per entry plus the first reading", len(reads))
			}
			// reads[0] is the first counter reading; from reads[1] on one per measurement.
			for i := 2; i < len(reads); i++ {
				gap := reads[i].Sub(reads[i-1])
				want := measurement + c.interval
				if gap != want {
					t.Errorf("measurements %d and %d start %v apart, want %v (the interval after the previous one ended)", i-1, i, gap, want)
				}
			}
		})
	}
}

func TestWatchWritesAnEntryEvenWhenEveryAreaIsNull(t *testing.T) {
	e := tstIsolated(t)
	clk := newFakeClock()
	w := newHealthyWorld(clk)
	w.failAll()
	out, stderr, code := tstWatch(t, w, clk, []string{"--watch"}, e, 3)
	if code != 0 {
		t.Fatalf("exit code %d, want 0", code)
	}
	lines := out.lines()
	if len(lines) != 3 {
		t.Fatalf("%d lines, want 3 (an entry is written even with nothing measurable)", len(lines))
	}
	for i, l := range lines {
		doc := tstDecode(t, []byte(l))
		tstWantNotNull(t, doc, "collected_at")
		for _, k := range tstTopLevelKeys[1:] {
			tstWantNull(t, doc, k)
		}
		_ = i
	}
	if !strings.Contains(strings.ToLower(stderr), "cpu") {
		t.Errorf("stderr %q does not name the failed areas", stderr)
	}
}

func tstCountLinesMentioning(text, word string) int {
	n := 0
	for _, l := range strings.Split(text, "\n") {
		if strings.Contains(strings.ToLower(l), word) {
			n++
		}
	}
	return n
}

func TestWatchReportsAnOutageOncePerPhase(t *testing.T) {
	e := tstIsolated(t)
	clk := newFakeClock()
	w := newHealthyWorld(clk)
	// CPU reading 1 is the counter reading at creation. Sample n uses reading n+1.
	failing := map[int]bool{4: true, 5: true, 9: true} // samples 3, 4 and 8
	w.onRead = func(w *fakeWorld, src string, n int) {
		if src == "cpu" {
			if failing[n] {
				w.cpuErr = errFakeUnavailable
			} else {
				w.cpuErr = nil
			}
		}
	}
	const entries = 11
	out, stderr, code := tstWatch(t, w, clk, []string{"--watch"}, e, entries)
	if code != 0 {
		t.Fatalf("exit code %d", code)
	}
	lines := out.lines()
	if len(lines) != entries {
		t.Fatalf("%d lines, want %d", len(lines), entries)
	}
	// Phases are the runs of null cpu entries in the stream itself.
	phases := 0
	inPhase := false
	for i, l := range lines {
		doc := tstDecode(t, []byte(l))
		v, ok := doc["cpu"]
		if !ok {
			t.Fatalf("line %d has no cpu key", i)
		}
		if v == nil {
			if !inPhase {
				phases++
			}
			inPhase = true
		} else {
			inPhase = false
		}
		for _, k := range []string{"memory", "disks", "disk_io", "network_total", "uptime_seconds"} {
			tstWantNotNull(t, doc, k)
		}
	}
	if phases != 2 {
		t.Fatalf("stream shows %d outage phases of the CPU, want 2 (test setup)", phases)
	}
	if got := tstCountLinesMentioning(stderr, "cpu"); got != phases {
		t.Errorf("stderr mentions the CPU outage on %d lines, want %d (once per phase):\n%s", got, phases, stderr)
	}
	for _, other := range []string{"memory", "disk", "network", "process"} {
		if tstCountLinesMentioning(stderr, other) != 0 {
			t.Errorf("stderr mentions %q although that area never failed:\n%s", other, stderr)
		}
	}
}

func TestWatchReportsALastingOutageOnlyOnce(t *testing.T) {
	e := tstIsolated(t)
	clk := newFakeClock()
	w := newHealthyWorld(clk)
	w.procsErr = errFakeUnavailable
	out, stderr, code := tstWatch(t, w, clk, []string{"--watch"}, e, 5)
	if code != 0 {
		t.Fatalf("exit code %d", code)
	}
	for i, l := range out.lines() {
		doc := tstDecode(t, []byte(l))
		tstWantNull(t, doc, "top_processes")
		tstWantNull(t, doc, "procs")
		tstWantNotNull(t, doc, "cpu")
		_ = i
	}
	if got := tstCountLinesMentioning(stderr, "process"); got != 1 {
		t.Errorf("stderr names the process outage on %d lines, want 1:\n%s", got, stderr)
	}
}

func TestWatchStopsAtOnceWhenTheFirstWriteFails(t *testing.T) {
	e := tstIsolated(t)
	clk := newFakeClock()
	w := newHealthyWorld(clk)
	var errOut bytes.Buffer
	code := tstRunWith(t, w, clk, []string{"--watch"}, e.env, false, &tstLineLimitWriter{limit: 0}, &errOut)
	if code != 0 {
		t.Errorf("exit code %d, want 0", code)
	}
	if errOut.Len() != 0 {
		t.Errorf("stderr = %q, want empty", errOut.String())
	}
}

func TestWatchEntriesAreValidJSONWithNumbersAsNumbers(t *testing.T) {
	e := tstIsolated(t)
	clk := newFakeClock()
	w := newHealthyWorld(clk)
	out, _, _ := tstWatch(t, w, clk, []string{"--watch"}, e, 2)
	for _, l := range out.lines() {
		dec := json.NewDecoder(strings.NewReader(l))
		dec.UseNumber()
		var doc map[string]any
		if err := dec.Decode(&doc); err != nil {
			t.Fatalf("invalid JSON line %q: %v", l, err)
		}
		if _, ok := doc["procs"].(json.Number); !ok {
			t.Errorf("procs = %#v, want a JSON number", doc["procs"])
		}
	}
}
