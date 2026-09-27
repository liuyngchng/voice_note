package ui

import (
	"fmt"
	"os/exec"
	"runtime"
)

// openDir opens the given directory in the system file manager.
func openDir(path string) error {
	var cmd string
	var args []string
	switch runtime.GOOS {
	case "windows":
		cmd = "explorer"
		args = []string{path}
	default:
		cmd = "xdg-open"
		args = []string{path}
	}
	return exec.Command(cmd, args...).Start()
}

// formatDuration converts seconds to a display string (mm:ss or h:mm:ss).
func formatDuration(seconds int64) string {
	h := seconds / 3600
	m := (seconds % 3600) / 60
	s := seconds % 60
	if h > 0 {
		return fmt.Sprintf("%d:%02d:%02d", h, m, s)
	}
	return fmt.Sprintf("%02d:%02d", m, s)
}