package main

// Data protection (ST-23): proxy settings with credentials, names of the
// machine or the user, environment values and process paths appear in no
// output; IP addresses only on the screen of the display.

import (
	"bytes"
	"os"
	"regexp"
	"strings"
	"testing"
)

var tstProxySecrets = []string{"Hunter2-Zq9", "proxyuser-Q7", "proxyhost.invalid"}

// tstPrivacySetup puts proxy variables with credentials, names and a secret
// into both the environment map and the real process environment.
func tstPrivacySetup(t *testing.T) (tstEnv, []string) {
	t.Helper()
	e := tstIsolated(t)
	proxy := "http://proxyuser-Q7:Hunter2-Zq9@proxyhost.invalid:3128"
	values := map[string]string{
		"HTTP_PROXY": proxy, "HTTPS_PROXY": proxy, "ALL_PROXY": proxy,
		"http_proxy": proxy, "https_proxy": proxy, "all_proxy": proxy,
		"NO_PROXY":           "internal.invalid",
		"USERNAME":           "ExampleUserQ7",
		"USER":               "ExampleUserQ7",
		"COMPUTERNAME":       "EXAMPLE-PC-Q7",
		"HOSTNAME":           "EXAMPLE-PC-Q7",
		"SWEEPR_TEST_SECRET": "Zq9-secret-value",
	}
	for k, v := range values {
		t.Setenv(k, v)
		e = e.with(k, v)
	}
	forbidden := append([]string{}, tstProxySecrets...)
	forbidden = append(forbidden, "ExampleUserQ7", "EXAMPLE-PC-Q7", "Zq9-secret-value", "internal.invalid", e.data, e.home)
	if host, err := os.Hostname(); err == nil && len(host) >= 6 {
		forbidden = append(forbidden, host)
	}
	return e, forbidden
}

func tstPrivacyProcs() []fakeProc {
	return []fakeProc{
		{PID: 4, Name: "", Start: 1, PrivateWS: tstMiB},
		{PID: 100, Name: `C:\Users\ExampleUserQ7\AppData\Local\Tool\tool.exe`, Start: 5, PrivateWS: 10 * tstMiB},
		{PID: 101, Name: "chrome.exe", Start: 6, PrivateWS: 20 * tstMiB},
	}
}

func tstPrivacyWorld(clk *fakeClock) *fakeWorld {
	w := newHealthyWorld(clk)
	w.procs = tstPrivacyProcs()
	w.adapters = []fakeAdapter{{Name: "Ethernet", IPv4: []string{"192.0.2.17"}, Default: true}}
	return w
}

func tstAssertClean(t *testing.T, where, output string, forbidden []string) {
	t.Helper()
	lower := strings.ToLower(output)
	for _, f := range forbidden {
		if strings.Contains(lower, strings.ToLower(f)) {
			t.Errorf("%s contains %q", where, f)
		}
	}
}

func TestOutputNeverContainsProxySettingsNamesOrEnvironmentValues(t *testing.T) {
	e, forbidden := tstPrivacySetup(t)

	clk := newFakeClock()
	oneShot := tstRun(t, tstPrivacyWorld(clk), clk, nil, e.env, false)
	if oneShot.code != 0 {
		t.Fatalf("one-shot exit code %d: %s", oneShot.code, oneShot.stderr)
	}
	tstAssertClean(t, "one-shot stdout", oneShot.stdout, forbidden)
	tstAssertClean(t, "one-shot stderr", oneShot.stderr, forbidden)

	clk = newFakeClock()
	w := tstPrivacyWorld(clk)
	w.procsErr = errFakeUnavailable
	partial := tstRun(t, w, clk, []string{"--json"}, e.env, true)
	tstAssertClean(t, "partial stdout", partial.stdout, forbidden)
	tstAssertClean(t, "partial stderr", partial.stderr, forbidden)

	clk = newFakeClock()
	w = tstPrivacyWorld(clk)
	w.failAll()
	failed := tstRun(t, w, clk, nil, e.env, false)
	tstAssertClean(t, "failure stdout", failed.stdout, forbidden)
	tstAssertClean(t, "failure stderr", failed.stderr, forbidden)

	for _, args := range [][]string{{"--help"}, {"--bogus"}, {"--interval=abc"}, {"foo"}} {
		clk = newFakeClock()
		res := tstRun(t, tstPrivacyWorld(clk), clk, args, e.env, false)
		tstAssertClean(t, "stdout of "+strings.Join(args, " "), res.stdout, forbidden)
		tstAssertClean(t, "stderr of "+strings.Join(args, " "), res.stderr, forbidden)
	}

	clk = newFakeClock()
	w = tstPrivacyWorld(clk)
	w.cpuErr = errFakeUnavailable
	out := &tstLineLimitWriter{limit: 3}
	var errOut bytes.Buffer
	tstRunWith(t, w, clk, []string{"--watch"}, e.env, false, out, &errOut)
	tstAssertClean(t, "stream stdout", out.raw(), forbidden)
	tstAssertClean(t, "stream stderr", errOut.String(), forbidden)
	e.assertUntouched(t)
}

func TestOutputNeverContainsProcessPaths(t *testing.T) {
	e, _ := tstPrivacySetup(t)
	clk := newFakeClock()
	res := tstRun(t, tstPrivacyWorld(clk), clk, nil, e.env, false)
	doc := tstAssertSingleDocument(t, res.stdout)
	var names []string
	for _, p := range tstArr(t, doc, "top_processes") {
		n, _ := tstAt(p, "name")
		s, _ := n.(string)
		names = append(names, s)
		if strings.ContainsAny(s, `\/`) || strings.Contains(strings.ToLower(s), ".exe") {
			t.Errorf("process name %q carries a path or extension", s)
		}
	}
	if !containsString(names, "tool") {
		t.Errorf("process names %q should contain the bare name tool", names)
	}
}

func TestIPAddressesNeverReachJSONOrStderr(t *testing.T) {
	e, _ := tstPrivacySetup(t)
	ipv4 := regexp.MustCompile(`\b\d{1,3}(\.\d{1,3}){3}\b`)

	clk := newFakeClock()
	res := tstRun(t, tstPrivacyWorld(clk), clk, nil, e.env, false)
	for where, text := range map[string]string{"one-shot stdout": res.stdout, "one-shot stderr": res.stderr} {
		if m := ipv4.FindString(text); m != "" {
			t.Errorf("%s contains the address %s", where, m)
		}
	}

	clk = newFakeClock()
	w := tstPrivacyWorld(clk)
	w.procsErr = errFakeUnavailable
	out := &tstLineLimitWriter{limit: 3}
	var errOut bytes.Buffer
	tstRunWith(t, w, clk, []string{"--watch"}, e.env, false, out, &errOut)
	for where, text := range map[string]string{"stream stdout": out.raw(), "stream stderr": errOut.String()} {
		if m := ipv4.FindString(text); m != "" {
			t.Errorf("%s contains the address %s", where, m)
		}
	}
}

func TestDisplayNeverContainsProxySettingsNamesOrEnvironmentValues(t *testing.T) {
	e, forbidden := tstPrivacySetup(t)
	r := tstNewRigIn(t, e, func(w *fakeWorld) { w.procs = tstPrivacyProcs() })
	r.boot(120, 60)
	view := r.view()
	tstAssertClean(t, "display", view, forbidden)
	if strings.Contains(view, `ExampleUserQ7`) || strings.Contains(view, `\Tool\`) {
		t.Errorf("the display shows a process path:\n%s", view)
	}
	for _, color := range []bool{false, true} {
		doc := tstCopyDoc(tstBaseDoc())
		frame := tstRenderFrame(tstSnapshotFromDoc(t, doc), 2, 100, 60, color)
		tstAssertClean(t, "frame", frame, forbidden)
	}
}
