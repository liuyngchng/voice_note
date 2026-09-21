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
	"github.com/liuyngchng/voice-note-desktop/internal/audio"
	"github.com/liuyngchng/voice-note-desktop/internal/service"
)

type recordingViewModel struct {
	app *App
	mu  sync.Mutex

	recordID      int64
	transcript    string
	statusMessage string
	isStopping    bool
	isFinished    bool

	// UI elements.
	titleLabel     *widget.Label
	transcriptArea *widget.Label
	stopBtn        *widget.Button
	durationLabel  *widget.Label
	statusLabel    *widget.Label

	// Recorder.
	recorder *service.Recorder
}

// newRecordingScreen builds the recording page.
func newRecordingScreen(app *App) fyne.CanvasObject {
	vm := &recordingViewModel{
		app:            app,
		titleLabel:     widget.NewLabel("录音中"),
		transcriptArea: widget.NewLabel("语音识别结果将在此显示"),
		durationLabel:  widget.NewLabel("00:00"),
		statusLabel:    widget.NewLabel("正在初始化..."),
		stopBtn:        widget.NewButton("结束录音", nil),
	}

	vm.transcriptArea.Wrapping = fyne.TextWrapWord

	// Make the stop button stand out: red (danger) and on its own line.
	vm.stopBtn.Importance = widget.DangerImportance

	vm.stopBtn.OnTapped = func() {
		vm.isStopping = true
		vm.stopBtn.Disable()
		vm.stopBtn.SetText("正在保存...")
		if vm.recorder != nil {
			vm.recorder.Stop()
		}
	}

	vm.statusLabel.TextStyle = fyne.TextStyle{Italic: true}

	// Stop button: fixed width, not full-width — centered in the bottom bar.
	buttonBox := container.NewCenter(container.NewPadded(vm.stopBtn))

	content := container.NewBorder(
		vm.titleLabel,
		container.NewVBox(vm.statusLabel, buttonBox),
		nil, nil,
		container.NewVBox(
			vm.durationLabel,
			vm.transcriptArea,
		),
	)

	// Mark recording active immediately so navigation is blocked while the
	// recording screen is shown (startRecording may still be opening the mic).
	app.beginRecording()

	go vm.startRecording()

	return content
}

func (vm *recordingViewModel) startRecording() {
	ctx := context.Background()

	now := time.Now()
	rec := domain.VoiceRecord{
		Title:            fmt.Sprintf("新录音 %s", now.Format("1月2日 15:04")),
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
	recorder := service.NewRecorder(audioRec, vm.app.asrEngine, vm.app.dataDir)
	vm.recorder = recorder

	if err := recorder.Start(recordID); err != nil {
		fyne.Do(func() {
			vm.statusLabel.SetText("启动录音失败: " + err.Error())
			vm.app.endRecording()
		})
		return
	}

	// Listen for state updates.
	go vm.stateLoop(recorder)
}

func (vm *recordingViewModel) stateLoop(rec *service.Recorder) {
	done := rec.Done()
	stateCh := rec.StateChan()

	// Drain state updates until recording finishes.
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
				if state.Transcript != "" {
					vm.transcriptArea.SetText(state.Transcript)
				}
				if state.StatusMessage != "" {
					vm.statusLabel.SetText(state.StatusMessage)
				}
			})
		case <-done:
			// Drain any remaining buffered states.
			for {
				select {
				case state := <-stateCh:
					if state.Transcript != "" {
						vm.mu.Lock()
						vm.transcript = state.Transcript
						vm.mu.Unlock()
					}
				default:
					goto finalize
				}
			}
		}
	}

finalize:
	vm.mu.Lock()
	finalText := vm.transcript
	vm.mu.Unlock()

	ctx := context.Background()

	// Update audio file path in DB.
	audioDir := audioDirPath(vm.app.dataDir, vm.recordID)
	matches := findWavFiles(audioDir)
	if len(matches) > 0 {
		_ = vm.app.repo.UpdateAudioFilePath(ctx, vm.recordID, matches[0], time.Now().UnixMilli())
	}

	// Update transcript status.
	if finalText == "" {
		_ = vm.app.repo.UpdateTranscriptStatus(ctx, vm.recordID, domain.StatusUnavailable)
	} else {
		_ = vm.app.repo.UpdateTranscriptStatus(ctx, vm.recordID, domain.StatusCompleted)
	}

	vm.isFinished = true
	vm.app.endRecording()
	fyne.Do(func() { vm.app.navigate(0) })
}

func findWavFiles(dir string) []string {
	entries, err := readDir(dir)
	if err != nil {
		return nil
	}
	var wavs []string
	for _, e := range entries {
		if !e.IsDir() {
			wavs = append(wavs, dir+"/"+e.Name())
		}
	}
	return wavs
}
