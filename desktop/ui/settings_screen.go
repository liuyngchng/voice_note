// Package ui provides the Fyne-based graphical user interface.
package ui

import (
	"os"
	"path/filepath"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
)

// settingsViewModel manages settings screen state.
type settingsViewModel struct {
	app *App

	dataDir     *widget.Label
	modelStatus *widget.Label
	vadStatus   *widget.Label
	punctStatus *widget.Label

	loginStatus *widget.Label
}

// newSettingsScreen builds the settings page.
func newSettingsScreen(win fyne.Window, app *App) fyne.CanvasObject {
	vm := &settingsViewModel{app: app}
	cfg := app.store.Get()

	// Data directory.
	dataTitle := widget.NewLabel("数据与模型")
	dataTitle.TextStyle = fyne.TextStyle{Bold: true}

	vm.dataDir = widget.NewLabel("")
	vm.dataDir.Wrapping = fyne.TextWrapWord

	// Model status.
	modelDir := filepath.Join(app.dataDir, "models")
	vm.modelStatus = widget.NewLabel(checkModelStatus(modelDir, "model.onnx"))
	vm.vadStatus = widget.NewLabel(checkModelStatus(modelDir, "silero_vad.onnx"))
	vm.punctStatus = widget.NewLabel(checkModelStatus(modelDir, "punct_ct_transformer.onnx"))

	// Login status.
	vm.loginStatus = widget.NewLabel("")
	if cfg.AuthToken != "" {
		vm.loginStatus.SetText("已登录: " + cfg.Username)
	} else {
		vm.loginStatus.SetText("未登录")
	}

	// Buttons.
	logoutBtn := widget.NewButton("退出登录", func() {
		vm.logout()
		vm.loginStatus.SetText("未登录")
	})
	logoutBtn.Importance = widget.DangerImportance

	backBtn := widget.NewButton("返回", func() {
		win.SetContent(app.homeScreen())
	})

	content := container.NewBorder(
		container.NewVBox(backBtn),
		nil, nil, nil,
		container.NewVBox(
			dataTitle,
			widget.NewLabel("数据目录"),
			vm.dataDir,
			widget.NewLabel("ASR 模型 (SenseVoice FP32)"),
			vm.modelStatus,
			widget.NewLabel("VAD 模型"),
			vm.vadStatus,
			widget.NewLabel("标点模型"),
			vm.punctStatus,
			vm.loginStatus,
			logoutBtn,
		),
	)

	// Load data dir.
	go func() {
		vm.dataDir.SetText(app.dataDir)
	}()

	return content
}

func (vm *settingsViewModel) logout() {
	_ = vm.app.store.ClearAuth()
}

func checkModelStatus(dir, filename string) string {
	path := filepath.Join(dir, filename)
	_, err := os.Stat(path)
	if err != nil {
		return "未安装"
	}
	return "已安装"
}
