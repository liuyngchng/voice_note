// Package ui provides the Fyne-based graphical user interface.
package ui

import (
	"context"
	"os"
	"sync"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/widget"

	"github.com/liuyngchng/voice-note-desktop/domain"
)

// historyViewModel manages history screen state.
type historyViewModel struct {
	app *App
	mu  sync.Mutex // guards records + in-flight refresh

	records    []domain.VoiceRecord
	list       *widget.List
	refreshing bool
}

// newHistoryScreen builds the history page with search and list.
// Returns the view model and its root canvas object.
func newHistoryScreen(app *App) (*historyViewModel, fyne.CanvasObject) {
	vm := &historyViewModel{app: app}

	vm.list = widget.NewList(
		func() int { return len(vm.records) },
		func() fyne.CanvasObject {
			l := widget.NewLabel("template")
			l.TextStyle = fyne.TextStyle{Underline: true}
			return l
		},
		func(i int, obj fyne.CanvasObject) {
			rec := vm.records[i]
			label := obj.(*widget.Label)
			label.SetText(rec.Title)
		},
	)

	vm.list.OnSelected = func(id widget.ListItemID) {
		if id >= 0 && id < len(vm.records) {
			openDir(vm.app.outputDir)
		}
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

	// Keep the clear button from stretching to fill the tab width.
	deleteAllRow := container.NewCenter(deleteAllBtn)

	content := container.NewBorder(
		nil,
		deleteAllRow,
		nil, nil,
		vm.list,
	)

	vm.refresh()
	return vm, content
}

// refresh reloads the record list from the database. Like the home screen, it
// coalesces concurrent calls so no goroutine accumulates across navigation.
func (vm *historyViewModel) refresh() {
	vm.mu.Lock()
	if vm.refreshing {
		vm.mu.Unlock()
		return
	}
	vm.refreshing = true
	vm.mu.Unlock()

	go vm.loadAll()
}

func (vm *historyViewModel) loadAll() {
	defer func() {
		vm.mu.Lock()
		vm.refreshing = false
		vm.mu.Unlock()
	}()

	ctx := context.Background()
	records, err := vm.app.repo.GetAll(ctx)
	if err != nil {
		return
	}
	fyne.Do(func() {
		vm.mu.Lock()
		vm.records = records
		vm.mu.Unlock()
		vm.list.Refresh()
	})
}

func (vm *historyViewModel) deleteAll() {
	ctx := context.Background()

	// Delete disk files (WAV + transcript) first.
	records, err := vm.app.repo.GetAll(ctx)
	if err != nil {
		return
	}
	for _, r := range records {
		if r.AudioFilePath != "" {
			os.Remove(r.AudioFilePath)
		}
		if r.TranscriptFilePath != "" {
			os.Remove(r.TranscriptFilePath)
		}
	}

	if err := vm.app.repo.DeleteAll(ctx); err != nil {
		return
	}
	fyne.Do(func() {
		vm.mu.Lock()
		vm.records = nil
		vm.mu.Unlock()
		vm.list.Refresh()
	})
}
