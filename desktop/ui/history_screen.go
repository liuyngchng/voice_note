// Package ui provides the Fyne-based graphical user interface.
package ui

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/widget"

	"github.com/liuyngchng/voice-note-desktop/domain"
	"github.com/liuyngchng/voice-note-desktop/internal/asr"
	"github.com/liuyngchng/voice-note-desktop/internal/audio"
)

// historyViewModel manages history screen state.
type historyViewModel struct {
	app         *App
	records     []domain.VoiceRecord
	searchEntry *widget.Entry
	list        *widget.List
}

// newHistoryScreen builds the history page with search and list.
func newHistoryScreen(app *App) fyne.CanvasObject {
	vm := &historyViewModel{app: app}

	vm.searchEntry = widget.NewEntry()
	vm.searchEntry.SetPlaceHolder("搜索")

	vm.list = widget.NewList(
		func() int { return len(vm.records) },
		func() fyne.CanvasObject {
			return widget.NewLabel("template")
		},
		func(i int, obj fyne.CanvasObject) {
			rec := vm.records[i]
			label := obj.(*widget.Label)
			loc := time.Local
			label.SetText(rec.Title + " · " + rec.StartTime.In(loc).Format("01/02 15:04"))
		},
	)

	vm.list.OnSelected = func(id widget.ListItemID) {
		if id >= 0 && id < len(vm.records) {
			app.showDetail(vm.records[id].ID)
		}
	}

	vm.searchEntry.OnChanged = func(query string) {
		go vm.search(query)
	}

	deleteAllBtn := widget.NewButton("清空", func() {
		dialog.ShowConfirm("清空所有记录",
			"将删除全部记录及其音频文件，此操作不可撤销。",
			func(ok bool) {
				if !ok {
					return
				}
				go vm.deleteAll()
			}, app.win)
	})
	deleteAllBtn.Importance = widget.DangerImportance

	importBtn := widget.NewButton("导入音频", func() {
		fd := dialog.NewFileOpen(func(reader fyne.URIReadCloser, err error) {
			if err != nil || reader == nil {
				return
			}
			path := reader.URI().Path()
			reader.Close()
			go vm.importAudio(path)
		}, app.win)
		fd.SetFilter(nil)
		fd.Show()
	})

	content := container.NewBorder(
		container.NewVBox(vm.searchEntry, importBtn, deleteAllBtn),
		nil, nil, nil,
		vm.list,
	)

	go vm.loadAll()
	return content
}

func (vm *historyViewModel) loadAll() {
	ctx := context.Background()
	records, err := vm.app.repo.GetAll(ctx)
	if err != nil {
		return
	}
	fyne.Do(func() {
		vm.records = records
		vm.list.Refresh()
	})
}

func (vm *historyViewModel) search(query string) {
	ctx := context.Background()
	var records []domain.VoiceRecord
	var err error
	if query == "" {
		records, err = vm.app.repo.GetAll(ctx)
	} else {
		records, err = vm.app.repo.Search(ctx, query)
	}
	if err != nil {
		return
	}
	fyne.Do(func() {
		vm.records = records
		vm.list.Refresh()
	})
}

func (vm *historyViewModel) deleteAll() {
	ctx := context.Background()
	for _, r := range vm.records {
		vm.app.repo.Delete(ctx, r.ID)
	}
	fyne.Do(func() {
		vm.records = nil
		vm.list.Refresh()
	})
}

func (vm *historyViewModel) importAudio(path string) {
	ctx := context.Background()

	now := time.Now()
	rec := domain.VoiceRecord{
		Title:            "导入音频 " + now.Format("1月2日 15:04"),
		SourceType:       "IMPORTED",
		StartTime:        now,
		CreatedAt:        now,
		TranscriptStatus: domain.StatusPending,
		SummaryStatus:    domain.StatusPending,
	}
	recordID, err := vm.app.repo.Create(ctx, rec)
	if err != nil {
		return
	}

	// Copy audio into app-managed directory.
	destPath, err := importAudioFile(path, vm.app.dataDir, recordID)
	if err != nil {
		return
	}
	_ = vm.app.repo.UpdateAudioFilePath(ctx, recordID, destPath, now.UnixMilli())

	fyne.Do(func() {
		vm.loadAll()
	})

	// Background ASR processing.
	go vm.processImportedAudio(recordID, destPath)
}

// processImportedAudio runs offline ASR on the imported audio and persists
// the transcript, mirroring Android's AudioImporter.processAudio.
func (vm *historyViewModel) processImportedAudio(recordID int64, audioPath string) {
	ctx := context.Background()

	if vm.app.asrEngine == nil || !vm.app.asrEngine.IsReady() {
		_ = vm.app.repo.UpdateTranscriptStatus(ctx, recordID, domain.StatusUnavailable)
		return
	}

	_ = vm.app.repo.UpdateTranscriptStatus(ctx, recordID, domain.StatusProcessing)

	text, err := transcribeFile(vm.app.asrEngine, audioPath)
	if err != nil || text == "" {
		_ = vm.app.repo.UpdateTranscriptStatus(ctx, recordID, domain.StatusUnavailable)
		return
	}

	// Write transcript file.
	audioDir := audioDirPath(vm.app.dataDir, recordID)
	if err := os.MkdirAll(audioDir, 0700); err == nil {
		txtPath := filepath.Join(audioDir, fmt.Sprintf("import_%s.txt", time.Now().Format("20060102_150405")))
		if os.WriteFile(txtPath, []byte(text), 0600) == nil {
			_ = vm.app.repo.UpdateTranscriptWithFile(ctx, recordID, txtPath)
		}
	}
	_ = vm.app.repo.UpdateTranscriptStatus(ctx, recordID, domain.StatusCompleted)

	// Refresh list so status is reflected.
	fyne.Do(func() {
		vm.loadAll()
	})
}

// transcribeFile decodes an audio file (WAV/PCM) in chunks and returns the
// concatenated transcript.
func transcribeFile(engine *asr.Engine, audioPath string) (string, error) {
	info, err := audio.ReadWavInfo(audioPath)
	if err != nil {
		return "", err
	}
	bytesPerSec := int64(info.SampleRate) * int64(info.Channels) * int64(info.BitsPerSample/8)
	if bytesPerSec <= 0 {
		return "", fmt.Errorf("invalid WAV format")
	}

	chunkSizeBytes := int64(30 * bytesPerSec) // 30-second chunks
	if chunkSizeBytes < 32000 {
		chunkSizeBytes = 32000
	}

	f, err := os.Open(audioPath)
	if err != nil {
		return "", err
	}
	defer f.Close()

	_, err = f.Seek(info.DataOffset, 0)
	if err != nil {
		return "", err
	}

	var result string
	remaining := info.DataSize
	buf := make([]byte, chunkSizeBytes)
	for remaining > 0 {
		toRead := chunkSizeBytes
		if remaining < toRead {
			toRead = remaining
		}
		n, err := f.Read(buf[:toRead])
		if err != nil && n == 0 {
			break
		}
		chunk := buf[:n]
		text, err := engine.Decode(audio.ConvertPCMToFloats(chunk))
		if err == nil && text != "" {
			result += text
		}
		remaining -= int64(n)
	}
	return result, nil
}
