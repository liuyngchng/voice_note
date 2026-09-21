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
)

// homeViewModel manages home screen state.
type homeViewModel struct {
	app         *App
	todayCount  *widget.Label
	totalCount  *widget.Label
	recordList  *widget.List
	records     []domain.VoiceRecord
}

// newHomeScreen builds the home page with stats and recent records.
func newHomeScreen(app *App) fyne.CanvasObject {
	vm := &homeViewModel{app: app}

	vm.recordList = widget.NewList(
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

	vm.recordList.OnSelected = func(id widget.ListItemID) {
		if id >= 0 && id < len(vm.records) {
			app.showDetail(vm.records[id].ID)
		}
	}

	// Stats row.
	statsRow := container.NewGridWithColumns(2,
		statCard("今日记录", "0"),
		statCard("总记录", "0"),
	)

	vm.todayCount = widget.NewLabel("0")
	vm.totalCount = widget.NewLabel("0")

	go vm.loadStats(statsRow)

	content := container.NewVBox(
		statsRow,
		widget.NewLabel("最近记录"),
		vm.recordList,
	)

	return content
}

func (vm *homeViewModel) loadStats(statsRow *fyne.Container) {
	ctx := context.Background()
	records, err := vm.app.repo.GetAll(ctx)
	if err != nil {
		return
	}

	now := time.Now()
	todayStart := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	todayCount := 0
	for _, r := range records {
		if r.StartTime.After(todayStart) {
			todayCount++
		}
	}

	// Rebuild stats cards with actual numbers.
	todayCard := statCard("今日记录", fmt.Sprintf("%d", todayCount))
	totalCard := statCard("总记录", fmt.Sprintf("%d", len(records)))

	fyne.Do(func() {
		statsRow.Objects = []fyne.CanvasObject{todayCard, totalCard}
		statsRow.Refresh()
		vm.records = records
		if len(vm.records) > 5 {
			vm.records = vm.records[:5]
		}
		vm.recordList.Refresh()
	})
}
