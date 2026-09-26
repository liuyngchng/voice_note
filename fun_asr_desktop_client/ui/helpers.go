// Package ui provides the Fyne-based graphical user interface.
package ui

import "fmt"

// formatDuration converts seconds to mm:ss or h:mm:ss.
func formatDuration(seconds int64) string {
	h := seconds / 3600
	m := (seconds % 3600) / 60
	s := seconds % 60
	if h > 0 {
		return fmt.Sprintf("%d:%02d:%02d", h, m, s)
	}
	return fmt.Sprintf("%02d:%02d", m, s)
}