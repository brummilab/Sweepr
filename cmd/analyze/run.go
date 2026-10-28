package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"sort"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

// Deps is everything the program reaches the outside world through, so that a
// test can replace each part. Scanner nil means the scanner over FS; StartUI
// nil means the real terminal display.
type Deps struct {
	FS       FS
	Recycler Recycler
	Clock    Clock
	Scanner  Scanner
	StartUI  func(tea.Model) error
}

const usageLine = "Usage: sw analyze [OPTIONS] [PATH]"

const helpText = usageLine + `

Show where the disk space went: the size of everything below each folder,
the largest files, and a safe way to move entries to the Recycle Bin.

Without PATH the overview shows the profile folder and the fixed drives.
On a terminal the explorer opens; when the output is redirected, or with
--json, one JSON document is printed instead.

Options:
  --json        print one JSON document and exit
  -h, --help    show this help

Keys in the explorer:
  Up Down PgUp PgDn Home End   move
  Enter, Right                 open the folder
  Left, Backspace, Esc         back (Esc in the overview quits)
  Space                        mark or unmark
  Delete                       move the marked entries (or the current one)
                               to the Recycle Bin, after a confirmation
  T                            largest files
  R                            measure again
  Q, Ctrl+C                    quit

Entries are only ever moved to the Recycle Bin, never deleted for good.
Protected locations, links and cloud files cannot be moved.
`

type options struct {
	help  bool
	json  bool
	paths []string
}

// parseArgs reads the command line. One or two dashes are the same; option
// names are lower case; "--" ends the options. At most one path word is
// allowed, before or after the options.
func parseArgs(args []string) (options, error) {
	var o options
	onlyPaths := false
	for _, a := range args {
		if !onlyPaths && a == "--" {
			onlyPaths = true
			continue
		}
		if !onlyPaths && len(a) > 1 && a[0] == '-' {
			name := strings.TrimPrefix(strings.TrimPrefix(a, "-"), "-")
			switch name {
			case "h", "help":
				o.help = true
			case "json":
				o.json = true
			default:
				return o, fmt.Errorf("unknown option '%s'", a)
			}
			continue
		}
		o.paths = append(o.paths, a)
		if len(o.paths) > 1 {
			return o, fmt.Errorf("unexpected argument '%s': only one path is accepted", a)
		}
	}
	return o, nil
}

// Run is the program: it reads the command line and the environment map,
// writes to the given streams and returns the exit code (0 or 1).
func Run(args []string, env map[string]string, stdout, stderr io.Writer, stdoutIsTerminal bool, d Deps) int {
	opts, err := parseArgs(args)
	if err != nil {
		fmt.Fprintf(stderr, "analyze: %v\nTry 'sw analyze --help' for usage.\n", err)
		return 1
	}
	if opts.help {
		io.WriteString(stdout, helpText)
		return 0
	}
	if d.Clock == nil {
		d.Clock = systemClock{}
	}
	if d.FS == nil {
		fmt.Fprintln(stderr, "analyze: no file system access available")
		return 1
	}

	target := strings.TrimSpace(env["SWEEPR_ANALYZE_PATH"])
	if target == "" && len(opts.paths) == 1 {
		target = opts.paths[0]
	}
	if target != "" {
		resolved, err := resolveTarget(target, env, d.FS)
		if err != nil {
			fmt.Fprintf(stderr, "analyze: %v\n", err)
			return 1
		}
		target = resolved
	}

	if opts.json || !stdoutIsTerminal {
		return runJSON(target, env, stdout, stderr, d)
	}
	start := d.StartUI
	if start == nil {
		start = runTerminalUI
	}
	model := newExplorerModel(d, env, target)
	err = start(model)
	if em, ok := model.(*explorerModel); ok {
		em.waitIdle()
	}
	if err != nil {
		fmt.Fprintf(stderr, "analyze: the display could not start: %v\n", err)
		return 1
	}
	return 0
}

// runTerminalUI runs the display on the alternate screen; the terminal is
// restored when it ends.
func runTerminalUI(m tea.Model) error {
	_, err := tea.NewProgram(m, tea.WithAltScreen()).Run()
	return err
}

func runJSON(target string, env map[string]string, stdout, stderr io.Writer, d Deps) int {
	var doc string
	if target == "" {
		doc = overviewJSON(overviewItems(context.Background(), d.FS, env))
	} else {
		l, err := Measure(context.Background(), d.FS, target, &Counters{}, nil)
		if err != nil {
			fmt.Fprintf(stderr, "analyze: cannot read %s: %v\n", target, err)
			return 1
		}
		doc = folderJSON(l)
	}
	if _, err := io.WriteString(stdout, doc); err != nil {
		fmt.Fprintf(stderr, "analyze: cannot write the result: %v\n", err)
		return 1
	}
	return 0
}

// resolveTarget turns what the user typed into an absolute, cleaned path of
// an existing folder. A leading ~ is the profile folder, "D:" is the root
// "D:\", a relative path is taken from the working directory.
func resolveTarget(raw string, env map[string]string, fsys FS) (string, error) {
	p := raw
	if p == "~" || strings.HasPrefix(p, `~\`) || strings.HasPrefix(p, "~/") {
		home := profileFolder(env)
		if home == "" {
			return "", fmt.Errorf("%s: the profile folder is not known", raw)
		}
		p = home + p[1:]
	}
	if len(p) == 2 && isASCIILetter(p[0]) && p[1] == ':' {
		p += `\`
	}
	wp, ok := parseWinPath(p)
	if !ok {
		var err error
		if wp, err = absolutize(p); err != nil {
			return "", fmt.Errorf("%s: %v", raw, err)
		}
	}
	path := wp.String()
	id, err := fsys.Identity(path)
	switch {
	case err == nil && !id.IsDir:
		return "", fmt.Errorf("%s: not a folder", path)
	case err != nil && errors.Is(err, fs.ErrNotExist):
		return "", fmt.Errorf("%s: not found", path)
	case err != nil:
		return "", fmt.Errorf("%s: %v", path, err)
	}
	return path, nil
}

// absolutize makes a relative path absolute against the working directory of
// the process: "dir" and "..\dir" start there, "\dir" at the root of its
// drive, "D:dir" in the current folder of D when that is the current drive.
func absolutize(p string) (winPath, error) {
	cwd, err := workingDir()
	if err != nil {
		return winPath{}, err
	}
	base, ok := parseWinPath(cwd)
	if !ok {
		return winPath{}, errors.New("the path is not absolute and the working directory is not a Windows path")
	}
	switch {
	case len(p) >= 2 && isSep(rune(p[0])) && !isSep(rune(p[1])):
		base.segs = nil
		p = p[1:]
	case len(p) >= 2 && isASCIILetter(p[0]) && p[1] == ':':
		if !strings.EqualFold(base.root, p[:2]) {
			base = winPath{root: strings.ToLower(p[:1]) + ":", display: strings.ToUpper(p[:1]) + `:\`}
		}
		p = p[2:]
	}
	wp, ok := parseWinPath(base.String() + `\` + p)
	if !ok {
		return winPath{}, errors.New("not a usable path")
	}
	return wp, nil
}

// sortedDrives returns the fixed drives in letter order.
func sortedDrives(fsys FS) []Drive {
	drives := fsys.Drives()
	sort.SliceStable(drives, func(i, j int) bool {
		return strings.ToUpper(drives[i].Root) < strings.ToUpper(drives[j].Root)
	})
	return drives
}

// driveItem is the row of a drive: the occupied space of the whole volume,
// total minus all free space, read without walking the drive.
func driveItem(d Drive) Item {
	root := d.Root
	if wp, ok := parseWinPath(root); ok {
		root = wp.String()
	}
	it := Item{Name: root, Path: root, IsDir: true}
	if d.Err != nil || d.Total <= 0 || d.Free < 0 || d.Free > d.Total {
		it.State = Unavailable
		return it
	}
	it.Size = d.Total - d.Free
	return it
}

// homeFolder is the profile folder when it is an existing folder.
func homeFolder(env map[string]string, fsys FS) (string, bool) {
	wp, ok := parseWinPath(profileFolder(env))
	if !ok {
		return "", false
	}
	path := wp.String()
	if id, err := fsys.Identity(path); err != nil || !id.IsDir {
		return "", false
	}
	return path, true
}

// homeItem is the row of the profile folder after its measurement.
func homeItem(path string, l *Listing, err error) Item {
	it := Item{Name: "Home", Path: path, IsDir: true}
	if err != nil || l == nil {
		it.State = Unavailable
		return it
	}
	it.Size, it.OnlineSize, it.State = l.TotalSize, l.TotalOnlineSize, l.State
	for _, c := range l.Items {
		if c.Cloud {
			it.Cloud = true
		}
	}
	return it
}

// overviewItems measures the profile folder like any folder and reads the
// drives; the result is the profile folder first, then the drives by letter.
func overviewItems(ctx context.Context, fsys FS, env map[string]string) []Item {
	var items []Item
	if home, ok := homeFolder(env, fsys); ok {
		l, err := Measure(ctx, fsys, home, &Counters{}, nil)
		items = append(items, homeItem(home, &l, err))
	}
	for _, d := range sortedDrives(fsys) {
		items = append(items, driveItem(d))
	}
	return items
}
