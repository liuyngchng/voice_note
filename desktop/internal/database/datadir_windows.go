//go:build windows

// Package database provides SQLite persistence for voice records.
package database

import (
	"os"
	"path/filepath"
)

// defaultDataDir returns the platform default user-data directory.
func defaultDataDir() string {
	appData := os.Getenv("APPDATA")
	if appData == "" {
		return ".voicenote"
	}
	return filepath.Join(appData, "VoiceNote")
}

// DefaultDataDir returns the platform default user-data directory.
func DefaultDataDir() string { return defaultDataDir() }