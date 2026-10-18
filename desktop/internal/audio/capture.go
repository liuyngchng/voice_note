// Package audio provides PCM audio capture and playback.
package audio

import "log/slog"

// Recorder captures audio from the default microphone device.
// It returns a channel of float32 PCM samples at 16kHz mono,
// normalized in [-1, 1].
type Recorder interface {
	// Start begins recording and returns a channel that emits audio chunks.
	Start() (<-chan []float32, error)

	// Stop permanently stops recording and releases the device.
	Stop()

	// Pause suspends audio capture without releasing the device.
	Pause()

	// Resume restarts audio capture after a pause.
	Resume()
}

// NewRecorder creates a dual-source recorder that captures both the microphone
// and system audio output (monitor/loopback). If the system monitor is
// unavailable it falls back to microphone-only.
//
// Platform constructors newMicRecorder and newMonitorRecorder are provided by
// platform-specific source files (capture_linux.go / capture_windows.go).
func NewRecorder() (Recorder, error) {
	mic, err := newMicRecorder()
	if err != nil {
		return nil, err
	}

	sys, err := newMonitorRecorder()
	if err != nil {
		slog.Warn("audio_monitor_unavailable_falling_back_to_mic_only", "error", err)
		return mic, nil
	}

	return newMixedRecorder(mic, sys), nil
}