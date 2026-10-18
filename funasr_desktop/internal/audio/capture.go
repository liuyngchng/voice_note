// Package audio provides PCM audio capture.
package audio

import "log/slog"

// Recorder captures audio from the default microphone.
type Recorder interface {
	Start() (<-chan []float32, error)
	Stop()
}

// NewRecorder creates a dual-source recorder that captures both the microphone
// and system audio output (monitor/loopback). If the system monitor is
// unavailable it falls back to microphone-only.
//
// Platform constructors newMicRecorder and newMonitorRecorder are provided by
// platform-specific source files.
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