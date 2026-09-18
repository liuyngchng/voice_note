//go:build !embed

// Package embedres is a fallback for builds without the `embed` tag.
// Models are expected to already exist on disk under dataDir/models/.
package embedres

import (
	"path/filepath"
)

// Available reports whether models were embedded at build time.
func Available() bool { return false }

// EnsureModels returns the on-disk model directory without extracting
// anything. Files must already be present at destDir/models/.
func EnsureModels(destDir string) (string, error) {
	return filepath.Join(destDir, "models"), nil
}
