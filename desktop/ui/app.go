// Package ui provides the Fyne-based graphical user interface.
package ui

import (
	"log/slog"
	"os"
	"sync"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"

	"github.com/liuyngchng/voice-note-desktop/data"
	"github.com/liuyngchng/voice-note-desktop/internal/asr"
	"github.com/liuyngchng/voice-note-desktop/internal/database"
	"github.com/liuyngchng/voice-note-desktop/internal/desktopentry"
)

// App is the application shell, managing window and navigation between screens.
type App struct {
	win       fyne.Window
	dataDir   string
	modelDir  string
	outputDir string

	repo      *data.Repository
	asrEngine *asr.Engine
	engineMu  sync.RWMutex    // protects asrEngine reads/writes
	engineReady chan struct{} // closed when ASR engine load finishes (success or failure)

	// Recording guard — only one recording at a time.
	recordingMu     sync.Mutex
	recordingActive bool
	recordingVM     *recordingViewModel // current recording page (set when page is shown)

	// Sidebar widgets.
	navButtons []*widget.Button
	modelLabel *widget.Label

	// Navigation state.
	navIndex     int
	contentStack *fyne.Container // right pane, swapped by navigate
}

// NewApp constructs the application shell with all backend dependencies.
func NewApp(win fyne.Window, dataDir, modelDir, outputDir string, dao *database.RecordDAO) *App {
	a := &App{
		win:         win,
		dataDir:     dataDir,
		modelDir:    modelDir,
		outputDir:   outputDir,
		repo:        data.NewRepository(dao),
		engineReady: make(chan struct{}),
	}

	// Load the offline ASR engine in the background. Once done (success or
	// failure) the engineReady channel is closed so that recording flows can
	// wait on it.
	go a.initEngine()

	return a
}

// initEngine loads the ASR model in the background. This runs once at startup
// so the model is typically ready by the time the user starts a recording.
func (a *App) initEngine() {
	defer close(a.engineReady)

	engine, err := asr.New(a.modelDir)
	a.engineMu.Lock()
	if err != nil {
		slog.Warn("app_asr_init_failed", "error", err)
		a.asrEngine = nil
	} else {
		a.asrEngine = engine
	}
	a.engineMu.Unlock()

	fyne.Do(a.refreshModelStatus)
}

// Engine returns the ASR engine (nil if loading failed).
func (a *App) Engine() *asr.Engine {
	a.engineMu.RLock()
	defer a.engineMu.RUnlock()
	return a.asrEngine
}

// WaitForEngine blocks until ASR loading completes or timeout expires.
// Returns true if the engine is ready after waiting, false on timeout or failure.
func (a *App) WaitForEngine(timeout time.Duration) bool {
	select {
	case <-a.engineReady:
	case <-time.After(timeout):
	}
	eng := a.Engine()
	return eng != nil && eng.IsReady()
}

// Close releases ASR engine resources (sherpa-onnx native handles).
func (a *App) Close() {
	a.engineMu.Lock()
	eng := a.asrEngine
	a.asrEngine = nil
	a.engineMu.Unlock()

	if eng != nil {
		eng.Close()
	}
}

// Show starts the app at the home screen and installs the top menu bar.
func (a *App) Show() {
	a.win.SetMainMenu(a.buildMainMenu())
	a.win.SetContent(a.buildLayout())

	// Intercept window close: if a recording is in progress, gracefully stop
	// it first, then close after the finalize flow completes.
	a.win.SetCloseIntercept(a.onCloseIntercepted)
}

// onCloseIntercepted handles the window close (X button). If a recording is
// active it triggers the same stop flow as pressing the stop button, and the
// recording view will call win.Close() when finalize is done. If no recording
// is active the window closes immediately.
func (a *App) onCloseIntercepted() {
	if !a.isRecording() {
		a.win.Close()
		return
	}
	if a.recordingVM != nil {
		a.recordingVM.stopRecording()
	}
}

// closeWindowAfterRecording is called by the recording VM after its finalize
// flow completes following a window-close-initiated stop.
func (a *App) closeWindowAfterRecording() {
	fyne.Do(func() {
		a.win.Close()
	})
}

// buildLayout creates the desktop layout: a left sidebar for navigation and a
// right content area that swaps based on the selected section.
func (a *App) buildLayout() fyne.CanvasObject {
	// Sidebar title.
	title := widget.NewLabel("语音笔记")
	title.TextStyle = fyne.TextStyle{Bold: true}

	// Navigation buttons.
	homeBtn := widget.NewButton("首页", func() { a.navigate(0) })
	recordBtn := widget.NewButton("录音", func() { a.navigate(1) })
	historyBtn := widget.NewButton("历史记录", func() { a.navigate(2) })
	settingsBtn := widget.NewButton("系统信息", func() { a.navigate(3) })

	a.navButtons = []*widget.Button{homeBtn, recordBtn, historyBtn, settingsBtn}

	// Model status indicator (bottom of sidebar).
	a.modelLabel = widget.NewLabel("模型加载中...")
	a.modelLabel.Wrapping = fyne.TextWrapWord
	a.refreshModelStatus()

	// Sidebar column: title + nav + spacer + model status.
	sidebar := container.NewBorder(
		container.NewVBox(title, widget.NewSeparator(),
			homeBtn, recordBtn, historyBtn, settingsBtn),
		a.modelLabel,
		nil, nil,
	)

	// Right content area — starts with home.
	a.contentStack = container.NewStack(a.homeScreen())
	a.navIndex = 0
	a.updateNavHighlight()

	split := container.NewHSplit(sidebar, a.contentStack)
	split.Offset = 0.22
	return split
}

// navigate switches the right content pane and updates the sidebar highlight.
func (a *App) navigate(index int) {
	if a.contentStack == nil {
		return
	}

	// Block leaving the recording screen (index 1) while a recording is active.
	if a.navIndex == 1 && index != 1 && a.isRecording() {
		dialog.ShowInformation("录音进行中", "请先结束当前录音", a.win)
		return
	}

	a.navIndex = index
	a.updateNavHighlight()

	switch index {
	case 0:
		a.contentStack.Objects = []fyne.CanvasObject{a.homeScreen()}
	case 1:
		a.contentStack.Objects = []fyne.CanvasObject{a.recordingScreen()}
	case 2:
		a.contentStack.Objects = []fyne.CanvasObject{a.historyScreen()}
	case 3:
		a.contentStack.Objects = []fyne.CanvasObject{a.settingsScreen()}
	}
	a.contentStack.Refresh()
}

// isRecording reports whether a recording is currently active.
func (a *App) isRecording() bool {
	a.recordingMu.Lock()
	defer a.recordingMu.Unlock()
	return a.recordingActive
}

// beginRecording marks a recording as active (called when recording starts).
func (a *App) beginRecording() {
	a.recordingMu.Lock()
	a.recordingActive = true
	a.recordingMu.Unlock()
}

// endRecording clears the active-recording flag (called when recording stops).
func (a *App) endRecording() {
	a.recordingMu.Lock()
	a.recordingActive = false
	a.recordingMu.Unlock()
}

// updateNavHighlight marks the selected sidebar button.
func (a *App) updateNavHighlight() {
	for i, btn := range a.navButtons {
		if i == a.navIndex {
			btn.Importance = widget.HighImportance
		} else {
			btn.Importance = widget.MediumImportance
		}
		btn.Refresh()
	}
}

// refreshModelStatus updates the sidebar model indicator.
func (a *App) refreshModelStatus() {
	if a.modelLabel == nil {
		return
	}
	eng := a.Engine()
	if eng == nil || !eng.IsReady() {
		a.modelLabel.SetText("离线模型未加载")
		return
	}
	a.modelLabel.SetText("离线模型就绪")
}

// buildMainMenu constructs the top-level application menu. The desktop shortcut
// toggle lives here so it is always visible, independent of the current screen.
func (a *App) buildMainMenu() *fyne.MainMenu {
	installed := desktopentry.IsInstalled()

	shortcutItem := fyne.NewMenuItem("创建桌面快捷方式", a.toggleShortcut)
	if installed {
		shortcutItem.Label = "移除桌面快捷方式"
	}

	fileMenu := fyne.NewMenu("应用", shortcutItem)

	return fyne.NewMainMenu(fileMenu)
}

// toggleShortcut installs or removes the desktop launcher shortcut, showing a
// confirmation dialog of the result.
func (a *App) toggleShortcut() {
	if desktopentry.IsInstalled() {
		if err := desktopentry.RemoveShortcut(); err != nil {
			dialog.ShowError(err, a.win)
			return
		}
		dialog.ShowInformation("完成", "桌面快捷方式已移除", a.win)
		a.win.SetMainMenu(a.buildMainMenu())
		return
	}

	exe, err := os.Executable()
	if err != nil {
		dialog.ShowError(err, a.win)
		return
	}
	if err := desktopentry.CreateShortcut(exe); err != nil {
		dialog.ShowError(err, a.win)
		return
	}
	dialog.ShowInformation("完成", "桌面快捷方式已创建 — 可在系统菜单中搜索", a.win)

	// Refresh the menu label to reflect the new state.
	a.win.SetMainMenu(a.buildMainMenu())
}

// ---- Navigation helpers (called by sub-pages) ----

func (a *App) homeScreen() fyne.CanvasObject {
	return newHomeScreen(a)
}

func (a *App) recordingScreen() fyne.CanvasObject {
	vm := newRecordingScreen(a)
	a.recordingVM = vm
	return vm.content
}


func (a *App) historyScreen() fyne.CanvasObject {
	return newHistoryScreen(a)
}

func (a *App) settingsScreen() fyne.CanvasObject {
	return newInfoScreen(a)
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