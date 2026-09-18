// Package common provides shared utility functions.
package common

import "fmt"

// FormatDuration converts seconds to a display string.
//   - < 1 hour  → "mm:ss"
//   - >= 1 hour → "h:mm:ss"
func FormatDuration(seconds int64) string {
	h := seconds / 3600
	m := (seconds % 3600) / 60
	s := seconds % 60
	if h > 0 {
		return fmt.Sprintf("%d:%02d:%02d", h, m, s)
	}
	return fmt.Sprintf("%02d:%02d", m, s)
}