// Package audio provides PCM audio capture and playback.
package audio

// ConvertPCMToFloats converts 16-bit little-endian PCM bytes to normalized
// float32 samples in [-1, 1]. It is shared by ASR inference and audio-level
// computation.
func ConvertPCMToFloats(pcm []byte) []float32 {
	sampleCount := len(pcm) / 2
	floats := make([]float32, sampleCount)
	offset := 0
	for i := 0; i < sampleCount; i++ {
		sample := int16(uint16(pcm[offset]) | uint16(pcm[offset+1])<<8)
		floats[i] = float32(sample) / 32768.0
		offset += 2
	}
	return floats
}

// ConvertFloatsToPCM converts normalized float32 samples to 16-bit
// little-endian PCM bytes.
func ConvertFloatsToPCM(samples []float32) []byte {
	buf := make([]byte, len(samples)*2)
	for i, s := range samples {
		if s > 1.0 {
			s = 1.0
		} else if s < -1.0 {
			s = -1.0
		}
		v := int16(s * 32767.0)
		buf[i*2] = byte(v)
		buf[i*2+1] = byte(uint16(v) >> 8)
	}
	return buf
}
