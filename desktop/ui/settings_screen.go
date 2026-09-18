// Package ui provides the Fyne-based graphical user interface.
package ui

import (
	"os"
	"path/filepath"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"

	"github.com/liuyngchng/voice-note-desktop/internal/desktopentry"
)

// settingsViewModel manages settings screen state.
type settingsViewModel struct {
	app *App

	dataDir     *widget.Label
	modelStatus *widget.Label
	vadStatus   *widget.Label
	punctStatus *widget.Label

	loginStatus   *widget.Label
	shortcutLabel *widget.Label
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

	// Desktop shortcut status.
	vm.shortcutLabel = widget.NewLabel("")
	vm.refreshShortcutStatus()

	// Buttons.
	logoutBtn := widget.NewButton("退出登录", func() {
		vm.logout()
		vm.loginStatus.SetText("未登录")
	})
	logoutBtn.Importance = widget.DangerImportance

	var shortcutBtn *widget.Button
	shortcutBtn = widget.NewButton("", func() {
		if desktopentry.IsInstalled() {
			if err := desktopentry.RemoveShortcut(); err != nil {
				vm.shortcutLabel.SetText("移除失败: " + err.Error())
				return
			}
			vm.shortcutLabel.SetText("桌面快捷方式已移除")
		} else {
			exe, err := os.Executable()
			if err != nil {
				vm.shortcutLabel.SetText("错误: 无法获取程序路径")
				return
			}
			if err := desktopentry.CreateShortcut(exe); err != nil {
				vm.shortcutLabel.SetText("创建失败: " + err.Error())
				return
			}
			vm.shortcutLabel.SetText("桌面快捷方式已创建 — 可在系统菜单中搜索")
		}
		// Update button text after toggle.
		vm.updateShortcutButton(shortcutBtn)
	})
	if desktopentry.IsInstalled() {
		shortcutBtn.SetText("移除桌面快捷方式")
	} else {
		shortcutBtn.SetText("创建桌面快捷方式")
	}

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
			widget.NewSeparator(),
			widget.NewLabel("桌面集成"),
			vm.shortcutLabel,
			shortcutBtn,
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

func (vm *settingsViewModel) refreshShortcutStatus() {
	if desktopentry.IsInstalled() {
		vm.shortcutLabel.SetText("桌面快捷方式已安装")
	} else {
		vm.shortcutLabel.SetText("未创建桌面快捷方式")
	}
}

// updateShortcutButton syncs the button text with the current install state.
func (vm *settingsViewModel) updateShortcutButton(btn *widget.Button) {
	if desktopentry.IsInstalled() {
		btn.SetText("移除桌面快捷方式")
	} else {
		btn.SetText("创建桌面快捷方式")
	}
}

func checkModelStatus(dir, filename string) string {
	path := filepath.Join(dir, filename)
	_, err := os.Stat(path)
	if err != nil {
		return "未安装"
	}
	return "已安装"
}
