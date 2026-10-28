package main

// The JSON document (output schema): exact key sets, value types, ranges and
// the null convention (ST-5, ST-6, ST-23).

import (
	"encoding/json"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"
)

func tstKeys(v any) []string {
	m, ok := v.(map[string]any)
	if !ok {
		return nil
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func tstWantKeys(t *testing.T, where string, v any, want ...string) {
	t.Helper()
	sort.Strings(want)
	if got := tstKeys(v); !tstSameStrings(got, want) {
		t.Errorf("%s has keys %q, want exactly %q", where, got, want)
	}
}

// tstFullDocument samples a healthy world with a rich set of values.
func tstFullDocument(t *testing.T) (map[string]any, string) {
	t.Helper()
	clk := newFakeClock()
	w := newHealthyWorld(clk)
	w.drives = []fakeDrive{
		{Mount: `C:\`, Total: 100 * tstGiB, Free: 60 * tstGiB, FS: "NTFS"},
		{Mount: `D:\`, Total: 64 * tstGiB, Free: 44 * tstGiB, FS: "exFAT", Removable: true},
	}
	w.nets = []fakeNet{{Name: "Ethernet"}, {Name: "WLAN"}}
	w.adapters = []fakeAdapter{{Name: "Ethernet", IPv4: []string{"192.0.2.17"}, Default: true}, {Name: "WLAN", IPv4: []string{"198.51.100.7"}}}
	s := tstNewSampler(w, clk)
	clk.Advance(time.Second)
	snap, err := s.Sample()
	if err != nil {
		t.Fatalf("Sample: %v", err)
	}
	raw, err := json.Marshal(&snap)
	if err != nil {
		t.Fatal(err)
	}
	return tstDecode(t, raw), string(raw)
}

func TestSchemaHasExactlyTheDocumentedKeys(t *testing.T) {
	doc, _ := tstFullDocument(t)
	tstWantKeys(t, "document", doc, tstTopLevelKeys...)
	cpu, _ := tstAt(doc, "cpu")
	tstWantKeys(t, "cpu", cpu, "usage", "per_core", "core_count", "logical_cpu")
	mem, _ := tstAt(doc, "memory")
	tstWantKeys(t, "memory", mem, "used", "total", "available", "used_percent", "swap_used", "swap_total")
	disks := tstArr(t, doc, "disks")
	if len(disks) == 0 {
		t.Fatal("disks is empty")
	}
	for _, d := range disks {
		tstWantKeys(t, "disks element", d, "mount", "fstype", "used", "total", "used_percent", "external")
	}
	diskIO, _ := tstAt(doc, "disk_io")
	tstWantKeys(t, "disk_io", diskIO, "read_rate", "write_rate")
	nets := tstArr(t, doc, "network")
	if len(nets) == 0 {
		t.Fatal("network is empty")
	}
	for _, n := range nets {
		tstWantKeys(t, "network element", n, "name", "rx_rate_mbs", "tx_rate_mbs")
	}
	tot, _ := tstAt(doc, "network_total")
	tstWantKeys(t, "network_total", tot, "rx_rate_mbs", "tx_rate_mbs")
	procs := tstArr(t, doc, "top_processes")
	if len(procs) == 0 {
		t.Fatal("top_processes is empty")
	}
	for _, p := range procs {
		tstWantKeys(t, "process element", p, "pid", "name", "cpu", "memory_bytes")
	}
}

func TestSchemaValueTypes(t *testing.T) {
	doc, _ := tstFullDocument(t)
	if s, ok := doc["platform"].(string); !ok || s == "" {
		t.Errorf("platform = %v, want a string", doc["platform"])
	}
	if s, ok := doc["collected_at"].(string); !ok {
		t.Errorf("collected_at = %v, want a string", doc["collected_at"])
	} else if _, err := time.Parse(time.RFC3339, s); err != nil {
		t.Errorf("collected_at %q is not RFC 3339: %v", s, err)
	}
	for _, d := range tstArr(t, doc, "disks") {
		if v, _ := tstAt(d, "external"); v != true && v != false {
			t.Errorf("external = %v, want a boolean", v)
		}
		if v, _ := tstAt(d, "mount"); !regexp.MustCompile(`^[A-Z]:\\$`).MatchString(tstString(v)) {
			t.Errorf("mount = %v, want the form X:\\", v)
		}
		if v, _ := tstAt(d, "fstype"); v != nil {
			if _, ok := v.(string); !ok {
				t.Errorf("fstype = %v, want a string or null", v)
			}
		}
	}
	for _, n := range tstNames(t, tstArr(t, doc, "network")) {
		if n == "" {
			t.Errorf("network element without a name")
		}
	}
}

func TestSchemaWholeNumbersAreWrittenWithoutFraction(t *testing.T) {
	_, raw := tstFullDocument(t)
	dec := json.NewDecoder(strings.NewReader(raw))
	dec.UseNumber()
	var doc map[string]any
	if err := dec.Decode(&doc); err != nil {
		t.Fatal(err)
	}
	integers := [][]string{
		{"uptime_seconds"}, {"procs"}, {"cpu", "logical_cpu"}, {"cpu", "core_count"},
		{"memory", "used"}, {"memory", "total"}, {"memory", "available"},
		{"memory", "swap_used"}, {"memory", "swap_total"},
	}
	check := func(where string, v any) {
		n, ok := v.(json.Number)
		if !ok {
			t.Errorf("%s = %#v, want a JSON number", where, v)
			return
		}
		if strings.ContainsAny(n.String(), ".eE") {
			t.Errorf("%s = %s, want a whole number without fraction or exponent", where, n)
		}
	}
	for _, p := range integers {
		v, _ := tstAt(doc, p...)
		check(strings.Join(p, "."), v)
	}
	for _, d := range doc["disks"].([]any) {
		for _, k := range []string{"used", "total"} {
			v, _ := tstAt(d, k)
			check("disks."+k, v)
		}
	}
	for _, p := range doc["top_processes"].([]any) {
		for _, k := range []string{"pid", "memory_bytes"} {
			v, _ := tstAt(p, k)
			check("top_processes."+k, v)
		}
	}
}

func TestSchemaPercentagesAndRatesAreInRange(t *testing.T) {
	doc, _ := tstFullDocument(t)
	pct := func(where string, v any) {
		f, ok := v.(float64)
		if !ok || f < 0 || f > 100 {
			t.Errorf("%s = %v, want a number in 0..100", where, v)
		}
	}
	rate := func(where string, v any) {
		f, ok := v.(float64)
		if !ok || f < 0 {
			t.Errorf("%s = %v, want a number >= 0", where, v)
		}
	}
	v, _ := tstAt(doc, "cpu", "usage")
	pct("cpu.usage", v)
	for _, c := range tstArr(t, doc, "cpu", "per_core") {
		pct("cpu.per_core", c)
	}
	logical, _ := tstAt(doc, "cpu", "logical_cpu")
	if n := len(tstArr(t, doc, "cpu", "per_core")); float64(n) != logical {
		t.Errorf("per_core has %d values, logical_cpu is %v", n, logical)
	}
	v, _ = tstAt(doc, "memory", "used_percent")
	pct("memory.used_percent", v)
	for _, d := range tstArr(t, doc, "disks") {
		v, _ = tstAt(d, "used_percent")
		pct("disks.used_percent", v)
	}
	for _, p := range tstArr(t, doc, "top_processes") {
		v, _ = tstAt(p, "cpu")
		pct("top_processes.cpu", v)
	}
	for _, k := range []string{"read_rate", "write_rate"} {
		v, _ = tstAt(doc, "disk_io", k)
		rate("disk_io."+k, v)
	}
	for _, k := range []string{"rx_rate_mbs", "tx_rate_mbs"} {
		v, _ = tstAt(doc, "network_total", k)
		rate("network_total."+k, v)
		for _, n := range tstArr(t, doc, "network") {
			v, _ = tstAt(n, k)
			rate("network."+k, v)
		}
	}
}

func TestSchemaOmitsPrivateDetails(t *testing.T) {
	_, raw := tstFullDocument(t)
	ipv4 := regexp.MustCompile(`\b\d{1,3}(\.\d{1,3}){3}\b`)
	if m := ipv4.FindString(raw); m != "" {
		t.Errorf("document contains an IP address: %s", m)
	}
	for _, key := range []string{"host", "hostname", "uptime", "hardware", "health_score", "network_history", "proxy", "batteries", "ip", "ppid", "command"} {
		if strings.Contains(raw, "\""+key+"\":") {
			t.Errorf("document contains the removed key %q", key)
		}
	}
}

func TestSnapshotRoundTripsThroughJSONKeepingNulls(t *testing.T) {
	doc, _ := tstFullDocument(t)
	for _, k := range []string{"cpu", "memory", "disks", "disk_io", "network", "network_total", "top_processes", "platform", "uptime_seconds", "procs"} {
		doc[k] = nil
	}
	snap := tstSnapshotFromDoc(t, doc)
	back := tstSnapshotDoc(t, snap)
	tstWantKeys(t, "round-tripped document", back, tstTopLevelKeys...)
	for _, k := range tstTopLevelKeys[1:] {
		tstWantNull(t, back, k)
	}
	tstWantNotNull(t, back, "collected_at")
}

func tstString(v any) string {
	s, _ := v.(string)
	return s
}
