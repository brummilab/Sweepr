package main

// ignoreBrokenPipe does nothing on Windows: a write to a closed pipe returns
// an error and never raises a signal.
func ignoreBrokenPipe() {}
