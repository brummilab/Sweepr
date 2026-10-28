package main

// The network history of the display: only measured values are drawn, a
// sample that failed is a gap, and a history without any measured value is
// not drawn at all.

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func tstHistoryFrame(t *testing.T, rx []histPoint) string {
	t.Helper()
	snap := tstSnapshotFromDoc(t, tstCopyDoc(tstBaseDoc()))
	return renderFrame(frameInput{snap: snap, set: Settings{CPUCores: 2}, width: 80, height: 40, rxHistory: rx, txHistory: rx})
}

func TestHistoryDrawsMeasuredPointsAndLeavesGapsBlank(t *testing.T) {
	frame := tstHistoryFrame(t, []histPoint{{1, true}, {}, {4, true}})
	found := false
	for _, l := range tstFrameLines(frame) {
		if strings.HasPrefix(strings.TrimSpace(l), "Down") && strings.HasSuffix(l, "▂ █") {
			found = true
		}
	}
	if !found {
		t.Errorf("no history line ending in the points 1, gap, 4:\n%s", frame)
	}
}

func TestHistoryOfGapsOnlyIsNotDrawn(t *testing.T) {
	frame := tstHistoryFrame(t, []histPoint{{}, {}, {}})
	for _, l := range tstFrameLines(frame) {
		if word := strings.TrimSpace(l); word == "Down" || word == "Up" {
			t.Errorf("a history line is drawn for samples that were never measured:\n%s", frame)
		}
	}
}

func TestHistoryKeepsAtMostTheLastHundredTwentyPoints(t *testing.T) {
	var h []histPoint
	for i := 0; i < 3*historyLength; i++ {
		h = appendHistory(h, histPoint{float64(i), true})
	}
	if len(h) != historyLength {
		t.Fatalf("history holds %d points, want %d", len(h), historyLength)
	}
	if first := h[0].v; first != float64(2*historyLength) {
		t.Errorf("oldest point is %v, want the 241st sample", first)
	}
}

func TestModelLeavesAGapInTheHistoryForASampleWithoutNetworkRates(t *testing.T) {
	m := newDashboardModel(Sources{}, newFakeClock(), nil)
	m.Update(tea.WindowSizeMsg{Width: 80, Height: 40})
	withRate := func(mbs float64) Snapshot {
		snap := tstSnapshotFromDoc(t, tstCopyDoc(tstBaseDoc()))
		snap.NetworkTotal = &NetworkTotalSnapshot{RxRateMBs: mbs, TxRateMBs: mbs}
		return snap
	}
	failed := withRate(0)
	failed.NetworkTotal = nil
	for _, snap := range []Snapshot{withRate(8), failed, withRate(4)} {
		m.Update(measuredMsg{sampler: nil, snap: snap})
	}
	found := false
	for _, l := range tstFrameLines(m.View()) {
		if strings.HasPrefix(strings.TrimSpace(l), "Down") && strings.HasSuffix(l, "█ ▄") {
			found = true
			if strings.Contains(l, "▁") {
				t.Errorf("the failed sample is drawn as the lowest bar: %q", l)
			}
		}
	}
	if !found {
		t.Errorf("history does not show 8, gap, 4:\n%s", m.View())
	}
}
