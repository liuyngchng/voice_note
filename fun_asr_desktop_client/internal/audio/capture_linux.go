//go:build linux

// Package audio provides PCM audio capture and playback.
//
// This file implements microphone capture via ALSA (Linux) using CGo.
// Capture is 16kHz mono 16-bit PCM, exposed as float32 samples in [-1,1].
package audio

// #cgo LDFLAGS: -lasound
// #include <alsa/asoundlib.h>
// #include <stdlib.h>
import "C"

import (
	"fmt"
	"log/slog"
	"sync"
	"sync/atomic"
	"unsafe"
)

type alsaRecorder struct {
	mu       sync.Mutex
	handle   *C.snd_pcm_t
	running  atomic.Bool
	sampleCh chan []float32
	done     chan struct{}
	closed   bool
}

// NewRecorder creates a new Linux ALSA recorder (16kHz / mono / S16_LE).
func NewRecorder() (Recorder, error) {
	r := &alsaRecorder{
		sampleCh: make(chan []float32, 8),
		done:     make(chan struct{}),
	}

	deviceName := C.CString("default")
	defer C.free(unsafe.Pointer(deviceName))

	var handle *C.snd_pcm_t
	ret := C.snd_pcm_open(&handle, deviceName, C.SND_PCM_STREAM_CAPTURE, 0)
	if ret < 0 {
		return nil, fmt.Errorf("audio: failed to open ALSA device: %s", alsaError(ret))
	}
	r.handle = handle

	var hwparams *C.snd_pcm_hw_params_t
	C.snd_pcm_hw_params_malloc(&hwparams)
	defer C.snd_pcm_hw_params_free(hwparams)

	ret = C.snd_pcm_hw_params_any(handle, hwparams)
	if ret < 0 {
		C.snd_pcm_close(handle)
		return nil, fmt.Errorf("audio: hw_params_any: %s", alsaError(ret))
	}

	if ret = C.snd_pcm_hw_params_set_access(handle, hwparams, C.SND_PCM_ACCESS_RW_INTERLEAVED); ret < 0 {
		C.snd_pcm_close(handle)
		return nil, fmt.Errorf("audio: set_access: %s", alsaError(ret))
	}

	ret = C.snd_pcm_hw_params_set_format(handle, hwparams, C.SND_PCM_FORMAT_S16_LE)
	if ret < 0 {
		C.snd_pcm_close(handle)
		return nil, fmt.Errorf("audio: set_format: %s", alsaError(ret))
	}

	rate := C.uint(16000)
	ret = C.snd_pcm_hw_params_set_rate_near(handle, hwparams, &rate, nil)
	if ret < 0 {
		C.snd_pcm_close(handle)
		return nil, fmt.Errorf("audio: set_rate: %s", alsaError(ret))
	}

	ret = C.snd_pcm_hw_params_set_channels(handle, hwparams, 1)
	if ret < 0 {
		C.snd_pcm_close(handle)
		return nil, fmt.Errorf("audio: set_channels: %s", alsaError(ret))
	}

	bufferSize := C.snd_pcm_uframes_t(1600) // 100ms at 16kHz
	ret = C.snd_pcm_hw_params_set_buffer_size_near(handle, hwparams, &bufferSize)
	if ret < 0 {
		C.snd_pcm_close(handle)
		return nil, fmt.Errorf("audio: set_buffer_size: %s", alsaError(ret))
	}

	ret = C.snd_pcm_hw_params(handle, hwparams)
	if ret < 0 {
		C.snd_pcm_close(handle)
		return nil, fmt.Errorf("audio: hw_params: %s", alsaError(ret))
	}

	slog.Info("audio_capture_opened", "device", "default", "rate", 16000)
	return r, nil
}

func (r *alsaRecorder) Start() (<-chan []float32, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.closed {
		return nil, fmt.Errorf("audio: recorder already closed")
	}
	if r.running.Load() {
		return r.sampleCh, nil
	}
	if r.handle == nil {
		return nil, fmt.Errorf("audio: capture not initialized")
	}

	r.running.Store(true)
	select {
	case <-r.done:
		r.done = make(chan struct{})
		r.sampleCh = make(chan []float32, 8)
	default:
	}

	go r.loop()
	return r.sampleCh, nil
}

func (r *alsaRecorder) loop() {
	defer close(r.sampleCh)

	framesPerBuffer := 1600 // 100ms at 16kHz
	buf := make([]int16, framesPerBuffer)

	for r.running.Load() {
		n := C.snd_pcm_readi(r.handle, unsafe.Pointer(&buf[0]), C.snd_pcm_uframes_t(framesPerBuffer))
		if n < 0 {
			rec := C.snd_pcm_recover(r.handle, C.int(n), 1)
			if rec < 0 {
				slog.Warn("audio_capture_error", "error", alsaError(rec))
				return
			}
			continue
		}
		if n > 0 {
			samples := make([]float32, n)
			for i := 0; i < int(n); i++ {
				samples[i] = float32(buf[i]) / 32768.0
			}
			select {
			case r.sampleCh <- samples:
			case <-r.done:
				return
			}
		}
	}
}

func (r *alsaRecorder) Stop() {
	r.mu.Lock()
	defer r.mu.Unlock()

	if !r.running.Load() {
		return
	}
	r.running.Store(false)
	close(r.done)
	for range r.sampleCh {
	}
}

func alsaError(err C.int) string {
	return C.GoString(C.snd_strerror(err))
}