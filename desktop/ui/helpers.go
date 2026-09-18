package ui

import (
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/liuyngchng/voice-note-desktop/internal/audio"
)

// openFileForRead opens a file for reading.
func openFileForRead(path string) (*os.File, error) {
	return os.Open(path)
}

// readFileBytes reads a file fully into memory.
func readFileBytes(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return io.ReadAll(f)
}

// readDir lists entries in a directory.
func readDir(dir string) ([]os.DirEntry, error) {
	return os.ReadDir(dir)
}

// importAudioFile copies an external audio file into the app's managed directory.
func importAudioFile(srcPath, dataDir string, recordID int64) (string, error) {
	return audio.ImportAudio(srcPath, dataDir, recordID)
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

// audioDirPath builds the audio directory path for a record.
func audioDirPath(dataDir string, recordID int64) string {
	return filepath.Join(dataDir, "audio", fmt.Sprintf("record_%d", recordID))
}
