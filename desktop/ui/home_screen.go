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

// homeViewModel manages home screen state.
type homeViewModel struct {
	app *App
	mu  sync.Mutex // guards records + in-flight refresh

	statsRow    *fyne.Container
	recordList  *widget.List
	records     []domain.VoiceRecord
	refreshing  bool
}

// newHomeScreen builds the home page with stats and recent records.
// Returns the view model and its root canvas object.
func newHomeScreen(app *App) (*homeViewModel, fyne.CanvasObject) {
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
			openDir(app.outputDir)
		}
	}

	// Stats row.
	vm.statsRow = container.NewGridWithColumns(2,
		statCard("今日记录", "0"),
		statCard("总记录", "0"),
	)

	content := container.NewVBox(
		vm.statsRow,
		widget.NewLabel("最近记录"),
		vm.recordList,
	)

	vm.refresh()
	return vm, content
}

// refresh reloads stats and recent records from the database. It is safe to
// call on every navigation to the home screen: concurrent calls are coalesced
// so no goroutine accumulates, and stale results never touch the UI after a
// newer refresh has started.
func (vm *homeViewModel) refresh() {
	vm.mu.Lock()
	if vm.refreshing {
		vm.mu.Unlock()
		return
	}
	vm.refreshing = true
	vm.mu.Unlock()

	go vm.loadStats()
}

func (vm *homeViewModel) loadStats() {
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
		vm.mu.Lock()
		vm.records = records
		if len(vm.records) > 5 {
			vm.records = vm.records[:5]
		}
		vm.mu.Unlock()

		vm.statsRow.Objects = []fyne.CanvasObject{todayCard, totalCard}
		vm.statsRow.Refresh()
		vm.recordList.Refresh()
	})
}
