// Package ui provides the Fyne-based graphical user interface.
package ui

import (
	"context"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/widget"

	"github.com/liuyngchng/voice-note-desktop/domain"
)

// historyViewModel manages history screen state.
type historyViewModel struct {
	app        *App
	records    []domain.VoiceRecord
	searchEntry *widget.Entry
	list       *widget.List
}

// newHistoryScreen builds the history page with search and list.
func newHistoryScreen(win fyne.Window, app *App) fyne.CanvasObject {
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
			win.SetContent(app.detailScreen(vm.records[id].ID))
		}
	}

	vm.searchEntry.OnChanged = func(query string) {
		go vm.search(query)
	}

	backBtn := widget.NewButton("返回", func() {
		win.SetContent(app.homeScreen())
	})

	deleteAllBtn := widget.NewButton("清空", func() {
		dialog.ShowConfirm("清空所有记录",
			"将删除全部记录及其音频文件，此操作不可撤销。",
			func(ok bool) {
				if !ok {
					return
				}
				go vm.deleteAll()
			}, win)
	})
	deleteAllBtn.Importance = widget.DangerImportance

	importBtn := widget.NewButton("导入音频", func() {
		fd := dialog.NewFileOpen(func(reader fyne.URIReadCloser, err error) {
			if err != nil || reader == nil {
				return
			}
			path := reader.URI().Path()
			reader.Close()
			go vm.importAudio(path, win)
		}, win)
		fd.SetFilter(nil)
		fd.Show()
	})

	content := container.NewBorder(
		container.NewVBox(backBtn, vm.searchEntry, importBtn, deleteAllBtn),
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

func (vm *historyViewModel) importAudio(path string, win fyne.Window) {
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

	// Import audio file (TODO: ASR processing).
	destPath, err := importAudioFile(path, vm.app.dataDir, recordID)
	if err != nil {
		return
	}
	_ = destPath

	fyne.Do(func() {
		vm.loadAll()
	})
}
