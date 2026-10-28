// Command status measures the load of the computer: CPU, memory, drives,
// network and processes. It shows them in an interactive display, as one JSON
// document or as a stream of JSON lines. It only measures; the single file it
// ever writes is its own settings file.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/charmbracelet/x/term"
)

const helpText = `Usage: sw status [--json | --watch [--interval <duration>]]

Show the load of this computer: CPU, memory, drives, network and processes.

With a terminal as output, an interactive display opens. Press c to change
how many CPU cores are listed, q, Esc or Ctrl+C to quit. Without a terminal
(a pipe or a file), one JSON measurement is printed.

Options:
  --json                  Print one JSON measurement, even on a terminal.
  --watch                 Print one JSON line per measurement until the output
                          closes.
  --interval <duration>   Wait between measurements of --watch, for example
                          500ms, 1s or 2m. Must be greater than 0. Default: 1s.
  -h, --help              Show this help.
`

// Area names used in notices and in the title of the display.
const (
	areaPlatform = "platform"
	areaUptime   = "uptime"
	areaCPU      = "cpu"
	areaMemory   = "memory"
	areaSwap     = "page file"
	areaDisks    = "disks"
	areaDiskIO   = "disk I/O"
	areaNetwork  = "network"
	areaProcs    = "processes"
)

// unavailableAreas names the areas of a snapshot that could not be measured.
// A process ranking that is missing only because the CPU could not be measured
// is reported as the CPU.
func unavailableAreas(s Snapshot) []string {
	var out []string
	add := func(missing bool, name string) {
		if missing {
			out = append(out, name)
		}
	}
	add(s.CPU == nil, areaCPU)
	add(s.Memory == nil, areaMemory)
	add(s.Memory != nil && (s.Memory.SwapTotal == nil || s.Memory.SwapUsed == nil), areaSwap)
	add(s.Disks == nil, areaDisks)
	add(s.DiskIO == nil, areaDiskIO)
	add(s.Network == nil || s.NetworkTotal == nil, areaNetwork)
	add(s.Procs == nil, areaProcs)
	add(s.UptimeSeconds == nil, areaUptime)
	add(s.Platform == nil, areaPlatform)
	return out
}

type options struct {
	help     bool
	json     bool
	watch    bool
	interval time.Duration
}

// usageError is a rejected command line.
type usageError struct{ msg string }

func (e usageError) Error() string { return e.msg }

// parseArgs reads the command line from left to right. The first problem ends
// the parse; the help option ends it successfully, so it wins over everything
// that was valid before it.
func parseArgs(args []string) (options, error) {
	opts := options{interval: time.Second}
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if !strings.HasPrefix(arg, "-") || arg == "-" || arg == "--" {
			if arg == "-" || arg == "--" {
				return opts, usageError{fmt.Sprintf("unknown option %q", arg)}
			}
			return opts, usageError{fmt.Sprintf("unexpected argument %q", arg)}
		}
		name := strings.TrimPrefix(strings.TrimPrefix(arg, "-"), "-")
		value, hasValue := "", false
		if k := strings.Index(name, "="); k >= 0 {
			name, value, hasValue = name[:k], name[k+1:], true
		}
		switch name {
		case "h", "help":
			if hasValue {
				return opts, usageError{fmt.Sprintf("option %q takes no value", "--"+name)}
			}
			opts.help = true
			return opts, nil
		case "json", "watch":
			if hasValue {
				return opts, usageError{fmt.Sprintf("option %q takes no value", "--"+name)}
			}
			if name == "json" {
				opts.json = true
			} else {
				opts.watch = true
			}
		case "interval":
			if !hasValue {
				if i+1 >= len(args) {
					return opts, usageError{"option \"--interval\" needs a value such as 500ms, 1s or 2m"}
				}
				i++
				value = args[i]
			}
			d, err := time.ParseDuration(value)
			if err != nil || d <= 0 {
				return opts, usageError{fmt.Sprintf("invalid value %q for option \"--interval\": use a duration greater than 0 such as 500ms, 1s or 2m", value)}
			}
			opts.interval = d
		default:
			return opts, usageError{fmt.Sprintf("unknown option %q", arg)}
		}
	}
	return opts, nil
}

// DashboardConfig is what the interactive display needs from Run.
type DashboardConfig struct {
	Env     map[string]string
	Sources Sources
	Clock   Clock
	Prefs   *PrefsStore
	Stdout  io.Writer
	Stderr  io.Writer
}

// DashboardStarter runs the interactive display until the user quits and
// returns the exit code.
type DashboardStarter func(DashboardConfig) int

// RunOption changes how Run behaves.
type RunOption func(*runSettings)

type runSettings struct {
	dashboard DashboardStarter
}

// WithDashboard replaces the function that starts the interactive display, so
// that the choice of the display can be checked without a terminal.
func WithDashboard(start DashboardStarter) RunOption {
	return func(r *runSettings) { r.dashboard = start }
}

// Run is the program without the process around it. It returns the exit code.
// Standard output carries data only (help, JSON); messages go to stderr.
func Run(args []string, env map[string]string, stdout, stderr io.Writer, stdoutIsTerminal bool,
	src Sources, clk Clock, runOpts ...RunOption) int {
	rs := runSettings{dashboard: runDashboard}
	for _, o := range runOpts {
		o(&rs)
	}
	if stderr == nil {
		stderr = io.Discard
	}

	opts, err := parseArgs(args)
	if err != nil {
		fmt.Fprintf(stderr, "status: %v\nTry 'sw status --help' for usage.\n", err)
		return 1
	}
	if opts.help {
		if _, err := io.WriteString(stdout, helpText); err != nil {
			return 1
		}
		return 0
	}

	switch {
	case opts.watch:
		return stream(opts.interval, env, stdout, stderr, src, clk)
	case opts.json || !stdoutIsTerminal:
		return measureOnce(env, stdout, stderr, src, clk)
	default:
		return rs.dashboard(DashboardConfig{
			Env:     env,
			Sources: src,
			Clock:   clk,
			Prefs:   OpenPrefs(env),
			Stdout:  stdout,
			Stderr:  stderr,
		})
	}
}

func newSampler(env map[string]string, src Sources, clk Clock) *Sampler {
	s := NewSampler(src, clk)
	s.SetSystemDrive(lookupEnv(env, "SystemDrive"))
	return s
}

// encode writes the snapshot as one JSON document followed by a newline.
// HTML escaping is off, so adapter names stay readable.
func encode(w io.Writer, s Snapshot, indent bool) error {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if indent {
		enc.SetIndent("", "  ")
	}
	if err := enc.Encode(&s); err != nil {
		return err
	}
	_, err := w.Write(buf.Bytes())
	return err
}

func reportUnavailable(stderr io.Writer, areas []string) {
	for _, a := range areas {
		fmt.Fprintf(stderr, "status: %s is not available\n", a)
	}
}

// measureOnce prints one measurement. It fails only when nothing could be
// measured or the document could not be written.
func measureOnce(env map[string]string, stdout, stderr io.Writer, src Sources, clk Clock) int {
	snap, err := newSampler(env, src, clk).Sample()
	reportUnavailable(stderr, unavailableAreas(snap))
	if err != nil {
		return 1
	}
	if err := encode(stdout, snap, true); err != nil {
		fmt.Fprintln(stderr, "status: cannot write the measurement")
		return 1
	}
	return 0
}

// stream prints one compact JSON line per measurement, the next one interval
// after the previous one finished. It ends quietly when stdout is closed. A
// notice about an unavailable area appears once per outage, not once per line.
func stream(interval time.Duration, env map[string]string, stdout, stderr io.Writer, src Sources, clk Clock) int {
	s := newSampler(env, src, clk)
	reported := map[string]bool{}
	for {
		snap, _ := s.Sample()
		if err := encode(stdout, snap, false); err != nil {
			return 0
		}
		now := map[string]bool{}
		for _, a := range unavailableAreas(snap) {
			now[a] = true
			if !reported[a] {
				reportUnavailable(stderr, []string{a})
			}
		}
		reported = now
		clk.Sleep(interval)
	}
}

// environMap turns the process environment into a map.
func environMap() map[string]string {
	env := map[string]string{}
	for _, kv := range os.Environ() {
		if kv == "" {
			continue
		}
		// Windows keeps entries such as "=C:=C:\" for the current folders,
		// so the search for the separator starts after the first character.
		if k, v, ok := strings.Cut(kv[1:], "="); ok {
			env[kv[:1]+k] = v
		}
	}
	return env
}

func main() {
	ignoreBrokenPipe()
	os.Exit(Run(os.Args[1:], environMap(), os.Stdout, os.Stderr,
		term.IsTerminal(os.Stdout.Fd()), nativeSources(), systemClock{}))
}
