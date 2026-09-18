//go:build !windows

// Package database provides SQLite persistence for voice records.
package database

import (
	"os"
	"path/filepath"
)

// defaultDataDir returns the platform default user-data directory.
func defaultDataDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ".voicenote"
	}
	return filepath.Join(home, ".voicenote")
}

// DefaultDataDir returns the platform default user-data directory.
func DefaultDataDir() string { return defaultDataDir() }