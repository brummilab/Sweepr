package main

// Number formats (invariant, decimal point, no locale): sizes and percentages.

import (
	"strings"
	"testing"
)

func TestFormatSizeTable(t *testing.T) {
	cases := []struct {
		n    int64
		want string
	}{
		{0, "0B"},
		{1, "1B"},
		{512, "512B"},
		{1023, "1023B"},
		{1024, "1.0KB"},
		{1536, "1.5KB"},
		{1048575, "1024.0KB"},
		{1048576, "1.0MB"},
		{1073741824, "1.0GB"},
		{1099511627776, "1.0TB"},
	}
	for _, c := range cases {
		if got := FormatSize(c.n); got != c.want {
			t.Errorf("FormatSize(%d) = %q, want %q", c.n, got, c.want)
		}
	}
}

func TestFormatSizeUnitDoesNotDependOnTheRoundedValue(t *testing.T) {
	cases := []struct {
		n    int64
		want string
	}{
		{tstMiB - 1, "1024.0KB"},
		{tstGiB - 1, "1024.0MB"},
		{tstTiB - 1, "1024.0GB"},
		{tstMiB - 52, "1023.9KB"},
	}
	for _, c := range cases {
		if got := FormatSize(c.n); got != c.want {
			t.Errorf("FormatSize(%d) = %q, want %q", c.n, got, c.want)
		}
	}
}

func TestFormatSizeKeepsTBAboveOneTB(t *testing.T) {
	cases := []struct {
		n    int64
		want string
	}{
		{5 * tstTiB, "5.0TB"},
		{1 << 50, "1024.0TB"},
		{3*tstTiB + tstTiB/2, "3.5TB"},
	}
	for _, c := range cases {
		if got := FormatSize(c.n); got != c.want {
			t.Errorf("FormatSize(%d) = %q, want %q", c.n, got, c.want)
		}
	}
}

func TestFormatSizeRoundsToOneDecimal(t *testing.T) {
	cases := []struct {
		n    int64
		want string
	}{
		{1126, "1.1KB"}, // 1.0996
		{1177, "1.1KB"}, // 1.1494
		{1178, "1.2KB"}, // 1.1504
		{3 * tstMiB / 2, "1.5MB"},
		{5 * tstGiB / 2, "2.5GB"},
		{tstGiB + tstGiB*6/100, "1.1GB"}, // 1.06 GiB
	}
	for _, c := range cases {
		if got := FormatSize(c.n); got != c.want {
			t.Errorf("FormatSize(%d) = %q, want %q", c.n, got, c.want)
		}
	}
}

func TestFormatSizeHasNoSpaceAndNoGroupingSeparator(t *testing.T) {
	for _, n := range []int64{0, 999, 1500, 123456789, 98765432101, 5 * tstTiB} {
		got := FormatSize(n)
		if strings.ContainsAny(got, " ,  ") {
			t.Errorf("FormatSize(%d) = %q contains a space or a grouping separator", n, got)
		}
	}
}

func TestFormatSizeBelow1024IsAWholeNumber(t *testing.T) {
	for _, n := range []int64{0, 7, 100, 1000, 1023} {
		got := FormatSize(n)
		if strings.Contains(got, ".") || !strings.HasSuffix(got, "B") || strings.HasSuffix(got, "KB") {
			t.Errorf("FormatSize(%d) = %q, want whole bytes", n, got)
		}
	}
}

func TestFormatPercentTable(t *testing.T) {
	cases := []struct {
		p    float64
		want string
	}{
		{0, "0.0%"},
		{12.3, "12.3%"},
		{50, "50.0%"},
		{87.5, "87.5%"},
		{100, "100.0%"},
		{0.1, "0.1%"},
		{0.05, "0.1%"},
	}
	for _, c := range cases {
		if got := FormatPercent(c.p); got != c.want {
			t.Errorf("FormatPercent(%v) = %q, want %q", c.p, got, c.want)
		}
	}
}

func TestFormatPercentRoundsHalfUp(t *testing.T) {
	// 0.25, 1.25 and 12.25 are exact in binary: half-even would give 0.2, 1.2, 12.2.
	cases := []struct {
		p    float64
		want string
	}{
		{0.25, "0.3%"},
		{1.25, "1.3%"},
		{12.25, "12.3%"},
		{2.75, "2.8%"},
	}
	for _, c := range cases {
		if got := FormatPercent(c.p); got != c.want {
			t.Errorf("FormatPercent(%v) = %q, want %q", c.p, got, c.want)
		}
	}
}

func TestFormatPercentShowsSmallPositiveValuesAsLessThanOneTenth(t *testing.T) {
	for _, p := range []float64{0.04, 0.049, 0.001, 1e-9} {
		if got := FormatPercent(p); got != "<0.1%" {
			t.Errorf("FormatPercent(%v) = %q, want %q", p, got, "<0.1%")
		}
	}
}

func TestFormatPercentZeroIsNotLessThanOneTenth(t *testing.T) {
	if got := FormatPercent(0); got != "0.0%" {
		t.Errorf("FormatPercent(0) = %q, want 0.0%%", got)
	}
}

func TestFormatPercentUsesDecimalPoint(t *testing.T) {
	if got := FormatPercent(33.3); strings.Contains(got, ",") {
		t.Errorf("FormatPercent(33.3) = %q, want a decimal point", got)
	}
}
