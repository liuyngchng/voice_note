// FunASR 实时语音转文本桌面客户端
//
// 连接 FunASR 2pass WebSocket 服务（ws://host:port），
// 采集麦克风音频推流，实时显示识别文本。
package main

import (
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"

	"github.com/liuyngchng/funasr-desktop-client/ui"
)

// initLogging configures slog to write to both stderr and a rotating
// daily log file under logs/ (e.g. logs/app_2025-09-26.log).
func initLogging() {
	if err := os.MkdirAll("logs", 0o755); err != nil {
		// Fall back to stderr-only if we can't create the log dir.
		slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, nil)))
		return
	}

	logPath := filepath.Join("logs", "app_"+time.Now().Format("2006-01-02")+".log")
	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, nil)))
		return
	}

	// Write to both stderr (for live debugging) and the log file (for later inspection).
	w := io.MultiWriter(os.Stderr, f)
	slog.SetDefault(slog.New(slog.NewTextHandler(w, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})))
}

func main() {
	initLogging()

	a := app.NewWithID("com.funasr.desktop.client")
	w := a.NewWindow("实时语音转文本")

	w.SetContent(ui.NewMainScreen(w, a.Preferences()))

	w.Resize(fyne.NewSize(600, 500))
	w.ShowAndRun()
}
