// Package audio provides PCM audio capture.
package audio

// Recorder captures audio from the default microphone.
type Recorder interface {
	Start() (<-chan []float32, error)
	Stop()
}