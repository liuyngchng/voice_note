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
	app      *App
	todayCount *widget.Label
	totalCount *widget.Label
	modelBanner *widget.Label
	recordList  *widget.List
	records   []domain.VoiceRecord
}

// newHomeScreen builds the home page with stats, model status, and recent records.
func newHomeScreen(win fyne.Window, app *App) fyne.CanvasObject {
	vm := &homeViewModel{app: app}

	vm.todayCount = widget.NewLabel("0")
	vm.todayCount.TextStyle = fyne.TextStyle{Bold: true}
	vm.totalCount = widget.NewLabel("0")
	vm.totalCount.TextStyle = fyne.TextStyle{Bold: true}

	vm.modelBanner = widget.NewLabel("正在加载语音识别模型...")

	vm.recordList = widget.NewList(
		func() int { return len(vm.records) },
		func() fyne.CanvasObject {
			return widget.NewLabel("template")
		},
		func(i int, obj fyne.CanvasObject) {
			rec := vm.records[i]
			obj.(*widget.Label).SetText(rec.Title)
		},
	)

	// Toolbar actions.
	recordBtn := widget.NewButton("新建录音", func() {
		win.SetContent(app.recordingScreen())
	})
	recordBtn.Importance = widget.HighImportance

	historyBtn := widget.NewButton("历史记录", func() {
		win.SetContent(app.historyScreen())
	})

	settingsBtn := widget.NewButton("设置", func() {
		win.SetContent(app.settingsScreen())
	})

	// Stats row.
	statsRow := container.NewGridWithColumns(2,
		statCard("今日记录", "0"),
		statCard("总记录", "0"),
	)

	// Reload counts.
	go vm.loadStats(statsRow)

	content := container.NewBorder(
		container.NewVBox(recordBtn, historyBtn, settingsBtn),
		nil, nil, nil,
		container.NewVBox(
			statsRow,
			vm.modelBanner,
			widget.NewLabel("最近记录"),
			vm.recordList,
		),
	)

	return content
}

func (vm *homeViewModel) loadStats(statsRow *fyne.Container) {
	ctx := context.Background()
	records, err := vm.app.repo.GetAll(ctx)
	if err != nil {
		return
	}

	// Count today's records.
	now := time.Now()
	todayStart := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	todayCount := 0
	for _, r := range records {
		if r.StartTime.After(todayStart) {
			todayCount++
		}
	}

	// Update UI on the main thread via fyne.Do.
	fyne.Do(func() {
		vm.todayCount.SetText(fmt.Sprintf("%d", todayCount))
		vm.totalCount.SetText(fmt.Sprintf("%d", len(records)))
		vm.records = records
		if len(vm.records) > 2 {
			vm.records = vm.records[:2]
		}
		vm.recordList.Refresh()

		// Update model banner.
		if vm.app.asrEngine == nil {
			vm.modelBanner.SetText("离线模型未安装或加载失败，请检查模型文件")
		} else {
			vm.modelBanner.SetText("")
			vm.modelBanner.Hide()
		}
	})
}