package main

import (
	"fmt"
	"strconv"
)

// Byte formatting uses binary (1024-based) units, the same convention Task
// Manager uses.

// humanBytes formats with one decimal and a spaced unit label ("1.0 GB").
// Values at exactly 1<<n stay in the smaller unit (1024 -> "1024 B").
func humanBytes(v uint64) string {
	switch {
	case v > 1<<40:
		return fmt.Sprintf("%.1f TB", float64(v)/(1<<40))
	case v > 1<<30:
		return fmt.Sprintf("%.1f GB", float64(v)/(1<<30))
	case v > 1<<20:
		return fmt.Sprintf("%.1f MB", float64(v)/(1<<20))
	case v > 1<<10:
		return fmt.Sprintf("%.1f KB", float64(v)/(1<<10))
	default:
		return strconv.FormatUint(v, 10) + " B"
	}
}

// humanBytesShort formats with no decimals and a one-letter suffix ("100G").
func humanBytesShort(v uint64) string {
	switch {
	case v >= 1<<40:
		return fmt.Sprintf("%.0fT", float64(v)/(1<<40))
	case v >= 1<<30:
		return fmt.Sprintf("%.0fG", float64(v)/(1<<30))
	case v >= 1<<20:
		return fmt.Sprintf("%.0fM", float64(v)/(1<<20))
	case v >= 1<<10:
		return fmt.Sprintf("%.0fK", float64(v)/(1<<10))
	default:
		return strconv.FormatUint(v, 10)
	}
}

// humanBytesCompact formats with one decimal and a one-letter suffix ("1.5G").
func humanBytesCompact(v uint64) string {
	switch {
	case v >= 1<<40:
		return fmt.Sprintf("%.1fT", float64(v)/(1<<40))
	case v >= 1<<30:
		return fmt.Sprintf("%.1fG", float64(v)/(1<<30))
	case v >= 1<<20:
		return fmt.Sprintf("%.1fM", float64(v)/(1<<20))
	case v >= 1<<10:
		return fmt.Sprintf("%.1fK", float64(v)/(1<<10))
	default:
		return strconv.FormatUint(v, 10)
	}
}
