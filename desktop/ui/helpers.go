package ui

import (
	"context"
	"io"
	"os"
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