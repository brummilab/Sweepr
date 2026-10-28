package main

// Fixtures shared by the status tests.
//
// Everything that depends on the exact shape of the production seams is
// concentrated in the tst* adapter functions of this file. The seams are
// Sources, Clock, NewSampler/Sampler, Snapshot, Run, RenderFrame,
// dashboardModel and PrefsStore/OpenPrefs; the reading types, Settings,
// newDashboardModel and all field names below are this file's assumption and
// are the only place to change if the production code names them differently:
//
//	type Sources struct {
//		CPU         func() (CPUReading, error)         // PerCPU []CPUTimes{Idle, Total uint64}, PhysicalCores int (0 = unknown)
//		Memory      func() (MemoryReading, error)      // Total, Available uint64
//		Swap        func() (SwapReading, error)        // Used, Total uint64
//		Drives      func() ([]DriveReading, error)     // Name, Total, Free uint64, FSType string, Removable bool
//		DiskIO      func() (DiskIOReading, error)      // ReadBytes, WriteBytes uint64 (cumulative)
//		NetCounters func() ([]NetCounterReading, error) // Name string, RxBytes, TxBytes uint64 (cumulative)
//		Adapters    func() ([]AdapterReading, error)   // Name string, IPv4 []string, DefaultRoute, Tunnel bool
//		Processes   func() ([]ProcessReading, error)   // PID uint32, Name string, StartTime, CPUTime, PrivateBytes uint64
//		Uptime      func() (time.Duration, error)
//		Platform    func() (string, error)
//	}
//	type Clock interface { Now() time.Time; Sleep(d time.Duration) }
//	func NewSampler(Sources, Clock) *Sampler
//	func (*Sampler) Sample() (Snapshot, error)
//	func Run(args []string, env map[string]string, stdout, stderr io.Writer,
//		stdoutIsTerminal bool, src Sources, clk Clock) int
//	func RenderFrame(s Snapshot, set Settings, width, height int, color bool) string
//	type Settings struct{ CPUCores int }
//	func newDashboardModel(src Sources, clk Clock, prefs *PrefsStore) <tea.Model>
//	func OpenPrefs(env map[string]string) *PrefsStore
//	func (*PrefsStore) Get(key string) (string, bool)
//	func (*PrefsStore) Set(key, value string)
//
// Conventions the tests rely on beyond the written rules:
//   - Notices about unmeasurable areas contain a word of the area (case-
//     insensitive): cpu, memory, disk, network, process.
//   - The display waits through Clock.Sleep (one second between measurements);
//     the sampler waits through Clock.Sleep (250 ms window).
//   - A measurement reads each source once; the window is the time between
//     two readings of the clock taken immediately before the source reads.
//   - The frame is a single column at widths up to 80.
//   - Drive names reach the sampler as upper case "X:\" strings.
//   - The adapter source lists in-service, non-loopback adapters only and
//     marks the default route itself; the sampler filters tunnels, sorts,
//     totals and picks the first IPv4 address that is not loopback or
//     link-local.
//
// Snapshot must marshal to the JSON document of the output schema and decode
// from it (encoding/json); the tests build snapshots for the renderer from
// JSON documents so that they do not depend on Go field names.
// The package must define main(), which exits with the code returned by Run.

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

const (
	tstMiB = 1 << 20
	tstGiB = 1 << 30
)

var errFakeUnavailable = errors.New("source unavailable")

// ---------------------------------------------------------------------------
// Artificial clock

type fakeClock struct {
	mu     sync.Mutex
	now    time.Time
	sleeps []time.Duration
	dead   bool
}

func newFakeClock() *fakeClock {
	zone := time.FixedZone("UTC+2", 2*3600)
	return &fakeClock{now: time.Date(2026, 10, 28, 12, 0, 0, 0, zone)}
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

// Sleep advances the artificial time without waiting.
func (c *fakeClock) Sleep(d time.Duration) {
	c.mu.Lock()
	if c.dead {
		c.mu.Unlock()
		select {}
	}
	c.sleeps = append(c.sleeps, d)
	if d > 0 {
		c.now = c.now.Add(d)
	}
	c.mu.Unlock()
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

func (c *fakeClock) totalSlept() time.Duration {
	c.mu.Lock()
	defer c.mu.Unlock()
	var sum time.Duration
	for _, d := range c.sleeps {
		if d > 0 {
			sum += d
		}
	}
	return sum
}

// kill makes every further Sleep block, so a runaway loop stops spinning.
func (c *fakeClock) kill() {
	c.mu.Lock()
	c.dead = true
	c.mu.Unlock()
}

// ---------------------------------------------------------------------------
// Artificial world: raw cumulative counters behind every source

type fakeCPU struct{ Idle, Total uint64 }

type fakeDrive struct {
	Mount       string
	Total, Free uint64
	FS          string
	Removable   bool
}

type fakeNet struct {
	Name   string
	Rx, Tx uint64
}

type fakeAdapter struct {
	Name            string
	IPv4            []string
	Default, Tunnel bool
}

type fakeProc struct {
	PID       int
	Name      string
	Start     uint64
	CPU       uint64 // cumulative processor time, 100 ns units
	PrivateWS uint64
}

type fakeWorld struct {
	mu  sync.Mutex
	clk *fakeClock

	// auto: every read of a source first advances its counters by the step.
	auto bool
	// cost: the artificial clock advances by this much after every CPU read.
	cost time.Duration

	cpu      []fakeCPU
	cpuSteps []fakeCPU // per processor; missing entries use 60 % idle of 10 ms
	physical int
	cpuErr   error

	memTotal, memAvail uint64
	memErr             error

	swapUsed, swapTotal uint64
	swapErr             error

	drives    []fakeDrive
	drivesErr error

	diskRead, diskWrite         uint64
	diskStepRead, diskStepWrite uint64
	diskErr                     error

	nets    []fakeNet
	netStep fakeNet
	netErr  error

	adapters    []fakeAdapter
	adaptersErr error

	procs    []fakeProc
	procStep uint64
	procsErr error

	uptime    time.Duration
	uptimeErr error

	platform    string
	platformErr error

	reads  map[string][]time.Time
	onRead func(w *fakeWorld, src string, n int) // called with the lock held

	gate                chan struct{}
	blocked, maxBlocked int
}

// newHealthyWorld has every source working and counters that grow on every
// read: two processors at 40 % usage, 20/10 MiB disk traffic, 3/1 MiB network
// traffic and 0.1 s of processor time per process per read.
func newHealthyWorld(clk *fakeClock) *fakeWorld {
	return &fakeWorld{
		clk:           clk,
		auto:          true,
		cpu:           []fakeCPU{{}, {}},
		physical:      1,
		memTotal:      16 * tstGiB,
		memAvail:      12 * tstGiB,
		swapUsed:      tstGiB,
		swapTotal:     4 * tstGiB,
		drives:        []fakeDrive{{Mount: `C:\`, Total: 100 * tstGiB, Free: 60 * tstGiB, FS: "NTFS"}},
		diskStepRead:  20 * tstMiB,
		diskStepWrite: 10 * tstMiB,
		nets:          []fakeNet{{Name: "Ethernet"}},
		netStep:       fakeNet{Rx: 3 * tstMiB, Tx: tstMiB},
		adapters:      []fakeAdapter{{Name: "Ethernet", IPv4: []string{"192.0.2.17"}, Default: true}},
		procs: []fakeProc{
			{PID: 4, Name: "", Start: 1, PrivateWS: tstMiB},
			{PID: 100, Name: "chrome.exe", Start: 5, PrivateWS: 100 * tstMiB},
		},
		procStep: 1_000_000,
		uptime:   93784 * time.Second,
		platform: "windows 10.0.26100",
		reads:    map[string][]time.Time{},
	}
}

// newManualWorld has every source working and constant counters; tests set the
// counters themselves between the two readings.
func newManualWorld(clk *fakeClock) *fakeWorld {
	w := newHealthyWorld(clk)
	w.auto = false
	return w
}

func (w *fakeWorld) begin(src string) {
	w.mu.Lock()
	w.reads[src] = append(w.reads[src], w.clk.Now())
	if w.onRead != nil {
		w.onRead(w, src, len(w.reads[src]))
	}
	var gate chan struct{}
	if src == "cpu" && w.gate != nil {
		gate = w.gate
		w.blocked++
		if w.blocked > w.maxBlocked {
			w.maxBlocked = w.blocked
		}
	}
	w.mu.Unlock()
	if gate != nil {
		<-gate
		w.mu.Lock()
		w.blocked--
		w.mu.Unlock()
	}
}

func (w *fakeWorld) end(src string) {
	if src == "cpu" && w.cost > 0 {
		w.clk.Advance(w.cost)
	}
}

func (w *fakeWorld) readTimes(src string) []time.Time {
	w.mu.Lock()
	defer w.mu.Unlock()
	return append([]time.Time(nil), w.reads[src]...)
}

func (w *fakeWorld) readCount(src string) int {
	w.mu.Lock()
	defer w.mu.Unlock()
	return len(w.reads[src])
}

func (w *fakeWorld) totalReads() int {
	w.mu.Lock()
	defer w.mu.Unlock()
	n := 0
	for _, r := range w.reads {
		n += len(r)
	}
	return n
}

func (w *fakeWorld) holdCPU() {
	w.mu.Lock()
	w.gate = make(chan struct{})
	w.mu.Unlock()
}

func (w *fakeWorld) releaseCPU() {
	w.mu.Lock()
	if w.gate != nil {
		close(w.gate)
		w.gate = nil
	}
	w.mu.Unlock()
}

func (w *fakeWorld) blockedCPU() (now, max int) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.blocked, w.maxBlocked
}

// set runs f with the world lock held.
func (w *fakeWorld) set(f func()) {
	w.mu.Lock()
	f()
	w.mu.Unlock()
}

// tstSources adapts the world to the production Sources.
func tstSources(w *fakeWorld) Sources {
	return Sources{
		CPU: func() (CPUReading, error) {
			w.begin("cpu")
			defer w.end("cpu")
			w.mu.Lock()
			defer w.mu.Unlock()
			if w.cpuErr != nil {
				return CPUReading{}, w.cpuErr
			}
			per := make([]CPUTimes, len(w.cpu))
			for i := range w.cpu {
				if w.auto {
					step := fakeCPU{Idle: 6_000_000, Total: 10_000_000}
					if i < len(w.cpuSteps) {
						step = w.cpuSteps[i]
					}
					w.cpu[i].Idle += step.Idle
					w.cpu[i].Total += step.Total
				}
				per[i] = CPUTimes{Idle: w.cpu[i].Idle, Total: w.cpu[i].Total}
			}
			return CPUReading{PerCPU: per, PhysicalCores: w.physical}, nil
		},
		Memory: func() (MemoryReading, error) {
			w.begin("memory")
			defer w.end("memory")
			w.mu.Lock()
			defer w.mu.Unlock()
			if w.memErr != nil {
				return MemoryReading{}, w.memErr
			}
			return MemoryReading{Total: w.memTotal, Available: w.memAvail}, nil
		},
		Swap: func() (SwapReading, error) {
			w.begin("swap")
			defer w.end("swap")
			w.mu.Lock()
			defer w.mu.Unlock()
			if w.swapErr != nil {
				return SwapReading{}, w.swapErr
			}
			return SwapReading{Used: w.swapUsed, Total: w.swapTotal}, nil
		},
		Drives: func() ([]DriveReading, error) {
			w.begin("drives")
			defer w.end("drives")
			w.mu.Lock()
			defer w.mu.Unlock()
			if w.drivesErr != nil {
				return nil, w.drivesErr
			}
			out := make([]DriveReading, len(w.drives))
			for i, d := range w.drives {
				out[i] = DriveReading{Name: d.Mount, Total: d.Total, Free: d.Free, FSType: d.FS, Removable: d.Removable}
			}
			return out, nil
		},
		DiskIO: func() (DiskIOReading, error) {
			w.begin("diskio")
			defer w.end("diskio")
			w.mu.Lock()
			defer w.mu.Unlock()
			if w.diskErr != nil {
				return DiskIOReading{}, w.diskErr
			}
			if w.auto {
				w.diskRead += w.diskStepRead
				w.diskWrite += w.diskStepWrite
			}
			return DiskIOReading{ReadBytes: w.diskRead, WriteBytes: w.diskWrite}, nil
		},
		NetCounters: func() ([]NetCounterReading, error) {
			w.begin("netcounters")
			defer w.end("netcounters")
			w.mu.Lock()
			defer w.mu.Unlock()
			if w.netErr != nil {
				return nil, w.netErr
			}
			out := make([]NetCounterReading, len(w.nets))
			for i := range w.nets {
				if w.auto {
					w.nets[i].Rx += w.netStep.Rx
					w.nets[i].Tx += w.netStep.Tx
				}
				out[i] = NetCounterReading{Name: w.nets[i].Name, RxBytes: w.nets[i].Rx, TxBytes: w.nets[i].Tx}
			}
			return out, nil
		},
		Adapters: func() ([]AdapterReading, error) {
			w.begin("adapters")
			defer w.end("adapters")
			w.mu.Lock()
			defer w.mu.Unlock()
			if w.adaptersErr != nil {
				return nil, w.adaptersErr
			}
			out := make([]AdapterReading, len(w.adapters))
			for i, a := range w.adapters {
				out[i] = AdapterReading{Name: a.Name, IPv4: append([]string(nil), a.IPv4...), DefaultRoute: a.Default, Tunnel: a.Tunnel}
			}
			return out, nil
		},
		Processes: func() ([]ProcessReading, error) {
			w.begin("processes")
			defer w.end("processes")
			w.mu.Lock()
			defer w.mu.Unlock()
			if w.procsErr != nil {
				return nil, w.procsErr
			}
			out := make([]ProcessReading, len(w.procs))
			for i := range w.procs {
				if w.auto {
					w.procs[i].CPU += w.procStep
				}
				p := w.procs[i]
				out[i] = ProcessReading{PID: uint32(p.PID), Name: p.Name, StartTime: p.Start, CPUTime: p.CPU, PrivateBytes: p.PrivateWS}
			}
			return out, nil
		},
		Uptime: func() (time.Duration, error) {
			w.begin("uptime")
			defer w.end("uptime")
			w.mu.Lock()
			defer w.mu.Unlock()
			if w.uptimeErr != nil {
				return 0, w.uptimeErr
			}
			return w.uptime, nil
		},
		Platform: func() (string, error) {
			w.begin("platform")
			defer w.end("platform")
			w.mu.Lock()
			defer w.mu.Unlock()
			if w.platformErr != nil {
				return "", w.platformErr
			}
			return w.platform, nil
		},
	}
}

// failAll makes every source fail.
func (w *fakeWorld) failAll() {
	w.set(func() {
		w.cpuErr, w.memErr, w.swapErr, w.drivesErr, w.diskErr = errFakeUnavailable, errFakeUnavailable, errFakeUnavailable, errFakeUnavailable, errFakeUnavailable
		w.netErr, w.adaptersErr, w.procsErr, w.uptimeErr, w.platformErr = errFakeUnavailable, errFakeUnavailable, errFakeUnavailable, errFakeUnavailable, errFakeUnavailable
	})
}

// ---------------------------------------------------------------------------
// Adapters to the production API

func tstNewSampler(w *fakeWorld, clk *fakeClock) *Sampler {
	return NewSampler(tstSources(w), clk)
}

func tstRenderFrame(snap Snapshot, cpuCores, width, height int, color bool) string {
	return RenderFrame(snap, Settings{CPUCores: cpuCores}, width, height, color)
}

func tstNewModel(w *fakeWorld, clk *fakeClock, prefs *PrefsStore) tea.Model {
	return newDashboardModel(tstSources(w), clk, prefs)
}

func tstOpenPrefs(env map[string]string) *PrefsStore { return OpenPrefs(env) }

// tstRunWith calls Run with a time limit; a runaway Run is stopped through the clock.
func tstRunWith(t *testing.T, w *fakeWorld, clk *fakeClock, args []string, env map[string]string,
	terminal bool, stdout, stderr io.Writer) int {
	t.Helper()
	done := make(chan int, 1)
	go func() { done <- Run(args, env, stdout, stderr, terminal, tstSources(w), clk) }()
	select {
	case code := <-done:
		return code
	case <-time.After(20 * time.Second):
		clk.kill()
		t.Fatalf("Run(%q) did not return within 20 s", args)
		return -1
	}
}

type tstResult struct {
	code           int
	stdout, stderr string
}

func tstRun(t *testing.T, w *fakeWorld, clk *fakeClock, args []string, env map[string]string, terminal bool) tstResult {
	t.Helper()
	var out, errOut bytes.Buffer
	code := tstRunWith(t, w, clk, args, env, terminal, &out, &errOut)
	return tstResult{code: code, stdout: out.String(), stderr: errOut.String()}
}

// ---------------------------------------------------------------------------
// Isolated file system and environment

type tstEnv struct {
	root, home, data string
	env              map[string]string
}

// tstIsolated returns an environment map whose data and home folders do not
// exist yet; tests assert that they stay absent where nothing may be written.
func tstIsolated(t *testing.T) tstEnv {
	t.Helper()
	root := t.TempDir()
	home := filepath.Join(root, "home")
	data := filepath.Join(root, "data")
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("SWEEPR_DATA_DIR", "")
	return tstEnv{
		root: root, home: home, data: data,
		env: map[string]string{
			"SWEEPR_DATA_DIR": data,
			"USERPROFILE":     home,
			"HOME":            home,
			"SystemDrive":     "C:",
		},
	}
}

func (e tstEnv) prefsFile() string { return filepath.Join(e.data, "config", "status_prefs") }

func (e tstEnv) with(k, v string) tstEnv {
	m := map[string]string{}
	for key, val := range e.env {
		m[key] = val
	}
	m[k] = v
	e.env = m
	return e
}

func (e tstEnv) writePrefs(t *testing.T, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(e.prefsFile()), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(e.prefsFile(), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func (e tstEnv) readPrefs(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile(e.prefsFile())
	if err != nil {
		t.Fatalf("settings file not readable: %v", err)
	}
	return string(b)
}

// assertUntouched fails when the isolated root gained any entry.
func (e tstEnv) assertUntouched(t *testing.T) {
	t.Helper()
	entries, err := os.ReadDir(e.root)
	if err != nil {
		t.Fatal(err)
	}
	for _, en := range entries {
		t.Errorf("unexpected entry %q created in the data or home folder", en.Name())
	}
}

// ---------------------------------------------------------------------------
// JSON helpers

func tstDecode(t *testing.T, b []byte) map[string]any {
	t.Helper()
	var doc map[string]any
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatalf("not a JSON object: %v\n%s", err, b)
	}
	return doc
}

func tstSnapshotDoc(t *testing.T, snap Snapshot) map[string]any {
	t.Helper()
	b, err := json.Marshal(&snap)
	if err != nil {
		t.Fatalf("Snapshot does not marshal: %v", err)
	}
	return tstDecode(t, b)
}

func tstSnapshotFromDoc(t *testing.T, doc map[string]any) Snapshot {
	t.Helper()
	b, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	var snap Snapshot
	if err := json.Unmarshal(b, &snap); err != nil {
		t.Fatalf("Snapshot does not decode from its JSON form: %v\n%s", err, b)
	}
	return snap
}

// tstAt follows a path of object keys; the second result tells whether every
// key exists (a JSON null exists and yields nil).
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

func tstWantNull(t *testing.T, doc map[string]any, path ...string) {
	t.Helper()
	v, ok := tstAt(doc, path...)
	if !ok {
		t.Errorf("%s: key is missing, want null", strings.Join(path, "."))
		return
	}
	if v != nil {
		t.Errorf("%s = %v, want null", strings.Join(path, "."), v)
	}
}

func tstWantNotNull(t *testing.T, doc map[string]any, path ...string) {
	t.Helper()
	v, ok := tstAt(doc, path...)
	if !ok || v == nil {
		t.Errorf("%s = %v (present %v), want a value", strings.Join(path, "."), v, ok)
	}
}

func tstWantNum(t *testing.T, doc map[string]any, want float64, path ...string) {
	t.Helper()
	v, ok := tstAt(doc, path...)
	f, isNum := v.(float64)
	if !ok || !isNum {
		t.Errorf("%s = %v, want the number %v", strings.Join(path, "."), v, want)
		return
	}
	if math.Abs(f-want) > 1e-6*math.Max(1, math.Abs(want)) {
		t.Errorf("%s = %v, want %v", strings.Join(path, "."), f, want)
	}
}

func tstWantStr(t *testing.T, doc map[string]any, want string, path ...string) {
	t.Helper()
	v, ok := tstAt(doc, path...)
	s, isStr := v.(string)
	if !ok || !isStr || s != want {
		t.Errorf("%s = %v, want %q", strings.Join(path, "."), v, want)
	}
}

func tstArr(t *testing.T, doc map[string]any, path ...string) []any {
	t.Helper()
	v, ok := tstAt(doc, path...)
	a, isArr := v.([]any)
	if !ok || !isArr {
		t.Fatalf("%s = %v, want an array", strings.Join(path, "."), v)
	}
	return a
}

func tstNames(t *testing.T, items []any) []string {
	t.Helper()
	var out []string
	for _, it := range items {
		n, _ := tstAt(it, "name")
		s, _ := n.(string)
		out = append(out, s)
	}
	return out
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

var tstTopLevelKeys = []string{
	"collected_at", "platform", "uptime_seconds", "procs", "cpu", "memory",
	"disks", "disk_io", "network", "network_total", "top_processes",
}

// ---------------------------------------------------------------------------
// Test binary as child process: the test program calls itself.

const tstModeEnv = "SWEEPR_STATUS_TEST_MODE"

func TestMain(m *testing.M) {
	switch os.Getenv(tstModeEnv) {
	case "main":
		main()
		os.Exit(0)
	case "prefs":
		tstPrefsChild()
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// tstPrefsChild saves COUNT distinct keys PREFIX00, PREFIX01, ... with the
// settings store, like a second running instance would.
func tstPrefsChild() {
	env := map[string]string{"SWEEPR_DATA_DIR": os.Getenv("SWEEPR_STATUS_TEST_DATA")}
	store := OpenPrefs(env)
	prefix := os.Getenv("SWEEPR_STATUS_TEST_PREFIX")
	n, _ := strconv.Atoi(os.Getenv("SWEEPR_STATUS_TEST_COUNT"))
	for i := 0; i < n; i++ {
		store.Set(fmt.Sprintf("%s%02d", prefix, i), strconv.Itoa(i))
	}
}

// tstChildMain runs the program's main function in a child process of the test
// binary. stdout and stderr are pipes (not terminals).
func tstChildMain(t *testing.T, args []string, extraEnv ...string) tstResult {
	t.Helper()
	cmd := exec.Command(os.Args[0], args...)
	cmd.Env = append(os.Environ(), tstModeEnv+"=main")
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

// tstChildStreamLines starts the program as a child process, reads n lines from
// its stdout and stops it.
func tstChildStreamLines(t *testing.T, args []string, n int) []string {
	t.Helper()
	cmd := exec.Command(os.Args[0], args...)
	cmd.Env = append(os.Environ(), tstModeEnv+"=main")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatalf("start child: %v", err)
	}
	defer func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}()
	type result struct {
		lines []string
		err   error
	}
	done := make(chan result, 1)
	go func() {
		rd := bufio.NewReader(stdout)
		var lines []string
		for len(lines) < n {
			l, err := rd.ReadString('\n')
			if err != nil {
				done <- result{lines, err}
				return
			}
			lines = append(lines, l)
		}
		done <- result{lines, nil}
	}()
	select {
	case r := <-done:
		if r.err != nil {
			t.Fatalf("stream ended after %d of %d lines: %v", len(r.lines), n, r.err)
		}
		return r.lines
	case <-time.After(30 * time.Second):
		t.Fatalf("no %d lines within 30 s", n)
		return nil
	}
}

// tstSystemDrive is the drive letter the real environment names, "C:" if empty.
func tstSystemDrive() string {
	if d := os.Getenv("SystemDrive"); d != "" {
		return d
	}
	return "C:"
}
