// Package audio provides PCM audio capture and WAV file writing.
package audio

import (
	"fmt"
	"os"
)

// WavWriter writes 16-bit mono PCM as a standard WAV file.
// The header is written with placeholder sizes on creation;
// Close() seeks back and patches the correct lengths.
type WavWriter struct {
	f        *os.File
	dataSize int64 // total PCM bytes written
}

// NewWavWriter creates a WAV file at path and writes the placeholder header.
// Sample rate is hard-coded to 16000; channel count to 1; bits per sample to 16.
func NewWavWriter(path string) (*WavWriter, error) {
	f, err := os.Create(path)
	if err != nil {
		return nil, fmt.Errorf("wav: create %s: %w", path, err)
	}

	w := &WavWriter{f: f}
	if err := w.writeHeader(0); err != nil {
		f.Close()
		return nil, err
	}
	return w, nil
}

// WriteSamples converts float32 samples to PCM and appends them to the file.
func (w *WavWriter) WriteSamples(samples []float32) error {
	pcm := ConvertFloatsToPCM(samples)
	n, err := w.f.Write(pcm)
	if err != nil {
		return err
	}
	w.dataSize += int64(n)
	return nil
}

// Close finalises the WAV file by patching the RIFF and data chunk sizes,
// then closes the underlying file handle.
func (w *WavWriter) Close() error {
	// Data size must be even for a valid WAV; pad with a zero byte if needed.
	dataSizePadded := w.dataSize
	if dataSizePadded%2 != 0 {
		var pad byte
		if _, err := w.f.Write([]byte{pad}); err != nil {
			w.f.Close()
			return err
		}
		dataSizePadded++
	}

	// Seek back to rewrite the header with correct sizes.
	if _, err := w.f.Seek(0, 0); err != nil {
		w.f.Close()
		return err
	}
	if err := w.writeHeader(dataSizePadded); err != nil {
		w.f.Close()
		return err
	}
	return w.f.Close()
}

// writeHeader writes the 44-byte WAV header.
// dataSize is the number of PCM bytes (must be even).
func (w *WavWriter) writeHeader(dataSize int64) error {
	// RIFF header: file size = 36 + dataSize.
	fileSize := uint32(36 + dataSize)

	header := [44]byte{}

	// "RIFF"
	header[0], header[1], header[2], header[3] = 'R', 'I', 'F', 'F'
	putU32LE(header[4:], fileSize)

	// "WAVE"
	header[8], header[9], header[10], header[11] = 'W', 'A', 'V', 'E'

	// "fmt " chunk
	header[12], header[13], header[14], header[15] = 'f', 'm', 't', ' '
	putU32LE(header[16:], 16)        // chunk size
	putU16LE(header[20:], 1)         // audio format: PCM
	putU16LE(header[22:], 1)         // channels: mono
	putU32LE(header[24:], 16000)     // sample rate
	putU32LE(header[28:], 16000*1*2) // byte rate = rate * ch * bps/8
	putU16LE(header[32:], 2)         // block align = ch * bps/8
	putU16LE(header[34:], 16)        // bits per sample

	// "data" chunk
	header[36], header[37], header[38], header[39] = 'd', 'a', 't', 'a'
	putU32LE(header[40:], uint32(dataSize))

	_, err := w.f.Write(header[:])
	return err
}

func putU16LE(b []byte, v uint16) {
	b[0] = byte(v)
	b[1] = byte(v >> 8)
}

func putU32LE(b []byte, v uint32) {
	b[0] = byte(v)
	b[1] = byte(v >> 8)
	b[2] = byte(v >> 16)
	b[3] = byte(v >> 24)
}
