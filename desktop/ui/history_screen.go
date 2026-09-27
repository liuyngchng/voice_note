// Package ui provides the Fyne-based graphical user interface.
package ui

import (
	"context"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/layout"
	"fyne.io/fyne/v2/widget"

	"github.com/liuyngchng/voice-note-desktop/domain"
)

// historyViewModel manages history screen state.
type historyViewModel struct {
	app     *App
	records []domain.VoiceRecord
	list    *widget.List
}

// newHistoryScreen builds the history page with search and list.
func newHistoryScreen(app *App) fyne.CanvasObject {
	vm := &historyViewModel{app: app}

	vm.list = widget.NewList(
		func() int { return len(vm.records) },
		func() fyne.CanvasObject {
			return widget.NewLabel("template")
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
	deleteAllRow := container.NewHBox(deleteAllBtn, layout.NewSpacer())

	content := container.NewBorder(
		container.NewVBox(deleteAllRow),
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