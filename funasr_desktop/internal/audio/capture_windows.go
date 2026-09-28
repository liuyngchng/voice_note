//go:build windows

// Package audio provides PCM audio capture and playback.
//
// This file implements microphone capture via WASAPI on Windows.
package audio

import (
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
	wasapiSampleRate     = 16000
	wasapiBufferDuration = wca.REFERENCE_TIME(30 * 10000) // 30ms in 100ns units
	wasapiPollInterval   = 10 * time.Millisecond
)

type wasapiRecorder struct {
	mu      sync.Mutex
	ch      chan []float32
	stopCh  chan struct{}
	started bool
}

// NewRecorder creates a new Windows WASAPI recorder.
func NewRecorder() (Recorder, error) {
	return &wasapiRecorder{}, nil
}

func (r *wasapiRecorder) Start() (<-chan []float32, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if !r.started {
		r.stopCh = make(chan struct{})
		r.started = true
		go r.captureLoop(r.stopCh)
	}

	ch := make(chan []float32, 32)
	r.ch = ch
	return ch, nil
}

// Stop stops capture and releases the WASAPI audio client, freeing the
// microphone. Start may be called again afterwards to reacquire it.
func (r *wasapiRecorder) Stop() {
	r.mu.Lock()
	defer r.mu.Unlock()

	if !r.started {
		return
	}
	close(r.stopCh)
	r.started = false
	r.ch = nil
}

func (r *wasapiRecorder) captureLoop(stopCh chan struct{}) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	if err := ole.CoInitializeEx(0, ole.COINIT_MULTITHREADED); err != nil {
		if err := ole.CoInitializeEx(0, ole.COINIT_APARTMENTTHREADED); err != nil {
			slog.Error("wasapi_capture_CoInitializeEx", "error", err)
			return
		}
	}
	defer ole.CoUninitialize()

	var mmde *wca.IMMDeviceEnumerator
	if err := wca.CoCreateInstance(wca.CLSID_MMDeviceEnumerator, 0, wca.CLSCTX_ALL,
		wca.IID_IMMDeviceEnumerator, &mmde); err != nil {
		slog.Error("wasapi_capture_CoCreateInstance", "error", err)
		return
	}
	defer mmde.Release()

	var mmd *wca.IMMDevice
	if err := mmde.GetDefaultAudioEndpoint(wca.ECapture, wca.EConsole, &mmd); err != nil {
		slog.Error("wasapi_capture_GetDefaultAudioEndpoint", "error", err)
		return
	}
	defer mmd.Release()

	var ac *wca.IAudioClient
	if err := mmd.Activate(wca.IID_IAudioClient, wca.CLSCTX_ALL, nil, &ac); err != nil {
		slog.Error("wasapi_capture_Activate", "error", err)
		return
	}
	defer ac.Release()

	requestedFormat := &wca.WAVEFORMATEX{
		WFormatTag:      wca.WAVE_FORMAT_PCM,
		NChannels:       1,
		NSamplesPerSec:  wasapiSampleRate,
		WBitsPerSample:  16,
		NBlockAlign:     2,
		NAvgBytesPerSec: wasapiSampleRate * 2,
		CbSize:          0,
	}

	streamFlags := uint32(wca.AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM)
	if err := ac.Initialize(wca.AUDCLNT_SHAREMODE_SHARED, streamFlags,
		wasapiBufferDuration, 0, requestedFormat, nil); err != nil {
		slog.Warn("wasapi_capture_Initialize_retry", "error", err)
		if err := ac.Initialize(wca.AUDCLNT_SHAREMODE_SHARED, 0,
			wasapiBufferDuration, 0, requestedFormat, nil); err != nil {
			slog.Error("wasapi_capture_Initialize", "error", err)
			return
		}
	}

	var bufferFrameSize uint32
	if err := ac.GetBufferSize(&bufferFrameSize); err != nil {
		slog.Error("wasapi_capture_GetBufferSize", "error", err)
		return
	}

	var acc *wca.IAudioCaptureClient
	if err := ac.GetService(wca.IID_IAudioCaptureClient, &acc); err != nil {
		slog.Error("wasapi_capture_GetService", "error", err)
		return
	}
	defer acc.Release()

	if err := ac.Start(); err != nil {
		slog.Error("wasapi_capture_Start", "error", err)
		return
	}
	defer ac.Stop()

	slog.Info("wasapi_capture_started", "buffer_frames", bufferFrameSize)

	for {
		select {
		case <-stopCh:
			slog.Info("wasapi_capture_stopped")
			return
		default:
		}

		hadData := false
		for {
			var packetSize uint32
			if err := acc.GetNextPacketSize(&packetSize); err != nil {
				slog.Error("wasapi_capture_GetNextPacketSize", "error", err)
				return
			}
			if packetSize == 0 {
				break
			}

			var data *byte
			var framesToRead uint32
			var flags uint32
			if err := acc.GetBuffer(&data, &framesToRead, &flags, nil, nil); err != nil {
				slog.Error("wasapi_capture_GetBuffer", "error", err)
				return
			}

			if flags&wca.AUDCLNT_BUFFERFLAGS_SILENT == 0 && data != nil && framesToRead > 0 {
				floatSamples := make([]float32, int(framesToRead))
				int16Ptr := (*[1 << 30]int16)(unsafe.Pointer(data))[:framesToRead:framesToRead]
				for i := range int(framesToRead) {
					floatSamples[i] = float32(int16Ptr[i]) / math.MaxInt16
				}
				hadData = true

				r.mu.Lock()
				ch := r.ch
				r.mu.Unlock()
				if ch != nil {
					select {
					case ch <- floatSamples:
					default:
					}
				}
			}

			acc.ReleaseBuffer(framesToRead)
		}

		if !hadData {
			time.Sleep(wasapiPollInterval)
		}
	}
}
