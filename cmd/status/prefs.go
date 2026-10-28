package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// The settings file holds one "key=value" line per setting. It is read when
// the display starts and written only when the user changes a setting. Every
// failure is silent: the display goes on and the value holds until it ends.

const (
	prefsDirName  = "config"
	prefsFileName = "status_prefs"
	// prefsProfileDir is the folder below the home folder in profile mode.
	prefsProfileDir = ".config/sweepr"

	prefsKeyCPUCores = "cpu_cores"
)

// PrefsStore reads and saves the settings file.
type PrefsStore struct {
	mu     sync.Mutex
	path   string // empty when no folder is known: nothing is read or written
	values map[string]string
	// newest remembers the latest ticket saved per key, so that a slow older
	// save cannot overwrite a newer one (see setOrdered).
	newest map[string]uint64
}

// lookupEnv reads from the environment map. Windows names are case
// insensitive, so the lookup falls back to a case-insensitive match there.
func lookupEnv(env map[string]string, name string) string {
	if v, ok := env[name]; ok {
		return v
	}
	if runtime.GOOS == "windows" {
		for k, v := range env {
			if strings.EqualFold(k, name) {
				return v
			}
		}
	}
	return ""
}

// prefsPath returns the location of the settings file, or "" when there is
// neither a data folder nor a home folder.
func prefsPath(env map[string]string) string {
	if data := strings.TrimSpace(lookupEnv(env, "SWEEPR_DATA_DIR")); data != "" {
		return filepath.Join(data, prefsDirName, prefsFileName)
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return filepath.Join(home, filepath.FromSlash(prefsProfileDir), prefsFileName)
}

// OpenPrefs reads the settings file if there is one. A missing or unreadable
// file gives no values; reading never creates a folder or a file.
func OpenPrefs(env map[string]string) *PrefsStore {
	p := &PrefsStore{path: prefsPath(env), values: map[string]string{}, newest: map[string]uint64{}}
	if p.path != "" {
		if data, err := os.ReadFile(p.path); err == nil {
			p.values = parsePrefs(data)
		}
	}
	return p
}

// Get returns the value of a setting.
func (p *PrefsStore) Get(key string) (string, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	v, ok := p.values[key]
	return v, ok
}

// Set stores a setting and tries to save it. The value holds in memory even if
// saving fails.
func (p *PrefsStore) Set(key, value string) {
	p.setOrdered(0, key, value)
}

// setOrdered is Set for callers that save from several goroutines: a save
// with a smaller ticket than one already done for the key is dropped. A ticket
// of 0 always saves.
func (p *PrefsStore) setOrdered(ticket uint64, key, value string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if ticket != 0 {
		if ticket < p.newest[key] {
			return
		}
		p.newest[key] = ticket
	}
	p.values[key] = value
	p.save(key, value)
}

// validPrefsEntry keeps the file free of anything but "key=value" lines.
func validPrefsEntry(key, value string) bool {
	if key == "" || strings.HasPrefix(key, "#") || strings.TrimSpace(key) != key {
		return false
	}
	return !strings.ContainsAny(key, "=\r\n") && !strings.ContainsAny(value, "\r\n")
}

// save merges one key into the file: lock first, then read the current
// content, set the key, write all keys sorted into a temporary file in the
// same folder and replace the file with it. Two programs that save different
// keys at the same time therefore lose neither. Errors end the save quietly.
func (p *PrefsStore) save(key, value string) {
	if p.path == "" || !validPrefsEntry(key, strings.TrimSpace(value)) {
		return
	}
	value = strings.TrimSpace(value)
	dir := filepath.Dir(p.path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return
	}
	lock, err := os.OpenFile(p.path+".lock", os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return
	}
	defer lock.Close()
	if err := lockExclusive(lock); err != nil {
		return
	}
	defer unlock(lock)

	current := map[string]string{}
	data, err := os.ReadFile(p.path)
	switch {
	case err == nil:
		current = parsePrefs(data)
	case errors.Is(err, os.ErrNotExist):
	default:
		// Unreadable: never replace what cannot be read.
		return
	}
	current[key] = value

	keys := make([]string, 0, len(current))
	for k := range current {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var out bytes.Buffer
	for _, k := range keys {
		out.WriteString(k + "=" + current[k] + "\n")
	}

	tmp, err := os.CreateTemp(dir, prefsFileName+".tmp*")
	if err != nil {
		return
	}
	tmpName := tmp.Name()
	_, werr := tmp.Write(out.Bytes())
	cerr := tmp.Close()
	if werr != nil || cerr != nil || os.Rename(tmpName, p.path) != nil {
		_ = os.Remove(tmpName)
	}
}

// parsePrefs reads "key=value" lines. Blank lines, lines starting with "#" and
// lines without "=" are ignored; keys and values are trimmed, CRLF line ends
// and a byte-order mark are tolerated.
func parsePrefs(data []byte) map[string]string {
	out := map[string]string{}
	text := strings.TrimPrefix(string(data), "\xef\xbb\xbf")
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		k = strings.TrimSpace(k)
		if k == "" {
			continue
		}
		out[k] = strings.TrimSpace(v)
	}
	return out
}

// settingsFrom reads the display settings. A missing, unreadable or negative
// value gives the default.
func settingsFrom(p *PrefsStore) Settings {
	set := Settings{CPUCores: defaultCPUCores}
	if p == nil {
		return set
	}
	if v, ok := p.Get(prefsKeyCPUCores); ok {
		if n, err := strconv.Atoi(v); err == nil && n >= 0 {
			set.CPUCores = n
		}
	}
	return set
}
