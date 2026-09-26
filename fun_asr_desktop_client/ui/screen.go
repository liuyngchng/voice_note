// Package ui provides the Fyne-based graphical user interface.
package ui

import (
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"

	"github.com/liuyngchng/funasr-desktop-client/client"
	"github.com/liuyngchng/funasr-desktop-client/internal/audio"
)

// serverConfig holds the FunASR server address.
type serverConfig struct {
	host string
	port int
}

type mainScreen struct {
	cfg serverConfig

	mu             sync.Mutex
	running        bool
	recording      bool
	partialText    string // transient online partial text
	finalizedText  string // accumulated finalized (offline) text
	connStatus     string
	startTime      time.Time

	// UI widgets.
	hostEntry   *widget.Entry
	portEntry   *widget.Entry
	statusLabel *widget.Label
	connectBtn  *widget.Button
	textArea    *widget.Label
	durationLbl *widget.Label

	stopCh chan struct{}
}

// NewMainScreen builds the main UI page.
func NewMainScreen() fyne.CanvasObject {
	m := &mainScreen{
		cfg:    serverConfig{host: "127.0.0.1", port: 10096},
		stopCh: make(chan struct{}),
	}

	m.hostEntry = widget.NewEntry()
	m.hostEntry.SetText(m.cfg.host)
	m.portEntry = widget.NewEntry()
	m.portEntry.SetText(fmt.Sprintf("%d", m.cfg.port))

	m.statusLabel = widget.NewLabel("未连接")
	m.connectBtn = widget.NewButton("开始识别", m.toggle)
	m.connectBtn.Importance = widget.HighImportance

	m.textArea = widget.NewLabel("识别结果将在此显示...")
	m.textArea.Wrapping = fyne.TextWrapWord
	m.durationLbl = widget.NewLabel("00:00")

	hostLabel := widget.NewLabel("服务器地址")
	portLabel := widget.NewLabel("端口")
	form := container.NewGridWithColumns(2,
		hostLabel, m.hostEntry,
		portLabel, m.portEntry,
	)

	content := container.NewVBox(
		widget.NewLabel("FunASR 实时语音转文本客户端"),
		form,
		m.connectBtn,
		m.statusLabel,
		m.durationLbl,
		m.textArea,
	)

	return content
}

func (m *mainScreen) toggle() {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.running {
		m.stopInternal()
		return
	}

	host := strings.TrimSpace(m.hostEntry.Text)
	port := 10096
	if _, err := fmt.Sscanf(strings.TrimSpace(m.portEntry.Text), "%d", &port); err != nil {
		port = 10096
	}
	m.cfg = serverConfig{host: host, port: port}

	m.running = true
	m.recording = false
	m.partialText = ""
	m.finalizedText = ""
	m.startTime = time.Now()
	m.connectBtn.SetText("停止识别")
	m.setUIStatus("连接中...")

	go m.run()
}

func (m *mainScreen) stopInternal() {
	if m.stopCh != nil {
		select {
		case <-m.stopCh:
		default:
			close(m.stopCh)
		}
	}
}

func (m *mainScreen) setUIStatus(s string) {
	m.connStatus = s
	fyne.Do(func() { m.statusLabel.SetText(s) })
}

func (m *mainScreen) setUISubtitle(s string) {
	fyne.Do(func() { m.statusLabel.SetText(m.connStatus + "  " + s) })
}

func (m *mainScreen) setUIText(t string) {
	fyne.Do(func() { m.textArea.SetText(t) })
}

// displayedText returns the combined online partial + offline finalized text.
func (m *mainScreen) displayedText() string {
	return m.finalizedText + m.partialText
}

func (m *mainScreen) run() {
	defer func() {
		m.mu.Lock()
		m.running = false
		m.recording = false
		m.stopCh = make(chan struct{})
		m.connectBtn.SetText("开始识别")
		m.setUIStatus("已停止")
		m.mu.Unlock()
	}()

	// ---- 1. Connect to FunASR server ----
	c := &client.Client{}
	if err := c.Connect(m.cfg.host, m.cfg.port); err != nil {
		slog.Error("funasr_connect", "err", err)
		m.setUIStatus("连接失败: " + err.Error())
		return
	}
	defer c.Close()
	m.setUIStatus("已连接，正在打开麦克风...")

	// ---- 2. Open microphone ----
	rec, err := audio.NewRecorder()
	if err != nil {
		slog.Error("mic_open", "err", err)
		m.setUIStatus("无法打开麦克风: " + err.Error())
		return
	}
	sampleCh, err := rec.Start()
	if err != nil {
		slog.Error("mic_start", "err", err)
		m.setUIStatus("启动录音失败: " + err.Error())
		rec.Stop()
		return
	}
	defer rec.Stop()

	m.mu.Lock()
	m.recording = true
	m.mu.Unlock()
	m.setUIStatus("识别中...")

	// ---- 3. Start result reader ----
	resultCh := make(chan *client.Result, 32)
	go func() {
		for {
			r, err := c.ReadNext()
			if err != nil {
				slog.Info("read_result_done", "err", err)
				close(resultCh)
				return
			}
			resultCh <- r
		}
	}()

	// ---- 4. Main loop ----
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()

	for {
		select {
		case samples, ok := <-sampleCh:
			if !ok {
				goto done
			}
			if err := c.SendAudio(audio.ConvertFloatsToPCM(samples)); err != nil {
				slog.Error("send_audio", "err", err)
				m.setUIStatus("发送音频失败: " + err.Error())
				goto done
			}

		case r, ok := <-resultCh:
			if !ok {
				goto done
			}
			m.mu.Lock()
			switch r.Mode {
			case "2pass-online":
				m.partialText = r.Text
			case "2pass-offline":
				m.finalizedText += r.Text
				m.partialText = ""
			default:
				// online / offline (non-2pass modes) — just accumulate
				m.finalizedText += r.Text
				m.partialText = ""
			}
			displayed := m.displayedText()
			m.mu.Unlock()
			m.setUIText(displayed)

		case <-ticker.C:
			elapsed := int64(time.Since(m.startTime).Seconds())
			fyne.Do(func() { m.durationLbl.SetText(formatDuration(elapsed)) })

		case <-m.stopCh:
			goto done
		}
	}

done:
	_ = c.SendEnd()
	// Give the server a moment to flush any remaining results.
	time.Sleep(100 * time.Millisecond)
}