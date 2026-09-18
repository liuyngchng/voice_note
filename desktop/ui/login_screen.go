// Package ui provides the Fyne-based graphical user interface.
package ui

import (
	"fmt"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"

	"github.com/liuyngchng/voice-note-desktop/internal/settings"
)

// loginViewModel manages login state.
type loginViewModel struct {
	store       *settings.Store
	username    string
	password    string
	errorLabel  *widget.Label
	loginButton *widget.Button
}

func (vm *loginViewModel) updateUsername(s string) { vm.username = s; vm.errorLabel.SetText("") }
func (vm *loginViewModel) updatePassword(s string) { vm.password = s; vm.errorLabel.SetText("") }

// login validates credentials and persists them (simulated login, matching Android).
func (vm *loginViewModel) login(onSuccess func()) {
	if vm.username == "" {
		vm.errorLabel.SetText("请输入用户名")
		return
	}
	if vm.password == "" {
		vm.errorLabel.SetText("请输入密码")
		return
	}

	vm.loginButton.Disable()
	vm.loginButton.SetText("登录中...")
	defer func() {
		vm.loginButton.Enable()
		vm.loginButton.SetText("登录")
	}()

	// Simulated login: generate a fake token (matches Android LoginViewModel).
	token := newFakeToken()
	if err := vm.store.UpdateAuth(token, vm.username, vm.password); err != nil {
		vm.errorLabel.SetText("登录失败: " + err.Error())
		return
	}
	onSuccess()
}

// newLoginScreen builds the login page.
func newLoginScreen(win fyne.Window, app *App, store *settings.Store) fyne.CanvasObject {
	vm := &loginViewModel{store: store}

	// If already logged in, auto-advance.
	if store.IsLoggedIn() {
		win.SetContent(app.homeScreen())
		return container.NewVBox()
	}

	title := widget.NewLabel("语音笔记")
	title.TextStyle = fyne.TextStyle{Bold: true}
	title.Alignment = fyne.TextAlignCenter

	subtitle := widget.NewLabel("登录以使用在线服务")
	subtitle.Alignment = fyne.TextAlignCenter

	usernameEntry := widget.NewEntry()
	usernameEntry.SetPlaceHolder("请输入用户名")
	usernameEntry.OnChanged = vm.updateUsername

	passwordEntry := widget.NewPasswordEntry()
	passwordEntry.SetPlaceHolder("请输入密码")
	passwordEntry.OnChanged = vm.updatePassword

	vm.errorLabel = widget.NewLabel("")
	vm.errorLabel.TextStyle = fyne.TextStyle{Bold: false}
	vm.errorLabel.Alignment = fyne.TextAlignCenter

	vm.loginButton = widget.NewButton("登录", func() {
		vm.login(func() { win.SetContent(app.homeScreen()) })
	})
	vm.loginButton.Importance = widget.HighImportance

	skipButton := widget.NewButton("跳过", func() {
		win.SetContent(app.homeScreen())
	})
	skipButton.Importance = widget.LowImportance

	content := container.NewVBox(
		title,
		subtitle,
		usernameEntry,
		passwordEntry,
		vm.errorLabel,
		vm.loginButton,
		skipButton,
	)

	return container.NewCenter(content)
}

// newFakeToken generates a random UUID-style token (avoiding crypto dependency).
func newFakeToken() string {
	now := time.Now().UnixNano()
	return fmt.Sprintf("%x-%x-%x-%x-%x", now, now>>32, now<<8, now<<16, now<<24)
}
