// FunASR 实时语音转文本桌面客户端
//
// 连接 FunASR 2pass WebSocket 服务（ws://host:port），
// 采集麦克风音频推流，实时显示识别文本。
package main

import (
	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"

	"github.com/liuyngchng/funasr-desktop-client/ui"
)

func main() {
	a := app.NewWithID("com.funasr.desktop.client")
	w := a.NewWindow("FunASR 实时语音转文本")

	w.SetContent(ui.NewMainScreen())

	w.Resize(fyne.NewSize(600, 500))
	w.ShowAndRun()
}