package main

import (
	"math"
	"strconv"
)

// All number formats are invariant: a decimal point and no grouping,
// independent of the locale. Rounding is half up.

// fixed formats v with the given number of decimals, rounding half up.
func fixed(v float64, decimals int) string {
	if math.IsNaN(v) || math.IsInf(v, 0) {
		return "0"
	}
	scale := math.Pow(10, float64(decimals))
	return strconv.FormatFloat(math.Floor(v*scale+0.5)/scale, 'f', decimals, 64)
}

// formatBytes writes a size with binary units and no space before the unit:
// "512B", "1.0KB", "16.0GB".
func formatBytes(n uint64) string {
	if n < 1024 {
		return strconv.FormatUint(n, 10) + "B"
	}
	units := []string{"KB", "MB", "GB", "TB"}
	v := float64(n)
	i := -1
	for v >= 1024 && i < len(units)-1 {
		v /= 1024
		i++
	}
	return fixed(v, 1) + units[i]
}

// formatPercent writes one decimal and the percent sign.
func formatPercent(v float64) string {
	return fixed(v, 1) + "%"
}

// formatRate writes a transfer rate in MB/s: below 0.01 as "0MB/s", below 1
// with two decimals, below 10 with one and above without decimals.
func formatRate(v float64) string {
	switch {
	case v < 0.01:
		return "0MB/s"
	case v < 1:
		return fixed(v, 2) + "MB/s"
	case v < 10:
		return fixed(v, 1) + "MB/s"
	default:
		return fixed(v, 0) + "MB/s"
	}
}

// formatUptime writes "<d>d <h>h" from one day on, "<h>h <m>m" from one hour
// on and "<m>m" below; minutes are rounded down.
func formatUptime(seconds int64) string {
	if seconds < 0 {
		seconds = 0
	}
	days := seconds / 86400
	hours := seconds % 86400 / 3600
	minutes := seconds % 3600 / 60
	switch {
	case days > 0:
		return strconv.FormatInt(days, 10) + "d " + strconv.FormatInt(hours, 10) + "h"
	case hours > 0:
		return strconv.FormatInt(hours, 10) + "h " + strconv.FormatInt(minutes, 10) + "m"
	default:
		return strconv.FormatInt(minutes, 10) + "m"
	}
}
