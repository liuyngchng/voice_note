// Package audio provides PCM audio capture and playback.
package audio

// ConvertFloatsToPCM converts float32 samples in [-1,1] to 16-bit
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
