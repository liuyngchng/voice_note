// Package audio provides WAV file reading and writing.
package audio

import (
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"time"
)

// WavInfo holds parsed WAV header metadata.
type WavInfo struct {
	DataOffset    int64 // byte offset of the PCM data chunk
	DataSize      int64 // number of PCM data bytes
	SampleRate    int
	Channels      int
	BitsPerSample int
	TotalFrames   int64
}

// ReadWavInfo parses the WAV header of a file.
func ReadWavInfo(path string) (WavInfo, error) {
	f, err := os.Open(path)
	if err != nil {
		return WavInfo{}, err
	}
	defer f.Close()

	info := WavInfo{
		DataOffset:    44,
		SampleRate:    16000,
		Channels:      1,
		BitsPerSample: 16,
	}

	// RIFF header
	header := make([]byte, 12)
	if _, err := f.ReadAt(header, 0); err != nil {
		return info, err
	}
	if string(header[0:4]) != "RIFF" {
		return info, errors.New("not a RIFF file")
	}

	// Chunk iteration starting at offset 12
	var offset int64 = 12
	chunkHeader := make([]byte, 8)
	for {
		if _, err := f.ReadAt(chunkHeader, offset); err != nil {
			break
		}
		chunkID := string(chunkHeader[0:4])
		chunkSize := int64(binary.LittleEndian.Uint32(chunkHeader[4:8]))

		switch chunkID {
		case "fmt ":
			fmtData := make([]byte, 16)
			if _, err := f.ReadAt(fmtData, offset+8); err != nil {
				return info, err
			}
			info.Channels = int(binary.LittleEndian.Uint16(fmtData[2:4]))
			info.SampleRate = int(binary.LittleEndian.Uint32(fmtData[4:8]))
			info.BitsPerSample = int(binary.LittleEndian.Uint16(fmtData[14:16]))
		case "data":
			info.DataOffset = offset + 8
			info.DataSize = chunkSize
			bytesPerFrame := int64(info.Channels) * int64(info.BitsPerSample/8)
			if bytesPerFrame > 0 {
				info.TotalFrames = chunkSize / bytesPerFrame
			}
			return info, nil
		}

		offset += 8 + chunkSize
	}

	return info, nil
}

// WavWriter writes 16kHz mono 16-bit WAV files incrementally.
type WavWriter struct {
	file      *os.File
	dataBytes int64
	lastSync  time.Time
	writeErr  error
}

// NewWavWriter creates a WAV file and writes the initial header (dataSize=0).
func NewWavWriter(path string) (*WavWriter, error) {
	f, err := os.Create(path)
	if err != nil {
		return nil, err
	}
	w := &WavWriter{file: f, lastSync: time.Now()}
	if err := w.writeHeader(0); err != nil {
		f.Close()
		return nil, err
	}
	return w, nil
}

// NewWavWriterAppend opens an existing WAV file for appending (crash recovery).
func NewWavWriterAppend(path string) (*WavWriter, error) {
	info, err := ReadWavInfo(path)
	if err != nil {
		return nil, err
	}
	fileLen, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	// Actual data bytes on disk = file length - header offset.
	actualDataBytes := fileLen.Size() - info.DataOffset
	if actualDataBytes < 0 {
		actualDataBytes = 0
	}

	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return nil, err
	}
	w := &WavWriter{file: f, dataBytes: actualDataBytes, lastSync: time.Now()}
	return w, nil
}

// Write appends PCM data to the WAV file.
func (w *WavWriter) Write(data []byte) error {
	if w.writeErr != nil {
		return w.writeErr
	}
	if _, err := w.file.Write(data); err != nil {
		w.writeErr = fmt.Errorf("disk write failed: %w", err)
		return w.writeErr
	}
	w.dataBytes += int64(len(data))

	// Periodic fsync: every ~30 seconds to bound data loss on crash.
	if time.Since(w.lastSync) >= 30*time.Second {
		w.Flush()
	}
	return nil
}

// Flush force-flushes buffered data to disk.
func (w *WavWriter) Flush() error {
	if w.writeErr != nil {
		return w.writeErr
	}
	if err := w.file.Sync(); err != nil {
		w.writeErr = err
		return err
	}
	w.lastSync = time.Now()
	return nil
}

// DataBytes returns the total number of PCM data bytes written.
func (w *WavWriter) DataBytes() int64 {
	return w.dataBytes
}

// HasWriteError returns true if a write error occurred (e.g. disk full).
func (w *WavWriter) HasWriteError() bool {
	return w.writeErr != nil
}

// Close finalizes the WAV file by patching the header and closing the stream.
func (w *WavWriter) Close() error {
	if w.file == nil {
		return nil
	}
	if err := w.Flush(); err != nil {
		// Still try to patch and close.
	}
	if err := w.patchHeader(); err != nil {
		return err
	}
	err := w.file.Close()
	w.file = nil
	return err
}

func (w *WavWriter) writeHeader(dataSize int64) error {
	header := make([]byte, 44)
	copy(header[0:4], "RIFF")
	binary.LittleEndian.PutUint32(header[4:8], uint32(dataSize+36))
	copy(header[8:12], "WAVE")
	copy(header[12:16], "fmt ")
	binary.LittleEndian.PutUint32(header[16:20], 16) // sub-chunk size
	binary.LittleEndian.PutUint16(header[20:22], 1)  // PCM
	binary.LittleEndian.PutUint16(header[22:24], 1)  // mono
	binary.LittleEndian.PutUint32(header[24:28], 16000)
	binary.LittleEndian.PutUint32(header[28:32], 32000) // byte rate
	binary.LittleEndian.PutUint16(header[32:34], 2)     // block align
	binary.LittleEndian.PutUint16(header[34:36], 16)    // bits per sample
	copy(header[36:40], "data")
	binary.LittleEndian.PutUint32(header[40:44], uint32(dataSize))

	_, err := w.file.WriteAt(header, 0)
	return err
}

func (w *WavWriter) patchHeader() error {
	// Patch RIFF size (offset 4) and data chunk size (offset 40).
	buf := make([]byte, 4)
	binary.LittleEndian.PutUint32(buf, uint32(w.dataBytes+36))
	if _, err := w.file.WriteAt(buf, 4); err != nil {
		return err
	}
	binary.LittleEndian.PutUint32(buf, uint32(w.dataBytes))
	if _, err := w.file.WriteAt(buf, 40); err != nil {
		return err
	}
	return nil
}
