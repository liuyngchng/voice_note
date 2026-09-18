// Package ui provides the Fyne-based graphical user interface.
package ui

import (
	"context"
	"fmt"
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
func newDetailScreen(win fyne.Window, app *App, recordID int64) fyne.CanvasObject {
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
		vm.switchTab(win, app, selected)
	}

	backBtn := widget.NewButton("返回", func() {
		win.SetContent(app.homeScreen())
	})

	content := container.NewBorder(
		container.NewVBox(backBtn, vm.titleLabel, vm.memoLabel, vm.descLabel, vm.timeLabel, tabBar),
		nil, nil, nil,
		vm.tabContainer,
	)

	go vm.loadRecord()
	// Default to audio tab.
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

func (vm *detailViewModel) switchTab(win fyne.Window, app *App, tab string) {
	if vm.record == nil {
		return
	}
	switch tab {
	case "音频":
		vm.tabContainer.Objects = []fyne.CanvasObject{
			vm.buildAudioTab(win, app),
		}
	case "转写":
		vm.tabContainer.Objects = []fyne.CanvasObject{
			vm.buildTranscriptTab(win, app),
		}
	case "总结":
		vm.tabContainer.Objects = []fyne.CanvasObject{
			vm.buildSummaryTab(win, app),
		}
	}
	vm.tabContainer.Refresh()
}

// ---- Audio tab ----

func (vm *detailViewModel) buildAudioTab(win fyne.Window, app *App) fyne.CanvasObject {
	rec := vm.record

	// Play button.
	playBtn := widget.NewButton("播放", func() {
		if rec.AudioFilePath == "" {
			return
		}
		// Load WAV metadata.
		info, err := audio.ReadWavInfo(rec.AudioFilePath)
		if err != nil {
			return
		}
		player, err := audio.NewPlayer(info.SampleRate)
		if err != nil {
			return
		}
		defer player.Close()

		// Read PCM data and play (naive: reads entire file into memory).
		go func() {
			data, err := loadPCMData(rec.AudioFilePath, info)
			if err == nil {
				player.PlaySync(data)
			}
		}()
	})

	// Upload button.
	uploadBtn := widget.NewButton("上传到服务器", func() {
		// TODO: wire up upload
	})
	uploadBtn.Disable()

	// Delete button.
	deleteBtn := widget.NewButton("删除记录", func() {
		ctx := context.Background()
		vm.app.repo.Delete(ctx, rec.ID)
		win.SetContent(app.homeScreen())
	})
	deleteBtn.Importance = widget.DangerImportance

	return container.NewVBox(
		playBtn,
		uploadBtn,
		deleteBtn,
	)
}

// ---- Transcript tab ----

func (vm *detailViewModel) buildTranscriptTab(win fyne.Window, app *App) fyne.CanvasObject {
	rec := vm.record

	text := "转写内容为空"
	if rec.TranscriptFilePath != "" {
		data, err := loadFileContent(rec.TranscriptFilePath)
		if err == nil && data != "" {
			text = data
		}
	}

	label := widget.NewLabel(text)
	label.Wrapping = fyne.TextWrapWord

	return container.NewVBox(label)
}

// ---- Summary tab ----

func (vm *detailViewModel) buildSummaryTab(win fyne.Window, app *App) fyne.CanvasObject {
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

	generateBtn := widget.NewButton("生成总结", func() {
		// TODO: wire up LLM summary generation
	})
	if rec.Summary != nil {
		generateBtn.SetText("重新生成")
	}

	return container.NewVBox(label, generateBtn)
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

func loadFileContent(path string) (string, error) {
	return readFileContent(path)
}

// ---- Low-level helpers (platform-independent file reading) ----

func readFileContent(path string) (string, error) {
	file, err := openFileForRead(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	data := make([]byte, 65536)
	n, err := file.Read(data)
	if err != nil {
		return "", err
	}
	return string(data[:n]), nil
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