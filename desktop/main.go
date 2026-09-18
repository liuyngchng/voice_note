// Package main is the entry point for the Voice Note desktop application.
package main

import (
	"log/slog"
	"os"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"

	"github.com/liuyngchng/voice-note-desktop/internal/database"
	"github.com/liuyngchng/voice-note-desktop/internal/settings"
	"github.com/liuyngchng/voice-note-desktop/ui"
)

func main() {
	// Setup structured logging.
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})))

	// Determine data directory.
	dataDir := database.DefaultDataDir()

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
	nav := ui.NewApp(w, dataDir, db.RecordDAO, store)
	nav.Show()

	w.Resize(fyne.NewSize(420, 720))
	w.ShowAndRun()
}
