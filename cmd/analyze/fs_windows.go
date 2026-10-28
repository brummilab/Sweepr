//go:build windows

package main

import (
	"io/fs"
	"strings"

	"golang.org/x/sys/windows"
)

// Reparse tags and attributes that decide what an entry is. The cloud tag
// has variants that differ in the fourth nibble, hence the mask.
const (
	tagMountPoint = 0xA0000003
	tagSymlink    = 0xA000000C
	tagCloudBase  = 0x9000001A
	tagCloudMask  = 0xFFFF0FFF

	attrOffline      = 0x00001000
	attrRecallOnOpen = 0x00040000
	attrRecallOnData = 0x00400000
)

const shareAll = windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE

// osFS reads the real file system. It lists directories with FindFirstFile,
// which hands out the attributes, the size and the reparse tag of every entry
// without opening it, so no file is ever opened for reading or hydrated.
type osFS struct{}

// NewOSFS returns the file system of the machine.
func NewOSFS() FS { return osFS{} }

// apiPath prepares a path for the Windows API: backslashes only, and the
// extended-length form for long paths, which the plain form cannot address.
func apiPath(p string) string {
	p = strings.ReplaceAll(p, "/", `\`)
	if len(p) < 240 || strings.HasPrefix(p, `\\?\`) {
		return p
	}
	if strings.HasPrefix(p, `\\`) {
		return `\\?\UNC\` + p[2:]
	}
	return `\\?\` + p
}

// classify turns attributes and reparse tag into what the logic needs. A
// junction, a symbolic link and a folder with a tag nobody here understands
// are links; a cloud tag, or the recall attribute, marks a cloud placeholder;
// any other tag on a file (deduplication, image compression, app aliases) is
// an ordinary file with its size.
func classify(attrs, tag uint32) (isDir bool, reparse Reparse, online bool) {
	isDir = attrs&windows.FILE_ATTRIBUTE_DIRECTORY != 0
	if attrs&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		switch {
		case tag&tagCloudMask == tagCloudBase:
			reparse = ReparseCloud
		case isDir, tag == tagSymlink, tag == tagMountPoint:
			reparse = ReparseLink
		}
	}
	if attrs&attrRecallOnData != 0 && reparse != ReparseLink {
		reparse = ReparseCloud
	}
	online = !isDir && attrs&(attrRecallOnData|attrRecallOnOpen|attrOffline) != 0
	return isDir, reparse, online
}

func pathError(op, path string, err error) error {
	return &fs.PathError{Op: op, Path: path, Err: err}
}

func (osFS) ReadDir(path string) ([]FSEntry, error) {
	pattern, err := windows.UTF16PtrFromString(strings.TrimRight(apiPath(path), `\`) + `\*`)
	if err != nil {
		return nil, pathError("readdir", path, err)
	}
	var data windows.Win32finddata
	h, err := windows.FindFirstFile(pattern, &data)
	if err != nil {
		return nil, pathError("readdir", path, err)
	}
	defer windows.FindClose(h)
	var out []FSEntry
	for {
		name := windows.UTF16ToString(data.FileName[:])
		if name != "." && name != ".." {
			isDir, reparse, online := classify(data.FileAttributes, data.Reserved0)
			e := FSEntry{Name: name, IsDir: isDir, Reparse: reparse, Online: online}
			if !isDir {
				e.Size = int64(data.FileSizeHigh)<<32 | int64(data.FileSizeLow)
			}
			out = append(out, e)
		}
		if err := windows.FindNextFile(h, &data); err != nil {
			if err == windows.ERROR_NO_MORE_FILES {
				return out, nil
			}
			// A listing cut short is an error, never a smaller folder.
			return nil, pathError("readdir", path, err)
		}
	}
}

// openHandle opens a handle that only asks about the object: with no access
// (or attribute access only), never for reading, so nothing is recalled.
func openHandle(path string, access uint32, flags uint32) (windows.Handle, error) {
	p, err := windows.UTF16PtrFromString(apiPath(path))
	if err != nil {
		return windows.InvalidHandle, err
	}
	return windows.CreateFile(p, access, shareAll, nil, windows.OPEN_EXISTING, flags, 0)
}

func (osFS) Resolve(path string) (string, error) {
	h, err := openHandle(path, 0, windows.FILE_FLAG_BACKUP_SEMANTICS)
	if err != nil {
		return "", pathError("resolve", path, err)
	}
	defer windows.CloseHandle(h)
	buf := make([]uint16, 512)
	for {
		n, err := windows.GetFinalPathNameByHandle(h, &buf[0], uint32(len(buf)), 0)
		if err != nil {
			return "", pathError("resolve", path, err)
		}
		if int(n) > len(buf) {
			buf = make([]uint16, n)
			continue
		}
		return windows.UTF16ToString(buf[:n]), nil
	}
}

// reparseTag reads the tag of the entry itself from its directory entry.
func reparseTag(path string) (uint32, error) {
	p, err := windows.UTF16PtrFromString(strings.TrimRight(apiPath(path), `\`))
	if err != nil {
		return 0, err
	}
	var data windows.Win32finddata
	h, err := windows.FindFirstFile(p, &data)
	if err != nil {
		return 0, err
	}
	windows.FindClose(h)
	return data.Reserved0, nil
}

func (osFS) Identity(path string) (FileID, error) {
	h, err := openHandle(path, windows.FILE_READ_ATTRIBUTES, windows.FILE_FLAG_BACKUP_SEMANTICS|windows.FILE_FLAG_OPEN_REPARSE_POINT)
	if err != nil {
		return FileID{}, pathError("identity", path, err)
	}
	defer windows.CloseHandle(h)
	var info windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(h, &info); err != nil {
		return FileID{}, pathError("identity", path, err)
	}
	var tag uint32
	if info.FileAttributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		if tag, err = reparseTag(path); err != nil {
			return FileID{}, pathError("identity", path, err)
		}
	}
	isDir, reparse, _ := classify(info.FileAttributes, tag)
	return FileID{
		Volume:  uint64(info.VolumeSerialNumber),
		Index:   uint64(info.FileIndexHigh)<<32 | uint64(info.FileIndexLow),
		Reparse: reparse,
		IsDir:   isDir,
	}, nil
}

func (osFS) Drives() []Drive {
	mask, err := windows.GetLogicalDrives()
	if err != nil {
		return nil
	}
	var out []Drive
	for i := 0; i < 26; i++ {
		if mask&(1<<uint(i)) == 0 {
			continue
		}
		root := string(rune('A'+i)) + `:\`
		rp, err := windows.UTF16PtrFromString(root)
		if err != nil || windows.GetDriveType(rp) != windows.DRIVE_FIXED {
			continue
		}
		d := Drive{Root: root}
		// The total free space, not the share a quota gives this user: the row
		// shows how full the volume is.
		var avail, total, free uint64
		if err := windows.GetDiskFreeSpaceEx(rp, &avail, &total, &free); err != nil {
			d.Err = err
		} else {
			d.Total, d.Free = int64(total), int64(free)
		}
		var label [windows.MAX_PATH + 1]uint16
		if windows.GetVolumeInformation(rp, &label[0], uint32(len(label)), nil, nil, nil, nil, 0) == nil {
			d.Label = windows.UTF16ToString(label[:])
		}
		out = append(out, d)
	}
	return out
}
