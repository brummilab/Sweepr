// Command analyze is the disk explorer behind `sw analyze`: it shows where the
// space of a Windows drive went and moves chosen entries to the Recycle Bin.
package main

import "os"

func main() {
	os.Exit(realMain())
}
