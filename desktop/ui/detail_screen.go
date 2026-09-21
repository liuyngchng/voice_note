// Package ui provides the Fyne-based graphical user interface.
package ui

import (
	"context"
	"fmt"
	"os"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"

	"github.com/liuyngchng/voice-note-desktop/domain"
	"github.com/liuyngchng/voice-note-desktop/internal/audio"
)

// detailViewModel manages the detail page state.
type detailViewModel struct {
	app      *App
	record   *domain.VoiceRecord
	recordID int64

	// UI elements updated on load.
	titleLabel   *widget.Label
	memoLabel    *widget.Label
	descLabel    *widget.Label
	timeLabel    *widget.Label
	tabContainer *fyne.Container
}

// newDetailScreen builds the detail page with 3 tabs (Audio, Transcript, Summary).
func newDetailScreen(app *App, recordID int64) fyne.CanvasObject {
	vm := &detailViewModel{app: app, recordID: recordID}

	vm.titleLabel = widget.NewLabel("")
	vm.titleLabel.TextStyle = fyne.TextStyle{Bold: true}
	vm.memoLabel = widget.NewLabel("")
	vm.descLabel = widget.NewLabel("")
	vm.timeLabel = widget.NewLabel("")

	tabBar := widget.NewRadioGroup([]string{"音频", "转写", "总结"}, nil)
	tabBar.Horizontal = true

	vm.tabContainer = &fyne.Container{}

	tabBar.OnChanged = func(selected string) {
		vm.switchTab(app, selected)
	}

	backBtn := widget.NewButton("返回", func() {
		app.goBack()
	})

	content := container.NewBorder(
		container.NewVBox(backBtn, vm.titleLabel, vm.memoLabel, vm.descLabel, vm.timeLabel, tabBar),
		nil, nil, nil,
		vm.tabContainer,
	)

	go vm.loadRecord()
	tabBar.SetSelected("音频")

	return content
}

func (vm *detailViewModel) loadRecord() {
	ctx := context.Background()
	rec, err := vm.app.repo.GetByID(ctx, vm.recordID)
	if err != nil || rec == nil {
		return
	}
	vm.record = rec

	fyne.Do(func() {
		vm.titleLabel.SetText(rec.Title)
		vm.memoLabel.SetText(rec.Memo)
		vm.descLabel.SetText(rec.Description)
		loc := time.Local
		if loc == nil {
			loc = time.UTC
		}
		vm.timeLabel.SetText(rec.StartTime.In(loc).Format("2006/01/02 15:04:05"))
	})
}

func (vm *detailViewModel) switchTab(app *App, tab string) {
	if vm.record == nil {
		return
	}
	switch tab {
	case "音频":
		vm.tabContainer.Objects = []fyne.CanvasObject{
			vm.buildAudioTab(app),
		}
	case "转写":
		vm.tabContainer.Objects = []fyne.CanvasObject{
			vm.buildTranscriptTab(app),
		}
	case "总结":
		vm.tabContainer.Objects = []fyne.CanvasObject{
			vm.buildSummaryTab(app),
		}
	}
	vm.tabContainer.Refresh()
}

// ---- Audio tab ----

func (vm *detailViewModel) buildAudioTab(app *App) fyne.CanvasObject {
	rec := vm.record

	// Play button.
	playBtn := widget.NewButton("播放", func() {
		if rec.AudioFilePath == "" {
			return
		}
		info, err := audio.ReadWavInfo(rec.AudioFilePath)
		if err != nil {
			return
		}
		player, err := audio.NewPlayer(info.SampleRate)
		if err != nil {
			return
		}
		defer player.Close()

		go func() {
			data, err := loadPCMData(rec.AudioFilePath, info)
			if err == nil {
				player.PlaySync(data)
			}
		}()
	})

	// Delete button.
	deleteBtn := widget.NewButton("删除记录", func() {
		ctx := context.Background()
		app.repo.Delete(ctx, rec.ID)
		app.goBack()
	})
	deleteBtn.Importance = widget.DangerImportance

	audioInfo := widget.NewLabel("")
	if rec.AudioFilePath != "" {
		info, err := audio.ReadWavInfo(rec.AudioFilePath)
		if err == nil {
			bytesPerSec := int64(info.SampleRate) * int64(info.Channels) * int64(info.BitsPerSample/8)
			durationSec := int64(0)
			if bytesPerSec > 0 {
				durationSec = info.DataSize / bytesPerSec
			}
			audioInfo.SetText(fmt.Sprintf("时长: %s  |  采样率: %d Hz  |  声道: %d",
				formatDuration(durationSec), info.SampleRate, info.Channels))
		}
	}

	return container.NewVBox(
		audioInfo,
		playBtn,
		deleteBtn,
	)
}

// ---- Transcript tab ----

func (vm *detailViewModel) buildTranscriptTab(app *App) fyne.CanvasObject {
	rec := vm.record

	text := "转写内容为空"
	if rec.TranscriptFilePath != "" {
		data, err := os.ReadFile(rec.TranscriptFilePath)
		if err == nil && len(data) > 0 {
			text = string(data)
		}
	}

	label := widget.NewLabel(text)
	label.Wrapping = fyne.TextWrapWord

	// Scroll container for long transcripts.
	scroll := container.NewScroll(label)

	return container.NewVBox(scroll)
}

// ---- Summary tab ----

func (vm *detailViewModel) buildSummaryTab(app *App) fyne.CanvasObject {
	rec := vm.record

	text := "暂无总结内容"
	if rec.Summary != nil && !rec.Summary.IsEmpty() {
		text = formatSummary(rec.Summary)
	} else if rec.SummaryStatus == domain.StatusProcessing {
		text = "正在生成总结..."
	} else if rec.SummaryStatus == domain.StatusUnavailable {
		text = "总结生成失败"
	}

	label := widget.NewLabel(text)
	label.Wrapping = fyne.TextWrapWord

	scroll := container.NewScroll(label)
	return container.NewVBox(scroll)
}

// ---- Helpers ----

func formatSummary(s *domain.RecordSummary) string {
	var out string
	if len(s.Topics) > 0 {
		out += "【议题】\n"
		for _, t := range s.Topics {
			out += fmt.Sprintf("  • %s\n", t)
		}
		out += "\n"
	}
	if len(s.Conclusions) > 0 {
		out += "【结论】\n"
		for _, c := range s.Conclusions {
			out += fmt.Sprintf("  • %s\n", c)
		}
		out += "\n"
	}
	if len(s.Todos) > 0 {
		out += "【待办】\n"
		for _, t := range s.Todos {
			meta := ""
			if t.Owner != "" || t.Deadline != "" {
				meta = fmt.Sprintf("（%s %s）", t.Owner, t.Deadline)
			}
			out += fmt.Sprintf("  • %s%s\n", t.Task, meta)
		}
		out += "\n"
	}
	if len(s.NextSteps) > 0 {
		out += "【后续步骤】\n"
		for _, n := range s.NextSteps {
			out += fmt.Sprintf("  • %s\n", n)
		}
	}
	return out
}

func loadPCMData(path string, info audio.WavInfo) ([]float32, error) {
	data, err := readFileBytes(path)
	if err != nil {
		return nil, err
	}
	if int64(len(data)) < info.DataOffset {
		return nil, fmt.Errorf("file too small")
	}
	pcm := data[info.DataOffset:]
	return audio.ConvertPCMToFloats(pcm), nil
}
