// Package ui provides the Fyne-based graphical user interface.
package ui

import (
	"context"
	"fmt"
	"sync"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"

	"github.com/liuyngchng/voice-note-desktop/domain"
)

// recordingViewModel manages recording screen state.
type recordingViewModel struct {
	app           *App
	mu            sync.Mutex
	recordID      int64
	durationSec   int64
	transcript    string
	statusMessage string
	isRecording   bool
	isStopping    bool

	// UI elements.
	titleBar     *widget.Label
	transcriptArea *widget.Label
	stopBtn      *widget.Button
	durationLabel *widget.Label
}

// newRecordingScreen builds the recording page.
func newRecordingScreen(win fyne.Window, app *App) fyne.CanvasObject {
	vm := &recordingViewModel{
		app:         app,
		isRecording: true,
		titleBar:    widget.NewLabel("录音中"),
		transcriptArea: widget.NewLabel("语音识别结果将在此显示"),
		durationLabel: widget.NewLabel("00:00"),
		stopBtn:     widget.NewButton("结束录音", nil),
	}

	vm.stopBtn.OnTapped = func() {
		vm.isStopping = true
		vm.stopBtn.Disable()
		vm.stopBtn.SetText("正在保存...")

		// Create the record in the background.
		go vm.finishRecording(win)
	}

	content := container.NewBorder(
		vm.titleBar,
		container.NewBorder(nil, nil, nil, vm.stopBtn, nil),
		nil, nil,
		container.NewVBox(
			vm.durationLabel,
			vm.transcriptArea,
		),
	)

	// Start the recording session in the background.
	go vm.startRecording(content)

	return content
}

func (vm *recordingViewModel) startRecording(outer fyne.CanvasObject) {
	ctx := context.Background()

	// Create a new voice record.
	now := time.Now()
	rec := domain.VoiceRecord{
		Title:       fmt.Sprintf("新录音 %s", now.Format("1月2日 15:04")),
		SourceType:  "RECORDING",
		StartTime:   now,
		CreatedAt:   now,
		TranscriptStatus: domain.StatusPending,
		SummaryStatus:    domain.StatusPending,
	}

	recordID, err := vm.app.repo.Create(ctx, rec)
	if err != nil {
		return
	}
	vm.recordID = recordID

	// Start duration counter.
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for range ticker.C {
			if vm.isStopping {
				return
			}
			vm.mu.Lock()
			vm.durationSec++
			sec := vm.durationSec
			vm.mu.Unlock()
			fyne.Do(func() {
				vm.durationLabel.SetText(formatDuration(sec))
			})
		}
	}()

	// TODO: Launch the actual recorder service when recording is connected.
	_ = recordID
}

func (vm *recordingViewModel) finishRecording(win fyne.Window) {
	fyne.Do(func() {
		win.SetContent(vm.app.homeScreen())
	})
}

func formatDuration(seconds int64) string {
	h := seconds / 3600
	m := (seconds % 3600) / 60
	s := seconds % 60
	if h > 0 {
		return fmt.Sprintf("%d:%02d:%02d", h, m, s)
	}
	return fmt.Sprintf("%02d:%02d", m, s)
}