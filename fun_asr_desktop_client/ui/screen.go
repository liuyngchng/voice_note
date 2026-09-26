// Package ui provides the Fyne-based graphical user interface.
package ui

import (
	"fmt"
	"log/slog"
	"net"
	"strings"
	"sync"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"

	"github.com/liuyngchng/funasr-desktop-client/client"
	"github.com/liuyngchng/funasr-desktop-client/internal/audio"
	"github.com/liuyngchng/funasr-desktop-client/internal/storage"
)

// serverConfig holds the FunASR server address.
type serverConfig struct {
	host string
	port int
}

const (
	flushInterval      = 30 * time.Second
	tcpPrecheckTimeout = 2 * time.Second
	maxDisplayBlocks   = 3

	defaultHost = "127.0.0.1"
	defaultPort = 10096

	prefKeyHost = "server.host"
	prefKeyPort = "server.port"
)

// session states.
const (
	stateIdle = iota
	stateActive
	statePaused
)

// ---------------------------------------------------------------------------

type mainScreen struct {
	cfg   serverConfig
	prefs fyne.Preferences
	win   fyne.Window

	mu              sync.Mutex
	state           int
	recording       bool
	partialText     string
	displayPartial  string   // accumulated online partials (FunASR sends increments)
	finalizedBlocks []string // finalized offline blocks, each is a natural sentence
	startTime       time.Time
	pausedAt        time.Time
	pausedElapsed   int64
	saveRecording   bool // controlled by checkbox

	sw             *storage.Writer
	lastFlushedLen int

	// UI widgets.
	hostEntry    *widget.Entry
	portEntry    *widget.Entry
	statusLabel  *widget.Label
	warningLabel *widget.Label
	toggleBtn    *widget.Button
	endBtn       *widget.Button
	textDisplay  *widget.RichText
	durationLbl  *widget.Label
	saveCheck    *widget.Check

	// Control channels.
	stopCh  chan struct{}
	pauseCh chan bool
}

// NewMainScreen builds the main UI page.
func NewMainScreen(win fyne.Window, prefs fyne.Preferences) fyne.CanvasObject {
	m := &mainScreen{
		win:           win,
		cfg:           serverConfig{host: defaultHost, port: defaultPort},
		prefs:         prefs,
		saveRecording: true,
		stopCh:        make(chan struct{}),
		pauseCh:       make(chan bool, 1),
	}

	m.hostEntry = widget.NewEntry()
	m.hostEntry.SetText(m.cfg.host)
	m.portEntry = widget.NewEntry()
	m.portEntry.SetText(fmt.Sprintf("%d", m.cfg.port))

	// Restore saved server config (overrides defaults when present).
	if h := prefs.StringWithFallback(prefKeyHost, ""); h != "" {
		m.cfg.host = h
		m.hostEntry.SetText(h)
	}
	if p := prefs.IntWithFallback(prefKeyPort, 0); p != 0 {
		m.cfg.port = p
		m.portEntry.SetText(fmt.Sprintf("%d", p))
	}

	m.statusLabel = widget.NewLabel("未连接")
	m.warningLabel = widget.NewLabel("")
	m.warningLabel.Hide()

	m.toggleBtn = widget.NewButton("启动", m.toggle)
	m.toggleBtn.Importance = widget.HighImportance

	m.endBtn = widget.NewButton("结束", m.endSession)
	m.endBtn.Importance = widget.DangerImportance
	m.endBtn.Hide()

	m.textDisplay = widget.NewRichTextWithText("识别结果将在此显示...")
	m.textDisplay.Wrapping = fyne.TextWrapWord
	m.durationLbl = widget.NewLabel("00:00")

	m.saveCheck = widget.NewCheck("保存录音到本地", func(checked bool) {
		m.mu.Lock()
		m.saveRecording = checked
		m.mu.Unlock()
	})
	m.saveCheck.SetChecked(true)

	hostLabel := widget.NewLabel("服务器地址")
	portLabel := widget.NewLabel("端口")
	form := container.NewGridWithColumns(2,
		hostLabel, m.hostEntry,
		portLabel, m.portEntry,
	)

	btnBox := container.NewHBox(
		widget.NewLabel(""),
		container.NewGridWrap(fyne.NewSize(120, 40), m.toggleBtn),
		container.NewGridWrap(fyne.NewSize(120, 40), m.endBtn),
		widget.NewLabel(""),
	)
	btnWrap := container.NewCenter(btnBox)

	content := container.NewBorder(
		nil,
		container.NewVBox(m.statusLabel, m.warningLabel, m.durationLbl),
		nil,
		nil,
		container.NewVBox(
			form,
			m.saveCheck,
			btnWrap,
			m.textDisplay,
		),
	)

	// Register the space-bar toggle shortcut at the canvas level so it fires
	// regardless of which widget has focus (except while typing in an Entry).
	if canvas := win.Canvas(); canvas != nil {
		canvas.SetOnTypedKey(m.handleKey)
	}

	return content
}

// handleKey implements the space-bar shortcut: idle→start, active→pause,
// paused→resume. Typing space in a text field should not trigger it.
func (m *mainScreen) handleKey(ev *fyne.KeyEvent) {
	if ev.Name != fyne.KeySpace {
		return
	}
	if c := m.win.Canvas(); c != nil {
		if _, ok := c.Focused().(*widget.Entry); ok {
			return
		}
	}
	m.toggle()
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

	// Remember for next launch.
	m.prefs.SetString(prefKeyHost, host)
	m.prefs.SetInt(prefKeyPort, port)

	m.state = stateActive
	m.recording = false
	m.partialText = ""
	m.finalizedBlocks = nil
	m.displayPartial = ""
	m.lastFlushedLen = 0
	m.pausedElapsed = 0
	m.startTime = time.Now()
	m.toggleBtn.SetText("暂停")
	m.endBtn.Show()
	m.setUIMode(stateActive)
	m.clearWarning()

	ts := time.Now().Format("2006-01-02_150405")
	wavName := ""
	if m.saveRecording {
		wavName = "recording_" + ts + ".wav"
	}
	slog.Info("session_started", "transcript", "transcript_"+ts+".txt", "recording", wavName)

	sw, err := storage.New("output", wavName, "transcript_"+ts+".txt", func(msg string) {
		fyne.Do(func() {
			m.warningLabel.SetText("⚠ " + msg)
			m.warningLabel.Show()
		})
	})
	if err != nil {
		slog.Error("storage_create", "err", err)
		m.showWarning("创建文件失败，" + err.Error())
	} else {
		m.sw = sw
	}

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
	fyne.Do(func() { m.statusLabel.SetText(s) })
}

func (m *mainScreen) showWarning(s string) {
	fyne.Do(func() {
		m.warningLabel.SetText("⚠ " + s)
		m.warningLabel.Show()
	})
}

func (m *mainScreen) clearWarning() {
	fyne.Do(func() { m.warningLabel.Hide() })
}

func (m *mainScreen) setUIText(t string) {
	fyne.Do(func() {
		m.textDisplay.Segments = []widget.RichTextSegment{
			&widget.TextSegment{
				Style: widget.RichTextStyleParagraph,
				Text:  t,
			},
		}
		m.textDisplay.Refresh()
	})
}

// setUIMode toggles host/port entries and save checkbox.
func (m *mainScreen) setUIMode(state int) {
	locked := state != stateIdle
	fyne.Do(func() {
		if locked {
			m.hostEntry.Disable()
			m.portEntry.Disable()
			m.saveCheck.Disable()
		} else {
			m.hostEntry.Enable()
			m.portEntry.Enable()
			m.saveCheck.Enable()
		}
	})
}

func (m *mainScreen) displayedText() string {
	var b strings.Builder
	for _, block := range m.finalizedBlocks {
		b.WriteString(block)
	}
	b.WriteString(m.partialText)
	return b.String()
}

// appendBlock appends a finalized offline block.
// Caller must hold m.mu.
func (m *mainScreen) appendBlock(text string) {
	if text == "" {
		return
	}
	m.finalizedBlocks = append(m.finalizedBlocks, text)
}

// displaySmoothed builds the display text from recent blocks plus accumulated
// online partials. Only the most recent finalized blocks are kept.
func (m *mainScreen) displaySmoothed() string {
	var b strings.Builder
	blocks := m.finalizedBlocks
	if len(blocks) > maxDisplayBlocks {
		blocks = blocks[len(blocks)-maxDisplayBlocks:]
	}
	for _, block := range blocks {
		b.WriteString(block)
	}
	b.WriteString(m.displayPartial)
	return b.String()
}

// ---------------------------------------------------------------------------

func (m *mainScreen) run() {
	// errStatus, when non-empty, records why the session aborted. The deferred
	// cleanup preserves it instead of overwriting with the generic "已停止".
	var errStatus string

	defer func() {
		m.mu.Lock()
		finalText := m.displayedText()
		sw := m.sw
		m.sw = nil
		m.mu.Unlock()

		if sw != nil {
			sw.Shutdown(finalText)
		}

		m.mu.Lock()
		m.state = stateIdle
		m.recording = false
		m.stopCh = make(chan struct{})
		m.pauseCh = make(chan bool, 1)
		fyne.Do(func() {
			m.toggleBtn.SetText("启动")
			m.endBtn.Hide()
		})
		if errStatus != "" {
			m.setUIStatus(errStatus)
			m.showWarning(errStatus)
		} else {
			m.setUIStatus("已停止")
			m.clearWarning()
		}
		m.setUIMode(stateIdle)
		m.mu.Unlock()
	}()

	// ---- 1. Pre-check TCP ----
	addr := net.JoinHostPort(m.cfg.host, fmt.Sprintf("%d", m.cfg.port))
	raw, err := net.DialTimeout("tcp", addr, tcpPrecheckTimeout)
	if err != nil {
		slog.Error("precheck_unreachable", "addr", addr, "err", err)
		errStatus = "无法连接服务器，请检查地址和端口"
		return
	}
	raw.Close()

	// ---- 2. Connect to FunASR ----
	c := &client.Client{}
	if err := c.Connect(m.cfg.host, m.cfg.port); err != nil {
		slog.Error("funasr_connect", "err", err)
		errStatus = "连接服务器失败: " + err.Error()
		return
	}
	defer c.Close()
	m.setUIStatus("已连接，正在打开麦克风...")

	// ---- 3. Open microphone ----
	rec, err := audio.NewRecorder()
	if err != nil {
		slog.Error("mic_open", "err", err)
		errStatus = "无法打开麦克风: " + err.Error()
		return
	}
	sampleCh, err := rec.Start()
	if err != nil {
		slog.Error("mic_start", "err", err)
		errStatus = "启动录音失败: " + err.Error()
		rec.Stop()
		return
	}
	defer rec.Stop()

	m.mu.Lock()
	m.recording = true
	m.mu.Unlock()
	m.setUIStatus("识别中...")

	// ---- 4. Result reader ----
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
				continue
			}
			// Feed disk writer (non-blocking).
			m.mu.Lock()
			sw := m.sw
			m.mu.Unlock()
			if sw != nil {
				sw.WriteSamples(samples)
			}
			// Send to FunASR.
			if err := c.SendAudio(audio.ConvertFloatsToPCM(samples)); err != nil {
				slog.Error("send_audio", "err", err)
				errStatus = "发送音频失败: " + err.Error()
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
				m.displayPartial += r.Text
			case "2pass-offline":
				m.appendBlock(r.Text)
				m.partialText = ""
				m.displayPartial = ""
			default:
				m.appendBlock(r.Text)
				m.partialText = ""
				m.displayPartial = ""
			}
			displayed := m.displaySmoothed()
			m.mu.Unlock()
			m.setUIText(displayed)

		case <-flushTicker.C:
			m.mu.Lock()
			text := m.displayedText()
			if len(text) > m.lastFlushedLen {
				m.lastFlushedLen = len(text)
				if m.sw != nil {
					m.sw.WriteText(text)
				}
			}
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
	time.Sleep(100 * time.Millisecond)
}
