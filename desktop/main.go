// Package main is the entry point for the Voice Note desktop application.
//
// Model loading strategy (portable-first):
//  1. ./models/  next to the executable (ZIP portable distribution)
//  2. %APPDATA%/VoiceNote/models/ (installed mode)
//
// User data (database, settings, audio) always goes to %APPDATA%/VoiceNote/
// on Windows and ~/.voicenote/ on Linux.
package main

import (
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"

	"github.com/go-gl/glfw/v3.4/glfw"
	"github.com/liuyngchng/voice-note-desktop/internal/database"
	"github.com/liuyngchng/voice-note-desktop/ui"
)

// initLogging configures slog to write to both stderr and a rotating daily log
// file under logs/ (e.g. logs/app_2025-09-28.log).
func initLogging() {
	if err := os.MkdirAll("logs", 0o755); err != nil {
		slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{
			Level: slog.LevelInfo,
		})))
		return
	}

	logPath := filepath.Join("logs", "app_"+time.Now().Format("2006-01-02")+".log")
	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{
			Level: slog.LevelInfo,
		})))
		return
	}

	w := io.MultiWriter(os.Stderr, f)
	slog.SetDefault(slog.New(slog.NewTextHandler(w, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})))
}

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
	// Setup structured logging (stderr + rotating daily log file).
	initLogging()

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

	slog.Info("app_starting", "data_dir", dataDir, "model_dir", modelDir, "output_dir", outputDir)

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
