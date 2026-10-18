//go:build linux

// Package audio provides PCM audio capture and playback.
//
// This file implements system-audio (monitor) capture on Linux by spawning
// the parec(1) utility from PulseAudio/PipeWire.  It records from the
// default monitor source, which captures whatever is being played through
// the default sink — the other side of an online meeting, music, etc.
//
// Using a subprocess avoids the blocking-read problem that plagues the
// PulseAudio Simple API: when no audio is playing on the monitor source,
// pa_simple_read blocks forever with no way to cancel it from another
// thread. A subprocess can be killed instantly.
package audio

import (
	"fmt"
	"log/slog"
	"os/exec"
	"sync"
	"sync/atomic"
)

const (
	monitorCmd  = "parec"
	monitorFramesPerBuffer = 1600 // 100ms at 16kHz
	monitorBytesPerBuffer  = monitorFramesPerBuffer * 2
)

// execMonitorRecorder wraps a parec subprocess for system-audio capture.
type execMonitorRecorder struct {
	mu       sync.Mutex
	cmd      *exec.Cmd
	sampleCh chan []float32
	done     chan struct{}
	running  atomic.Bool
}

// newMonitorRecorder prepares a parec subprocess to capture from the
// default monitor source at 16kHz mono S16LE. It does not start the
// subprocess until Start() is called.
func newMonitorRecorder() (Recorder, error) {
	// Verify parec is available but don't start it yet.
	if _, err := exec.LookPath(monitorCmd); err != nil {
		return nil, fmt.Errorf("audio: %s not found ($PATH)", monitorCmd)
	}
	r := &execMonitorRecorder{
		sampleCh: make(chan []float32, 8),
		done:     make(chan struct{}),
	}
	slog.Info("exec_monitor_ready", "cmd", monitorCmd)
	return r, nil
}

func (r *execMonitorRecorder) Start() (<-chan []float32, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.running.Load() {
		return r.sampleCh, nil
	}

	// Re-open channels if we were stopped previously.
	select {
	case <-r.done:
		r.done = make(chan struct{})
		r.sampleCh = make(chan []float32, 8)
	default:
	}

	// parec --format=s16le --rate=16000 --channels=1 --device=@DEFAULT_MONITOR@
	r.cmd = exec.Command(
		monitorCmd,
		"--format=s16le",
		"--rate=16000",
		"--channels=1",
		"--device=@DEFAULT_MONITOR@",
	)

	stdout, err := r.cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("audio: parec stdout pipe: %w", err)
	}

	if err := r.cmd.Start(); err != nil {
		return nil, fmt.Errorf("audio: parec start: %w", err)
	}

	r.running.Store(true)
	go r.loop(stdout)

	slog.Info("exec_monitor_started")
	return r.sampleCh, nil
}

// loop reads 100ms chunks from parec stdout, converts int16→float32, and
// sends them on the sample channel. It returns when the process exits or
// the recorder is stopped.
func (r *execMonitorRecorder) loop(stdout interface{ Read([]byte) (int, error) }) {
	defer func() {
		r.running.Store(false)
		close(r.sampleCh)
		slog.Info("exec_monitor_loop_exited")
	}()

	buf := make([]byte, monitorBytesPerBuffer)
	for {
		// Read exactly monitorBytesPerBuffer bytes (3200 = 1600 frames * 2 bytes).
		if err := readFull(stdout, buf); err != nil {
			// Process exited or pipe closed — expected on Stop().
			return
		}

		samples := make([]float32, monitorFramesPerBuffer)
		for i := 0; i < monitorFramesPerBuffer; i++ {
			lo := int16(buf[i*2])
			hi := int16(buf[i*2+1])
			samples[i] = float32(lo|(hi<<8)) / 32768.0
		}

		select {
		case r.sampleCh <- samples:
		case <-r.done:
			return
		}
	}
}

// readFull reads exactly len(buf) bytes from r or returns an error.
func readFull(r interface{ Read([]byte) (int, error) }, buf []byte) error {
	got := 0
	for got < len(buf) {
		n, err := r.Read(buf[got:])
		if n > 0 {
			got += n
		}
		if err != nil {
			return err
		}
	}
	return nil
}

func (r *execMonitorRecorder) Stop() {
	r.mu.Lock()
	defer r.mu.Unlock()

	if !r.running.Load() {
		return
	}
	r.running.Store(false)
	close(r.done)

	// Kill the subprocess — this unblocks any goroutine stuck in readFull.
	if r.cmd != nil && r.cmd.Process != nil {
		_ = r.cmd.Process.Kill()
		_ = r.cmd.Wait()
		r.cmd = nil
	}

	// Drain the channel so the loop goroutine can exit.
	for range r.sampleCh {
	}
	slog.Info("exec_monitor_stopped")
}

func (r *execMonitorRecorder) Pause()  {} // no-op: caller discards data while paused
func (r *execMonitorRecorder) Resume() {}