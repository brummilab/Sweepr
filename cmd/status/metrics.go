package main

import (
	"container/heap"
	"fmt"
	"net/url"
	"os"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"
)

// RingBuffer is a fixed-size circular buffer for float64 values.
type RingBuffer struct {
	data  []float64
	index int // Current insert position (oldest value)
	size  int // Number of valid elements
	cap   int // Total capacity
}

func NewRingBuffer(capacity int) *RingBuffer {
	return &RingBuffer{
		data: make([]float64, capacity),
		cap:  capacity,
	}
}

func (rb *RingBuffer) Add(val float64) {
	rb.data[rb.index] = val
	rb.index = (rb.index + 1) % rb.cap
	if rb.size < rb.cap {
		rb.size++
	}
}

// Slice returns the data in chronological order (oldest to newest).
func (rb *RingBuffer) Slice() []float64 {
	if rb.size == 0 {
		return nil
	}
	res := make([]float64, rb.size)
	if rb.size < rb.cap {
		copy(res, rb.data[:rb.size])
	} else {
		copy(res, rb.data[rb.index:])
		copy(res[rb.cap-rb.index:], rb.data[:rb.index])
	}
	return res
}

// MetricsSnapshot mirrors main's JSON contract for the fields Windows can
// measure. Fields main fills from macOS-only sources (thermal sensors, GPU,
// Bluetooth, Trash, zombie processes) are left out rather than emitted as zeros.
type MetricsSnapshot struct {
	CollectedAt    time.Time    `json:"collected_at"`
	Host           string       `json:"host"`
	Platform       string       `json:"platform"`
	Uptime         string       `json:"uptime"`
	UptimeSeconds  uint64       `json:"uptime_seconds"`
	Procs          uint64       `json:"procs"`
	Hardware       HardwareInfo `json:"hardware"`
	HealthScore    int          `json:"health_score"`
	HealthScoreMsg string       `json:"health_score_msg"`

	CPU                CPUStatus          `json:"cpu"`
	Memory             MemoryStatus       `json:"memory"`
	Disks              []DiskStatus       `json:"disks"`
	DiskIO             DiskIOStatus       `json:"disk_io"`
	Network            []NetworkStatus    `json:"network"`
	NetworkHistory     NetworkHistory     `json:"network_history"`
	Proxy              ProxyStatus        `json:"proxy"`
	Batteries          []BatteryStatus    `json:"batteries"`
	TopProcesses       []ProcessInfo      `json:"top_processes"`
	ProcessCollectedAt *time.Time         `json:"process_collected_at,omitempty"`
	ProcessStale       *bool              `json:"process_stale,omitempty"`
	ProcessWatch       ProcessWatchConfig `json:"process_watch"`
	ProcessAlerts      []ProcessAlert     `json:"process_alerts"`
}

type HardwareInfo struct {
	Model       string `json:"model"`
	CPUModel    string `json:"cpu_model"`
	TotalRAM    string `json:"total_ram"`
	DiskSize    string `json:"disk_size"`
	OSVersion   string `json:"os_version"`
	RefreshRate string `json:"refresh_rate"`
}

type DiskIOStatus struct {
	ReadRate  float64 `json:"read_rate"`  // MB/s
	WriteRate float64 `json:"write_rate"` // MB/s
}

type ProcessInfo struct {
	PID         int     `json:"pid"`
	PPID        int     `json:"ppid"`
	Name        string  `json:"name"`
	Command     string  `json:"command"`
	CPU         float64 `json:"cpu"`    // Percent of one logical CPU, like ps on macOS.
	Memory      float64 `json:"memory"` // Percent of physical memory.
	MemoryBytes uint64  `json:"memory_bytes,omitempty"`
}

type CPUStatus struct {
	Usage            float64   `json:"usage"`
	PerCore          []float64 `json:"per_core"`
	PerCoreEstimated bool      `json:"per_core_estimated"`
	CoreCount        int       `json:"core_count"`
	LogicalCPU       int       `json:"logical_cpu"`
}

type MemoryStatus struct {
	Used        uint64  `json:"used"`
	Total       uint64  `json:"total"`
	Available   uint64  `json:"available"`
	UsedPercent float64 `json:"used_percent"`
	SwapUsed    uint64  `json:"swap_used"`
	SwapTotal   uint64  `json:"swap_total"`
	Cached      uint64  `json:"cached"`
	// Pressure stays empty on Windows: there is no counterpart to macOS
	// memory_pressure, so the Status row is never rendered.
	Pressure string `json:"pressure"`
}

type DiskStatus struct {
	Mount       string  `json:"mount"`
	Device      string  `json:"device"`
	Used        uint64  `json:"used"`
	Total       uint64  `json:"total"`
	UsedPercent float64 `json:"used_percent"`
	Fstype      string  `json:"fstype"`
	External    bool    `json:"external"`
	SmartStatus string  `json:"smart_status"`
}

type NetworkStatus struct {
	defaultTunnel bool
	primary       bool    // Carries the default route; its IP is the one the card shows.
	Name          string  `json:"name"`
	RxRateMBs     float64 `json:"rx_rate_mbs"`
	TxRateMBs     float64 `json:"tx_rate_mbs"`
	IP            string  `json:"ip"`
}

type NetworkHistory struct {
	RxHistory []float64 `json:"rx_history"`
	TxHistory []float64 `json:"tx_history"`
}

const NetworkHistorySize = 120

type ProxyStatus struct {
	Enabled  bool   `json:"enabled"`
	Type     string `json:"type"` // HTTP, HTTPS, SOCKS, PAC, TUN
	Host     string `json:"host"`
	IsTunnel bool   `json:"-"`
}

type BatteryStatus struct {
	Percent    float64 `json:"percent"`
	Status     string  `json:"status"`
	TimeLeft   string  `json:"time_left"`
	Health     string  `json:"health"`
	CycleCount int     `json:"cycle_count"`
	Capacity   int     `json:"capacity"`
}

// smartStatusFailing is the one SMART state the view acts on. Windows exposes
// SMART prediction only to administrators, so it is never set here; the
// constant keeps the ported health and view rules intact.
const smartStatusFailing = "failing"

// Raw platform samples. The platform files fill these; everything that turns
// them into rates, rankings, and snapshots lives here so it can be tested on
// any OS.
type netCounter struct {
	rx, tx uint64
}

type netAdapter struct {
	Name      string
	IP        string
	IsDefault bool
	IsTunnel  bool
}

type procSample struct {
	PID         int
	PPID        int
	Image       string
	CreateTime  int64
	CPUTime     int64 // User plus kernel time, in 100ns units.
	MemoryBytes uint64
}

type procKey struct {
	pid        int
	createTime int64
}

const (
	minNetworkSampleInterval = 100 * time.Millisecond
	networkAdapterTTL        = 10 * time.Second
	minProcessSampleWindow   = 250 * time.Millisecond
	hardwareTTL              = 10 * time.Minute
)

// Platform hooks, replaced in tests.
var (
	readCPUFunc        = readCPU
	readMemoryFunc     = readMemory
	readDisksFunc      = readDisks
	readDiskIOFunc     = readDiskIO
	readNetCountersFn  = readNetCounters
	readNetAdaptersFn  = readNetAdapters
	readProcessesFunc  = readProcesses
	readBatteriesFunc  = readBatteries
	readHardwareFunc   = readHardware
	readSystemProxyFn  = readSystemProxy
	readExternalDrives = readExternalDriveSet
	readUptimeFunc     = readUptime
	sleepFunc          = time.Sleep
)

type Collector struct {
	hardware    HardwareInfo
	lastHWAt    time.Time
	hasHardware bool

	prevNet      map[string]netCounter
	lastNetAt    time.Time
	rxHistoryBuf *RingBuffer
	txHistoryBuf *RingBuffer
	adapters     map[string]netAdapter
	lastAdaptAt  time.Time

	prevDiskRead  uint64
	prevDiskWrite uint64
	lastDiskAt    time.Time

	prevProcs    map[procKey]int64
	lastProcAt   time.Time
	processTotal uint64

	enrichment    snapshotEnrichment
	hasEnrichment bool

	watchMu           sync.Mutex
	processWatch      ProcessWatchConfig
	processWatcher    *ProcessWatcher
	processEnrichment processEnrichment
	hasProcessData    bool
}

type collectedMetrics struct {
	cpuStats     CPUStatus
	memStats     MemoryStatus
	diskStats    []DiskStatus
	diskIO       DiskIOStatus
	netStats     []NetworkStatus
	proxyStats   ProxyStatus
	batteryStats []BatteryStatus
	allProcs     []ProcessInfo
	hasProcesses bool
}

type snapshotEnrichment struct {
	hardware  HardwareInfo
	external  map[string]bool
	proxy     ProxyStatus
	batteries []BatteryStatus
}

type processEnrichment struct {
	topProcesses  []ProcessInfo
	collectedAt   time.Time
	processAlerts []ProcessAlert
}

func NewCollector(options ProcessWatchOptions) *Collector {
	c := &Collector{
		prevNet:        make(map[string]netCounter),
		rxHistoryBuf:   NewRingBuffer(NetworkHistorySize),
		txHistoryBuf:   NewRingBuffer(NetworkHistorySize),
		prevProcs:      make(map[procKey]int64),
		processWatch:   options.SnapshotConfig(),
		processWatcher: NewProcessWatcher(options),
	}
	now := time.Now()
	c.primeNetworkCounters(now)
	_ = c.primeProcesses(now) // A failure is retried, and reported, by the first process collection.
	return c
}

func collectConcurrently(tasks ...func() error) error {
	var (
		wg     sync.WaitGroup
		errMu  sync.Mutex
		merged error
	)
	record := func(err error) {
		errMu.Lock()
		defer errMu.Unlock()
		if merged == nil {
			merged = err
		} else {
			merged = fmt.Errorf("%v; %w", merged, err)
		}
	}

	for _, task := range tasks {
		wg.Add(1)
		go func() {
			defer wg.Done()
			defer func() {
				if r := recover(); r != nil {
					record(fmt.Errorf("collector panic: %v", r))
				}
			}()
			if err := task(); err != nil {
				record(err)
			}
		}()
	}

	wg.Wait()
	return merged
}

func (c *Collector) CollectFast() (MetricsSnapshot, error) {
	return c.collect(false, false)
}

func (c *Collector) CollectProcesses() (MetricsSnapshot, error) {
	return c.collect(true, false)
}

func (c *Collector) Collect() (MetricsSnapshot, error) {
	return c.collect(true, true)
}

// collect runs one collection. Every source here is an in-process Win32 call,
// so the fast and full modes differ only in how often the slow-changing
// enrichment (hardware, battery health, proxy, drive bus types) is re-read.
func (c *Collector) collect(includeProcesses, full bool) (MetricsSnapshot, error) {
	now := time.Now()
	var collected collectedMetrics
	next := c.enrichment

	// Sample CPU before the other collectors start so their own work does not
	// land in the usage window, the same ordering main uses (#1237).
	var cpuErr error
	collected.cpuStats, cpuErr = readCPUFunc()

	if full {
		external, err := readExternalDrives()
		if err == nil {
			next.external = external
		}
	}

	// Adapter metadata is refreshed here, before the tasks run, so the network
	// and proxy tasks read one shared map instead of racing to refresh it.
	adapters := c.netAdaptersCached(now)

	tasks := []func() error{
		func() error { return cpuErr },
		func() (err error) { collected.memStats, err = readMemoryFunc(); return },
		func() (err error) { collected.diskStats, err = readDisksFunc(next.external); return },
		func() error { collected.diskIO = c.collectDiskIO(now); return nil },
		func() error { collected.netStats = c.collectNetwork(now, adapters); return nil },
	}
	if includeProcesses {
		tasks = append(tasks, func() error { return c.collectProcessesInto(&collected) })
	}
	if full {
		tasks = append(tasks,
			func() error {
				collected.proxyStats = collectProxy(adapters)
				next.proxy = collected.proxyStats
				return nil
			},
			func() error {
				batts, err := readBatteriesFunc()
				if err != nil {
					return err
				}
				collected.batteryStats = batts
				next.batteries = slices.Clone(batts)
				return nil
			},
		)
	}
	hwDue := full && (!c.hasHardware || now.Sub(c.lastHWAt) > hardwareTTL)
	var hwStatic HardwareInfo
	if hwDue {
		tasks = append(tasks, func() error { hwStatic = readHardwareFunc(); return nil })
	}

	mergeErr := collectConcurrently(tasks...)

	if hwDue {
		c.hardware = finishHardware(hwStatic, collected.memStats.Total, collected.diskStats)
		c.lastHWAt = now
		c.hasHardware = true
	}

	uptime := readUptimeFunc()
	snapshot := c.snapshotFromMetrics(now, uptime, collected)
	if full {
		next.hardware = snapshot.Hardware
		c.enrichment = next
		c.hasEnrichment = true
	}
	c.applyEnrichment(&snapshot, collected.hasProcesses)
	if collected.hasProcesses {
		c.cacheProcessEnrichment(snapshot)
	}
	return snapshot, mergeErr
}

func finishHardware(hw HardwareInfo, totalRAM uint64, disks []DiskStatus) HardwareInfo {
	if totalRAM > 0 {
		hw.TotalRAM = humanBytes(totalRAM)
	}
	if disk, ok := rootDisk(disks); ok && disk.Total > 0 {
		hw.DiskSize = humanBytes(disk.Total)
	}
	return hw
}

func (c *Collector) snapshotFromMetrics(now time.Time, uptime uint64, collected collectedMetrics) MetricsSnapshot {
	score, scoreMsg := calculateHealthScore(
		collected.cpuStats,
		collected.memStats,
		collected.diskStats,
		collected.diskIO,
		collected.batteryStats,
		uptime,
	)

	var topProcs []ProcessInfo
	var processCollectedAt *time.Time
	var processStale *bool
	if collected.hasProcesses {
		topProcs = topProcesses(collected.allProcs, 5)
		processTime := now
		stale := false
		processCollectedAt = &processTime
		processStale = &stale
	}

	var processAlerts []ProcessAlert
	c.watchMu.Lock()
	if c.processWatcher != nil {
		if collected.hasProcesses {
			processAlerts = c.processWatcher.Update(now, collected.allProcs)
		} else {
			processAlerts = c.processWatcher.Snapshot()
		}
	}
	c.watchMu.Unlock()

	host, _ := os.Hostname()
	var hw HardwareInfo
	if c.hasHardware {
		hw = c.hardware
	}

	return MetricsSnapshot{
		CollectedAt:    now,
		Host:           host,
		Platform:       platformName(),
		Uptime:         formatUptime(uptime),
		UptimeSeconds:  uptime,
		Procs:          c.processTotal,
		Hardware:       hw,
		HealthScore:    score,
		HealthScoreMsg: scoreMsg,
		CPU:            collected.cpuStats,
		Memory:         collected.memStats,
		Disks:          collected.diskStats,
		DiskIO:         collected.diskIO,
		Network:        collected.netStats,
		NetworkHistory: NetworkHistory{
			RxHistory: c.rxHistoryBuf.Slice(),
			TxHistory: c.txHistoryBuf.Slice(),
		},
		Proxy:              collected.proxyStats,
		Batteries:          collected.batteryStats,
		TopProcesses:       topProcs,
		ProcessCollectedAt: processCollectedAt,
		ProcessStale:       processStale,
		ProcessWatch:       c.processWatch,
		ProcessAlerts:      processAlerts,
	}
}

func (c *Collector) cacheProcessEnrichment(snapshot MetricsSnapshot) {
	collectedAt := snapshot.CollectedAt
	if snapshot.ProcessCollectedAt != nil {
		collectedAt = *snapshot.ProcessCollectedAt
	}
	if collectedAt.IsZero() {
		return
	}
	c.processEnrichment = processEnrichment{
		topProcesses:  slices.Clone(snapshot.TopProcesses),
		collectedAt:   collectedAt,
		processAlerts: slices.Clone(snapshot.ProcessAlerts),
	}
	c.hasProcessData = true
}

func (c *Collector) applyEnrichment(snapshot *MetricsSnapshot, preserveLiveProcesses bool) {
	if snapshot == nil {
		return
	}
	if c.hasEnrichment {
		c.enrichment.apply(snapshot)
		snapshot.HealthScore, snapshot.HealthScoreMsg = calculateHealthScore(
			snapshot.CPU,
			snapshot.Memory,
			snapshot.Disks,
			snapshot.DiskIO,
			snapshot.Batteries,
			snapshot.UptimeSeconds,
		)
	}
	if !preserveLiveProcesses && c.hasProcessData {
		c.processEnrichment.apply(snapshot)
	}
}

func (e snapshotEnrichment) apply(snapshot *MetricsSnapshot) {
	snapshot.Hardware = e.hardware
	snapshot.Proxy = e.proxy
	snapshot.Batteries = slices.Clone(e.batteries)
}

func (e processEnrichment) apply(snapshot *MetricsSnapshot) {
	snapshot.TopProcesses = slices.Clone(e.topProcesses)
	collectedAt := e.collectedAt
	stale := true
	snapshot.ProcessCollectedAt = &collectedAt
	snapshot.ProcessStale = &stale
	snapshot.ProcessAlerts = slices.Clone(e.processAlerts)
}

// --- Disk I/O ---

func (c *Collector) collectDiskIO(now time.Time) DiskIOStatus {
	read, write, err := readDiskIOFunc()
	if err != nil {
		return DiskIOStatus{}
	}
	if c.lastDiskAt.IsZero() {
		c.prevDiskRead, c.prevDiskWrite = read, write
		c.lastDiskAt = now
		return DiskIOStatus{}
	}
	elapsed := now.Sub(c.lastDiskAt).Seconds()
	if elapsed <= 0 {
		elapsed = 1
	}
	status := DiskIOStatus{
		ReadRate:  float64(counterDelta(read, c.prevDiskRead)) / 1024 / 1024 / elapsed,
		WriteRate: float64(counterDelta(write, c.prevDiskWrite)) / 1024 / 1024 / elapsed,
	}
	c.prevDiskRead, c.prevDiskWrite = read, write
	c.lastDiskAt = now
	return status
}

func counterDelta(current, previous uint64) uint64 {
	if current < previous {
		return 0
	}
	return current - previous
}

// --- Network ---

func (c *Collector) primeNetworkCounters(now time.Time) {
	counters, err := readNetCountersFn()
	if err != nil {
		return
	}
	c.lastNetAt = now
	for name, v := range counters {
		c.prevNet[name] = v
	}
}

func (c *Collector) netAdaptersCached(now time.Time) map[string]netAdapter {
	if c.adapters != nil && now.Sub(c.lastAdaptAt) < networkAdapterTTL {
		return c.adapters
	}
	list, err := readNetAdaptersFn()
	if err != nil {
		if c.adapters == nil {
			c.adapters = map[string]netAdapter{}
		}
		return c.adapters
	}
	adapters := make(map[string]netAdapter, len(list))
	for _, a := range list {
		adapters[a.Name] = a
	}
	c.adapters = adapters
	c.lastAdaptAt = now
	return adapters
}

func (c *Collector) collectNetwork(now time.Time, adapters map[string]netAdapter) []NetworkStatus {
	counters, err := readNetCountersFn()
	if err != nil {
		c.rxHistoryBuf.Add(0)
		c.txHistoryBuf.Add(0)
		return nil
	}

	if c.lastNetAt.IsZero() {
		c.lastNetAt = now
		for name, v := range counters {
			c.prevNet[name] = v
		}
	}
	elapsed := max(now.Sub(c.lastNetAt).Seconds(), minNetworkSampleInterval.Seconds())

	var result []NetworkStatus
	for name, cur := range counters {
		// Only operational, non-loopback adapters are listed; a tunnel shows
		// only while it carries the default route, as on main.
		adapter, ok := adapters[name]
		if !ok || (adapter.IsTunnel && !adapter.IsDefault) {
			continue
		}
		prev, ok := c.prevNet[name]
		if !ok {
			continue
		}
		result = append(result, NetworkStatus{
			Name:          name,
			RxRateMBs:     float64(counterDelta(cur.rx, prev.rx)) / 1024 / 1024 / elapsed,
			TxRateMBs:     float64(counterDelta(cur.tx, prev.tx)) / 1024 / 1024 / elapsed,
			IP:            adapter.IP,
			primary:       adapter.IsDefault,
			defaultTunnel: adapter.IsDefault && adapter.IsTunnel,
		})
	}

	c.lastNetAt = now
	for name, v := range counters {
		c.prevNet[name] = v
	}

	sort.Slice(result, func(i, j int) bool {
		if result[i].defaultTunnel != result[j].defaultTunnel {
			return result[i].defaultTunnel
		}
		ri := result[i].RxRateMBs + result[i].TxRateMBs
		rj := result[j].RxRateMBs + result[j].TxRateMBs
		if ri != rj {
			return ri > rj
		}
		return result[i].Name < result[j].Name
	})
	if len(result) > 3 {
		result = result[:3]
	}

	totalRx, totalTx := networkTotals(result)
	c.rxHistoryBuf.Add(totalRx)
	c.txHistoryBuf.Add(totalTx)
	return result
}

// networkTotals uses the routed tunnel alone when there is one, because tunnel
// and carrier counters describe overlapping traffic.
func networkTotals(stats []NetworkStatus) (rx, tx float64) {
	for _, n := range stats {
		if n.defaultTunnel {
			return n.RxRateMBs, n.TxRateMBs
		}
		rx += n.RxRateMBs
		tx += n.TxRateMBs
	}
	return rx, tx
}

func defaultAdapter(adapters map[string]netAdapter) (netAdapter, bool) {
	for _, a := range adapters {
		if a.IsDefault {
			return a, true
		}
	}
	return netAdapter{}, false
}

// --- Proxy ---

func collectProxy(adapters map[string]netAdapter) ProxyStatus {
	if proxy := collectProxyFromEnv(os.Getenv); proxy.Enabled {
		return proxy
	}
	if proxy := readSystemProxyFn(); proxy.Enabled {
		return proxy
	}
	if a, ok := defaultAdapter(adapters); ok && a.IsTunnel {
		// A routed tunnel is a VPN as often as a TUN-mode proxy client, so it
		// is labelled as a tunnel, never as a proxy (same rule as main).
		return ProxyStatus{Enabled: true, Type: "TUN", Host: a.Name, IsTunnel: true}
	}
	return ProxyStatus{}
}

func collectProxyFromEnv(getenv func(string) string) ProxyStatus {
	envKeys := []string{
		"https_proxy", "HTTPS_PROXY",
		"http_proxy", "HTTP_PROXY",
		"all_proxy", "ALL_PROXY",
	}
	for _, key := range envKeys {
		val := strings.TrimSpace(getenv(key))
		if val == "" {
			continue
		}
		proxyType := "HTTP"
		if strings.HasPrefix(strings.ToLower(val), "socks") {
			proxyType = "SOCKS"
		}
		host := displayProxyHost(val)
		return ProxyStatus{Enabled: true, Type: proxyType, Host: host}
	}
	return ProxyStatus{}
}

// proxyFromInternetSettings reads the WinINet values under
// HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings. ProxyServer
// is either "host:port" for every protocol or "http=h:p;https=h:p;socks=h:p".
func proxyFromInternetSettings(enabled bool, server, autoConfigURL string) ProxyStatus {
	server = strings.TrimSpace(server)
	if enabled && server != "" {
		if !strings.Contains(server, "=") {
			return ProxyStatus{Enabled: true, Type: "HTTP", Host: displayProxyHost(server)}
		}
		perProtocol := map[string]string{}
		for part := range strings.SplitSeq(server, ";") {
			key, value, ok := strings.Cut(strings.TrimSpace(part), "=")
			if ok && strings.TrimSpace(value) != "" {
				perProtocol[strings.ToLower(strings.TrimSpace(key))] = strings.TrimSpace(value)
			}
		}
		for _, p := range []struct{ key, label string }{{"socks", "SOCKS"}, {"https", "HTTPS"}, {"http", "HTTP"}} {
			if host, ok := perProtocol[p.key]; ok {
				return ProxyStatus{Enabled: true, Type: p.label, Host: displayProxyHost(host)}
			}
		}
	}
	if pac := strings.TrimSpace(autoConfigURL); pac != "" {
		host := parseProxyHost(pac)
		if host == "" {
			host = "PAC"
		}
		return ProxyStatus{Enabled: true, Type: "PAC", Host: host}
	}
	return ProxyStatus{}
}

// Invalid URLs may still contain credentials. Never expose an unparsed
// environment or registry value in the dashboard or JSON output.
func displayProxyHost(raw string) string {
	if host := parseProxyHost(raw); host != "" {
		return host
	}
	return "Unknown"
}

func parseProxyHost(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	target := raw
	if !strings.Contains(target, "://") {
		target = "http://" + target
	}
	parsed, err := url.Parse(target)
	if err != nil || parsed.Host == "" {
		return ""
	}
	return strings.TrimPrefix(parsed.Host, "@")
}

// --- Processes ---

func (c *Collector) primeProcesses(now time.Time) error {
	samples, err := readProcessesFunc()
	if err != nil {
		return err
	}
	c.prevProcs = processTimes(samples)
	c.lastProcAt = now
	return nil
}

// collectProcessesInto turns two process-table snapshots into per-process CPU
// percentages. Windows keeps only cumulative CPU time, so a usable reading
// needs a measured window; a window shorter than minProcessSampleWindow is
// topped up first so the first full collection already has a real sample.
func (c *Collector) collectProcessesInto(collected *collectedMetrics) error {
	if c.lastProcAt.IsZero() {
		if err := c.primeProcesses(time.Now()); err != nil {
			return err
		}
	}
	if wait := minProcessSampleWindow - time.Since(c.lastProcAt); wait > 0 {
		sleepFunc(wait)
	}
	samples, err := readProcessesFunc()
	if err != nil {
		return err
	}
	now := time.Now()
	elapsed := now.Sub(c.lastProcAt)
	logical := max(collected.cpuStats.LogicalCPU, 1)
	// The memory task fills collected.memStats concurrently, so read the total
	// here; GlobalMemoryStatusEx is a cheap call.
	var totalMem uint64
	if mem, err := readMemoryFunc(); err == nil {
		totalMem = mem.Total
	}

	collected.allProcs = processInfoFromSamples(samples, c.prevProcs, elapsed, logical, totalMem)
	collected.hasProcesses = true
	c.prevProcs = processTimes(samples)
	c.lastProcAt = now
	c.processTotal = uint64(len(samples))
	return nil
}

func processTimes(samples []procSample) map[procKey]int64 {
	times := make(map[procKey]int64, len(samples))
	for _, s := range samples {
		times[procKey{s.PID, s.CreateTime}] = s.CPUTime
	}
	return times
}

// processInfoFromSamples reports CPU as a percent of one logical CPU, the scale
// ps uses on macOS, so the alert threshold and bar colors mean the same thing on
// both platforms. A process absent from the previous table (new, or a reused
// PID with a different creation time) has no window yet and reports 0.
func processInfoFromSamples(samples []procSample, prev map[procKey]int64, elapsed time.Duration, logical int, totalMem uint64) []ProcessInfo {
	procs := make([]ProcessInfo, 0, len(samples))
	window := float64(elapsed) / 100 // 100ns ticks in the window.
	for _, s := range samples {
		if s.PID <= 0 {
			continue // The Idle process is idle time, not a process.
		}
		var cpu float64
		if before, ok := prev[procKey{s.PID, s.CreateTime}]; ok && window > 0 && s.CPUTime >= before {
			cpu = float64(s.CPUTime-before) / window * 100
			cpu = min(cpu, float64(logical)*100)
		}
		var memPct float64
		if totalMem > 0 {
			memPct = float64(s.MemoryBytes) / float64(totalMem) * 100
		}
		procs = append(procs, ProcessInfo{
			PID:         s.PID,
			PPID:        s.PPID,
			Name:        processDisplayName(s.Image, s.PID),
			Command:     s.Image,
			CPU:         cpu,
			Memory:      memPct,
			MemoryBytes: s.MemoryBytes,
		})
	}
	return procs
}

func processDisplayName(image string, pid int) string {
	name := image
	if idx := strings.LastIndexAny(name, `\/`); idx >= 0 {
		name = name[idx+1:]
	}
	if len(name) > 4 && strings.EqualFold(name[len(name)-4:], ".exe") {
		name = name[:len(name)-4]
	}
	if name == "" && pid == 4 {
		return "System"
	}
	return name
}

func topProcesses(processes []ProcessInfo, limit int) []ProcessInfo {
	if limit <= 0 || len(processes) == 0 {
		return nil
	}
	h := &processHeap{}
	heap.Init(h)
	for _, proc := range processes {
		if h.Len() < limit {
			heap.Push(h, proc)
			continue
		}
		if processRanksBefore(proc, (*h)[0]) {
			heap.Pop(h)
			heap.Push(h, proc)
		}
	}
	top := make([]ProcessInfo, h.Len())
	for i := len(top) - 1; i >= 0; i-- {
		top[i] = heap.Pop(h).(ProcessInfo)
	}
	return top
}

func formatProcessLabel(proc ProcessInfo) string {
	if proc.Name != "" {
		return fmt.Sprintf("%s (%d)", proc.Name, proc.PID)
	}
	return fmt.Sprintf("pid %d", proc.PID)
}

func processRanksBefore(a, b ProcessInfo) bool {
	if a.CPU != b.CPU {
		return a.CPU > b.CPU
	}
	if a.Memory != b.Memory {
		return a.Memory > b.Memory
	}
	return a.PID < b.PID
}

type processHeap []ProcessInfo

func (h processHeap) Len() int           { return len(h) }
func (h processHeap) Less(i, j int) bool { return processRanksBefore(h[j], h[i]) }
func (h processHeap) Swap(i, j int)      { h[i], h[j] = h[j], h[i] }
func (h *processHeap) Push(x any)        { *h = append(*h, x.(ProcessInfo)) }
func (h *processHeap) Pop() any {
	old := *h
	n := len(old)
	x := old[n-1]
	*h = old[:n-1]
	return x
}
