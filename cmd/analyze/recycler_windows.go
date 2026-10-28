//go:build windows

package main

import (
	"errors"
	"fmt"
	"io/fs"
	"runtime"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

// The Recycle Bin is reached through the one shell operation that has no
// deleting branch: ITransferSource.RecycleItem, bound on the folder item of
// the parent with the source item handed in. If it fails, nothing is done
// instead; there is no fallback to a call that removes for good, and none to
// one that asks the shell a question.

var (
	iidShellItem      = windows.GUID{Data1: 0x43826D1E, Data2: 0xE718, Data3: 0x42EE, Data4: [8]byte{0xBC, 0x55, 0xA1, 0xE2, 0x61, 0xC3, 0x7B, 0xFE}}
	iidTransferSource = windows.GUID{Data1: 0x00ADB003, Data2: 0xBDE9, Data3: 0x45C6, Data4: [8]byte{0x8E, 0x29, 0xD0, 0x9F, 0x93, 0x53, 0xE1, 0x08}}
	bhidTransfer      = windows.GUID{Data1: 0xD5E346A1, Data2: 0xF753, Data3: 0x4932, Data4: [8]byte{0xB4, 0x03, 0x45, 0x74, 0x80, 0x0E, 0x24, 0x98}}

	procCreateItemFromParsingName = windows.NewLazySystemDLL("shell32.dll").NewProc("SHCreateItemFromParsingName")
)

// The Recycle Bin folder as the shell names it.
const recycleBinParsingName = "::{645FF040-5081-101B-9F08-00AA002F954E}"

// Slots of the COM interfaces used: IUnknown has Release in slot 2, IShellItem
// continues with BindToHandler and GetParent, ITransferSource has RecycleItem
// in slot 8.
const (
	slotRelease       = 2
	slotBindToHandler = 3
	slotGetParent     = 4
	slotRecycleItem   = 8
	// vtableSlots is the length of the method table as the code looks at it;
	// only the slots above are ever read.
	vtableSlots = 16
)

// sFalse is the success code CoInitializeEx gives when the thread already had
// a COM apartment of the same kind.
const sFalse = 1

const is64BitProcess = ^uint(0)>>63 == 1

type shellRecycler struct{}

// NewShellRecycler returns the Recycler that uses the shell.
func NewShellRecycler() Recycler { return shellRecycler{} }

type hresultError int32

func (e hresultError) Error() string {
	return fmt.Sprintf("the shell reported an error (0x%08X)", uint32(e))
}

// comCall calls a method of a COM object by its slot in the method table.
func comCall(obj unsafe.Pointer, slot int, args ...uintptr) int32 {
	table := *(**[vtableSlots]uintptr)(obj)
	all := make([]uintptr, 0, 1+len(args))
	all = append(all, uintptr(obj))
	all = append(all, args...)
	r, _, _ := syscall.SyscallN(table[slot], all...)
	return int32(r)
}

func release(obj unsafe.Pointer) {
	if obj != nil {
		comCall(obj, slotRelease)
	}
}

func hrErr(hr int32) error {
	if hr < 0 {
		return hresultError(hr)
	}
	return nil
}

func createShellItem(name string) (unsafe.Pointer, error) {
	p, err := windows.UTF16PtrFromString(name)
	if err != nil {
		return nil, err
	}
	out := new(unsafe.Pointer)
	r, _, _ := procCreateItemFromParsingName.Call(
		uintptr(unsafe.Pointer(p)), 0, uintptr(unsafe.Pointer(&iidShellItem)), uintptr(unsafe.Pointer(out)))
	if err := hrErr(int32(r)); err != nil {
		return nil, err
	}
	return *out, nil
}

// Recycle moves one file or folder, as a whole, to the Recycle Bin of its
// drive. Only a path on a fixed drive with a letter is accepted: network,
// removable and other drives have no Recycle Bin of their own, and a 32-bit
// process does not reach the 64-bit shell reliably. It reports success only
// when the source is gone afterwards.
func (shellRecycler) Recycle(path string) error {
	if !is64BitProcess {
		return errors.New("moving to the Recycle Bin needs a 64-bit process")
	}
	wp, ok := parseWinPath(path)
	if !ok || len(wp.root) != 2 || wp.root[1] != ':' || wp.isRoot() {
		return errors.New("only a file or folder on a drive with a letter can be moved to the Recycle Bin")
	}
	root, err := windows.UTF16PtrFromString(wp.display)
	if err != nil {
		return err
	}
	if windows.GetDriveType(root) != windows.DRIVE_FIXED {
		return errors.New("only fixed drives have a Recycle Bin")
	}
	shellPath := wp.String()

	// The shell objects live in a single-threaded apartment, which belongs to
	// one operating-system thread: do all of it on a thread of its own.
	done := make(chan error, 1)
	go func() {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		if err := windows.CoInitializeEx(0, windows.COINIT_APARTMENTTHREADED); err != nil && err != syscall.Errno(sFalse) {
			done <- err
			return
		}
		defer windows.CoUninitialize()
		done <- recycleInApartment(shellPath)
	}()
	return <-done
}

func recycleInApartment(path string) error {
	item, err := createShellItem(path)
	if err != nil {
		return err
	}
	defer release(item)

	parent := new(unsafe.Pointer)
	if err := hrErr(comCall(item, slotGetParent, uintptr(unsafe.Pointer(parent)))); err != nil {
		return err
	}
	defer release(*parent)

	bin, err := createShellItem(recycleBinParsingName)
	if err != nil {
		return err
	}
	defer release(bin)

	handler := new(unsafe.Pointer)
	if err := hrErr(comCall(*parent, slotBindToHandler, 0,
		uintptr(unsafe.Pointer(&bhidTransfer)), uintptr(unsafe.Pointer(&iidTransferSource)), uintptr(unsafe.Pointer(handler)))); err != nil {
		return err
	}
	defer release(*handler)

	recycled := new(unsafe.Pointer)
	hr := comCall(*handler, slotRecycleItem, uintptr(item), uintptr(bin), 0, uintptr(unsafe.Pointer(recycled)))
	defer release(*recycled)
	if err := hrErr(hr); err != nil {
		return err
	}
	if *recycled == nil {
		return errors.New("the shell did not report where the entry went")
	}

	// The shell said yes; trust only the file system.
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	if _, err := windows.GetFileAttributes(p); err == nil || !errors.Is(err, fs.ErrNotExist) {
		return errors.New("the entry is still there after the move")
	}
	return nil
}
