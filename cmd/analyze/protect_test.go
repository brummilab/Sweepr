package main

// Path protection (normalization, rule groups A to E, resolution, identity,
// fail-closed) as a function of strings and the artificial file system.

import "testing"

// tstEnsure creates the path (and its folders) in the artificial file system
// when it has a form that the fake understands.
func tstEnsure(f *fakeFS, paths ...string) {
	for _, p := range paths {
		if _, ok := tstParse(p); ok {
			f.dir(p)
		}
	}
}

func tstProtected(t *testing.T, f *fakeFS, env map[string]string, path string) bool {
	t.Helper()
	return IsProtected(path, env, f)
}

func tstProtRig() (*fakeFS, map[string]string) {
	f := newFakeFS()
	tstWinTree(f)
	return f, tstWinEnv()
}

var tstProtectedPaths = []string{
	// group A: trees on every volume
	`C:\Windows`, `C:\Windows\System32\drivers\etc\hosts`, `c:\WINDOWS\system32`, `C:\Windows\Temp\x`,
	`D:\Program Files\App`, `D:\Program Files (x86)\App`, `E:\ProgramData\x`,
	`E:\$Recycle.Bin\S-1-5-21\f`, `C:\System Volume Information`, `D:\Recovery\x`, `C:\Config.Msi`,
	`C:\Users\Default\x`, `C:\Users\Public\Documents`, `E:\Users\Default`,
	// group B: exact
	`C:\`, `D:\`, `C:\Users`, `D:\Users`, `C:\Users\someone`, `D:\Users\Joe`, `C:\Users\Example`,
	// group C: environment trees
	`C:\ProgramData\Microsoft\Windows Defender\x`,
	`C:\Users\Example\AppData\Local\Docker\x`, `C:\Users\Example\AppData\Local\Packages\Microsoft.Foo\x`,
	// group D1
	`C:\Users\Example\AppData\Roaming\Microsoft\Credentials\blob`,
	`C:\Users\Example\AppData\Roaming\Microsoft\Protect\S-1\k`,
	`C:\Users\Example\AppData\Roaming\Microsoft\Crypto\RSA\k`,
	`C:\Users\Example\AppData\Local\Microsoft\Vault\v`,
	`C:\Users\Example\AppData\Roaming\Microsoft\SystemCertificates\My`,
	`C:\Users\Example\AppData\Roaming\Microsoft\Windows\Start Menu\Programs`,
	// group D2
	`C:\Users\Example\.ssh\id_ed25519`, `C:\Users\Example\.gnupg\x`, `C:\Users\Example\.aws\credentials`,
	`C:\Users\Example\.azure\x`, `C:\Users\Example\.kube\config`, `C:\Users\Example\.docker\config.json`,
	`C:\Users\Example\Documents\.ssh`, // as the last segment
	`C:\Users\Example\AppData\Local\Google\Chrome\User Data\Default\Login Data`,
	`C:\Users\Example\AppData\Local\Google\Chrome\User Data\Default\Cookies`,
	`C:\Users\Example\AppData\Local\Google\Chrome\User Data\Default\Web Data`,
	`C:\Users\Example\AppData\Local\Google\Chrome\User Data\Default\Local Storage\leveldb`,
	`C:\Users\Example\AppData\Local\Google\Chrome\User Data\Default\Session Storage\x`,
	`C:\Users\Example\AppData\Local\Google\Chrome\User Data\Default\IndexedDB\x`,
	`C:\Users\Example\AppData\Local\Google\Chrome\User Data\Default\Sessions\x`,
	`C:\Users\Example\AppData\Local\Google\Chrome\User Data\Default\Local Extension Settings\x`,
	`C:\Users\Example\AppData\Local\Google\Chrome\User Data\Default\Sync Data\x`,
	`C:\Users\Example\AppData\Local\Google\Chrome\User Data\Default\Service Worker\CacheStorage\x`,
	`C:\Users\Example\AppData\Roaming\Adobe\Common\Team Projects Cache\x`,
	`C:\Users\Example\AppData\Local\pypoetry\Cache\virtualenvs\env1`,
	`C:\Users\Example\AppData\Roaming\Code\User\History\x`,
	`C:\Users\Example\.claude\projects\p\s.jsonl`, `C:\Users\Example\.claude\file-history\x`,
	`C:\Users\Example\.claude\history.jsonl`,
	`C:\Users\Example\.codex\sessions\x`, `C:\Users\Example\.codex\archived_sessions`, `C:\Users\Example\.codex\history.jsonl`,
	`c:\users\example\.SSH\ID`,
	// spellings
	`\\?\C:\ProgramData`, `\\?\C:\Windows\System32`, `\\.\C:\Windows`, `\??\C:\Windows`, `\\?\C:\`,
	`\\localhost\c$\Windows\x`, `\\?\UNC\localhost\c$\Windows`, `\\localhost\c$\`,
	`\\?\Volume{0123-4567}\Windows\x`, `\\?\HarddiskVolume3\Windows\x`,
	`\\?\Volume{0123-4567}\Users\Example`,
	`C:\Windows\`, `C:\Windows\\System32`, `C:\Data\..\Windows\x`, `C:/Windows/x`,
	`\\?\GLOBALROOT\Device\HarddiskVolume1\x`,
}

var tstUnprotectedPaths = []string{
	`C:\Windows.old\x`, `D:\data\Program Files`, `C:\Projects\Windows`, `C:\ProgramDataBackup\x`,
	`C:\Users\Example\Downloads`, `C:\Users\Example\Documents\x`,
	`C:\Users\Example\AppData\Local\Temp\x`,
	`C:\Users\someone\Downloads`, `D:\Users\Joe\Docs`,
	`C:\Users\Example\.awsome\x`, `C:\Users\Example\CookiesBackup\x`, `C:\Users\Example\Sessions2\x`,
	`C:\Users\Example\AppData\Local\DockerDesktop\x`, `C:\Users\Example\AppData\Local\PackagesX\y`,
	`C:\Users\Example\sub\Microsoft\Windows\Themes`, `C:\Users\Example\x\Credentials\y`,
	`C:\Users\Example\x\Microsoft\Cryptography\y`,
	`C:\Users\Example\.claude\settings.json`, `C:\Users\Example\.claude`, `C:\Users\Example\.codex\config.toml`,
	`C:\Windows\..\Data\x`, `D:\Data\x`, `E:\Stuff`,
	`\\?\Volume{0123-4567}\Data\x`, `\\?\Volume{0123-4567}\Users\Example\Downloads`,
}

func TestProtectionCoversEveryRuleGroupAndSpelling(t *testing.T) {
	for _, p := range tstProtectedPaths {
		f, env := tstProtRig()
		tstEnsure(f, p)
		if !tstProtected(t, f, env, p) {
			t.Errorf("%s is not protected", p)
		}
	}
}

func TestProtectionLeavesOrdinaryPathsAndNameLookalikesAlone(t *testing.T) {
	for _, p := range tstUnprotectedPaths {
		f, env := tstProtRig()
		tstEnsure(f, p)
		if tstProtected(t, f, env, p) {
			t.Errorf("%s is protected", p)
		}
	}
}

func TestProtectionFailsClosedForEmptyRelativeAndOddPaths(t *testing.T) {
	for _, p := range []string{"", " ", `foo\bar`, `..\x`, `C:foo`, `\Windows`, "C:\\x\x00y", `Data`, `.`} {
		f, env := tstProtRig()
		if !tstProtected(t, f, env, p) {
			t.Errorf("%q is not protected, want fail-closed", p)
		}
	}
}

func TestProtectionFailsClosedWhenTheParentDoesNotExist(t *testing.T) {
	f, env := tstProtRig()
	if !tstProtected(t, f, env, `C:\NoSuchParent\x`) {
		t.Errorf(`C:\NoSuchParent\x is not protected, want fail-closed for an unresolvable parent`)
	}
}

func TestProtectionFailsClosedWhenResolvingTheParentFails(t *testing.T) {
	f, env := tstProtRig()
	f.dir(`C:\Data\x`)
	f.resolveErr[tstKey(`C:\Data`)] = errTstBoom
	if !tstProtected(t, f, env, `C:\Data\x`) {
		t.Errorf("not protected although the parent cannot be resolved")
	}
}

func TestProtectionFollowsTheEnvironmentValues(t *testing.T) {
	f, _ := tstProtRig()
	env := map[string]string{
		"USERPROFILE": `C:\Users\Example`, "LOCALAPPDATA": `F:\Local`,
		"WINDIR": `F:\Win`, "SystemRoot": `F:\Win`,
		"ProgramFiles": `F:\PF`, "ProgramFiles(x86)": `F:\PF86`, "ProgramW6432": `F:\PF64`,
		"ProgramData": `F:\PD`,
	}
	prot := []string{
		`F:\Win\x`, `F:\PF\x`, `F:\PF86\x`, `F:\PF64\x`, `F:\PD\x`,
		`F:\PD\Microsoft\Windows Defender\x`, `F:\Local\Docker\x`, `F:\Local\Packages\x`,
	}
	open := []string{`F:\Other\x`, `F:\Local\Temp\x`, `F:\Win2\x`}
	tstEnsure(f, prot...)
	tstEnsure(f, open...)
	for _, p := range prot {
		if !tstProtected(t, f, env, p) {
			t.Errorf("%s is not protected", p)
		}
	}
	for _, p := range open {
		if tstProtected(t, f, env, p) {
			t.Errorf("%s is protected", p)
		}
	}
}

func TestProtectionDropsEmptyVariablesWithoutProtectingRelativeLookalikes(t *testing.T) {
	f, _ := tstProtRig()
	env := map[string]string{"USERPROFILE": `C:\Users\Example`}
	open := []string{`C:\Docker\x`, `C:\Packages\x`, `C:\Microsoft\Windows Defender\x`, `C:\Data\x`}
	tstEnsure(f, open...)
	for _, p := range open {
		if tstProtected(t, f, env, p) {
			t.Errorf("%s is protected although the variables are missing", p)
		}
	}
	tstEnsure(f, `C:\Windows\x`)
	if !tstProtected(t, f, env, `C:\Windows\x`) {
		t.Errorf(`C:\Windows\x is not protected without WINDIR: the tree rule of every volume still applies`)
	}
	for _, v := range []string{"", "  "} {
		env2 := tstEnvWith(tstWinEnv(), "WINDIR", v, "SystemRoot", v, "ProgramFiles", v, "ProgramFiles(x86)", v,
			"ProgramW6432", v, "ProgramData", v, "LOCALAPPDATA", v)
		for _, p := range open {
			if tstProtected(t, f, env2, p) {
				t.Errorf("%s is protected with the variable set to %q", p, v)
			}
		}
	}
}

func TestProtectionOfTheProfileFolderIsExact(t *testing.T) {
	f, _ := tstProtRig()
	env := tstEnvWith(tstWinEnv(), "USERPROFILE", `E:\Home\Me`)
	tstEnsure(f, `E:\Home\Me\Docs`)
	if !tstProtected(t, f, env, `E:\Home\Me`) {
		t.Errorf("the profile folder itself is not protected")
	}
	if tstProtected(t, f, env, `E:\Home\Me\Docs`) {
		t.Errorf("a folder inside the profile folder is protected")
	}
}

func TestProtectionFallsBackToTheHomeFolderOfTheRuntime(t *testing.T) {
	home := `D:\Profiles\Fallback`
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	f, _ := tstProtRig()
	tstEnsure(f, home+`\Docs`)
	env := tstEnvWith(tstWinEnv(), "USERPROFILE", "")
	if !tstProtected(t, f, env, home) {
		t.Errorf("the home folder of the runtime is not protected")
	}
	if tstProtected(t, f, env, home+`\Docs`) {
		t.Errorf("a folder inside the home folder is protected")
	}
}

func TestProtectionKnowsNoDataFolderWhenNothingIsKnown(t *testing.T) {
	t.Setenv("HOME", "")
	t.Setenv("USERPROFILE", "")
	f, _ := tstProtRig()
	tstEnsure(f, `C:\Data\x`)
	if tstProtected(t, f, map[string]string{}, `C:\Data\x`) {
		t.Errorf(`C:\Data\x is protected although no variable is set`)
	}
}

// ---------------------------------------------------------------------------
// Resolution of the parent (junctions, aliases)

func TestProtectionLooksThroughAJunctionInTheParent(t *testing.T) {
	for _, verbatim := range []bool{false, true} {
		f, env := tstProtRig()
		f.verbatimResolve = verbatim
		f.dir(`C:\ProgramData\Microsoft`)
		f.link(`D:\pd`, `C:\ProgramData`)
		f.link(`D:\w`, `C:\Windows`)
		tstEnsure(f, `C:\Windows\Temp\x`)
		if !tstProtected(t, f, env, `D:\pd\Microsoft`) {
			t.Errorf("verbatim=%v: D:\\pd\\Microsoft (a junction to C:\\ProgramData) is not protected", verbatim)
		}
		if !tstProtected(t, f, env, `D:\w\Temp\x`) {
			t.Errorf("verbatim=%v: D:\\w\\Temp\\x (a junction to C:\\Windows) is not protected", verbatim)
		}
	}
}

func TestProtectionOfABenignJunctionStaysOpen(t *testing.T) {
	f, env := tstProtRig()
	f.file(`D:\Data2\x`, 1)
	f.link(`D:\j`, `D:\Data2`)
	if tstProtected(t, f, env, `D:\j\x`) {
		t.Errorf(`D:\j\x is protected although the junction leads to an ordinary folder`)
	}
}

func TestProtectionDoesNotResolveTheLastSegment(t *testing.T) {
	f, env := tstProtRig()
	f.link(`D:\Data\lnk`, `C:\Windows`)
	if tstProtected(t, f, env, `D:\Data\lnk`) {
		t.Errorf("the leaf is resolved: a link named lnk is judged by its own name")
	}
}

func TestProtectionLooksThroughShortNamesInTheParent(t *testing.T) {
	f, env := tstProtRig()
	f.alias(`C:\PROGRA~1`, `C:\Program Files`)
	tstEnsure(f, `C:\Program Files\App`)
	if !tstProtected(t, f, env, `C:\PROGRA~1\App`) {
		t.Errorf(`C:\PROGRA~1\App is not protected`)
	}
}

// ---------------------------------------------------------------------------
// Sweepr data folders

func tstDataRig(dataDir string) (*fakeFS, map[string]string) {
	f, env := tstProtRig()
	env = tstEnvWith(env, "SWEEPR_DATA_DIR", dataDir)
	return f, env
}

func TestProtectionOfTheDataFolderWithADataDirectory(t *testing.T) {
	f, env := tstDataRig(`C:\SweeprData`)
	prot := []string{
		`C:\SweeprData\config`, `C:\SweeprData\config\operations.log`, `C:\SweeprData\cache\x`,
		`C:\SweeprData`, // an ancestor takes the data folders with it
	}
	open := []string{`C:\SweeprData2`, `C:\SweeprData2\config`, `C:\SweeprData\other`, `C:\SweeprData\configx`, `C:\Users\Example\Downloads`}
	tstEnsure(f, prot...)
	tstEnsure(f, open...)
	tstEnsure(f, `C:\SweeprData\cache`)
	for _, p := range prot {
		if !tstProtected(t, f, env, p) {
			t.Errorf("%s is not protected", p)
		}
	}
	for _, p := range open {
		if tstProtected(t, f, env, p) {
			t.Errorf("%s is protected", p)
		}
	}
}

func TestProtectionOfTheProfileDataFoldersWithoutADataDirectory(t *testing.T) {
	f, env := tstProtRig()
	prot := []string{
		`C:\Users\Example\.config\sweepr`, `C:\Users\Example\.config\sweepr\x`, `C:\Users\Example\.cache\sweepr\y`,
		`C:\Users\Example\.config`, `C:\Users\Example\.cache`,
	}
	open := []string{`C:\Users\Example\.config\sweepr2`, `C:\Users\Example\.config\other`, `C:\Users\Example\.cache\other\z`}
	tstEnsure(f, prot...)
	tstEnsure(f, open...)
	for _, p := range prot {
		if !tstProtected(t, f, env, p) {
			t.Errorf("%s is not protected", p)
		}
	}
	for _, p := range open {
		if tstProtected(t, f, env, p) {
			t.Errorf("%s is protected", p)
		}
	}
}

func TestProtectionTakesAWhitespaceDataDirectoryAsUnset(t *testing.T) {
	f, env := tstDataRig("   ")
	tstEnsure(f, `C:\Users\Example\.config\sweepr\x`)
	if !tstProtected(t, f, env, `C:\Users\Example\.config\sweepr\x`) {
		t.Errorf("the profile data folder is not protected although the data directory is blank")
	}
}

func TestProtectionTrimsTheDataDirectory(t *testing.T) {
	f, env := tstDataRig(`  C:\SweeprData  `)
	tstEnsure(f, `C:\SweeprData\config\x`)
	if !tstProtected(t, f, env, `C:\SweeprData\config\x`) {
		t.Errorf("the data folder is not protected when the variable has surrounding blanks")
	}
}

func TestProtectionDataDirectoryReplacesTheProfileFolders(t *testing.T) {
	f, env := tstDataRig(`C:\SweeprData`)
	tstEnsure(f, `C:\Users\Example\.config\sweepr\x`)
	if tstProtected(t, f, env, `C:\Users\Example\.config\sweepr\x`) {
		t.Errorf("the profile data folder is protected although SWEEPR_DATA_DIR names another place")
	}
}

func TestProtectionRecognisesTheDataFolderByIdentityThroughAnotherName(t *testing.T) {
	for _, resolving := range []bool{true, false} {
		f, env := tstDataRig(`C:\SweeprData`)
		tstEnsure(f, `C:\SweeprData\config\x`, `C:\SweeprData\other`)
		f.noResolve = !resolving
		f.rootAlias("S", `C:\SweeprData`)       // a subst drive
		f.alias(`C:\SWEEPR~1`, `C:\SweeprData`) // a short name
		f.link(`D:\j`, `C:\SweeprData`)         // a junction in the ancestor
		cases := map[string]bool{
			`S:\config\x`:                        true,
			`S:\config`:                          true,
			`C:\SWEEPR~1\config\x`:               true,
			`D:\j\config\x`:                      true,
			`\\localhost\C$\SweeprData\config\x`: true,
			`S:\other`:                           false,
		}
		for p, want := range cases {
			if got := tstProtected(t, f, env, p); got != want {
				t.Errorf("resolving=%v: IsProtected(%s) = %v, want %v", resolving, p, got, want)
			}
		}
	}
}

func TestProtectionRejectsWhenAnIdentityCannotBeRead(t *testing.T) {
	f, env := tstProtRig()
	tstEnsure(f, `C:\Data\x`, `D:\Data\y`)
	f.failIdentity(`C:\Data\x`, errTstAccess)
	if !tstProtected(t, f, env, `C:\Data\x`) {
		t.Errorf("not protected although the identity of the target cannot be read")
	}
	f.failIdentity(`D:\Data`, errTstBoom)
	if !tstProtected(t, f, env, `D:\Data\y`) {
		t.Errorf("not protected although the identity of an ancestor cannot be read")
	}
}

func TestProtectionDoesNotRejectWhenTheDataFolderDoesNotExistYet(t *testing.T) {
	f, env := tstProtRig()
	tstEnsure(f, `C:\Data\x`)
	if tstProtected(t, f, env, `C:\Data\x`) {
		t.Errorf("an ordinary path is protected only because the data folder does not exist")
	}
}
