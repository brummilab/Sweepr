package main

import (
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"
)

// The JSON document is written by hand: encoding/json leaves non-ASCII text
// as it is, and Windows PowerShell 5.1 decodes the output of a native program
// with the console code page. Every character above U+007F is therefore
// written as a \u escape (a surrogate pair outside the basic plane), and the
// parsed text stays the same.

type jsonWriter struct {
	b strings.Builder
}

func (w *jsonWriter) str(s string) {
	w.b.WriteByte('"')
	for i := 0; i < len(s); {
		r, n := utf8.DecodeRuneInString(s[i:])
		i += n
		switch {
		case r == '"':
			w.b.WriteString(`\"`)
		case r == '\\':
			w.b.WriteString(`\\`)
		case r == '\n':
			w.b.WriteString(`\n`)
		case r == '\r':
			w.b.WriteString(`\r`)
		case r == '\t':
			w.b.WriteString(`\t`)
		case r < 0x20:
			fmt.Fprintf(&w.b, `\u%04x`, r)
		case r < 0x80:
			w.b.WriteRune(r)
		case r >= 0x10000:
			r -= 0x10000
			fmt.Fprintf(&w.b, `\u%04x\u%04x`, 0xd800+(r>>10), 0xdc00+(r&0x3ff))
		default:
			fmt.Fprintf(&w.b, `\u%04x`, r)
		}
	}
	w.b.WriteByte('"')
}

func (w *jsonWriter) boolean(v bool) { w.b.WriteString(strconv.FormatBool(v)) }

func (w *jsonWriter) num(v int64) { w.b.WriteString(strconv.FormatInt(v, 10)) }

// numOrNull writes null for a value that was not measured.
func (w *jsonWriter) numOrNull(v int64, known bool) {
	if known {
		w.num(v)
		return
	}
	w.b.WriteString("null")
}

func (w *jsonWriter) pad(depth int) {
	for i := 0; i < depth; i++ {
		w.b.WriteString("  ")
	}
}

// field writes `"key": ` at the given depth, after a comma when it is not the
// first of its object.
func (w *jsonWriter) field(depth int, key string, first bool) {
	if !first {
		w.b.WriteString(",\n")
	}
	w.pad(depth)
	w.str(key)
	w.b.WriteString(": ")
}

func (w *jsonWriter) entry(it Item, depth int) {
	w.pad(depth)
	w.b.WriteString("{\n")
	w.field(depth+1, "scan_status", true)
	w.str(it.State.String())
	w.field(depth+1, "name", false)
	w.str(it.Name)
	w.field(depth+1, "path", false)
	w.str(it.Path)
	w.field(depth+1, "size", false)
	w.numOrNull(it.Size, it.measured())
	w.field(depth+1, "online_size", false)
	w.numOrNull(it.OnlineSize, it.State != Unavailable)
	w.field(depth+1, "is_dir", false)
	w.boolean(it.IsDir)
	w.field(depth+1, "is_link", false)
	w.boolean(it.IsLink)
	w.field(depth+1, "cloud", false)
	w.boolean(it.Cloud)
	w.b.WriteString("\n")
	w.pad(depth)
	w.b.WriteString("}")
}

func (w *jsonWriter) entries(items []Item) {
	if len(items) == 0 {
		w.b.WriteString("[]")
		return
	}
	w.b.WriteString("[\n")
	for i, it := range items {
		if i > 0 {
			w.b.WriteString(",\n")
		}
		w.entry(it, 2)
	}
	w.b.WriteString("\n  ]")
}

// folderJSON is the document of a measured folder.
func folderJSON(l Listing) string {
	var w jsonWriter
	w.b.WriteString("{\n")
	w.field(1, "scan_status", true)
	w.str(l.State.String())
	w.field(1, "path", false)
	w.str(l.Root)
	w.field(1, "overview", false)
	w.boolean(false)
	w.field(1, "entries", false)
	w.entries(l.Items)
	w.field(1, "large_files", false)
	if len(l.TopFiles) == 0 {
		w.b.WriteString("[]")
	} else {
		w.b.WriteString("[\n")
		for i, f := range l.TopFiles {
			if i > 0 {
				w.b.WriteString(",\n")
			}
			w.pad(2)
			w.b.WriteString("{\n")
			w.field(3, "name", true)
			w.str(f.Name)
			w.field(3, "path", false)
			w.str(f.Path)
			w.field(3, "size", false)
			w.num(f.Size)
			w.b.WriteString("\n")
			w.pad(2)
			w.b.WriteString("}")
		}
		w.b.WriteString("\n  ]")
	}
	w.field(1, "total_size", false)
	w.num(l.TotalSize)
	w.field(1, "total_online_size", false)
	w.num(l.TotalOnlineSize)
	w.field(1, "total_files", false)
	w.num(l.TotalFiles)
	w.b.WriteString("\n}\n")
	return w.b.String()
}

// overviewJSON is the document of the overview. It has no totals: the rows
// lie inside each other (the profile folder is on a drive), so a sum would
// count the same bytes twice.
func overviewJSON(items []Item) string {
	var w jsonWriter
	status := Complete
	for _, it := range items {
		if it.State != Complete {
			status = Partial
		}
	}
	w.b.WriteString("{\n")
	w.field(1, "scan_status", true)
	w.str(status.String())
	w.field(1, "path", false)
	w.str("")
	w.field(1, "overview", false)
	w.boolean(true)
	w.field(1, "entries", false)
	w.entries(items)
	w.b.WriteString("\n}\n")
	return w.b.String()
}
