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
}

// newSettingsScreen builds the settings page.
func newSettingsScreen(app *App) fyne.CanvasObject {
	vm := &settingsViewModel{app: app}

	// Data directory.
	dataTitle := widget.NewLabel("数据与模型")
	dataTitle.TextStyle = fyne.TextStyle{Bold: true}

	vm.dataDir = widget.NewLabel("")
	vm.dataDir.Wrapping = fyne.TextWrapWord

	// Model status.
	vm.modelStatus = widget.NewLabel(checkModelStatus(app.modelDir, "model.int8.onnx"))
	vm.vadStatus = widget.NewLabel(checkModelStatus(app.modelDir, "silero_vad.onnx"))
	vm.punctStatus = widget.NewLabel(checkModelStatus(app.modelDir, "punct_ct_transformer.onnx"))

	content := container.NewVBox(
		dataTitle,
		widget.NewLabel("数据目录"),
		vm.dataDir,
		widget.NewLabel("ASR 模型 (SenseVoiceSmall INT8)"),
		vm.modelStatus,
		widget.NewLabel("VAD 模型"),
		vm.vadStatus,
		widget.NewLabel("标点模型"),
		vm.punctStatus,
	)

	// Load data dir.
	go func() {
		vm.dataDir.SetText(app.dataDir)
	}()

	return content
}

func checkModelStatus(dir, filename string) string {
	path := filepath.Join(dir, filename)
	_, err := os.Stat(path)
	if err != nil {
		return "未安装"
	}
	return "已安装"
}
