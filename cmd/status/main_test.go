package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func TestShouldUseJSONOutput_ForceFlag(t *testing.T) {
	if !shouldUseJSONOutput(true, nil) {
		t.Fatalf("expected force JSON flag to enable JSON mode")
	}
}

func TestShouldUseJSONOutput_NilStdout(t *testing.T) {
	if shouldUseJSONOutput(false, nil) {
		t.Fatalf("expected nil stdout to keep TUI mode")
	}
}

func TestShouldUseJSONOutput_NonTTYPipe(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatalf("create pipe: %v", err)
	}
	defer reader.Close()
	defer writer.Close()

	if !shouldUseJSONOutput(false, writer) {
		t.Fatalf("expected pipe stdout to use JSON mode")
	}
}

func TestShouldUseJSONOutput_NonTTYFile(t *testing.T) {
	tmpFile, err := os.CreateTemp("", "sweepr-status-stdout-*.txt")
	if err != nil {
		t.Fatalf("create temp file: %v", err)
	}
	defer os.Remove(tmpFile.Name())
	defer tmpFile.Close()

	if !shouldUseJSONOutput(false, tmpFile) {
		t.Fatalf("expected file stdout to use JSON mode")
	}
}

func TestProcessWatchOptionsFromFlags(t *testing.T) {
	oldThreshold := *procCPUThreshold
	oldWindow := *procCPUWindow
	oldAlerts := *procCPUAlerts
	defer func() {
		*procCPUThreshold = oldThreshold
		*procCPUWindow = oldWindow
		*procCPUAlerts = oldAlerts
	}()

	*procCPUThreshold = 125
	*procCPUWindow = 2 * time.Minute
	*procCPUAlerts = false

	opts := processWatchOptionsFromFlags()
	if opts.CPUThreshold != 125 {
		t.Fatalf("CPUThreshold = %v, want 125", opts.CPUThreshold)
	}
	if opts.Window != 2*time.Minute {
		t.Fatalf("Window = %v, want 2m", opts.Window)
	}
	if opts.Enabled {
		t.Fatal("Enabled = true, want false")
	}
}

func TestValidateFlags(t *testing.T) {
	oldThreshold := *procCPUThreshold
	oldWindow := *procCPUWindow
	defer func() {
		*procCPUThreshold = oldThreshold
		*procCPUWindow = oldWindow
	}()

	*procCPUThreshold = -1
	*procCPUWindow = 5 * time.Minute
	if err := validateFlags(); err == nil {
		t.Fatal("expected negative threshold to fail validation")
	}

	*procCPUThreshold = 100
	*procCPUWindow = 0
	if err := validateFlags(); err == nil {
		t.Fatal("expected zero window to fail validation")
	}
}

func TestParseWatchInterval(t *testing.T) {
	tests := []struct {
		name    string
		raw     string
		want    time.Duration
		wantErr bool
	}{
		{name: "default", raw: "", want: refreshInterval},
		{name: "duration", raw: "250ms", want: 250 * time.Millisecond},
		{name: "invalid", raw: "soon", wantErr: true},
		{name: "zero", raw: "0s", wantErr: true},
		{name: "negative", raw: "-1s", wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parseWatchInterval(tt.raw)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("parseWatchInterval(%q) returned nil error", tt.raw)
				}
				return
			}
			if err != nil {
				t.Fatalf("parseWatchInterval(%q) error = %v", tt.raw, err)
			}
			if got != tt.want {
				t.Fatalf("parseWatchInterval(%q) = %v, want %v", tt.raw, got, tt.want)
			}
		})
	}
}

func TestCollectionScheduleUsesFastFirstThenPeriodicFull(t *testing.T) {
	now := time.Now()
	var schedule collectionSchedule
	if got := schedule.nextMode(now); got != collectionFast {
		t.Fatalf("initial collection = %v, want fast", got)
	}

	first := collectionResult{mode: collectionFast, completedAt: now, data: MetricsSnapshot{CollectedAt: now}}
	if delay := schedule.recordCompletion(first, refreshInterval); delay != 0 {
		t.Fatalf("initial enrichment delayed by %v", delay)
	}
	if got := schedule.nextMode(now); got != collectionFull {
		t.Fatalf("first enrichment = %v, want full", got)
	}

	full := collectionResult{mode: collectionFull, completedAt: now, data: first.data}
	if delay := schedule.recordCompletion(full, refreshInterval); delay != refreshInterval {
		t.Fatalf("full collection delay = %v, want %v", delay, refreshInterval)
	}
	for _, tc := range []struct {
		after time.Duration
		want  collectionMode
	}{
		{processWatchInterval - time.Nanosecond, collectionFast},
		{processWatchInterval, collectionProcess},
		{slowRefreshInterval - time.Nanosecond, collectionProcess},
		{slowRefreshInterval, collectionFull},
	} {
		if got := schedule.nextMode(now.Add(tc.after)); got != tc.want {
			t.Errorf("next collection after %v = %v, want %v", tc.after, got, tc.want)
		}
	}
}

func TestCollectionScheduleWaitsForMissingSnapshots(t *testing.T) {
	now := time.Now()
	var schedule collectionSchedule
	failed := collectionResult{mode: collectionFast, completedAt: now, err: errors.New("no snapshot")}
	for range 2 {
		if delay := schedule.recordCompletion(failed, refreshInterval); delay != refreshInterval {
			t.Fatalf("missing snapshot delay = %v, want %v", delay, refreshInterval)
		}
		if schedule.hasSnapshot || schedule.nextMode(now) != collectionFast {
			t.Fatal("missing snapshot advanced startup")
		}
	}

	// A partial snapshot is still useful. Enrich it immediately once, then
	// honor the normal interval even when the full collection also fails.
	failed.data.CollectedAt = now
	if delay := schedule.recordCompletion(failed, refreshInterval); delay != 0 {
		t.Fatalf("first usable snapshot delay = %v, want immediate enrichment", delay)
	}
	failed.mode = collectionFull
	if delay := schedule.recordCompletion(failed, refreshInterval); delay != refreshInterval {
		t.Fatalf("failed enrichment delay = %v, want %v", delay, refreshInterval)
	}
	if got := schedule.nextMode(now); got != collectionFast {
		t.Fatalf("failed enrichment next mode = %v, want fast", got)
	}
}

func TestFullCollectionUsesCompletionTimeWithoutMarkingErrorsFresh(t *testing.T) {
	startedAt := time.Now()
	completedAt := startedAt.Add(2 * slowRefreshInterval)
	for _, collectionErr := range []error{nil, errors.New("full collector failed")} {
		m := model{schedule: collectionSchedule{hasSnapshot: true}}
		updated, _ := m.Update(collectionResult{
			data:        MetricsSnapshot{CollectedAt: startedAt},
			err:         collectionErr,
			mode:        collectionFull,
			completedAt: completedAt,
		})
		got := updated.(model)
		if got.fullCollected != (collectionErr == nil) {
			t.Fatalf("fullCollected = %v after error %v", got.fullCollected, collectionErr)
		}
		if !got.lastUpdated.Equal(startedAt) || !got.metrics.CollectedAt.Equal(startedAt) {
			t.Fatal("attempt completion replaced the original sample timestamp")
		}
		if got.schedule.nextMode(completedAt) != collectionFast {
			t.Fatal("slow full collection immediately retried")
		}
		if got.schedule.nextMode(completedAt.Add(slowRefreshInterval-time.Nanosecond)) != collectionProcess {
			t.Fatal("full collection retried before its interval elapsed")
		}
		if got.schedule.nextMode(completedAt.Add(slowRefreshInterval)) != collectionFull {
			t.Fatal("full collection did not become eligible after its interval")
		}
	}
}

func TestProcessFailureDoesNotForceFullRefresh(t *testing.T) {
	now := time.Now()
	m := model{schedule: collectionSchedule{hasSnapshot: true, lastFullAttemptAt: now}, fullCollected: true}
	for second := 1; second < int(slowRefreshInterval/time.Second); second++ {
		completedAt := now.Add(time.Duration(second) * time.Second)
		updated, _ := m.Update(collectionResult{
			data:        MetricsSnapshot{CollectedAt: completedAt},
			err:         errors.New("process collector failed"),
			mode:        collectionProcess,
			completedAt: completedAt,
		})
		m = updated.(model)
		if !m.fullCollected || !m.schedule.lastFullAttemptAt.Equal(now) {
			t.Fatal("process failure changed the full collection state")
		}
		if got := m.schedule.nextMode(completedAt); got != collectionFast {
			t.Fatalf("process failure retried immediately: mode %v", got)
		}
	}
	if got := m.schedule.nextMode(now.Add(slowRefreshInterval)); got != collectionFull {
		t.Fatalf("full refresh suppressed after process errors: mode %v", got)
	}
}

func TestCollectionRecoveryKeepsReadinessAndSerializesTicks(t *testing.T) {
	var m model
	now := time.Now()
	for _, collectionErr := range []error{errors.New("probe failed"), nil, errors.New("probe failed again")} {
		started, command := m.Update(tickMsg{})
		m = started.(model)
		if command == nil || !m.collecting {
			t.Fatal("tick did not start collection")
		}
		if _, duplicate := m.Update(tickMsg{}); duplicate != nil {
			t.Fatal("a second tick started overlapping collection")
		}

		wasFullCollected := m.fullCollected
		updated, nextTick := m.Update(collectionResult{
			data:        MetricsSnapshot{CollectedAt: now, CPU: CPUStatus{Usage: 25}},
			err:         collectionErr,
			mode:        collectionFull,
			completedAt: now.Add(time.Second),
		})
		m = updated.(model)
		if m.collecting || nextTick == nil || !m.schedule.hasSnapshot {
			t.Fatal("completed collection did not publish its snapshot and schedule another tick")
		}
		if m.metrics.CPU.Usage != 25 || (m.errMessage != "") != (collectionErr != nil) {
			t.Fatal("partial data or collection error was lost")
		}
		if m.fullCollected != (wasFullCollected || collectionErr == nil) {
			t.Fatal("full collection readiness did not survive failure and recovery")
		}
		now = now.Add(slowRefreshInterval)
	}
}

// Run the real one-shot JSON path in a child so os.Exit and stdout stay
// isolated. Every platform reader is stubbed and the process probe fails.
func TestStatusJSONProcess(t *testing.T) {
	scenario := os.Getenv("SWEEPR_STATUS_JSON_TEST")
	if scenario == "" {
		t.Skip("json subprocess helper")
	}
	stubPlatformForTest()
	readDisksFunc = func(map[string]bool) ([]DiskStatus, error) {
		return []DiskStatus{{Mount: `C:\`, Device: "C:", Total: 2 << 30, Used: 1 << 30, UsedPercent: 50}}, nil
	}
	readProcessesFunc = func() ([]procSample, error) { return nil, errors.New("process probe failed") }
	if scenario != "1" {
		readCPUFunc = func() (CPUStatus, error) { return CPUStatus{}, errors.New("cpu probe failed") }
		readMemoryFunc = func() (MemoryStatus, error) { return MemoryStatus{}, errors.New("memory probe failed") }
		readDisksFunc = func(map[string]bool) ([]DiskStatus, error) { return nil, errors.New("disk probe failed") }
		switch scenario {
		case "cpu":
			readCPUFunc = func() (CPUStatus, error) { return CPUStatus{LogicalCPU: 2}, nil }
		case "memory":
			readMemoryFunc = func() (MemoryStatus, error) { return MemoryStatus{Total: 8 << 30}, nil }
		case "processes":
			readProcessesFunc = func() ([]procSample, error) { return nil, nil }
		}
	}
	runJSONMode()
	os.Exit(0)
}

func runJSONChild(t *testing.T, scenario string) (stdout, stderr bytes.Buffer, err error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestStatusJSONProcess$")
	cmd.Env = append(os.Environ(), "SWEEPR_STATUS_JSON_TEST="+scenario)
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err = cmd.Run()
	return stdout, stderr, err
}

func TestJSONModePrintsPartialSnapshotWhenOneCollectorFails(t *testing.T) {
	stdout, stderr, err := runJSONChild(t, "1")
	if err != nil {
		t.Fatalf("json mode exited with %v; stderr: %s", err, &stderr)
	}
	if !strings.Contains(stderr.String(), "process probe failed") {
		t.Fatalf("collector failure not reported on stderr: %q", &stderr)
	}
	var snapshot MetricsSnapshot
	if err := json.Unmarshal(stdout.Bytes(), &snapshot); err != nil {
		t.Fatalf("stdout is not one JSON snapshot: %v\n%s", err, &stdout)
	}
	if snapshot.CollectedAt.IsZero() || len(snapshot.Disks) != 1 || snapshot.Disks[0].Total != 2<<30 {
		t.Fatalf("successful metrics missing: collected_at=%v disks=%+v", snapshot.CollectedAt, snapshot.Disks)
	}
	if snapshot.ProcessCollectedAt != nil {
		t.Fatalf("failed process probe reported a sample: %+v", snapshot)
	}
}

func TestWriteJSONSnapshotFailsWhenNothingWasCollected(t *testing.T) {
	for _, collectErr := range []error{errors.New("cpu probe failed"), nil} {
		var stdout, stderr bytes.Buffer
		if code := writeJSONSnapshot(&stdout, &stderr, MetricsSnapshot{}, collectErr); code != 1 {
			t.Fatalf("empty snapshot exit = %d, want 1", code)
		}
		if stdout.Len() != 0 {
			t.Fatalf("empty snapshot printed JSON: %q", &stdout)
		}
		if !strings.Contains(stderr.String(), "status: collect failed:") {
			t.Fatalf("empty snapshot gave no reason: %q", &stderr)
		}
	}
}

func TestJSONModeCollectorAvailability(t *testing.T) {
	for _, scenario := range []string{"none", "cpu", "memory", "processes"} {
		t.Run(scenario, func(t *testing.T) {
			stdout, stderr, err := runJSONChild(t, scenario)
			if scenario == "none" {
				var exitErr *exec.ExitError
				if !errors.As(err, &exitErr) || exitErr.ExitCode() != 1 || stdout.Len() != 0 {
					t.Fatalf("all failed: err=%v stdout=%q stderr=%q", err, &stdout, &stderr)
				}
			} else {
				if err != nil {
					t.Fatalf("partial snapshot failed: %v, %s", err, &stderr)
				}
				var snapshot MetricsSnapshot
				if err := json.Unmarshal(stdout.Bytes(), &snapshot); err != nil {
					t.Fatal(err)
				}
				switch scenario {
				case "cpu":
					if snapshot.CPU.LogicalCPU != 2 || snapshot.CPU.Usage != 0 {
						t.Fatalf("idle CPU sample lost: %+v", snapshot.CPU)
					}
				case "memory":
					if snapshot.Memory.Total != 8<<30 {
						t.Fatalf("memory sample lost: %+v", snapshot.Memory)
					}
				case "processes":
					if snapshot.ProcessCollectedAt == nil || len(snapshot.TopProcesses) != 0 {
						t.Fatalf("empty process sample lost: %+v", snapshot)
					}
				}
			}
			if !strings.Contains(stderr.String(), "probe failed") {
				t.Fatalf("missing collector errors: %q", &stderr)
			}
		})
	}
}

func TestWriteJSONSnapshotReportsOutputFailure(t *testing.T) {
	reader, writer := io.Pipe()
	_ = reader.Close()
	defer writer.Close()
	var stderr bytes.Buffer
	data := MetricsSnapshot{Memory: MemoryStatus{Total: 8 << 30}}
	if code := writeJSONSnapshot(writer, &stderr, data, nil); code != 1 {
		t.Fatalf("output failure exit = %d, want 1", code)
	}
	if !strings.Contains(stderr.String(), "error encoding JSON:") {
		t.Fatalf("missing output error: %q", &stderr)
	}
}
