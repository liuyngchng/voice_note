// Package ui provides the Fyne-based graphical user interface.
package ui

import (
	"fmt"
	"log/slog"
	"net"
	"os"
	"path/filepath"
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

const (
	// maxDisplayRunes is the number of characters kept in the on-screen sliding window.
	maxDisplayRunes = 200
	// flushInterval controls how often finalized text is persisted to disk.
	flushInterval = 30 * time.Second
	// tcpPrecheckTimeout is the max time to wait for a TCP dial during pre-check.
	tcpPrecheckTimeout = 2 * time.Second
)

// session states.
const (
	stateIdle   = iota // not started
	stateActive        // recording + streaming
	statePaused        // paused (audio stream suspended)
)

type mainScreen struct {
	cfg serverConfig

	mu             sync.Mutex
	state          int
	recording      bool
	partialText    string // transient online partial text
	finalizedText  string // accumulated finalized (offline) text
	connStatus     string
	startTime      time.Time
	pausedAt       time.Time // when pause started (to adjust elapsed display)
	pausedElapsed  int64     // total seconds spent paused
	transcriptPath string    // path of the on-disk transcript file
	lastFlushedLen int       // length of text already flushed to disk

	// UI widgets.
	hostEntry   *widget.Entry
	portEntry   *widget.Entry
	statusLabel *widget.Label
	toggleBtn   *widget.Button
	endBtn      *widget.Button
	textArea    *widget.Label
	durationLbl *widget.Label

	// Control channels.
	stopCh  chan struct{}
	pauseCh chan bool // true = pause, false = resume
}

// NewMainScreen builds the main UI page.
func NewMainScreen() fyne.CanvasObject {
	m := &mainScreen{
		cfg:     serverConfig{host: "127.0.0.1", port: 10096},
		stopCh:  make(chan struct{}),
		pauseCh: make(chan bool, 1),
	}

	m.hostEntry = widget.NewEntry()
	m.hostEntry.SetText(m.cfg.host)
	m.portEntry = widget.NewEntry()
	m.portEntry.SetText(fmt.Sprintf("%d", m.cfg.port))

	m.statusLabel = widget.NewLabel("未连接")
	m.toggleBtn = widget.NewButton("启动", m.toggle)
	m.toggleBtn.Importance = widget.HighImportance

	m.endBtn = widget.NewButton("结束", m.endSession)
	m.endBtn.Importance = widget.DangerImportance
	m.endBtn.Hide()

	m.textArea = widget.NewLabel("识别结果将在此显示...")
	m.textArea.Wrapping = fyne.TextWrapWord
	m.durationLbl = widget.NewLabel("00:00")

	hostLabel := widget.NewLabel("服务器地址")
	portLabel := widget.NewLabel("端口")
	form := container.NewGridWithColumns(2,
		hostLabel, m.hostEntry,
		portLabel, m.portEntry,
	)

	// Two centered buttons side by side.
	btnBox := container.NewHBox(
		widget.NewLabel(""), // spacer
		container.NewGridWrap(fyne.NewSize(120, 40), m.toggleBtn),
		container.NewGridWrap(fyne.NewSize(120, 40), m.endBtn),
		widget.NewLabel(""), // spacer
	)
	btnWrap := container.NewCenter(btnBox)

	content := container.NewBorder(
		nil,
		container.NewVBox(m.statusLabel, m.durationLbl),
		nil,
		nil,
		container.NewVBox(
			form,
			btnWrap,
			m.textArea,
		),
	)

	return content
}

// toggle cycles through idle → active → paused → active → ...
func (m *mainScreen) toggle() {
	m.mu.Lock()
	defer m.mu.Unlock()

	switch m.state {
	case stateIdle:
		m.startSession()
	case stateActive:
		m.doPause()
	case statePaused:
		m.doResume()
	}
}

// endSession finalises the current transcription and returns to idle.
func (m *mainScreen) endSession() {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.state == stateIdle {
		return
	}
	m.stopInternal()
	// UI will transition in the deferred cleanup of run().
}

// startSession begins a new transcription session.
// Caller must hold m.mu.
func (m *mainScreen) startSession() {
	host := strings.TrimSpace(m.hostEntry.Text)
	port := 10096
	if _, err := fmt.Sscanf(strings.TrimSpace(m.portEntry.Text), "%d", &port); err != nil {
		port = 10096
	}
	m.cfg = serverConfig{host: host, port: port}

	m.state = stateActive
	m.recording = false
	m.partialText = ""
	m.finalizedText = ""
	m.lastFlushedLen = 0
	m.pausedElapsed = 0
	m.startTime = time.Now()
	m.toggleBtn.SetText("暂停")
	m.endBtn.Show()
	m.setUIMode(stateActive)

	// Create transcript file.
	m.transcriptPath = filepath.Join(".", "transcript_"+time.Now().Format("2006-01-02_150405")+".txt")
	slog.Info("transcript_file", "path", m.transcriptPath)

	m.setUIStatus("连接中...")

	go m.run()
}

// doPause pauses the current session.
// Caller must hold m.mu.
func (m *mainScreen) doPause() {
	m.state = statePaused
	m.pausedAt = time.Now()
	m.toggleBtn.SetText("继续")
	m.setUIStatus("已暂停")
	m.setUIMode(statePaused)

	select {
	case m.pauseCh <- true:
	default:
	}
}

// doResume resumes a paused session.
// Caller must hold m.mu.
func (m *mainScreen) doResume() {
	m.state = stateActive
	m.pausedElapsed += int64(time.Since(m.pausedAt).Seconds())
	m.toggleBtn.SetText("暂停")
	m.setUIStatus("识别中...")
	m.setUIMode(stateActive)

	select {
	case m.pauseCh <- false:
	default:
	}
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
	fyne.Do(func() { m.textArea.SetText(slidingWindow(t)) })
}

// setUIMode toggles host/port entries (disabled while session is live).
func (m *mainScreen) setUIMode(state int) {
	locked := state != stateIdle
	fyne.Do(func() {
		if locked {
			m.hostEntry.Disable()
			m.portEntry.Disable()
		} else {
			m.hostEntry.Enable()
			m.portEntry.Enable()
		}
	})
}

// displayedText returns the combined online partial + offline finalized text.
func (m *mainScreen) displayedText() string {
	return m.finalizedText + m.partialText
}

// slidingWindow trims text to the last maxDisplayRunes characters for display.
func slidingWindow(s string) string {
	runes := []rune(s)
	if len(runes) <= maxDisplayRunes {
		return s
	}
	return string(runes[len(runes)-maxDisplayRunes:])
}

// flushToDisk writes the full text to disk. Caller must hold m.mu.
func (m *mainScreen) flushToDisk() error {
	if m.transcriptPath == "" {
		return nil
	}
	full := m.displayedText()
	if len(full) <= m.lastFlushedLen {
		return nil
	}
	if err := os.WriteFile(m.transcriptPath, []byte(full), 0o644); err != nil {
		return err
	}
	m.lastFlushedLen = len(full)
	return nil
}

func (m *mainScreen) run() {
	defer func() {
		m.mu.Lock()
		_ = m.flushToDisk()
		m.state = stateIdle
		m.recording = false
		m.stopCh = make(chan struct{})
		m.pauseCh = make(chan bool, 1)
		m.toggleBtn.SetText("启动")
		fyne.Do(func() { m.endBtn.Hide() })
		m.setUIStatus("已停止")
		m.setUIMode(stateIdle)
		m.mu.Unlock()
	}()

	// ---- 1. Pre-check: test TCP reachability before dialing WebSocket ----
	addr := net.JoinHostPort(m.cfg.host, fmt.Sprintf("%d", m.cfg.port))
	raw, err := net.DialTimeout("tcp", addr, tcpPrecheckTimeout)
	if err != nil {
		slog.Error("precheck_unreachable", "addr", addr, "err", err)
		m.setUIStatus("服务不可达 - " + err.Error())
		return
	}
	raw.Close()

	// ---- 2. Connect to FunASR server ----
	c := &client.Client{}
	if err := c.Connect(m.cfg.host, m.cfg.port); err != nil {
		slog.Error("funasr_connect", "err", err)
		m.setUIStatus("连接失败: " + err.Error())
		return
	}
	defer c.Close()
	m.setUIStatus("已连接，正在打开麦克风...")

	// ---- 3. Open microphone ----
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

	// ---- 4. Start result reader ----
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

	// ---- 5. Main loop ----
	secTicker := time.NewTicker(time.Second)
	defer secTicker.Stop()
	flushTicker := time.NewTicker(flushInterval)
	defer flushTicker.Stop()

	paused := false

	for {
		select {
		case p := <-m.pauseCh:
			paused = p
			if paused {
				_ = c.SendPause()
			} else {
				_ = c.SendResume()
			}

		case samples, ok := <-sampleCh:
			if !ok {
				goto done
			}
			if paused {
				continue // drain audio while paused
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

		case <-flushTicker.C:
			m.mu.Lock()
			_ = m.flushToDisk()
			m.mu.Unlock()

		case <-secTicker.C:
			m.mu.Lock()
			elapsed := int64(time.Since(m.startTime).Seconds())
			if m.state == statePaused {
				elapsed -= m.pausedElapsed
			}
			m.mu.Unlock()
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