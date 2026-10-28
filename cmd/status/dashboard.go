package main

import (
	"errors"
	"fmt"
	"strconv"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// refreshDelay is the pause between the end of one measurement and the start
// of the next.
const refreshDelay = time.Second

// measuredMsg carries the result of one measurement back to the model.
type measuredMsg struct {
	sampler *Sampler
	snap    Snapshot
}

// dashboardModel is the Bubble Tea model of the interactive display. A
// measurement runs as a command in its own goroutine, one at a time: the next
// one is only started when the previous result has arrived. Keys and window
// changes therefore never wait for a measurement.
type dashboardModel struct {
	src      Sources
	clk      Clock
	prefs    *PrefsStore
	sysDrive string
	color    bool

	settings      Settings
	width, height int

	snap      *Snapshot
	rxHistory []histPoint
	txHistory []histPoint

	saveTicket uint64
}

func newDashboardModel(src Sources, clk Clock, prefs *PrefsStore) *dashboardModel {
	return &dashboardModel{
		src:      src,
		clk:      clk,
		prefs:    prefs,
		sysDrive: "C:",
		settings: settingsFrom(prefs),
	}
}

// Init starts the first measurement at once. The sampler is created inside the
// command, because creating it reads the counters.
func (m *dashboardModel) Init() tea.Cmd {
	src, clk, drive := m.src, m.clk, m.sysDrive
	return func() tea.Msg {
		s := NewSampler(src, clk)
		s.SetSystemDrive(drive)
		return sample(s)
	}
}

func sample(s *Sampler) tea.Msg {
	snap, _ := s.Sample()
	return measuredMsg{sampler: s, snap: snap}
}

func (m *dashboardModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
	case measuredMsg:
		m.snap = &msg.snap
		m.remember(msg.snap)
		clk, s := m.clk, msg.sampler
		return m, func() tea.Msg {
			clk.Sleep(refreshDelay)
			return sample(s)
		}
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "esc", "ctrl+c":
			return m, tea.Quit
		case "c":
			return m, m.cycleCores()
		}
	}
	return m, nil
}

// cycleCores steps the number of listed cores through 2, 4, 8 and all (0); a
// value outside that sequence goes to 2. The new value shows at once and is
// saved in the background.
func (m *dashboardModel) cycleCores() tea.Cmd {
	next := defaultCPUCores
	switch m.settings.CPUCores {
	case 2:
		next = 4
	case 4:
		next = 8
	case 8:
		next = 0
	}
	m.settings.CPUCores = next
	if m.prefs == nil {
		return nil
	}
	m.saveTicket++
	ticket, prefs, value := m.saveTicket, m.prefs, strconv.Itoa(next)
	return func() tea.Msg {
		prefs.setOrdered(ticket, prefsKeyCPUCores, value)
		return nil
	}
}

// remember adds the network rates of a measurement to the history, which is
// kept for the display only. A measurement without rates leaves a gap.
func (m *dashboardModel) remember(s Snapshot) {
	rx, tx := histPoint{}, histPoint{}
	if t := s.NetworkTotal; t != nil {
		rx, tx = histPoint{t.RxRateMBs, true}, histPoint{t.TxRateMBs, true}
	}
	m.rxHistory = appendHistory(m.rxHistory, rx)
	m.txHistory = appendHistory(m.txHistory, tx)
}

func appendHistory(h []histPoint, p histPoint) []histPoint {
	h = append(h, p)
	if len(h) > historyLength {
		h = append([]histPoint(nil), h[len(h)-historyLength:]...)
	}
	return h
}

func (m *dashboardModel) View() string {
	if m.snap == nil {
		return loadingFrame(m.width, m.height, m.color)
	}
	return renderFrame(frameInput{
		snap:      *m.snap,
		set:       m.settings,
		width:     m.width,
		height:    m.height,
		color:     m.color,
		rxHistory: m.rxHistory,
		txHistory: m.txHistory,
	})
}

// useColor tells whether the display may use color: not when NO_COLOR is set
// to a non-empty value.
func useColor(env map[string]string) bool {
	return lookupEnv(env, "NO_COLOR") == ""
}

// runDashboard runs the display on the alternate screen until the user quits.
func runDashboard(cfg DashboardConfig) int {
	m := newDashboardModel(cfg.Sources, cfg.Clock, cfg.Prefs)
	m.sysDrive = lookupEnv(cfg.Env, "SystemDrive")
	m.color = useColor(cfg.Env)
	p := tea.NewProgram(m, tea.WithAltScreen(), tea.WithOutput(cfg.Stdout))
	if _, err := p.Run(); err != nil && !errors.Is(err, tea.ErrInterrupted) {
		fmt.Fprintf(cfg.Stderr, "status: cannot run the display: %v\n", err)
		return 1
	}
	return 0
}
