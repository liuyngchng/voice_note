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

	"github.com/go-gl/glfw/v3.4/glfw"
	"github.com/liuyngchng/voice-note-desktop/internal/database"
	"github.com/liuyngchng/voice-note-desktop/ui"
)

// findModelDir returns the path to the models directory. It tries:
// 1. ./models/ adjacent to the current working directory, then
// 2. %APPDATA%/VoiceNote/models/ (Windows) or ~/.voicenote/models/ (Unix).
//
// The function checks for model.int8.onnx as a sentinel file.
func findModelDir(dataDir string) string {
	// Portable: check ./models/ relative to the current working directory.
	cwd, err := os.Getwd()
	if err == nil {
		portable := filepath.Join(cwd, "models")
		if _, err := os.Stat(filepath.Join(portable, "model.int8.onnx")); err == nil {
			slog.Info("using portable model directory", "path", portable)
			return portable
		}
	}

	// Also check ./models/ relative to the executable.
	exePath, err := os.Executable()
	if err == nil {
		exeDir := filepath.Dir(exePath)
		portable := filepath.Join(exeDir, "models")
		if _, err := os.Stat(filepath.Join(portable, "model.int8.onnx")); err == nil {
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

	// GLFW must be initialized before we can set window hints.
	// Fyne's own glfw.Init() later is a no-op after a successful init.
	if err := glfw.Init(); err != nil {
		panic("glfw init: " + err.Error())
	}
	defer glfw.Terminate()

	// X11: without these ASCII hints GLFW falls back to using the window
	// title (Chinese) as the ICCCM WM_CLASS property, which docks show as
	// garbled text and which breaks .desktop matching.
	glfw.WindowHintString(glfw.X11InstanceName, "voice-note")
	glfw.WindowHintString(glfw.X11ClassName, "VoiceNote")

	// Determine data directory (user data: DB, settings, audio).
	dataDir := database.DefaultDataDir()

	// Determine model directory (portable-first).
	modelDir := findModelDir(dataDir)

	// Output directory: next to the executable, for WAV and transcript files.
	outputDir := dataDir
	if exePath, err := os.Executable(); err == nil {
		outputDir = filepath.Join(filepath.Dir(exePath), "output")
		if err := os.MkdirAll(outputDir, 0755); err != nil {
			slog.Warn("cannot create output directory", "path", outputDir, "error", err)
		}
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
	nav := ui.NewApp(w, dataDir, modelDir, outputDir, db.RecordDAO)
	defer nav.Close()
	nav.Show()

	w.Resize(fyne.NewSize(900, 640))
	w.ShowAndRun()
}