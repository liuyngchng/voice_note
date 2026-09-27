// Package ui provides the Fyne-based graphical user interface.
package ui

import (
	"context"
	"strings"
	"sync"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/layout"
	"fyne.io/fyne/v2/widget"

	"github.com/liuyngchng/voice-note-desktop/domain"
	"github.com/liuyngchng/voice-note-desktop/internal/audio"
	"github.com/liuyngchng/voice-note-desktop/internal/service"
)

const maxDisplayLines = 5

// recordingState tracks whether the page is idle or actively recording.
type recordingState int

const (
	stateIdle      recordingState = iota
	stateRecording               // actively capturing audio
)

type recordingViewModel struct {
	app *App
	mu  sync.Mutex

	recordID      int64
	transcript    string
	statusMessage string
	isPaused      bool
	isFinished    bool
	state         recordingState

	// UI elements.
	titleLabel     *widget.Label
	transcriptArea *widget.Label
	startPauseBtn  *widget.Button
	stopBtn        *widget.Button
	durationLabel  *widget.Label
	statusLabel    *widget.Label

	// Recorder (set once recording starts).
	recorder *service.Recorder

	// The root content object, exposed so App can use it for close intercept.
	content fyne.CanvasObject
}

// newRecordingScreen builds the recording page. Recording does NOT start
// automatically when the page is shown — the user must tap "开始".
func newRecordingScreen(app *App) *recordingViewModel {
	vm := &recordingViewModel{
		app:            app,
		state:          stateIdle,
		titleLabel:     widget.NewLabel("录音"),
		transcriptArea: widget.NewLabel("点击「开始」启动录音"),
		durationLabel:  widget.NewLabel("00:00"),
		statusLabel:    widget.NewLabel("就绪"),
		startPauseBtn:  widget.NewButton("开始", nil),
		stopBtn:        widget.NewButton("结束", nil),
	}

	vm.transcriptArea.Wrapping = fyne.TextWrapWord

	vm.startPauseBtn.Importance = widget.HighImportance
	vm.startPauseBtn.OnTapped = func() { vm.onStartPauseTapped() }

	vm.stopBtn.Importance = widget.DangerImportance
	vm.stopBtn.Disable()
	vm.stopBtn.OnTapped = func() { vm.onStopTapped(false) }

	vm.statusLabel.TextStyle = fyne.TextStyle{Italic: true}

	// Buttons: Start/Pause | Stop
	buttonRow := container.NewHBox(
		layout.NewSpacer(),
		container.NewPadded(vm.startPauseBtn),
		layout.NewSpacer(),
		container.NewPadded(vm.stopBtn),
		layout.NewSpacer(),
	)
	buttonBox := container.NewCenter(buttonRow)

	c := container.NewBorder(
		vm.titleLabel,
		container.NewVBox(vm.statusLabel, buttonBox),
		nil, nil,
		container.NewVBox(
			vm.durationLabel,
			vm.transcriptArea,
		),
	)
	vm.content = c
	return vm
}

// onStartPauseTapped handles both "start" and "pause/resume" depending on state.
func (vm *recordingViewModel) onStartPauseTapped() {
	switch vm.state {
	case stateIdle:
		vm.state = stateRecording
		vm.startPauseBtn.SetText("暂停")
		vm.isPaused = false
		vm.statusLabel.SetText("正在初始化...")
		// Mark recording active so navigation is blocked and window-close is
		// intercepted once recording has actually begun.
		vm.app.beginRecording()
		go vm.startRecording()
	case stateRecording:
		vm.isPaused = !vm.isPaused
		if vm.isPaused {
			vm.startPauseBtn.SetText("继续")
			if vm.recorder != nil {
				vm.recorder.Pause(true)
			}
		} else {
			vm.startPauseBtn.SetText("暂停")
			if vm.recorder != nil {
				vm.recorder.Pause(false)
			}
		}
	}
}

// onStopTapped ends the recording and triggers finalize. When closeWindow is
// true, the window is closed after finalize completes (triggered by the window
// close intercept).
func (vm *recordingViewModel) onStopTapped(closeWindow bool) {
	if vm.recorder == nil {
		vm.finish(closeWindow)
		return
	}
	vm.stopBtn.Disable()
	vm.stopBtn.SetText("正在保存...")
	vm.recorder.Stop()
	// stateLoop will call finish() when done.
}

// stopRecording is called by the App when the window close (X) is intercepted
// during an active recording. It triggers the same graceful stop flow.
func (vm *recordingViewModel) stopRecording() {
	vm.onStopTapped(true)
}

func (vm *recordingViewModel) startRecording() {
	ctx := context.Background()

	// Wait for the ASR engine to be ready (already loaded at startup, but may
	// still be in-flight if the user hits record immediately). On timeout or
	// load failure we proceed without transcription.
	if vm.app.WaitForEngine(30 * time.Second) {
		fyne.Do(func() {
			vm.titleLabel.SetText("录音中")
		})
	} else {
		fyne.Do(func() {
			vm.titleLabel.SetText("录音中（无转写）")
			vm.statusLabel.SetText("模型未就绪，将以无转写模式录音")
		})
	}

	now := time.Now()
	rec := domain.VoiceRecord{
		Title:            now.Format("20060102_150405") + "_voice_note",
		SourceType:       "RECORDING",
		StartTime:        now,
		CreatedAt:        now,
		TranscriptStatus: domain.StatusPending,
		SummaryStatus:    domain.StatusPending,
	}

	recordID, err := vm.app.repo.Create(ctx, rec)
	if err != nil {
		fyne.Do(func() {
			vm.statusLabel.SetText("创建录音记录失败")
			vm.app.endRecording()
		})
		return
	}
	vm.recordID = recordID

	// Create audio capture.
	audioRec, err := audio.NewRecorder()
	if err != nil {
		fyne.Do(func() {
			vm.statusLabel.SetText("无法打开麦克风: " + err.Error())
			vm.app.endRecording()
		})
		return
	}

	// Create and start the recorder orchestrator.
	recorder := service.NewRecorder(audioRec, vm.app.Engine(), vm.app.outputDir)
	vm.recorder = recorder

	if err := recorder.Start(recordID); err != nil {
		fyne.Do(func() {
			vm.statusLabel.SetText("启动录音失败: " + err.Error())
			vm.app.endRecording()
		})
		return
	}

	vm.stopBtn.Enable()
	fyne.Do(func() {
		vm.statusLabel.SetText("正在录音...")
	})

	// Listen for state updates.
	go vm.stateLoop(recorder)
}

func (vm *recordingViewModel) stateLoop(rec *service.Recorder) {
	done := rec.Done()
	stateCh := rec.StateChan()

	var finalWavPath string
	var finalTranscriptPath string
	var displayLines []string // sliding window of last N lines

	for {
		select {
		case state, ok := <-stateCh:
			if !ok {
				continue
			}
			vm.mu.Lock()
			if state.Transcript != "" {
				vm.transcript = state.Transcript
			}
			if state.StatusMessage != "" {
				vm.statusMessage = state.StatusMessage
			}
			vm.mu.Unlock()

			fyne.Do(func() {
				if state.DurationSec > 0 {
					vm.durationLabel.SetText(formatDuration(state.DurationSec))
				}
				if state.NewSegment != "" {
					lines := strings.Split(state.NewSegment, "\n")
					for _, line := range lines {
						line = strings.TrimSpace(line)
						if line == "" {
							continue
						}
						displayLines = append(displayLines, line)
					}
					if len(displayLines) > maxDisplayLines {
						displayLines = displayLines[len(displayLines)-maxDisplayLines:]
					}
					vm.transcriptArea.SetText(strings.Join(displayLines, "\n"))
				}
				if state.StatusMessage != "" {
					vm.statusLabel.SetText(state.StatusMessage)
				}
			})

			if state.WavPath != "" {
				finalWavPath = state.WavPath
			}
			if state.TranscriptPath != "" {
				finalTranscriptPath = state.TranscriptPath
			}
		case <-done:
			goto finalize
		}
	}

finalize:
	vm.mu.Lock()
	finalText := vm.transcript
	vm.mu.Unlock()

	ctx := context.Background()

	if finalWavPath != "" {
		_ = vm.app.repo.UpdateAudioFilePath(ctx, vm.recordID, finalWavPath, time.Now().UnixMilli())
	}

	if finalTranscriptPath != "" {
		_ = vm.app.repo.UpdateTranscriptWithFile(ctx, vm.recordID, finalTranscriptPath)
	}
	if finalText == "" {
		_ = vm.app.repo.UpdateTranscriptStatus(ctx, vm.recordID, domain.StatusUnavailable)
	} else {
		_ = vm.app.repo.UpdateTranscriptStatus(ctx, vm.recordID, domain.StatusCompleted)
	}

	vm.isFinished = true
	vm.finish(false)
}

// finish cleans up recording state and navigates back to home. If
// closeWindow is true, the window is closed after cleanup (triggered
// by a window close intercept).
func (vm *recordingViewModel) finish(closeWindow bool) {
	vm.app.endRecording()
	if closeWindow {
		vm.app.closeWindowAfterRecording()
	} else {
		fyne.Do(func() { vm.app.navigate(0) })
	}
}