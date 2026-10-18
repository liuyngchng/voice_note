// Package audio provides PCM audio capture and playback.
//
// This file implements a dual-source sample mixer that combines microphone
// and system-audio monitor streams into a single output channel. When both
// sources deliver data simultaneously the samples are averaged; when only
// one source has data it is passed through unchanged.
package audio

import (
	"log/slog"
	"sync"
)

// mixer combines two sample channels (mic and system audio monitor) into one.
// Both inputs are expected at 16kHz mono float32. The output is also 16kHz
// mono float32. If either input runs dry the other is forwarded as-is.
type mixer struct {
	micCh <-chan []float32
	sysCh <-chan []float32
	outCh chan []float32

	mu     sync.Mutex
	stopCh chan struct{}
	done   chan struct{}
}

func newMixer(micCh, sysCh <-chan []float32) *mixer {
	return &mixer{
		micCh:  micCh,
		sysCh:  sysCh,
		outCh:  make(chan []float32, 8),
		stopCh: make(chan struct{}),
		done:   make(chan struct{}),
	}
}

// start begins mixing and returns the output channel.
func (m *mixer) start() <-chan []float32 {
	go m.loop()
	return m.outCh
}

// stop signals the mixer to shut down and waits for it to finish.
func (m *mixer) stop() {
	select {
	case <-m.stopCh:
	default:
		close(m.stopCh)
	}
	<-m.done
}

func (m *mixer) loop() {
	defer close(m.done)
	defer close(m.outCh)

	for {
		samples, ok := m.readNext()
		if !ok {
			return
		}
		if len(samples) == 0 {
			continue
		}

		select {
		case m.outCh <- samples:
		case <-m.stopCh:
			return
		}
	}
}

// readNext returns the next mixed chunk, or ok=false when the mixer is
// stopped or both sources have closed. Every blocking read also watches
// stopCh so Stop() never deadlocks.
func (m *mixer) readNext() ([]float32, bool) {
	// Primary source: microphone. Always read from it first.
	var mic []float32
	select {
	case <-m.stopCh:
		return nil, false
	case s, ok := <-m.micCh:
		if !ok {
			// Microphone closed — forward remaining system audio until
			// stopped or the system channel also closes.
			return m.forwardSys()
		}
		mic = s
	}

	// Secondary source: system audio monitor. Non-blocking try.
	select {
	case sys := <-m.sysCh:
		if len(sys) == 0 {
			return mic, true
		}
		return mixSamples(mic, sys), true
	default:
		// No system audio available right now — pass microphone through.
		return mic, true
	}
}

// forwardSys drains the system channel until it closes or the mixer stops.
func (m *mixer) forwardSys() ([]float32, bool) {
	for {
		select {
		case <-m.stopCh:
			return nil, false
		case sys, ok := <-m.sysCh:
			if !ok {
				return nil, false
			}
			if len(sys) > 0 {
				return sys, true
			}
		}
	}
}

// mixSamples merges two float32 slices by averaging corresponding samples.
// The longer slice determines the output length; missing samples in the
// shorter slice are treated as silence (0.0).
func mixSamples(a, b []float32) []float32 {
	if len(a) == 0 {
		return b
	}
	if len(b) == 0 {
		return a
	}

	n := len(a)
	if len(b) > n {
		n = len(b)
	}
	out := make([]float32, n)
	for i := 0; i < n; i++ {
		var sum float32
		if i < len(a) {
			sum += a[i]
		}
		if i < len(b) {
			sum += b[i]
		}
		// Average the two sources to avoid clipping.
		out[i] = sum / 2.0
	}
	return out
}

// mixedRecorder wraps a microphone recorder and a system-audio monitor
// recorder, mixing their output into a single sample stream.
type mixedRecorder struct {
	mic Recorder
	sys Recorder

	mu      sync.Mutex
	mix     *mixer
	outCh   <-chan []float32
	running bool
}

func newMixedRecorder(mic, sys Recorder) Recorder {
	return &mixedRecorder{mic: mic, sys: sys}
}

func (r *mixedRecorder) Start() (<-chan []float32, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.running {
		return r.outCh, nil
	}

	micCh, err := r.mic.Start()
	if err != nil {
		return nil, err
	}

	sysCh, err := r.sys.Start()
	if err != nil {
		// System monitor unavailable — release mic and return error so the
		// caller can fall back to mic-only.
		r.mic.Stop()
		return nil, err
	}

	r.mix = newMixer(micCh, sysCh)
	r.outCh = r.mix.start()
	r.running = true
	slog.Info("mixed_recorder_started")
	return r.outCh, nil
}

func (r *mixedRecorder) Stop() {
	r.mu.Lock()
	defer r.mu.Unlock()

	if !r.running {
		return
	}

	if r.mix != nil {
		r.mix.stop()
		r.mix = nil
	}
	r.mic.Stop()
	r.sys.Stop()
	r.running = false
	r.outCh = nil
	slog.Info("mixed_recorder_stopped")
}

func (r *mixedRecorder) Pause() {
	r.mic.Pause()
	r.sys.Pause()
}

func (r *mixedRecorder) Resume() {
	r.mic.Resume()
	r.sys.Resume()
}