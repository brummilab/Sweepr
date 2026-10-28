package main

import (
	"fmt"
	"math"
	"strconv"
)

// Number formats are invariant: a decimal point, no grouping, no locale.

var sizeUnits = []string{"KB", "MB", "GB", "TB"}

// FormatSize writes a byte count with binary units and one decimal ("1.5KB").
// The unit is chosen from the exact value, not from the rounded one, so
// 1048575 bytes read "1024.0KB" and never "1.0MB" for a value below 1 MiB.
// Rounding is half up and done in integers, so the text is exact.
func FormatSize(n int64) string {
	if n < 1024 {
		if n < 0 {
			n = 0
		}
		return strconv.FormatInt(n, 10) + "B"
	}
	unit := int64(1024)
	idx := 0
	for idx < len(sizeUnits)-1 && n/unit >= 1024 {
		unit *= 1024
		idx++
	}
	var tenths int64
	if n <= math.MaxInt64/10-unit {
		tenths = (n*10 + unit/2) / unit
	} else {
		tenths = int64(math.Floor(float64(n)/float64(unit)*10 + 0.5))
	}
	return fmt.Sprintf("%d.%d%s", tenths/10, tenths%10, sizeUnits[idx])
}

// FormatPercent writes a percentage (12.3 means 12.3 percent) with one
// decimal, rounded half up. A positive value that would show as 0.0 reads
// "<0.1%" so that a small share never looks like none.
func FormatPercent(p float64) string {
	if math.IsNaN(p) || p <= 0 {
		return "0.0%"
	}
	p = math.Min(p, 1e12)
	tenths := int64(math.Floor(p*10 + 0.5))
	if tenths == 0 {
		return "<0.1%"
	}
	return fmt.Sprintf("%d.%d%%", tenths/10, tenths%10)
}
