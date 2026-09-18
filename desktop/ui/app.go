// Package ui provides the Fyne-based graphical user interface.
package ui

import (
	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"

	"github.com/liuyngchng/voice-note-desktop/data"
	"github.com/liuyngchng/voice-note-desktop/internal/asr"
	"github.com/liuyngchng/voice-note-desktop/internal/database"
	"github.com/liuyngchng/voice-note-desktop/internal/settings"
)

// App is the application shell, managing window and navigation between screens.
type App struct {
	win     fyne.Window
	dataDir string
	theme   voiceNoteTheme

	repo       *data.Repository
	store      *settings.Store
	asrEngine  *asr.Engine
}

// NewApp constructs the application shell with all backend dependencies.
func NewApp(win fyne.Window, dataDir string, dao *database.RecordDAO, store *settings.Store) *App {
	a := &App{
		win:     win,
		dataDir: dataDir,
		repo:    data.NewRepository(dao),
		store:   store,
	}

	// Initialize the offline ASR engine in the background. UI proceeds even if
	// the model fails to load; the home screen will show the appropriate banner.
	go func() {
		engine, err := asr.New(dataDir)
		if err != nil {
			a.asrEngine = nil
			return
		}
		a.asrEngine = engine
	}()

	return a
}

// Show starts the app at the login screen.
func (a *App) Show() {
	a.win.SetContent(a.loginScreen())
}

// ---- Navigation helpers ----

func (a *App) loginScreen() fyne.CanvasObject {
	return newLoginScreen(a.win, a, a.store)
}

func (a *App) homeScreen() fyne.CanvasObject {
	return newHomeScreen(a.win, a)
}

func (a *App) recordingScreen() fyne.CanvasObject {
	return newRecordingScreen(a.win, a)
}

func (a *App) detailScreen(recordID int64) fyne.CanvasObject {
	return newDetailScreen(a.win, a, recordID)
}

func (a *App) historyScreen() fyne.CanvasObject {
	return newHistoryScreen(a.win, a)
}

func (a *App) settingsScreen() fyne.CanvasObject {
	return newSettingsScreen(a.win, a)
}

// ---- Shared UI helpers ----

// makeToolbar creates a standard top app bar with title and optional back.
func makeToolbar(title string, onBack func()) fyne.CanvasObject {
	left := widget.NewButton("", onBack)
	left.Importance = widget.LowImportance
	left.Icon = theme.NavigateBackIcon()
	left.Hidden = onBack == nil

	titleLabel := widget.NewLabel(title)
	titleLabel.TextStyle = fyne.TextStyle{Bold: true}

	bar := container.NewBorder(nil, nil, left, nil, titleLabel)
	return bar
}

// statCard renders a statistics card (title + value).
func statCard(title, value string) fyne.CanvasObject {
	titleLabel := widget.NewLabel(title)
	titleLabel.TextStyle = fyne.TextStyle{Bold: false}

	valueLabel := widget.NewLabel(value)
	valueLabel.TextStyle = fyne.TextStyle{Bold: true}

	card := widget.NewCard(title, "", container.NewVBox(valueLabel))
	return card
}