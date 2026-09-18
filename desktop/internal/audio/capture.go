// Package audio provides PCM audio capture and playback.
package audio

// Recorder captures audio from the default microphone device.
// It returns a channel of float32 PCM samples at 16kHz mono,
// normalized in [-1, 1].
type Recorder interface {
	// Start begins recording and returns a channel that emits audio chunks.
	Start() (<-chan []float32, error)

	// Stop permanently stops recording and releases the device.
	Stop()
}
