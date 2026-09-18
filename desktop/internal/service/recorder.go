// Package service provides recording orchestration (the desktop equivalent of
// Android's RecordingService). It coordinates audio capture, offline ASR, VAD,
// WAV writing, checkpointing, and punctuation.
package service

import (
	"bytes"
	"fmt"
	"log/slog"
	"math"
	"os"
	"path/filepath"
	"time"

	"github.com/liuyngchng/voice-note-desktop/internal/audio"
	"github.com/liuyngchng/voice-note-desktop/internal/common"
	"github.com/liuyngchng/voice-note-desktop/internal/asr"
)

const (
	decodeIntervalMs  = 5000
	recentCharWindow  = 100
	decodeRingBufferSize = 640000 // 20s at 16kHz/16bit/mono
	diskCheckInterval = 5 * time.Minute
	maxTranscriptChars = 1000000
	punctuationChunkSize = 5000
	checkpointInterval = 2 * time.Minute
	activeRecordingFile = "active_recording.txt"
)

// State holds the current recording session state, exposed to the UI via channels.
type State struct {
	IsRecording   bool
	DurationSec   int64
	Transcript    string
	StatusMessage string
	AudioLevel    float32
	RecordID      int64
	Error         error
}

// Recorder orchestrates a single recording session.
type Recorder struct {
	audioRec RecorderImpl
	asrEngine *asr.Engine
	dataDir     string

	stateCh   chan State
	stopCh    chan struct{}
	doneCh    chan struct{}
}

// RecorderImpl is the audio capture implementation (platform-specific).
type RecorderImpl interface {
	Start() (<-chan []float32, error)
	Stop()
}

// NewRecorder creates a new recording orchestrator.
func NewRecorder(audioRec RecorderImpl, asrEng *asr.Engine, dataDir string) *Recorder {
	return &Recorder{
		audioRec:  audioRec,
		asrEngine: asrEng,
		dataDir:   dataDir,
		stateCh:   make(chan State, 64),
		stopCh:    make(chan struct{}),
		doneCh:    make(chan struct{}),
	}
}

// StateChan returns a channel for observing recording state changes.
func (r *Recorder) StateChan() <-chan State { return r.stateCh }

// Done returns a channel that is closed when recording stops.
func (r *Recorder) Done() <-chan struct{} { return r.doneCh }

// Start begins recording. Call Stop to end gracefully.
func (r *Recorder) Start(recordID int64) error {
	r.emit(State{IsRecording: true, RecordID: recordID, StatusMessage: "正在初始化录音服务..."})

	// Start audio capture.
	sampleCh, err := r.audioRec.Start()
	if err != nil {
		r.emit(State{IsRecording: false, Error: fmt.Errorf("启动音频采集失败: %w", err)})
		return err
	}

	// Set up audio directory and WAV writer.
	audioDir := filepath.Join(r.dataDir, "audio", fmt.Sprintf("record_%d", recordID))
	if err := os.MkdirAll(audioDir, 0700); err != nil {
		return fmt.Errorf("create audio dir: %w", err)
	}

	dateStr := time.Now().Format("20060102_150405")
	wavPath := filepath.Join(audioDir, dateStr+".wav")
	wavWriter, err := audio.NewWavWriter(wavPath)
	if err != nil {
		return fmt.Errorf("create WAV file: %w", err)
	}

	// Transcript file path.
	transcriptPath := filepath.Join(audioDir, dateStr+"_voice_note.txt")

	// Write active recording marker for crash recovery.
	markerPath := filepath.Join(r.dataDir, activeRecordingFile)
	os.WriteFile(markerPath, []byte(fmt.Sprintf("%d", recordID)), 0600)

	go r.run(sampleCh, wavWriter, transcriptPath, recordID)
	return nil
}

// Stop signals the recorder to stop gracefully.
func (r *Recorder) Stop() {
	select {
	case <-r.stopCh:
	default:
		close(r.stopCh)
	}
	r.emit(State{StatusMessage: "录音已结束，正在保存..."})
}

func (r *Recorder) run(sampleCh <-chan []float32, wavWriter *audio.WavWriter, transcriptPath string, recordID int64) {
	defer close(r.doneCh)
	defer r.audioRec.Stop()
	defer func() {
		os.Remove(filepath.Join(r.dataDir, activeRecordingFile))
	}()

	var (
		mutableTranscript bytes.Buffer
		lastDecodeTime    int64
		durationSec       int64
		finalTranscript   string
		ticker            = time.NewTicker(time.Second)
		diskTicker        = time.NewTicker(diskCheckInterval)
		checkpointTicker  = time.NewTicker(checkpointInterval)
		decodeRingBuf     = make([]byte, decodeRingBufferSize)
		decodeRingBufEnd  int
	)

	defer ticker.Stop()
	defer diskTicker.Stop()
	defer checkpointTicker.Stop()

	// Ensure ASR is ready.
	vadActive := r.asrEngine != nil && r.asrEngine.VadIsDetected() // initial check
	asrReady := r.asrEngine != nil && r.asrEngine.IsReady()

	for {
		select {
		case <-r.stopCh:
			// Drain remaining and finalize.
			goto finalize

		case samples, ok := <-sampleCh:
			if !ok {
				goto finalize
			}
			// Write PCM to WAV.
			pcm := audio.ConvertFloatsToPCM(samples)
			if err := wavWriter.Write(pcm); err != nil {
				r.emit(State{StatusMessage: "磁盘写入失败，录音已中断"})
				// Finalize anyway to save what we have.
				goto finalizePunct
			}

			// Audio level for UI waveform.
			level := computeRMS(samples)
			r.emit(State{AudioLevel: level})

			// ASR decode.
			if asrReady {
				if vadActive {
					// VAD path.
					r.asrEngine.VadAccept(samples)
					elapsed := durationSec * 1000
					if elapsed-lastDecodeTime >= decodeIntervalMs {
						lastDecodeTime = elapsed
						segments := r.asrEngine.VadDecodeSegments()
						for _, text := range segments {
							mutableTranscript.WriteString(text)
							appendToFile(transcriptPath, text+"\n")
						}
						if len(segments) > 0 {
							full := mutableTranscript.String()
							tail := full
							runes := []rune(full)
							if len(runes) > recentCharWindow {
								tail = string(runes[len(runes)-recentCharWindow:])
							}
							r.emit(State{Transcript: tail, StatusMessage: "正在转写... " + common.FormatDuration(durationSec)})
						} else {
							r.emit(State{StatusMessage: "静音中... " + common.FormatDuration(durationSec)})
						}
						// Truncate if too long.
						if mutableTranscript.Len() > maxTranscriptChars {
							slog.Warn("recorder_transcript_capped", "len", mutableTranscript.Len())
							tmp := mutableTranscript.String()
							runes := []rune(tmp)
							mutableTranscript.Reset()
							mutableTranscript.WriteString(string(runes[len(runes)/4:]))
						}
					}
				} else {
					// Non-VAD path: ring buffer + periodic decode.
					copyToRing := min(len(pcm), decodeRingBufferSize-decodeRingBufEnd)
					if copyToRing < len(pcm) {
						shift := len(pcm) - copyToRing
						copy(decodeRingBuf, decodeRingBuf[shift:decodeRingBufEnd])
						decodeRingBufEnd -= shift
					}
					copy(decodeRingBuf[decodeRingBufEnd:], pcm)
					decodeRingBufEnd += copyToRing

					elapsed := durationSec * 1000
					if elapsed-lastDecodeTime >= decodeIntervalMs && decodeRingBufEnd > 0 {
						lastDecodeTime = elapsed
						chunk := make([]byte, decodeRingBufEnd)
						copy(chunk, decodeRingBuf[:decodeRingBufEnd])
						decodeRingBufEnd = 0

						text, err := r.asrEngine.Decode(audio.ConvertPCMToFloats(chunk))
						if err != nil {
							slog.Warn("recorder_decode_error", "error", err)
						} else if text != "" {
							mutableTranscript.WriteString(text)
							appendToFile(transcriptPath, text+"\n")
							full := mutableTranscript.String()
							runes := []rune(full)
							tail := full
							if len(runes) > recentCharWindow {
								tail = string(runes[len(runes)-recentCharWindow:])
							}
							r.emit(State{Transcript: tail, StatusMessage: "正在转写... " + common.FormatDuration(durationSec)})
						}
					}
				}
			}

		case <-ticker.C:
			durationSec++
			r.emit(State{DurationSec: durationSec})

		case <-diskTicker.C:
			// Disk space check.
			if wavWriter.HasWriteError() {
				r.emit(State{StatusMessage: "磁盘写入失败，录音已中断"})
				goto finalizePunct
			}
		case <-checkpointTicker.C:
			// Checkpoint: flush WAV.
			if err := wavWriter.Flush(); err != nil {
				slog.Warn("recorder_checkpoint_flush_error", "error", err)
			}
		}
	}

finalizePunct:
	// Drain remaining audio in ring buffer.
	if decodeRingBufEnd > 0 && r.asrEngine != nil && r.asrEngine.IsReady() {
		chunk := make([]byte, decodeRingBufEnd)
		copy(chunk, decodeRingBuf[:decodeRingBufEnd])
		text, err := r.asrEngine.Decode(audio.ConvertPCMToFloats(chunk))
		if err == nil && text != "" {
			mutableTranscript.WriteString(text)
			appendToFile(transcriptPath, text+"\n")
		}
	}

	// Drain remaining VAD segments.
	if r.asrEngine != nil && r.asrEngine.IsReady() {
		r.asrEngine.VadFlush()
		segments := r.asrEngine.VadDecodeSegments()
		for _, text := range segments {
			mutableTranscript.WriteString(text)
			appendToFile(transcriptPath, text+"\n")
		}
	}

	// Apply punctuation.
	finalTranscript = mutableTranscript.String()
	if r.asrEngine != nil && r.asrEngine.HasPunctuation() && finalTranscript != "" {
		r.emit(State{StatusMessage: "正在添加标点..."})
		finalTranscript = applyPunctuation(r.asrEngine, finalTranscript)
	}

	// Write final transcript file.
	if finalTranscript != "" {
		os.WriteFile(transcriptPath, []byte(finalTranscript), 0600)
	}
	r.emit(State{Transcript: finalTranscript})

finalize:
	// Close WAV file (patches header).
	if err := wavWriter.Close(); err != nil {
		slog.Error("recorder_wav_close_error", "error", err)
	}
	r.emit(State{IsRecording: false, Transcript: mutableTranscript.String()})
}

func (r *Recorder) emit(s State) {
	select {
	case r.stateCh <- s:
	default:
	}
}

func computeRMS(samples []float32) float32 {
	if len(samples) == 0 {
		return 0
	}
	var sum float64
	for _, s := range samples {
		sum += float64(s) * float64(s)
	}
	rms := float32(math.Sqrt(sum / float64(len(samples))))
	return min(1.0, rms*12.0)
}

func applyPunctuation(engine *asr.Engine, text string) string {
	if len(text) <= punctuationChunkSize {
		return engine.AddPunctuation(text)
	}

	var result bytes.Buffer
	runes := []rune(text)
	offset := 0
	for offset < len(runes) {
		end := min(offset+punctuationChunkSize, len(runes))
		// Try to find a sentence boundary.
		adjustedEnd := end
		searchStart := max(offset, end-500)
		searchRange := string(runes[searchStart:end])
		lastBreak := -1
		for _, ch := range []rune{'\n', '。', '！', '？', '.', '!', '?'} {
			for i := len(searchRange) - 1; i >= 0; i-- {
				if rune(searchRange[i]) == ch {
					if searchStart+i+1 > lastBreak {
						lastBreak = searchStart + i + 1
					}
				}
			}
		}
		if lastBreak > offset {
			adjustedEnd = lastBreak
		}
		chunk := string(runes[offset:adjustedEnd])
		result.WriteString(engine.AddPunctuation(chunk))
		offset = adjustedEnd
	}
	return result.String()
}

func appendToFile(path, text string) {
	if path == "" || text == "" {
		return
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		slog.Warn("recorder_append_transcript_error", "error", err)
		return
	}
	defer f.Close()
	f.WriteString(text)
	f.Sync()
}