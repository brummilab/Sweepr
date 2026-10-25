package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// Exercise the actual streaming loop in a child so its stdout and collector
// probes stay isolated from other tests. Every platform reader is stubbed.
func TestStatusWatchProcess(t *testing.T) {
	mode := os.Getenv("SWEEPR_STATUS_WATCH_TEST_MODE")
	if mode == "" {
		t.Skip("watch subprocess helper")
	}
	stubPlatformForTest()
	readBatteriesFunc = func() ([]BatteryStatus, error) {
		// This probe runs only during full collection. Count real dispatches
		// to ensure a process failure cannot restart it each tick.
		file, err := os.OpenFile(filepath.Join(os.Getenv("SWEEPR_STATUS_WATCH_TRACE_DIR"), "full-refreshes"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
		if err == nil {
			_, _ = file.WriteString("full\n")
			file.Close()
		}
		return []BatteryStatus{{Percent: 80, Status: "discharging"}}, nil
	}
	var calls atomic.Int32
	readDisksFunc = func(map[string]bool) ([]DiskStatus, error) {
		attempt := calls.Add(1)
		if mode == "failed" || (mode == "recover" && attempt <= 2) {
			return nil, errors.New("drive probe failed")
		}
		return []DiskStatus{{Mount: `C:\`, Device: "C:", Total: 2 << 30, Used: 1 << 30, UsedPercent: 50}}, nil
	}
	if mode == "process-failed" {
		readProcessesFunc = func() ([]procSample, error) { return nil, errors.New("process probe failed") }
	}
	runWatchStdout(time.Second)
}

func TestWatchHonorsIntervalAfterInitialSnapshot(t *testing.T) {
	for _, mode := range []string{"healthy", "failed", "recover", "process-failed"} {
		t.Run(mode, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestStatusWatchProcess$")
			fixtureHome := t.TempDir()
			cmd.Env = append(os.Environ(), "SWEEPR_STATUS_WATCH_TEST_MODE="+mode, "SWEEPR_STATUS_WATCH_TRACE_DIR="+fixtureHome)
			var stderr bytes.Buffer
			cmd.Stderr = &stderr
			stdout, err := cmd.StdoutPipe()
			if err != nil {
				t.Fatal(err)
			}
			defer stdout.Close()
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			defer func() {
				cancel()
				_ = cmd.Wait()
				if t.Failed() {
					t.Logf("watch stderr: %s", &stderr)
				}
			}()
			var snapshots [3]MetricsSnapshot
			decoder := json.NewDecoder(stdout)
			for i := range snapshots {
				if err := decoder.Decode(&snapshots[i]); err != nil {
					t.Fatalf("snapshot %d: %v", i, err)
				}
			}
			// Startup may enrich the first snapshot immediately. Every later
			// collection must wait, including repeated failures and recovery.
			if elapsed := snapshots[2].CollectedAt.Sub(snapshots[1].CollectedAt); elapsed < time.Second {
				t.Fatalf("next collection started after %v, want at least 1s", elapsed)
			}
			if mode == "failed" && len(snapshots[2].Disks) != 0 {
				t.Fatal("failed disk probe unexpectedly produced a disk")
			}
			if mode != "failed" && (len(snapshots[2].Disks) != 1 || snapshots[2].Disks[0].Total != 2<<30) {
				t.Fatalf("healthy or recovered disk missing: %+v", snapshots[2].Disks)
			}
			if mode == "process-failed" {
				for i, snapshot := range snapshots[1:] {
					if len(snapshot.Batteries) != 1 {
						t.Fatalf("snapshot %d lost the successful battery reading", i+1)
					}
				}
				trace, err := os.ReadFile(filepath.Join(fixtureHome, "full-refreshes"))
				if err != nil {
					t.Fatal(err)
				}
				if calls := strings.Count(string(trace), "full\n"); calls != 1 {
					t.Fatalf("process failure triggered %d full refreshes, want one startup attempt", calls)
				}
			}
		})
	}
}
