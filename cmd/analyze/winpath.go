package main

import "strings"

// Windows paths are handled as text on every host: the program measures a
// Windows file system, and the logic must give the same answer when it runs
// under test on another system. path/filepath is therefore not used for them.

// winPath is an absolute path split into volume and segments.
type winPath struct {
	root    string   // comparison key of the volume: "c:", `\\host\share`, `\\?\volume{id}`
	display string   // the volume as shown, ends with a backslash
	segs    []string // segments as written
}

func isSep(r rune) bool { return r == '\\' || r == '/' }

func hasPrefixFold(s, prefix string) bool {
	return len(s) >= len(prefix) && strings.EqualFold(s[:len(prefix)], prefix)
}

func isASCIILetter(b byte) bool { return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') }

// splitSegments splits on both separators and resolves "." and "..". A ".."
// at the top stays at the top, like the Windows path normalization does.
func splitSegments(s string) []string {
	var out []string
	for _, seg := range strings.FieldsFunc(s, isSep) {
		switch seg {
		case ".":
		case "..":
			if len(out) > 0 {
				out = out[:len(out)-1]
			}
		default:
			out = append(out, seg)
		}
	}
	return out
}

var devicePrefixes = []string{`\\?\`, `\\.\`, `\??\`}

// parseWinPath understands X:\..., \\?\X:\..., \\.\X:\..., \??\X:\...,
// \\host\share\..., \\?\UNC\host\share\..., \\localhost\x$\... (the same
// place as X:\) and \\?\Volume{id}\... / \\?\HarddiskVolumeN\.... Anything
// else (relative, drive-relative, other device paths, a NUL character) is not
// absolute and reports false.
func parseWinPath(p string) (winPath, bool) {
	if p == "" || strings.ContainsRune(p, 0) {
		return winPath{}, false
	}
	rest, verbatim := p, false
	for _, pre := range devicePrefixes {
		if hasPrefixFold(rest, pre) {
			rest, verbatim = rest[len(pre):], true
			break
		}
	}
	unc := func(body string) (winPath, bool) {
		segs := splitSegments(body)
		if len(segs) < 2 {
			return winPath{}, false
		}
		host, share := strings.ToLower(segs[0]), strings.ToLower(segs[1])
		if (host == "localhost" || host == "127.0.0.1") && len(share) == 2 && share[1] == '$' && isASCIILetter(share[0]) {
			return winPath{root: share[:1] + ":", display: strings.ToUpper(share[:1]) + `:\`, segs: segs[2:]}, true
		}
		return winPath{root: `\\` + host + `\` + share, display: `\\` + segs[0] + `\` + segs[1] + `\`, segs: segs[2:]}, true
	}
	switch {
	case len(rest) >= 3 && isASCIILetter(rest[0]) && rest[1] == ':' && isSep(rune(rest[2])):
		return winPath{root: strings.ToLower(rest[:1]) + ":", display: strings.ToUpper(rest[:1]) + `:\`, segs: splitSegments(rest[2:])}, true
	case verbatim && hasPrefixFold(rest, `UNC\`):
		return unc(rest[4:])
	case !verbatim && len(rest) >= 2 && isSep(rune(rest[0])) && isSep(rune(rest[1])):
		return unc(rest)
	case verbatim && (hasPrefixFold(rest, "Volume{") || hasPrefixFold(rest, "HarddiskVolume")):
		segs := splitSegments(rest)
		if len(segs) == 0 {
			return winPath{}, false
		}
		return winPath{root: `\\?\` + strings.ToLower(segs[0]), display: `\\?\` + segs[0] + `\`, segs: segs[1:]}, true
	}
	return winPath{}, false
}

// isGlobalRoot recognizes the object-manager root, through which every device
// and volume is reachable under another name.
func isGlobalRoot(p string) bool {
	for _, pre := range devicePrefixes {
		if hasPrefixFold(p, pre) {
			rest := p[len(pre):]
			if hasPrefixFold(rest, "GLOBALROOT") && (len(rest) == len("GLOBALROOT") || isSep(rune(rest[len("GLOBALROOT")]))) {
				return true
			}
		}
	}
	return false
}

func (w winPath) String() string { return w.display + strings.Join(w.segs, `\`) }

func (w winPath) isRoot() bool { return len(w.segs) == 0 }

func (w winPath) parent() winPath {
	if len(w.segs) == 0 {
		return w
	}
	w.segs = w.segs[:len(w.segs)-1]
	return w
}

func (w winPath) leaf() string {
	if len(w.segs) == 0 {
		return ""
	}
	return w.segs[len(w.segs)-1]
}

func (w winPath) child(name string) winPath {
	segs := make([]string, len(w.segs)+1)
	copy(segs, w.segs)
	segs[len(w.segs)] = name
	w.segs = segs
	return w
}

// foldSeg is the form of a segment used for comparisons: case folded, and
// without what Windows drops when it opens the name (a stream suffix and
// trailing dots and blanks), so that "Windows. " and "x:stream" are not a
// way around a name rule.
func foldSeg(s string) string {
	s = strings.ToLower(s)
	if i := strings.IndexByte(s, ':'); i >= 0 {
		s = s[:i]
	}
	return strings.TrimRight(s, ". ")
}

// folded returns the comparison form of the segments; names that fold to
// nothing are dropped.
func (w winPath) folded() []string {
	out := make([]string, 0, len(w.segs))
	for _, s := range w.segs {
		if f := foldSeg(s); f != "" {
			out = append(out, f)
		}
	}
	return out
}

func (w winPath) key() string { return w.root + `\` + strings.Join(w.folded(), `\`) }

// hasPrefix tells whether o is w itself or one of its ancestors.
func (w winPath) hasPrefix(o winPath) bool {
	if w.root != o.root {
		return false
	}
	a, b := w.folded(), o.folded()
	if len(b) > len(a) {
		return false
	}
	for i := range b {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// below tells whether w lies strictly below o.
func (w winPath) below(o winPath) bool {
	return w.hasPrefix(o) && len(w.folded()) > len(o.folded())
}

// ancestors lists the parents of w up to and including the volume root,
// nearest first.
func (w winPath) ancestors() []winPath {
	var out []winPath
	for cur := w; !cur.isRoot(); {
		cur = cur.parent()
		out = append(out, cur)
	}
	return out
}

// joinWin appends a name to a folder path.
func joinWin(dir, name string) string {
	if strings.HasSuffix(dir, `\`) {
		return dir + name
	}
	return dir + `\` + name
}

// hasDotDot tells whether the text has a ".." segment as written.
func hasDotDot(p string) bool {
	for _, seg := range strings.FieldsFunc(p, isSep) {
		if seg == ".." {
			return true
		}
	}
	return false
}
