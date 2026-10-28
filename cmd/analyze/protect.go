package main

import (
	"errors"
	"io/fs"
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
	trees  []winPath // environment folders, with everything below
	exact  []winPath // only the folder itself
	data   []winPath // Sweepr's data folders
	suffix map[string]bool
}

func newRuleSet(env map[string]string) ruleSet {
	var rs ruleSet
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
	rs.data = dataFolders(env)

	// Last segments that can make a path protected, to skip the full check for
	// the vast majority of names while a tree is walked.
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
	return rs
}

// dataFolders returns the places Sweepr keeps its configuration and cache:
// below SWEEPR_DATA_DIR when that is set, else below the profile folder. A
// data directory that is not a Windows path names no folder here.
func dataFolders(env map[string]string) []winPath {
	if dir := envValue(env, "SWEEPR_DATA_DIR"); dir != "" {
		wp, ok := parseWinPath(dir)
		if !ok {
			return nil
		}
		return []winPath{wp.child("config"), wp.child("cache")}
	}
	profile := profileFolder(env)
	if profile == "" {
		return nil
	}
	wp, ok := parseWinPath(profile)
	if !ok {
		return nil
	}
	return []winPath{wp.child(".config").child("sweepr"), wp.child(".cache").child("sweepr")}
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
func (rs ruleSet) rule(wp winPath) protVerdict {
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

// dataID is the identity of an existing data folder and of its ancestors.
type dataID struct {
	self  FileID
	above []FileID
}

func readDataIDs(fsys FS, folders []winPath) []dataID {
	var out []dataID
	for _, d := range folders {
		id, err := fsys.Identity(d.String())
		if err != nil {
			continue // not there (yet): nothing to compare with
		}
		di := dataID{self: id}
		for _, a := range d.ancestors() {
			if aid, err := fsys.Identity(a.String()); err == nil {
				di.above = append(di.above, aid)
			}
		}
		out = append(out, di)
	}
	return out
}

// byIdentity compares a target with the data folders by file identity, which
// no spelling (short name, substituted drive, share path, junction in an
// ancestor) can get around. A target or ancestor whose identity cannot be
// read is protected.
func byIdentity(chain idChain, data []dataID) protVerdict {
	for i, l := range chain {
		if l.err == nil {
			continue
		}
		if i == 0 && errors.Is(l.err, fs.ErrNotExist) {
			continue // a target that does not exist yet has no identity
		}
		return dataFolderBy("its identity could not be read, so it cannot be told apart from the Sweepr data folder")
	}
	for _, d := range data {
		for _, l := range chain {
			if l.err == nil && sameFile(l.id, d.self) {
				return dataFolderBy("it is part of the Sweepr data folder")
			}
		}
		if chain[0].err == nil {
			for _, a := range d.above {
				if sameFile(chain[0].id, a) {
					return dataFolderBy("it contains the Sweepr data folder")
				}
			}
		}
	}
	return protVerdict{}
}

// protector answers protection questions for one environment.
type protector struct {
	fs FS
	rs ruleSet
}

func newProtector(env map[string]string, fsys FS) *protector {
	return &protector{fs: fsys, rs: newRuleSet(env)}
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
	return byIdentity(readIDChain(p.fs, wp), readDataIDs(p.fs, p.rs.data))
}

// IsProtected tells whether a path may never be removed: it is a system,
// profile or secret-store location, part of Sweepr's data folder, or this
// cannot be told. Both the typed spelling and the spelling with the
// containing folder resolved are checked, and the identity is compared with
// the data folders. It does not walk the tree below the path.
func IsProtected(path string, env map[string]string, fs FS) bool {
	return newProtector(env, fs).verdict(path).kind != protNone
}
