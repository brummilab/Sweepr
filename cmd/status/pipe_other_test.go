//go:build !windows

package main

// A closed standard output ends the stream quietly; the program is never
// killed by SIGPIPE.

import (
	"bufio"
	"bytes"
	"errors"
	"os"
	"os/exec"
	"testing"
	"time"
)

func TestStreamEndsQuietlyWhenTheReaderCloses(t *testing.T) {
	cmd := exec.Command(os.Args[0], "--watch", "--interval=20ms")
	cmd.Env = append(os.Environ(), tstModeEnv+"=main")
	var errOut bytes.Buffer
	cmd.Stderr = &errOut
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	if _, err := bufio.NewReader(stdout).ReadString('\n'); err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		t.Fatalf("no first line: %v", err)
	}
	_ = stdout.Close() // the reader goes away while the program keeps writing

	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			t.Errorf("the program ended with %v, want exit code 0 and no signal", ee)
		} else if err != nil {
			t.Errorf("wait: %v", err)
		}
	case <-time.After(20 * time.Second):
		_ = cmd.Process.Kill()
		t.Fatal("the program did not end after its output closed")
	}
	for _, area := range []string{"closed", "broken", "pipe", "write"} {
		if bytes.Contains(bytes.ToLower(errOut.Bytes()), []byte(area)) {
			t.Errorf("stderr mentions %q: %q", area, errOut.String())
		}
	}
}
