package main

// The interactive display driven through its Bubble Tea model, without a
// terminal (ST-16 inside the model, ST-17, ST-18). Commands run in goroutines
// like in the real runtime; waiting goes through the artificial clock.

import (
	"fmt"
	"os"
	"reflect"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// ---------------------------------------------------------------------------
// Command pump

func tstBatch(msg tea.Msg) []tea.Cmd {
	v := reflect.ValueOf(msg)
	if v.Kind() != reflect.Slice || v.Type().Elem() != reflect.TypeOf((tea.Cmd)(nil)) {
		return nil
	}
	cmds := make([]tea.Cmd, v.Len())
	for i := range cmds {
		cmds[i], _ = v.Index(i).Interface().(tea.Cmd)
	}
	return cmds
}

// tstFlatten runs a command and everything it batches, in order. A command
// that does not finish within a second (a measurement) yields nothing.
func tstFlatten(cmd tea.Cmd) []tea.Msg {
	if cmd == nil {
		return nil
	}
	done := make(chan []tea.Msg, 1)
	go func() {
		msg := cmd()
		if msg == nil {
			done <- nil
			return
		}
		if subs := tstBatch(msg); subs != nil {
			var out []tea.Msg
			for _, c := range subs {
				out = append(out, tstFlatten(c)...)
			}
			done <- out
			return
		}
		done <- []tea.Msg{msg}
	}()
	select {
	case out := <-done:
		return out
	case <-time.After(time.Second):
		return nil
	}
}

func tstHasQuit(msgs []tea.Msg) bool {
	for _, m := range msgs {
		if _, ok := m.(tea.QuitMsg); ok {
			return true
		}
	}
	return false
}

type tstPump struct {
	m    tea.Model
	msgs chan tea.Msg
	quit bool
	wg   sync.WaitGroup
}

func newTstPump(m tea.Model) *tstPump {
	return &tstPump{m: m, msgs: make(chan tea.Msg, 8192)}
}

func (p *tstPump) start(cmd tea.Cmd) {
	if cmd == nil {
		return
	}
	p.wg.Add(1)
	go func() {
		defer p.wg.Done()
		if msg := cmd(); msg != nil {
			p.msgs <- msg
		}
	}()
}

// drain waits for the commands still running (a save must not outlive its test folder).
func (p *tstPump) drain() {
	done := make(chan struct{})
	go func() { p.wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
	}
}

// feed delivers a message the way the runtime does; call it from one goroutine.
func (p *tstPump) feed(msg tea.Msg) {
	if _, ok := msg.(tea.QuitMsg); ok {
		p.quit = true
		return
	}
	if cmds := tstBatch(msg); cmds != nil {
		for _, c := range cmds {
			p.start(c)
		}
		return
	}
	var cmd tea.Cmd
	p.m, cmd = p.m.Update(msg)
	p.start(cmd)
}

// settle delivers command results until the condition holds.
func (p *tstPump) settle(until func() bool) bool {
	deadline := time.Now().Add(15 * time.Second)
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
		}
	}
}

// ---------------------------------------------------------------------------
// Rig

// tstManyCoreWorld has twelve processors with the usage 91, 85, ..., 25 %
// (mean 58 %), 37.5 % memory use and constant process times.
func tstManyCoreWorld(clk *fakeClock) *fakeWorld {
	w := newHealthyWorld(clk)
	w.cpu = make([]fakeCPU, 12)
	w.cpuSteps = make([]fakeCPU, 12)
	for i := range w.cpuSteps {
		usage := 91 - 6*i
		w.cpuSteps[i] = fakeCPU{Idle: uint64(100-usage) * 100_000, Total: 10_000_000}
	}
	w.physical = 6
	w.procStep = 0
	w.memTotal, w.memAvail = 16*tstGiB, 10*tstGiB
	return w
}

func tstCoreRowsOf12(view string) int {
	n := 0
	for i := 0; i < 12; i++ {
		n += strings.Count(view, fmt.Sprintf("%.1f%%", float64(91-6*i)))
	}
	return n
}

type tstRig struct {
	t     *testing.T
	clk   *fakeClock
	w     *fakeWorld
	e     tstEnv
	prefs *PrefsStore
	p     *tstPump
}

func tstNewRig(t *testing.T, prefsText string, tweak func(w *fakeWorld)) *tstRig {
	t.Helper()
	e := tstIsolated(t)
	if prefsText != "" {
		e.writePrefs(t, prefsText)
	}
	return tstNewRigIn(t, e, tweak)
}

func tstNewRigIn(t *testing.T, e tstEnv, tweak func(w *fakeWorld)) *tstRig {
	t.Helper()
	clk := newFakeClock()
	w := tstManyCoreWorld(clk)
	if tweak != nil {
		tweak(w)
	}
	prefs := tstOpenPrefs(e.env)
	m := tstNewModel(w, clk, prefs)
	r := &tstRig{t: t, clk: clk, w: w, e: e, prefs: prefs, p: newTstPump(m)}
	t.Cleanup(func() {
		w.releaseCPU()
		r.p.drain()
	})
	return r
}

func (r *tstRig) view() string { return r.p.m.View() }

// boot starts the model and waits for the first measurement on screen.
func (r *tstRig) boot(width, height int) {
	r.t.Helper()
	r.p.start(r.p.m.Init())
	r.p.feed(tea.WindowSizeMsg{Width: width, Height: height})
	if !r.p.settle(func() bool { return strings.Contains(r.view(), "10.0GB") }) {
		r.t.Fatalf("the first measurement never appeared:\n%s", r.view())
	}
}

// freeze lets the next measurement block inside its CPU reading; the display
// then stays on the last result.
func (r *tstRig) freeze() int {
	r.t.Helper()
	r.w.holdCPU()
	if !r.p.settle(func() bool { n, _ := r.w.blockedCPU(); return n >= 1 }) {
		r.t.Fatalf("no measurement is running")
	}
	return r.w.readCount("cpu")
}

func (r *tstRig) thaw() { r.w.releaseCPU() }

func (r *tstRig) press(ch rune) {
	r.p.feed(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{ch}})
}

func tstWaitForFile(t *testing.T, path, want string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	var got string
	for time.Now().Before(deadline) {
		if b, err := os.ReadFile(path); err == nil {
			got = string(b)
			if got == want {
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Errorf("settings file = %q, want %q", got, want)
}

// ---------------------------------------------------------------------------
// ST-16: first frames

func TestDashboardShowsOnlyALoadingHintBeforeTheFirstMeasurement(t *testing.T) {
	r := tstNewRig(t, "", nil)
	view := r.view()
	if strings.TrimSpace(view) == "" {
		t.Errorf("the view is empty before the first measurement")
	}
	for _, re := range []string{`[0-9]%`, `[0-9](B|KB|MB|GB|TB)\b`} {
		if regexp.MustCompile(re).MatchString(view) {
			t.Errorf("the view shows measured values before any measurement: %q", view)
		}
	}
	r.w.holdCPU()
	r.p.start(r.p.m.Init())
	r.p.feed(tea.WindowSizeMsg{Width: 100, Height: 50})
	if !r.p.settle(func() bool { n, _ := r.w.blockedCPU(); return n == 1 }) {
		t.Fatal("the first measurement did not start")
	}
	if regexp.MustCompile(`[0-9]%`).MatchString(r.view()) {
		t.Errorf("the view shows values while the first measurement is running: %q", r.view())
	}
	r.thaw()
	if !r.p.settle(func() bool { return strings.Contains(r.view(), "10.0GB") }) {
		t.Fatalf("the first measurement never appeared:\n%s", r.view())
	}
}

func TestDashboardShowsTheMeasurementAfterItArrives(t *testing.T) {
	r := tstNewRig(t, "", nil)
	r.boot(100, 60)
	view := r.view()
	for _, tok := range []string{"58.0%", "91.0%", "85.0%", "37.5%", "10.0GB", "16.0GB", `C:\`, "1d 2h"} {
		if !strings.Contains(view, tok) {
			t.Errorf("the view does not contain %q:\n%s", tok, view)
		}
	}
}

func TestDashboardShowsTheDefaultAddressOnlyOnScreen(t *testing.T) {
	r := tstNewRig(t, "", func(w *fakeWorld) {
		w.adapters = []fakeAdapter{
			{Name: "Ethernet", IPv4: []string{"169.254.7.9", "127.0.0.1", "192.0.2.17", "192.0.2.99"}, Default: true},
			{Name: "WLAN", IPv4: []string{"198.51.100.7"}},
		}
		w.nets = []fakeNet{{Name: "Ethernet"}, {Name: "WLAN"}}
	})
	r.boot(100, 60)
	view := r.view()
	if !strings.Contains(view, "192.0.2.17") {
		t.Errorf("the address of the default adapter is not shown:\n%s", view)
	}
	for _, other := range []string{"169.254.7.9", "127.0.0.1", "192.0.2.99", "198.51.100.7"} {
		if strings.Contains(view, other) {
			t.Errorf("the view shows %s, which is not the first usable address of the default adapter", other)
		}
	}
}

func TestDashboardShowsNoAddressWhenNoneIsKnown(t *testing.T) {
	r := tstNewRig(t, "", func(w *fakeWorld) {
		w.adapters = []fakeAdapter{{Name: "Ethernet", Default: true}}
		w.nets = []fakeNet{{Name: "Ethernet"}}
	})
	r.boot(100, 60)
	if m := regexp.MustCompile(`\b\d{1,3}(\.\d{1,3}){3}\b`).FindString(r.view()); m != "" {
		t.Errorf("the view shows an address %q although none is known", m)
	}
}

// ---------------------------------------------------------------------------
// ST-17: keys

func TestDashboardQuitKeysEndTheDisplay(t *testing.T) {
	keys := map[string]tea.KeyMsg{
		"q":      {Type: tea.KeyRunes, Runes: []rune{'q'}},
		"Esc":    {Type: tea.KeyEsc},
		"Ctrl+C": {Type: tea.KeyCtrlC},
	}
	for name, key := range keys {
		r := tstNewRig(t, "", nil)
		_, cmd := r.p.m.Update(key)
		if !tstHasQuit(tstFlatten(cmd)) {
			t.Errorf("%s does not quit", name)
		}
	}
}

func TestDashboardQuitsPromptlyWhileAMeasurementIsRunning(t *testing.T) {
	r := tstNewRig(t, "", nil)
	r.boot(100, 60)
	r.freeze()
	defer r.thaw()
	start := time.Now()
	_, cmd := r.p.m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'q'}})
	if !tstHasQuit(tstFlatten(cmd)) {
		t.Errorf("q does not quit while a measurement is running")
	}
	if d := time.Since(start); d > time.Second {
		t.Errorf("quitting took %v", d)
	}
}

func TestDashboardOtherKeysDoNothing(t *testing.T) {
	r := tstNewRig(t, "cat_hidden=1\ncpu_cores=4\n", nil)
	r.boot(100, 60)
	r.freeze()
	defer r.thaw()
	before := r.view()
	keys := []tea.KeyMsg{
		{Type: tea.KeyRunes, Runes: []rune{'k'}},
		{Type: tea.KeyRunes, Runes: []rune{'K'}},
		{Type: tea.KeyRunes, Runes: []rune{'x'}},
		{Type: tea.KeyRunes, Runes: []rune{'1'}},
		{Type: tea.KeyRunes, Runes: []rune{' '}},
		{Type: tea.KeyRunes, Runes: []rune{'?'}},
		{Type: tea.KeyEnter},
		{Type: tea.KeyTab},
		{Type: tea.KeyUp},
		{Type: tea.KeyDown},
	}
	for _, key := range keys {
		m, cmd := r.p.m.Update(key)
		r.p.m = m
		if tstHasQuit(tstFlatten(cmd)) {
			t.Errorf("key %q quits", key.String())
		}
		if after := r.view(); after != before {
			t.Errorf("key %q changed the view", key.String())
		}
	}
	time.Sleep(50 * time.Millisecond)
	if got := r.e.readPrefs(t); got != "cat_hidden=1\ncpu_cores=4\n" {
		t.Errorf("settings file changed to %q by keys without function", got)
	}
}

func TestDashboardCKeyStepsThroughTwoFourEightAllTwo(t *testing.T) {
	r := tstNewRig(t, "", nil)
	r.boot(100, 60)
	r.freeze()
	defer r.thaw()
	if n := tstCoreRowsOf12(r.view()); n != 2 {
		t.Fatalf("default shows %d core rows, want 2", n)
	}
	steps := []struct {
		rows int
		file string
	}{
		{4, "cpu_cores=4\n"},
		{8, "cpu_cores=8\n"},
		{12, "cpu_cores=0\n"},
		{2, "cpu_cores=2\n"},
	}
	for i, s := range steps {
		r.press('c')
		if n := tstCoreRowsOf12(r.view()); n != s.rows {
			t.Errorf("after press %d the view shows %d core rows, want %d", i+1, n, s.rows)
		}
		tstWaitForFile(t, r.e.prefsFile(), s.file)
	}
}

func TestDashboardCKeyFromAValueOutsideTheSequenceJumpsToTwo(t *testing.T) {
	for _, start := range []string{"3", "5", "16", "1"} {
		r := tstNewRig(t, "cpu_cores="+start+"\n", nil)
		r.boot(100, 60)
		r.freeze()
		r.press('c')
		if n := tstCoreRowsOf12(r.view()); n != 2 {
			t.Errorf("cpu_cores=%s: after c the view shows %d core rows, want 2", start, n)
		}
		tstWaitForFile(t, r.e.prefsFile(), "cpu_cores=2\n")
		r.thaw()
	}
}

func TestDashboardReadsTheCoreCountFromTheSettingsFile(t *testing.T) {
	cases := []struct {
		content string
		rows    int
	}{
		{"", 2},
		{"cpu_cores=4\n", 4},
		{"cpu_cores=8\n", 8},
		{"cpu_cores=0\n", 12},
		{"cpu_cores=3\n", 3},
		{"cpu_cores=16\n", 12},
		{"cpu_cores=abc\n", 2},
		{"cpu_cores=-3\n", 2},
		{"cpu_cores=\n", 2},
		{"x=1\n", 2},
		{"# comment\r\n\r\ncpu_cores = 4 \r\n", 4},
		{"cpu_cores\ncpu_cores=3\n", 3},
	}
	for _, c := range cases {
		r := tstNewRig(t, c.content, nil)
		r.boot(100, 60)
		r.freeze()
		if n := tstCoreRowsOf12(r.view()); n != c.rows {
			t.Errorf("settings %q: %d core rows, want %d", c.content, n, c.rows)
		}
		r.thaw()
	}
}

func TestDashboardCKeyKeepsOtherKeysAndSortsThem(t *testing.T) {
	r := tstNewRig(t, "# note\r\ncat_hidden=1\nzeta = 9 \n\nnoequals\ncpu_cores=4\n", nil)
	r.boot(100, 60)
	r.freeze()
	defer r.thaw()
	r.press('c')
	tstWaitForFile(t, r.e.prefsFile(), "cat_hidden=1\ncpu_cores=8\nzeta=9\n")
}

func TestDashboardCKeyWorksWhenTheSettingsCannotBeSaved(t *testing.T) {
	e := tstIsolated(t)
	if err := os.WriteFile(e.data, []byte("a file where the data folder should be"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := tstNewRigIn(t, e, nil)
	r.boot(100, 60)
	r.freeze()
	defer r.thaw()
	for i, rows := range []int{4, 8, 12, 2} {
		r.press('c')
		if n := tstCoreRowsOf12(r.view()); n != rows {
			t.Errorf("press %d: %d core rows, want %d (the value holds until the display ends)", i+1, n, rows)
		}
	}
}

func TestDashboardCKeyWorksWithoutAnySettingsFolder(t *testing.T) {
	root := t.TempDir()
	t.Chdir(root)
	t.Setenv("HOME", "")
	t.Setenv("USERPROFILE", "")
	e := tstEnv{root: root, env: map[string]string{}}
	r := tstNewRigIn(t, e, nil)
	r.boot(100, 60)
	r.freeze()
	defer r.thaw()
	r.press('c')
	if n := tstCoreRowsOf12(r.view()); n != 4 {
		t.Errorf("%d core rows after c, want 4", n)
	}
	time.Sleep(50 * time.Millisecond)
	entries, _ := os.ReadDir(root)
	if len(entries) != 0 {
		t.Errorf("files were written without a settings folder: %v", entries)
	}
}

func TestDashboardDoesNotCreateTheSettingsFileByItself(t *testing.T) {
	r := tstNewRig(t, "", nil)
	r.boot(100, 60)
	r.p.settle(func() bool { return r.w.readCount("cpu") >= 5 })
	r.e.assertUntouched(t)
}

// ---------------------------------------------------------------------------
// ST-18: refresh

func TestDashboardStartsTheFirstMeasurementAtOnce(t *testing.T) {
	r := tstNewRig(t, "", nil)
	r.boot(100, 60)
	reads := r.w.readTimes("cpu")
	if len(reads) < 2 {
		t.Fatalf("CPU source read %d times", len(reads))
	}
	if gap := reads[1].Sub(reads[0]); gap > 260*time.Millisecond {
		t.Errorf("the first measurement started %v after the start, want only the 250ms window", gap)
	}
}

func TestDashboardStartsTheNextMeasurementOneSecondAfterTheLastEnded(t *testing.T) {
	r := tstNewRig(t, "", func(w *fakeWorld) { w.cost = 400 * time.Millisecond })
	r.boot(100, 60)
	r.p.settle(func() bool { return r.w.readCount("cpu") >= 6 })
	reads := r.w.readTimes("cpu")
	if len(reads) < 6 {
		t.Fatalf("only %d CPU readings", len(reads))
	}
	for i := 2; i < len(reads); i++ {
		if gap, want := reads[i].Sub(reads[i-1]), 1400*time.Millisecond; gap != want {
			t.Errorf("measurements %d and %d start %v apart, want %v (1 s after the previous one ended; waiting goes through the clock)", i-1, i, gap, want)
		}
	}
}

func TestDashboardRunsOneMeasurementAtATimeAndStaysResponsive(t *testing.T) {
	r := tstNewRig(t, "", nil)
	r.boot(100, 60)
	n := r.freeze()
	released := false
	defer func() {
		if !released {
			r.thaw()
		}
	}()

	start := time.Now()
	r.press('c')
	r.p.feed(tea.WindowSizeMsg{Width: 70, Height: 40})
	r.press('x')
	r.p.feed(tea.WindowSizeMsg{Width: 90, Height: 50})
	r.press('c')
	if d := time.Since(start); d > time.Second {
		t.Errorf("keys and size changes took %v while a measurement was running", d)
	}
	if rows := tstCoreRowsOf12(r.view()); rows != 8 {
		t.Errorf("two presses of c during a measurement show %d core rows, want 8", rows)
	}

	time.Sleep(150 * time.Millisecond)
	if got := r.w.readCount("cpu"); got != n {
		t.Errorf("a second measurement started while one was running: %d CPU readings, want %d", got, n)
	}
	if _, max := r.w.blockedCPU(); max != 1 {
		t.Errorf("%d measurements ran at the same time", max)
	}

	r.thaw()
	released = true
	r.p.settle(func() bool { return r.w.readCount("cpu") >= n+4 })
	if _, max := r.w.blockedCPU(); max != 1 {
		t.Errorf("%d measurements ran at the same time", max)
	}
}

func TestDashboardRedrawsAtOnceWhenTheWindowChanges(t *testing.T) {
	r := tstNewRig(t, "cpu_cores=0\n", nil)
	r.boot(100, 60)
	r.freeze()
	defer r.thaw()
	for _, sz := range [][2]int{{40, 12}, {60, 24}, {200, 80}, {80, 24}, {30, 10}} {
		r.p.feed(tea.WindowSizeMsg{Width: sz[0], Height: sz[1]})
		view := r.view()
		tstAssertFits(t, view, sz[0], sz[1])
		if !regexp.MustCompile(`[0-9]%`).MatchString(view) {
			t.Errorf("window %dx%d: the view shows no measured value after the change:\n%s", sz[0], sz[1], view)
		}
	}
	r.p.feed(tea.WindowSizeMsg{Width: 200, Height: 80})
	if n := tstCoreRowsOf12(r.view()); n != 12 {
		t.Errorf("after enlarging the window %d core rows are shown, want the saved 12", n)
	}
}

func TestDashboardAssumesTheDefaultSizeUntilTheWindowSizeIsKnown(t *testing.T) {
	r := tstNewRig(t, "cpu_cores=0\n", nil)
	r.p.start(r.p.m.Init())
	if !r.p.settle(func() bool { return strings.Contains(r.view(), "10.0GB") || r.w.readCount("cpu") > 3 }) {
		t.Fatal("no measurement arrived")
	}
	tstAssertFits(t, r.view(), 0, 0)
}

func TestDashboardMarksAnAreaUnavailableInsteadOfKeepingTheOldValue(t *testing.T) {
	cases := []struct {
		name   string
		fail   func(w *fakeWorld)
		gone   []string
		stays  []string
		before string // token proving the area was measured first
	}{
		{"cpu", func(w *fakeWorld) { w.cpuErr = errFakeUnavailable }, []string{"58.0%", "91.0%", "85.0%"}, []string{"10.0GB", "37.5%", `C:\`}, "58.0%"},
		{"network", func(w *fakeWorld) { w.netErr = errFakeUnavailable }, []string{"3.0MB/s"}, []string{"10.0GB", "58.0%", "20MB/s"}, "3.0MB/s"},
		{"disk counters", func(w *fakeWorld) { w.diskErr = errFakeUnavailable }, []string{"20MB/s"}, []string{"10.0GB", "58.0%", "3.0MB/s"}, "20MB/s"},
		{"memory", func(w *fakeWorld) { w.memErr = errFakeUnavailable }, []string{"10.0GB", "37.5%"}, []string{"58.0%", `C:\`}, "37.5%"},
	}
	for _, c := range cases {
		c := c
		t.Run(c.name, func(t *testing.T) {
			r := tstNewRig(t, "", nil)
			r.boot(100, 60)
			if !r.p.settle(func() bool { return strings.Contains(r.view(), c.before) }) {
				t.Fatalf("%q never appeared:\n%s", c.before, r.view())
			}
			r.w.set(func() { c.fail(r.w) })
			gone := func() bool {
				v := r.view()
				for _, tok := range c.gone {
					if strings.Contains(v, tok) {
						return false
					}
				}
				return true
			}
			if !r.p.settle(gone) {
				t.Fatalf("the old values stay on screen after the source failed:\n%s", r.view())
			}
			r.p.settle(func() bool { return r.w.readCount("cpu") >= 12 })
			if !gone() {
				t.Errorf("an old value returned:\n%s", r.view())
			}
			for _, tok := range c.stays {
				if !strings.Contains(r.view(), tok) {
					t.Errorf("another area changed: %q is gone:\n%s", tok, r.view())
				}
			}
		})
	}
}

func TestDashboardKeepsItsHistoryWithinTheWindowOverManyMeasurements(t *testing.T) {
	r := tstNewRig(t, "", nil)
	r.boot(60, 24)
	if !r.p.settle(func() bool { return r.w.readCount("cpu") >= 135 }) {
		t.Fatalf("only %d measurements ran", r.w.readCount("cpu"))
	}
	r.freeze()
	defer r.thaw()
	tstAssertFits(t, r.view(), 60, 24)
	if !strings.Contains(r.view(), "10.0GB") {
		t.Errorf("the memory section disappeared after many measurements:\n%s", r.view())
	}
}
