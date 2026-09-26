// Package storage handles local file persistence for the FunASR desktop
// client: writing the WAV recording and the transcript text to disk in a
// background goroutine, isolated from the real-time ASR pipeline.
package storage

import (
	"log/slog"
	"os"
	"path/filepath"
	"time"

	"github.com/liuyngchng/funasr-desktop-client/internal/audio"
)

// sampleBufSize is the capacity of the buffered channel carrying audio samples
// from the capture loop to the disk writer.
const sampleBufSize = 128

// Writer persists WAV samples and transcript text to disk in the background.
type Writer struct {
	wavWriter      *audio.WavWriter
	transcriptPath string

	samplesCh chan []float32
	textCh    chan string
	doneCh    chan struct{}
	warnFn    func(string)
}

// New creates output files under outputDir and starts the background writer
// goroutine. wavPath may be empty, in which case only transcript writes are
// performed.
func New(outputDir, wavName, transcriptName string, warnFn func(string)) (*Writer, error) {
	if err := os.MkdirAll(outputDir, 0o755); err != nil {
		return nil, err
	}

	w := &Writer{
		transcriptPath: filepath.Join(outputDir, transcriptName),
		samplesCh:      make(chan []float32, sampleBufSize),
		textCh:         make(chan string, 4),
		doneCh:         make(chan struct{}),
		warnFn:         warnFn,
	}

	if wavName != "" {
		ww, err := audio.NewWavWriter(filepath.Join(outputDir, wavName))
		if err != nil {
			return nil, err
		}
		w.wavWriter = ww
	}

	go w.run()
	return w, nil
}

func (w *Writer) run() {
	defer func() {
		if w.wavWriter != nil {
			if err := w.wavWriter.Close(); err != nil {
				slog.Error("wav_close", "err", err)
			}
		}
	}()

	for {
		select {
		case samples := <-w.samplesCh:
			if w.wavWriter != nil {
				if err := w.wavWriter.WriteSamples(samples); err != nil {
					slog.Error("wav_write", "err", err)
					w.warn("录音保存失败")
				}
			}

		case text := <-w.textCh:
			if w.transcriptPath != "" {
				if err := os.WriteFile(w.transcriptPath, []byte(text), 0o644); err != nil {
					slog.Error("transcript_write", "err", err)
					w.warn("文本保存失败")
				}
			}

		case <-w.doneCh:
			for {
				select {
				case samples := <-w.samplesCh:
					if w.wavWriter != nil {
						_ = w.wavWriter.WriteSamples(samples)
					}
				case text := <-w.textCh:
					if w.transcriptPath != "" {
						_ = os.WriteFile(w.transcriptPath, []byte(text), 0o644)
					}
				default:
					return
				}
			}
		}
	}
}

// WriteSamples queues a chunk of audio samples for writing (non-blocking).
func (w *Writer) WriteSamples(samples []float32) {
	select {
	case w.samplesCh <- samples:
	default:
	}
}

// WriteText queues a full transcript for writing (non-blocking).
func (w *Writer) WriteText(text string) {
	select {
	case w.textCh <- text:
	default:
	}
}

// Shutdown flushes the final transcript and stops the writer goroutine.
func (w *Writer) Shutdown(finalText string) {
	select {
	case w.textCh <- finalText:
	case <-time.After(2 * time.Second):
	}
	close(w.doneCh)
}

func (w *Writer) warn(msg string) {
	if w.warnFn != nil {
		w.warnFn(msg)
	}
}
