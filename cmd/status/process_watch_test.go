package main

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestTopProcessesSortsByCPU(t *testing.T) {
	procs := []ProcessInfo{
		{PID: 3, Name: "low", CPU: 20, Memory: 3},
		{PID: 1, Name: "high", CPU: 120, Memory: 1},
		{PID: 2, Name: "mid", CPU: 120, Memory: 8},
	}

	top := topProcesses(procs, 2)
	if len(top) != 2 {
		t.Fatalf("topProcesses() len = %d, want 2", len(top))
	}
	if top[0].PID != 2 || top[1].PID != 1 {
		t.Fatalf("unexpected order: %+v", top)
	}
}

func TestProcessWatcherTriggersAfterContinuousWindow(t *testing.T) {
	base := time.Date(2026, 3, 19, 10, 0, 0, 0, time.UTC)
	watcher := NewProcessWatcher(ProcessWatchOptions{
		Enabled:      true,
		CPUThreshold: 100,
		Window:       5 * time.Minute,
	})

	proc := []ProcessInfo{{PID: 42, Name: "stress", CPU: 140}}
	if alerts := watcher.Update(base, proc); len(alerts) != 0 {
		t.Fatalf("unexpected early alerts: %+v", alerts)
	}
	if alerts := watcher.Update(base.Add(4*time.Minute), proc); len(alerts) != 0 {
		t.Fatalf("unexpected early alerts at 4m: %+v", alerts)
	}
	alerts := watcher.Update(base.Add(5*time.Minute), proc)
	if len(alerts) != 1 {
		t.Fatalf("expected 1 alert after full window, got %+v", alerts)
	}
	if alerts[0].Status != "active" {
		t.Fatalf("unexpected alert status %q", alerts[0].Status)
	}
}

func TestProcessWatcherResetsWhenUsageDrops(t *testing.T) {
	base := time.Date(2026, 3, 19, 10, 0, 0, 0, time.UTC)
	watcher := NewProcessWatcher(ProcessWatchOptions{
		Enabled:      true,
		CPUThreshold: 100,
		Window:       5 * time.Minute,
	})

	high := []ProcessInfo{{PID: 42, Name: "stress", CPU: 140}}
	low := []ProcessInfo{{PID: 42, Name: "stress", CPU: 30}}

	watcher.Update(base, high)
	watcher.Update(base.Add(4*time.Minute), high)
	if alerts := watcher.Update(base.Add(4*time.Minute+30*time.Second), low); len(alerts) != 0 {
		t.Fatalf("expected reset after dip, got %+v", alerts)
	}
	if alerts := watcher.Update(base.Add(9*time.Minute), high); len(alerts) != 0 {
		t.Fatalf("expected no alert after reset, got %+v", alerts)
	}
	if alerts := watcher.Update(base.Add(14*time.Minute), high); len(alerts) != 1 {
		t.Fatalf("expected alert after second full window, got %+v", alerts)
	}
}

func TestProcessWatcherResetsOnPIDReuse(t *testing.T) {
	base := time.Date(2026, 3, 19, 10, 0, 0, 0, time.UTC)
	watcher := NewProcessWatcher(ProcessWatchOptions{
		Enabled:      true,
		CPUThreshold: 100,
		Window:       2 * time.Minute,
	})

	firstProc := []ProcessInfo{{
		PID:     42,
		PPID:    1,
		Name:    "stress",
		Command: "/usr/bin/stress",
		CPU:     140,
	}}
	secondProc := []ProcessInfo{{
		PID:     42,
		PPID:    99,
		Name:    "node",
		Command: "/usr/local/bin/node /tmp/server.js",
		CPU:     135,
	}}

	watcher.Update(base, firstProc)
	if alerts := watcher.Update(base.Add(2*time.Minute), firstProc); len(alerts) != 1 {
		t.Fatalf("expected first process to alert after window, got %+v", alerts)
	}

	if alerts := watcher.Update(base.Add(3*time.Minute), secondProc); len(alerts) != 0 {
		t.Fatalf("expected pid reuse to reset tracking, got %+v", alerts)
	}
	if alerts := watcher.Update(base.Add(5*time.Minute), secondProc); len(alerts) != 1 {
		t.Fatalf("expected reused pid to alert only after its own window, got %+v", alerts)
	}
}

func TestRenderProcessAlertBar(t *testing.T) {
	stale := false
	alerts := []ProcessAlert{
		{PID: 10, Name: "node", CPU: 150, Threshold: 100, Window: "5m0s", Status: "active"},
		{PID: 11, Name: "java", CPU: 130, Threshold: 100, Window: "5m0s", Status: "active"},
	}

	bar := renderProcessAlertBar(alerts, &stale, nil, 120)
	if !strings.Contains(bar, "ALERT") {
		t.Fatalf("missing alert prefix: %q", bar)
	}
	if !strings.Contains(bar, "node (10)") {
		t.Fatalf("missing lead process label: %q", bar)
	}
	if !strings.Contains(bar, "+1 more") {
		t.Fatalf("missing additional alert count: %q", bar)
	}
	if strings.Contains(bar, "terminate") || strings.Contains(bar, "ignore") {
		t.Fatalf("unexpected action text in read-only alert bar: %q", bar)
	}
}

func TestRenderProcessAlertBarMarksStaleSamplesBeforeTruncation(t *testing.T) {
	stale := true
	collectedAt := time.Date(2026, time.August, 30, 9, 7, 0, 0, time.FixedZone("UTC+8", 8*60*60))
	alerts := []ProcessAlert{{
		PID: 10, Name: "node", CPU: 150, Threshold: 100, Window: "5m0s", Status: "active",
	}}

	narrowBar := stripANSI(renderProcessAlertBar(alerts, &stale, &collectedAt, 10))
	if !strings.HasPrefix(strings.TrimSpace(narrowBar), "OLD") {
		t.Fatalf("historical alert marker should survive narrow rendering, got %q", narrowBar)
	}
	if strings.Contains(narrowBar, "2026") {
		t.Fatalf("narrow rendering should not show a partial timestamp, got %q", narrowBar)
	}
	wideBar := stripANSI(renderProcessAlertBar(alerts, &stale, &collectedAt, 120))
	if !strings.HasPrefix(strings.TrimSpace(wideBar), "LAST ALERT · STALE 2026-08-30T09:07:00+08:00") {
		t.Fatalf("stale process alert should include unambiguous age and historical semantics, got %q", wideBar)
	}
	if strings.Contains(wideBar, "· ALERT ") {
		t.Fatalf("stale process alert should not present itself as current, got %q", wideBar)
	}
	unboundedBar := stripANSI(renderProcessAlertBar(alerts, &stale, &collectedAt, 0))
	if !strings.HasPrefix(strings.TrimSpace(unboundedBar), "LAST ALERT · STALE 2026-08-30T09:07:00+08:00") {
		t.Fatalf("unbounded rendering should preserve the full historical marker, got %q", unboundedBar)
	}
	boundaryBar := stripANSI(renderProcessAlertBar(alerts, &stale, &collectedAt, 28))
	if !strings.HasPrefix(strings.TrimSpace(boundaryBar), "LAST ALERT · STALE") || strings.Contains(boundaryBar, "2026") {
		t.Fatalf("partial RFC3339 timestamp should collapse atomically, got %q", boundaryBar)
	}
}

func TestRenderProcessAlertBarMarksUnknownFreshnessAsLastKnown(t *testing.T) {
	alerts := []ProcessAlert{{
		PID: 10, Name: "node", CPU: 150, Threshold: 100, Window: "5m0s", Status: "active",
	}}

	bar := stripANSI(renderProcessAlertBar(alerts, nil, nil, 80))
	if !strings.HasPrefix(strings.TrimSpace(bar), "LAST ALERT · UNKNOWN") {
		t.Fatalf("unknown-freshness process alert should be last-known, got %q", bar)
	}
}

func TestMetricsSnapshotJSONIncludesProcessWatch(t *testing.T) {
	processCollectedAt := time.Date(2026, time.August, 29, 12, 30, 0, 0, time.UTC)
	processStale := false
	snapshot := MetricsSnapshot{
		ProcessCollectedAt: &processCollectedAt,
		ProcessStale:       &processStale,
		ProcessWatch: ProcessWatchConfig{
			Enabled:      true,
			CPUThreshold: 100,
			Window:       "5m0s",
		},
		ProcessAlerts: []ProcessAlert{{
			PID:       99,
			Name:      "node",
			CPU:       140,
			Threshold: 100,
			Window:    "5m0s",
			Status:    "active",
		}},
	}

	data, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatalf("json.Marshal() error = %v", err)
	}
	out := string(data)
	if !strings.Contains(out, "\"process_watch\"") {
		t.Fatalf("missing process_watch in json: %s", out)
	}
	if !strings.Contains(out, "\"process_alerts\"") {
		t.Fatalf("missing process_alerts in json: %s", out)
	}
	if !strings.Contains(out, "\"process_collected_at\":\"2026-08-29T12:30:00Z\"") ||
		!strings.Contains(out, "\"process_stale\":false") {
		t.Fatalf("missing process freshness in json: %s", out)
	}
	if strings.Contains(out, "zombie") {
		t.Fatalf("Windows has no zombie processes and must not report a zombie count: %s", out)
	}
}
