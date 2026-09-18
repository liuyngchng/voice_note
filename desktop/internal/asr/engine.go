// Package asr wraps the offline speech recognition engine (sherpa-onnx SenseVoiceSmall).
// Models are loaded from dataDir/models/ at runtime.
package asr

import (
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"runtime"

	sherpa "github.com/k2-fsa/sherpa-onnx-go/sherpa_onnx"
)

// Model status for UI to observe.
type ModelStatus int

const (
	StatusUnknown       ModelStatus = iota
	StatusMissing
	StatusLoading
	StatusReady
	StatusError
	StatusNativeMissing
)

func (s ModelStatus) String() string {
	switch s {
	case StatusUnknown:
		return "unknown"
	case StatusMissing:
		return "missing"
	case StatusLoading:
		return "loading"
	case StatusReady:
		return "ready"
	case StatusError:
		return "error"
	case StatusNativeMissing:
		return "native_missing"
	default:
		return "unknown"
	}
}

// Engine wraps the sherpa-onnx offline recognizer, VAD, and punctuation.
type Engine struct {
	recognizer *sherpa.OfflineRecognizer
	vad        *sherpa.VoiceActivityDetector
	sampleRate int

	// Punctuation model
	punct *sherpa.OfflinePunctuation

	// State
	status   ModelStatus
	statusCh chan ModelStatus // non-blocking updates for UI

	// Paths (models on disk)
	modelDir string
}

// New creates a new offline ASR engine, loading models from dataDir/models/.
func New(dataDir string) (*Engine, error) {
	e := &Engine{
		sampleRate: 16000,
		statusCh:   make(chan ModelStatus, 16),
	}

	modelDir := filepath.Join(dataDir, "models")
	e.modelDir = modelDir

	modelPath := filepath.Join(modelDir, "model.int8.onnx")
	tokensPath := filepath.Join(modelDir, "tokens.txt")
	vadPath := filepath.Join(modelDir, "silero_vad.onnx")
	punctPath := filepath.Join(modelDir, "punct_ct_transformer.onnx")

	for _, f := range []string{modelPath, tokensPath} {
		if _, err := os.Stat(f); err != nil {
			e.updateStatus(StatusMissing)
			return nil, fmt.Errorf("asr: model file not found: %s", f)
		}
	}

	e.updateStatus(StatusLoading)

	// Create recognizer.
	numThreads := runtime.NumCPU()
	if numThreads > 4 {
		numThreads = 4
	}
	if numThreads < 2 {
		numThreads = 2
	}

	config := &sherpa.OfflineRecognizerConfig{
		FeatConfig: sherpa.FeatureConfig{
			SampleRate: 16000,
			FeatureDim: 80,
		},
		ModelConfig: sherpa.OfflineModelConfig{
			SenseVoice: sherpa.OfflineSenseVoiceModelConfig{
				Model:                       modelPath,
				Language:                    "auto",
				UseInverseTextNormalization: 1,
			},
			Tokens:     tokensPath,
			NumThreads: numThreads,
			Provider:   "cpu",
			Debug:      0,
		},
		DecodingMethod: "greedy_search",
	}

	recognizer := sherpa.NewOfflineRecognizer(config)
	if recognizer == nil {
		e.updateStatus(StatusError)
		return nil, fmt.Errorf("asr: failed to create recognizer")
	}
	e.recognizer = recognizer

	// Create VAD if the model is available.
	if _, err := os.Stat(vadPath); err == nil {
		vadConfig := &sherpa.VadModelConfig{
			SileroVad: sherpa.SileroVadModelConfig{
				Model:              vadPath,
				Threshold:          0.5,
				MinSilenceDuration: 0.5,
				MinSpeechDuration:  0.25,
				MaxSpeechDuration:  30.0,
				WindowSize:         512,
			},
			SampleRate: 16000,
			NumThreads: 1,
			Provider:   "cpu",
		}
		if vad := sherpa.NewVoiceActivityDetector(vadConfig, 30.0); vad != nil {
			e.vad = vad
		} else {
			slog.Warn("asr_vad_create_failed")
		}
	} else {
		slog.Warn("asr_vad_model_missing", "path", vadPath)
	}

	// Create punctuation model if available.
	if _, err := os.Stat(punctPath); err == nil {
		punctConfig := &sherpa.OfflinePunctuationConfig{
			Model: sherpa.OfflinePunctuationModelConfig{
				CtTransformer: punctPath,
				NumThreads:    1,
				Provider:      "cpu",
				Debug:         0,
			},
		}
		if punct := sherpa.NewOfflinePunctuation(punctConfig); punct != nil {
			e.punct = punct
		} else {
			slog.Warn("asr_punctuation_create_failed")
		}
	} else {
		slog.Warn("asr_punctuation_model_missing", "path", punctPath)
	}

	e.updateStatus(StatusReady)
	slog.Info("asr_engine_ready",
		"num_threads", numThreads,
		"vad", e.vad != nil,
		"punct", e.punct != nil)
	return e, nil
}

// Decode runs offline recognition on float32 PCM samples (16kHz mono).
func (e *Engine) Decode(samples []float32) (string, error) {
	if e.recognizer == nil {
		return "", fmt.Errorf("asr: engine not initialized")
	}
	if len(samples) == 0 {
		return "", nil
	}

	stream := sherpa.NewOfflineStream(e.recognizer)
	if stream == nil {
		return "", fmt.Errorf("asr: failed to create stream")
	}
	defer sherpa.DeleteOfflineStream(stream)

	stream.AcceptWaveform(e.sampleRate, samples)
	e.recognizer.Decode(stream)

	result := stream.GetResult()
	if result == nil {
		return "", fmt.Errorf("asr: no result")
	}
	return result.Text, nil
}

// ---- VAD ----

// VadAccept feeds PCM audio to the VAD.
func (e *Engine) VadAccept(samples []float32) {
	if e.vad == nil {
		return
	}
	e.vad.AcceptWaveform(samples)
}

// VadHasSpeech returns true when the VAD has completed speech segments ready.
func (e *Engine) VadHasSpeech() bool {
	if e.vad == nil {
		return false
	}
	return !e.vad.IsEmpty()
}

// VadDecodeSegments decodes any completed speech segments from the VAD.
func (e *Engine) VadDecodeSegments() []string {
	if e.vad == nil {
		return nil
	}
	var results []string
	for !e.vad.IsEmpty() {
		seg := e.vad.Front()
		if seg != nil && len(seg.Samples) > 0 {
			text, err := e.Decode(seg.Samples)
			if err == nil && text != "" {
				results = append(results, text)
			}
		}
		e.vad.Pop()
	}
	return results
}

// VadFlush feeds silence to force completion of in-progress speech.
func (e *Engine) VadFlush() {
	if e.vad == nil {
		return
	}
	// ~0.6s of silence to flush
	silence := make([]float32, int(16000*0.6))
	e.vad.AcceptWaveform(silence)
}

// VadIsDetected returns true when the VAD currently detects speech.
func (e *Engine) VadIsDetected() bool {
	if e.vad == nil {
		return false
	}
	return e.vad.IsSpeech()
}

// ---- Punctuation ----

// AddPunctuation adds punctuation to raw text using the offline model.
func (e *Engine) AddPunctuation(text string) string {
	if e.punct == nil || text == "" {
		return text
	}
	return e.punct.AddPunct(text)
}

// HasPunctuation returns true if the punctuation model is loaded.
func (e *Engine) HasPunctuation() bool {
	return e.punct != nil
}

// ---- Lifecycle ----

// IsReady returns true when the engine is initialized and ready.
func (e *Engine) IsReady() bool {
	return e.recognizer != nil
}

// Status returns the current model status.
func (e *Engine) Status() ModelStatus {
	return e.status
}

// StatusChan returns a channel for non-blocking status updates.
func (e *Engine) StatusChan() <-chan ModelStatus {
	return e.statusCh
}

// Close releases all resources.
func (e *Engine) Close() {
	if e.recognizer != nil {
		sherpa.DeleteOfflineRecognizer(e.recognizer)
		e.recognizer = nil
	}
	if e.vad != nil {
		sherpa.DeleteVoiceActivityDetector(e.vad)
		e.vad = nil
	}
	if e.punct != nil {
		sherpa.DeleteOfflinePunc(e.punct)
		e.punct = nil
	}
	slog.Info("asr_engine_closed")
}

// ---- Internal ----

func (e *Engine) updateStatus(s ModelStatus) {
	e.status = s
	select {
	case e.statusCh <- s:
	default:
	}
}

