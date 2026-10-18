//go:build windows

// Package audio provides PCM audio capture.
//
// This file implements system-audio (loopback) capture via WASAPI on Windows.
// It captures from the default render endpoint (speakers/headphones), which
// includes the other side of an online meeting, music playback, etc.
package audio

import (
	"encoding/binary"
	"log/slog"
	"math"
	"runtime"
	"sync"
	"time"
	"unsafe"

	"github.com/go-ole/go-ole"
	"github.com/moutend/go-wca/pkg/wca"
)

const (
	_loopbackWAVE_FORMAT_IEEE_FLOAT  = 0x0003
	_loopbackWAVE_FORMAT_EXTENSIBLE  = 0xFFFE
	_loopbackPollInterval             = 10 * time.Millisecond
	_loopbackTargetSampleRate  uint32 = 16000
)

type wasapiLoopbackRecorder struct {
	mu      sync.Mutex
	ch      chan []float32
	stopCh  chan struct{}
	started bool
	once    sync.Once
}

// newMonitorRecorder creates a WASAPI loopback recorder that captures
// audio from the default render (playback) endpoint.
func newMonitorRecorder() (Recorder, error) {
	slog.Info("wasapi_loopback_recorder_created")
	return &wasapiLoopbackRecorder{}, nil
}

func (r *wasapiLoopbackRecorder) Start() (<-chan []float32, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if !r.started {
		r.stopCh = make(chan struct{})
		r.started = true
		go r.captureLoop()
	}

	ch := make(chan []float32, 32)
	r.ch = ch
	return ch, nil
}

func (r *wasapiLoopbackRecorder) Stop() {
	r.once.Do(func() {
		r.mu.Lock()
		if r.stopCh != nil {
			close(r.stopCh)
		}
		r.mu.Unlock()
	})
}

func (r *wasapiLoopbackRecorder) captureLoop() {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	if err := ole.CoInitializeEx(0, ole.COINIT_MULTITHREADED); err != nil {
		if err := ole.CoInitializeEx(0, ole.COINIT_APARTMENTTHREADED); err != nil {
			slog.Error("wasapi_loopback_CoInitializeEx", "error", err)
			return
		}
	}
	defer ole.CoUninitialize()

	var mmde *wca.IMMDeviceEnumerator
	if err := wca.CoCreateInstance(wca.CLSID_MMDeviceEnumerator, 0, wca.CLSCTX_ALL,
		wca.IID_IMMDeviceEnumerator, &mmde); err != nil {
		slog.Error("wasapi_loopback_CoCreateInstance", "error", err)
		return
	}
	defer mmde.Release()

	// Get the default render (playback) endpoint.
	var mmd *wca.IMMDevice
	if err := mmde.GetDefaultAudioEndpoint(wca.ERender, wca.EConsole, &mmd); err != nil {
		slog.Error("wasapi_loopback_GetDefaultAudioEndpoint", "error", err)
		return
	}
	defer mmd.Release()

	var ac *wca.IAudioClient
	if err := mmd.Activate(wca.IID_IAudioClient, wca.CLSCTX_ALL, nil, &ac); err != nil {
		slog.Error("wasapi_loopback_Activate", "error", err)
		return
	}
	defer ac.Release()

	// Query the engine's native mix format for conversion.
	var mixFormat *wca.WAVEFORMATEX
	if err := ac.GetMixFormat(&mixFormat); err != nil {
		slog.Error("wasapi_loopback_GetMixFormat", "error", err)
		return
	}
	defer ole.CoTaskMemFree(uintptr(unsafe.Pointer(mixFormat)))

	srcRate := mixFormat.NSamplesPerSec
	srcChannels := mixFormat.NChannels
	srcBits := mixFormat.WBitsPerSample
	wFormatTag := mixFormat.WFormatTag

	slog.Info("wasapi_loopback_mix_format",
		"rate", srcRate,
		"channels", srcChannels,
		"bits", srcBits,
		"format_tag", wFormatTag)

	isFloat := wFormatTag == _loopbackWAVE_FORMAT_IEEE_FLOAT
	isExtensible := wFormatTag == _loopbackWAVE_FORMAT_EXTENSIBLE
	if isExtensible && mixFormat.CbSize >= 22 {
		extra := (*[64]byte)(unsafe.Pointer(mixFormat))[22:]
		subFormatTag := binary.LittleEndian.Uint16(extra[2:4])
		if subFormatTag == _loopbackWAVE_FORMAT_IEEE_FLOAT {
			isFloat = true
		}
	}

	if err := ac.Initialize(wca.AUDCLNT_SHAREMODE_SHARED,
		wca.AUDCLNT_STREAMFLAGS_LOOPBACK,
		0, 0, mixFormat, nil); err != nil {
		slog.Error("wasapi_loopback_Initialize", "error", err)
		return
	}

	var bufferFrameSize uint32
	if err := ac.GetBufferSize(&bufferFrameSize); err != nil {
		slog.Error("wasapi_loopback_GetBufferSize", "error", err)
		return
	}

	var acc *wca.IAudioCaptureClient
	if err := ac.GetService(wca.IID_IAudioCaptureClient, &acc); err != nil {
		slog.Error("wasapi_loopback_GetService", "error", err)
		return
	}
	defer acc.Release()

	if err := ac.Start(); err != nil {
		slog.Error("wasapi_loopback_Start", "error", err)
		return
	}
	defer ac.Stop()

	slog.Info("wasapi_loopback_started", "buffer_frames", bufferFrameSize)

	decimationFactor := int(srcRate / _loopbackTargetSampleRate)
	if decimationFactor < 1 {
		decimationFactor = 1
	}
	decimationCounter := 0

	for {
		select {
		case <-r.stopCh:
			slog.Info("wasapi_loopback_stopped")
			return
		default:
		}

		hadData := false
	inner:
		for {
			var packetSize uint32
			if err := acc.GetNextPacketSize(&packetSize); err != nil {
				slog.Error("wasapi_loopback_GetNextPacketSize", "error", err)
				return
			}
			if packetSize == 0 {
				break inner
			}

			var data *byte
			var framesToRead uint32
			var flags uint32
			if err := acc.GetBuffer(&data, &framesToRead, &flags, nil, nil); err != nil {
				slog.Error("wasapi_loopback_GetBuffer", "error", err)
				return
			}

			if (flags&wca.AUDCLNT_BUFFERFLAGS_SILENT) == 0 && data != nil && framesToRead > 0 {
				samples := convertLoopbackFrames(data, int(framesToRead), int(srcChannels), int(srcBits), isFloat, decimationFactor, &decimationCounter)
				if len(samples) > 0 {
					hadData = true
					r.mu.Lock()
					ch := r.ch
					r.mu.Unlock()
					if ch != nil {
						for _, s := range samples {
							select {
							case ch <- s:
							default:
							}
						}
					}
				}
			}

			acc.ReleaseBuffer(framesToRead)
		}

		if !hadData {
			time.Sleep(_loopbackPollInterval)
		}
	}
}

// convertLoopbackFrames converts raw WASAPI loopback frames to 16kHz mono
// float32 chunks.
func convertLoopbackFrames(
	data *byte,
	nFrames int,
	srcChannels int,
	srcBits int,
	isFloat bool,
	decimationFactor int,
	counter *int,
) [][]float32 {
	const maxChunkSize = 1600
	var chunks [][]float32
	var currentChunk []float32

	for i := 0; i < nFrames; i++ {
		var mono float32
		for ch := 0; ch < srcChannels; ch++ {
			var val float32
			if isFloat && srcBits == 32 {
				offset := (i*srcChannels + ch) * 4
				raw := *(*uint32)(unsafe.Pointer(&(*[1 << 30]byte)(unsafe.Pointer(data))[offset]))
				val = math.Float32frombits(raw)
			} else {
				bytesPerSample := srcBits / 8
				offset := (i*srcChannels + ch) * bytesPerSample
				rawPtr := &(*[1 << 30]byte)(unsafe.Pointer(data))[offset]
				switch srcBits {
				case 16:
					raw := int16(binary.LittleEndian.Uint16(rawPtr))
					val = float32(raw) / 32768.0
				case 32:
					raw := int32(binary.LittleEndian.Uint32(rawPtr))
					val = float32(raw) / 2147483648.0
				default:
					val = 0
				}
			}
			mono += val
		}
		mono /= float32(srcChannels)

		if *counter == 0 {
			currentChunk = append(currentChunk, mono)
			if len(currentChunk) >= maxChunkSize {
				chunks = append(chunks, currentChunk)
				currentChunk = nil
			}
		}

		*counter++
		if *counter >= decimationFactor {
			*counter = 0
		}
	}

	if len(currentChunk) > 0 {
		chunks = append(chunks, currentChunk)
	}
	return chunks
}