// Package ui provides the Fyne-based graphical user interface.
package ui

import (
	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/widget"

	"github.com/liuyngchng/voice-note-desktop/internal/settings"
)

// settingsViewModel manages settings screen state.
type settingsViewModel struct {
	app *App

	llmEndpoint *widget.Entry
	llmAPIKey   *widget.Entry
	llmModel    *widget.Entry
	serverURI   *widget.Entry

	loginStatus *widget.Label
}

// newSettingsScreen builds the settings page.
func newSettingsScreen(win fyne.Window, app *App) fyne.CanvasObject {
	vm := &settingsViewModel{app: app}
	cfg := app.store.Get()

	// LLM configuration section.
	llmTitle := widget.NewLabel("大语言模型")
	llmTitle.TextStyle = fyne.TextStyle{Bold: true}

	vm.llmEndpoint = widget.NewEntry()
	vm.llmEndpoint.SetPlaceHolder("https://api.deepseek.com")
	vm.llmEndpoint.SetText(cfg.LLMAPIEendpoint)

	vm.llmAPIKey = widget.NewPasswordEntry()
	vm.llmAPIKey.SetPlaceHolder("<YOUR_API_KEY>")
	vm.llmAPIKey.SetText(cfg.LLMAPIKey)

	vm.llmModel = widget.NewEntry()
	vm.llmModel.SetPlaceHolder("deepseek-v4-flash")
	vm.llmModel.SetText(cfg.LLMModelName)

	// Server configuration section.
	serverTitle := widget.NewLabel("服务器配置")
	serverTitle.TextStyle = fyne.TextStyle{Bold: true}

	vm.serverURI = widget.NewEntry()
	vm.serverURI.SetPlaceHolder("http://192.168.1.110:8080")
	vm.serverURI.SetText(cfg.ServerURI)

	// Login status.
	vm.loginStatus = widget.NewLabel("")
	if cfg.AuthToken != "" {
		vm.loginStatus.SetText("已登录: " + cfg.Username)
	} else {
		vm.loginStatus.SetText("未登录")
	}

	// Buttons.
	testBtn := widget.NewButton("测试连接", func() {
		// Delegated to a helper; for now show a placeholder test.
		dialog.ShowInformation("连接测试", "测试功能开发中...", win)
	})

	saveBtn := widget.NewButton("保存", func() {
		vm.save()
		dialog.ShowInformation("设置", "已保存", win)
	})
	saveBtn.Importance = widget.HighImportance

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
			llmTitle,
			widget.NewLabel("API 地址"),
			vm.llmEndpoint,
			widget.NewLabel("API Key"),
			vm.llmAPIKey,
			widget.NewLabel("模型名称"),
			vm.llmModel,
			serverTitle,
			widget.NewLabel("服务器地址"),
			vm.serverURI,
			vm.loginStatus,
			testBtn,
			saveBtn,
			logoutBtn,
		),
	)

	return content
}

func (vm *settingsViewModel) save() {
	_ = vm.app.store.UpdateLLMConfig(vm.llmEndpoint.Text, vm.llmAPIKey.Text, vm.llmModel.Text)
	_ = vm.app.store.UpdateServerURI(vm.serverURI.Text)
}

func (vm *settingsViewModel) logout() {
	_ = vm.app.store.ClearAuth()
}