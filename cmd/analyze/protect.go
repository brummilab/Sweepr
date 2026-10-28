package main

import (
	"errors"
	"strings"
)

// Path protection. A path is protected when any rule matches; an empty path,
// a path that is not absolute and a path that cannot be normalized are
// protected too, because "unknown" must never read as "allowed".

type protKind int

const (
	protNone protKind = iota
	// protRule: a system, profile, secret-store or similar rule matched.
	protRule
	// protData: the path is, contains or lies in Sweepr's own data folders,
	// or this could not be ruled out.
	protData
)

type protVerdict struct {
	kind protKind
	why  string
}

func protectedBy(why string) protVerdict  { return protVerdict{protRule, why} }
func dataFolderBy(why string) protVerdict { return protVerdict{protData, why} }

// Trees on every volume, as folded segments from the volume root. The folder
// itself and everything below it is protected.
var protectedTrees = [][]string{
	{"windows"},
	{"program files"},
	{"program files (x86)"},
	{"programdata"},
	{"users", "default"},
	{"users", "public"},
	{"recovery"},
	{"system volume information"},
	{"$recycle.bin"},
	{"config.msi"},
}

// Segment sequences protected at any depth, also as the last segments of the
// path. They hold credentials, key material, browser profile data and session
// transcripts.
var protectedSequences = [][]string{
	{"microsoft", "credentials"},
	{"microsoft", "protect"},
	{"microsoft", "crypto"},
	{"microsoft", "vault"},
	{"microsoft", "systemcertificates"},
	{"microsoft", "windows", "start menu"},
	{".ssh"},
	{".gnupg"},
	{".aws"},
	{".azure"},
	{".kube"},
	{".docker"},
	{"login data"},
	{"cookies"},
	{"web data"},
	{"local storage"},
	{"session storage"},
	{"indexeddb"},
	{"sessions"},
	{"local extension settings"},
	{"sync data"},
	{"service worker", "cachestorage"},
	{"adobe", "common", "team projects cache"},
	{"pypoetry", "cache", "virtualenvs"},
	{"user", "history"},
	{".claude", "projects"},
	{".claude", "file-history"},
	{".claude", "history.jsonl"},
	{".codex", "sessions"},
	{".codex", "archived_sessions"},
	{".codex", "history.jsonl"},
}

// envTreeVars name the variables whose folder is protected with everything
// below it. Empty or missing variables add nothing.
var envTreeVars = []string{"WINDIR", "SystemRoot", "ProgramFiles", "ProgramFiles(x86)", "ProgramW6432", "ProgramData"}

// envValue reads a variable from the map the caller built; surrounding blanks
// do not count, and a missing variable is empty.
func envValue(env map[string]string, key string) string {
	return strings.TrimSpace(env[key])
}

// profileFolder is USERPROFILE, or the home folder of the runtime when the
// variable is empty.
func profileFolder(env map[string]string) string {
	if p := envValue(env, "USERPROFILE"); p != "" {
		return p
	}
	return runtimeHomeDir()
}

// ruleSet holds what the rules need from the environment. It is built again
// for every question, so a changed variable takes effect at once.
type ruleSet struct {
	trees []winPath // environment folders, with everything below
	exact []winPath // only the folder itself
	data  []winPath // Sweepr's data folders, as typed and as resolved
	// dataBad is set when SWEEPR_DATA_DIR names something that cannot be
	// compared as a Windows path and the platform treats that as an error.
	dataBad bool
	suffix  map[string]bool
}

func newRuleSet(env map[string]string) *ruleSet {
	rs := &ruleSet{}
	addTree := func(base string, tail ...string) {
		if base = strings.TrimSpace(base); base == "" {
			return
		}
		wp, ok := parseWinPath(base)
		if !ok {
			return
		}
		for _, t := range tail {
			wp = wp.child(t)
		}
		rs.trees = append(rs.trees, wp)
	}
	for _, k := range envTreeVars {
		addTree(env[k])
	}
	addTree(env["ProgramData"], "Microsoft", "Windows Defender")
	addTree(env["LOCALAPPDATA"], "Docker")
	addTree(env["LOCALAPPDATA"], "Packages")

	if wp, ok := parseWinPath(envValue(env, "USERPROFILE")); ok {
		rs.exact = append(rs.exact, wp)
	}
	if wp, ok := parseWinPath(runtimeHomeDir()); ok {
		rs.exact = append(rs.exact, wp)
	}
	rs.data, rs.dataBad = dataFolders(env)
	rs.indexSuffixes()
	return rs
}

// indexSuffixes records the last segments that can make a path protected, to
// skip the full check for the vast majority of names while a tree is walked.
func (rs *ruleSet) indexSuffixes() {
	rs.suffix = map[string]bool{}
	for _, t := range protectedTrees {
		rs.suffix[t[len(t)-1]] = true
	}
	for _, s := range protectedSequences {
		rs.suffix[s[len(s)-1]] = true
	}
	for _, group := range [][]winPath{rs.trees, rs.exact, rs.data} {
		for _, wp := range group {
			if f := wp.folded(); len(f) > 0 {
				rs.suffix[f[len(f)-1]] = true
			}
		}
	}
}

// dataFolders returns the places Sweepr keeps its configuration and cache:
// below SWEEPR_DATA_DIR when that is set, else below the profile folder. A
// data directory that is not a Windows path names no folder here; where the
// program really runs (strictDataDir) that is reported as bad, so that every
// removal is refused rather than guessed.
func dataFolders(env map[string]string) (folders []winPath, bad bool) {
	if dir := envValue(env, "SWEEPR_DATA_DIR"); dir != "" {
		wp, ok := parseWinPath(dir)
		if !ok {
			return nil, strictDataDir
		}
		return []winPath{wp.child("config"), wp.child("cache")}, false
	}
	profile := profileFolder(env)
	if profile == "" {
		return nil, false
	}
	wp, ok := parseWinPath(profile)
	if !ok {
		return nil, false
	}
	return []winPath{wp.child(".config").child("sweepr"), wp.child(".cache").child("sweepr")}, false
}

func hasSegPrefix(f, p []string) bool {
	if len(p) > len(f) {
		return false
	}
	for i := range p {
		if f[i] != p[i] {
			return false
		}
	}
	return true
}

func hasSegRun(f, run []string) bool {
	for i := 0; i+len(run) <= len(f); i++ {
		if hasSegPrefix(f[i:], run) {
			return true
		}
	}
	return false
}

// rule checks one spelling of a path against the protection rules and
// against the data folders by name.
func (rs *ruleSet) rule(wp winPath) protVerdict {
	f := wp.folded()
	switch {
	case len(f) == 0:
		return protectedBy("a drive or share root")
	case f[0] == "users" && len(f) <= 2:
		return protectedBy("the Users folder or a profile folder")
	}
	for _, t := range protectedTrees {
		if hasSegPrefix(f, t) {
			return protectedBy("a system folder")
		}
	}
	for _, e := range rs.exact {
		if e.key() == wp.key() {
			return protectedBy("the profile folder")
		}
	}
	for _, t := range rs.trees {
		if wp.hasPrefix(t) {
			return protectedBy("a system or program folder")
		}
	}
	for _, s := range protectedSequences {
		if hasSegRun(f, s) {
			return protectedBy("a folder with credentials, keys or profile data")
		}
	}
	for _, d := range rs.data {
		if wp.hasPrefix(d) {
			return dataFolderBy("it is part of the Sweepr data folder")
		}
		if d.hasPrefix(wp) {
			return dataFolderBy("it contains the Sweepr data folder")
		}
	}
	return protVerdict{}
}

// idLink is the identity of one path on the way from a target to its volume.
type idLink struct {
	id  FileID
	err error
}

// idChain holds the identity of a target (first) and of every ancestor up to
// the volume root, none of them followed through a final link.
type idChain []idLink

func readIDChain(fsys FS, wp winPath) idChain {
	chain := idChain{}
	read := func(p winPath) {
		id, err := fsys.Identity(p.String())
		chain = append(chain, idLink{id, err})
	}
	read(wp)
	for _, a := range wp.ancestors() {
		read(a)
	}
	return chain
}

// dataID holds the identities that stand for the data folders: the folders
// themselves (typed and resolved) and everything above them.
type dataID struct {
	self  []FileID
	above []FileID
}

// resolveNearest resolves a path that may not exist: the nearest existing
// part is resolved and the rest is appended. Only "does not exist" lets it
// move up; any other error is returned. A nil result means that not even the
// volume exists.
func resolveNearest(fsys FS, wp winPath) (*winPath, error) {
	var rest []string
	cur := wp
	for {
		r, err := fsys.Resolve(cur.String())
		if err == nil {
			rp, ok := parseWinPath(r)
			if !ok {
				return nil, errors.New("resolves to a form that cannot be compared")
			}
			for i := len(rest) - 1; i >= 0; i-- {
				rp = rp.child(rest[i])
			}
			return &rp, nil
		}
		if !isNotExist(err) {
			return nil, err
		}
		if cur.isRoot() {
			return nil, nil
		}
		rest = append(rest, cur.leaf())
		cur = cur.parent()
	}
}

// guardData prepares the comparison with the data folders. They are looked at
// as typed and as resolved (a link on the way, in a folder or in the data
// folder itself, moves them elsewhere), and by identity, for each of them and
// every ancestor. A folder that does not exist is no obstacle; any other
// failure to read leaves the question open, which refuses everything.
func (p *protector) guardData() {
	if p.rs.dataBad {
		p.dataFail = dataFolderBy("SWEEPR_DATA_DIR cannot be understood as a Windows path")
		return
	}
	typed := p.rs.data
	var all []winPath
	seen := map[string]bool{}
	add := func(w winPath) {
		if k := w.key(); !seen[k] {
			seen[k] = true
			all = append(all, w)
		}
	}
	for _, d := range typed {
		add(d)
		rd, err := resolveNearest(p.fs, d)
		if err != nil {
			p.dataFail = dataFolderBy("the Sweepr data folder cannot be resolved, so it cannot be told apart from other folders")
			return
		}
		if rd != nil {
			add(*rd)
		}
	}
	p.rs.data = all
	p.rs.indexSuffixes()

	var di dataID
	read := func(w winPath) (FileID, bool) {
		id, err := p.fs.Identity(w.String())
		if err != nil {
			if !isNotExist(err) {
				p.dataFail = dataFolderBy("the identity of the Sweepr data folder or a folder above it could not be read")
			}
			return FileID{}, false
		}
		return id, true
	}
	for _, w := range all {
		if id, ok := read(w); ok {
			di.self = append(di.self, id)
		}
		for _, a := range w.ancestors() {
			if id, ok := read(a); ok {
				di.above = append(di.above, id)
			}
		}
		if p.dataFail.kind != protNone {
			return
		}
	}
	p.dataIDs = di
}

// byIdentity compares a target with the data folders by file identity, which
// no spelling (short name, substituted drive, share path, junction in an
// ancestor) can get around. A target or ancestor whose identity cannot be
// read is protected.
func byIdentity(chain idChain, data dataID) protVerdict {
	for i, l := range chain {
		if l.err == nil {
			continue
		}
		if i == 0 && isNotExist(l.err) {
			continue // a target that does not exist yet has no identity
		}
		return dataFolderBy("its identity could not be read, so it cannot be told apart from the Sweepr data folder")
	}
	for _, l := range chain {
		for _, self := range data.self {
			if l.err == nil && sameFile(l.id, self) {
				return dataFolderBy("it is part of the Sweepr data folder")
			}
		}
	}
	if chain[0].err == nil {
		for _, a := range data.above {
			if sameFile(chain[0].id, a) {
				return dataFolderBy("it contains the Sweepr data folder")
			}
		}
	}
	return protVerdict{}
}

// protector answers protection questions for one environment.
type protector struct {
	fs       FS
	rs       *ruleSet
	dataIDs  dataID
	dataFail protVerdict // set when the data folders cannot be ruled in or out
}

func newProtector(env map[string]string, fsys FS) *protector {
	p := &protector{fs: fsys, rs: newRuleSet(env)}
	p.guardData()
	return p
}

// resolved returns the path as the file system sees it: the folder it lies in
// is resolved (junctions, links, short names), the last segment stays as
// written. A folder that cannot be resolved makes the path protected.
func (p *protector) resolved(wp winPath) (winPath, protVerdict) {
	if wp.isRoot() {
		return wp, protVerdict{}
	}
	r, err := p.fs.Resolve(wp.parent().String())
	if err != nil {
		return wp, protectedBy("the folder it lies in cannot be resolved")
	}
	rp, ok := parseWinPath(r)
	if !ok {
		return wp, protectedBy("the folder it lies in resolves to an unknown form")
	}
	return rp.child(wp.leaf()), protVerdict{}
}

// byName checks the typed and the resolved spelling against the rules.
func (p *protector) byName(wp winPath) (resolved winPath, v protVerdict) {
	if p.dataFail.kind != protNone {
		return wp, p.dataFail
	}
	if v = p.rs.rule(wp); v.kind != protNone {
		return wp, v
	}
	resolved, v = p.resolved(wp)
	if v.kind != protNone {
		return resolved, v
	}
	return resolved, p.rs.rule(resolved)
}

// verdict is the full answer for a path text.
func (p *protector) verdict(path string) protVerdict {
	if isGlobalRoot(path) {
		return protectedBy("a device path")
	}
	wp, ok := parseWinPath(path)
	if !ok {
		return protectedBy("it is not an absolute path")
	}
	if _, v := p.byName(wp); v.kind != protNone {
		return v
	}
	return byIdentity(readIDChain(p.fs, wp), p.dataIDs)
}

// IsProtected tells whether a path may never be removed: it is a system,
// profile or secret-store location, part of Sweepr's data folder, or this
// cannot be told. Both the typed spelling and the spelling with the
// containing folder resolved are checked, and the identity is compared with
// the data folders. It does not walk the tree below the path.
func IsProtected(path string, env map[string]string, fs FS) bool {
	return newProtector(env, fs).verdict(path).kind != protNone
}
