// Package main is the entry point for the Voice Note desktop application.
//
// Model loading strategy (portable-first):
//   1. ./models/  next to the executable (ZIP portable distribution)
//   2. %APPDATA%/VoiceNote/models/ (installed mode)
//
// User data (database, settings, audio) always goes to %APPDATA%/VoiceNote/
// on Windows and ~/.voicenote/ on Linux.
package main

import (
	"log/slog"
	"os"
	"path/filepath"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"

	"github.com/liuyngchng/voice-note-desktop/internal/database"
	"github.com/liuyngchng/voice-note-desktop/internal/settings"
	"github.com/liuyngchng/voice-note-desktop/ui"
)

// findModelDir returns the path to the models directory. It tries:
// 1. ./models/ adjacent to the current working directory, then
// 2. %APPDATA%/VoiceNote/models/ (Windows) or ~/.voicenote/models/ (Unix).
//
// The function checks for model.onnx as a sentinel file.
func findModelDir(dataDir string) string {
	// Portable: check ./models/ relative to the current working directory.
	cwd, err := os.Getwd()
	if err == nil {
		portable := filepath.Join(cwd, "models")
		if _, err := os.Stat(filepath.Join(portable, "model.onnx")); err == nil {
			slog.Info("using portable model directory", "path", portable)
			return portable
		}
	}

	// Also check ./models/ relative to the executable.
	exePath, err := os.Executable()
	if err == nil {
		exeDir := filepath.Dir(exePath)
		portable := filepath.Join(exeDir, "models")
		if _, err := os.Stat(filepath.Join(portable, "model.onnx")); err == nil {
			slog.Info("using portable model directory", "path", portable)
			return portable
		}
	}

	// Fallback: installed mode.
	fallback := filepath.Join(dataDir, "models")
	slog.Info("using installed model directory", "path", fallback)
	return fallback
}

func main() {
	// Setup structured logging.
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})))

	// Determine data directory (user data: DB, settings, audio).
	dataDir := database.DefaultDataDir()

	// Determine model directory (portable-first).
	modelDir := findModelDir(dataDir)

	// Load settings.
	store, err := settings.LoadStore(dataDir)
	if err != nil {
		slog.Error("failed to load settings", "error", err)
		os.Exit(1)
	}

	// Open database.
	db, err := database.Open(dataDir)
	if err != nil {
		slog.Error("failed to open database", "error", err)
		os.Exit(1)
	}
	defer db.Close()

	// Create Fyne application.
	a := app.NewWithID("com.voicenote.desktop")
	w := a.NewWindow("语音笔记")

	// Build and run the UI.
	nav := ui.NewApp(w, dataDir, modelDir, db.RecordDAO, store)
	nav.Show()

	w.Resize(fyne.NewSize(420, 720))
	w.ShowAndRun()
}