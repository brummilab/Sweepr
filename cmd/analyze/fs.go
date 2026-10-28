package main

import "time"

// Reparse tells how an entry relates to a reparse point.
type Reparse int

const (
	// ReparseNone is an ordinary entry. Files with other reparse tags
	// (deduplication, image compression, app execution aliases) also count
	// as ordinary: they are real files with a real size.
	ReparseNone Reparse = iota
	// ReparseLink is a junction or a symbolic link, or a folder with a
	// reparse tag nothing here understands. It is listed, never entered.
	ReparseLink
	// ReparseCloud is a cloud placeholder. Folders of this kind are entered
	// and measured like any folder.
	ReparseCloud
)

// FSEntry is one child in a directory listing.
type FSEntry struct {
	Name    string
	IsDir   bool
	Reparse Reparse
	// Size is the logical size from the listing (not the allocated size).
	Size int64
	// Online is set for a file whose content is not stored locally.
	Online bool
}

// FileID identifies a file or folder without following a final link.
type FileID struct {
	Volume, Index uint64
	Reparse       Reparse
	IsDir         bool
}

// sameFile tells whether two identities name the same object.
func sameFile(a, b FileID) bool {
	return a.Volume == b.Volume && a.Index == b.Index && (a.Volume != 0 || a.Index != 0)
}

// Drive is a fixed local drive.
type Drive struct {
	Root, Label string
	Total, Free int64
	Err         error
}

// FS is every read access to the file system. There is no function that
// changes anything, and the logic never reaches for the os package to read a
// folder, so the whole of it can be replaced by a stand-in.
type FS interface {
	// ReadDir lists the children of a folder. A missing path reports an error
	// for which errors.Is(err, fs.ErrNotExist) holds.
	ReadDir(path string) ([]FSEntry, error)
	// Resolve returns the final path of an existing path: junctions,
	// symbolic links, 8.3 names and drive aliases are looked through.
	Resolve(path string) (string, error)
	// Identity reads the identity of the object itself. A link in the last
	// position is not followed.
	Identity(path string) (FileID, error)
	// Drives lists the fixed drives.
	Drives() []Drive
}

// Clock is the source of time and of pauses.
type Clock interface {
	Now() time.Time
	Sleep(d time.Duration)
}

type systemClock struct{}

func (systemClock) Now() time.Time        { return time.Now() }
func (systemClock) Sleep(d time.Duration) { time.Sleep(d) }

// Recycler moves one path to the Recycle Bin of its drive. It must never
// delete permanently, never ask the shell whether to delete permanently, and
// report success only when the source no longer exists.
type Recycler interface {
	Recycle(path string) error
}
