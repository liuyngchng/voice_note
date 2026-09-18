// Package audio provides audio file import (external WAV/M4A/MP3 → app).
package audio

import (
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"time"
)

// ImportAudio copies an external audio file into the app's managed audio
// directory and returns the destination path.
func ImportAudio(srcPath, dataDir string, recordID int64) (string, error) {
	src, err := os.Open(srcPath)
	if err != nil {
		return "", fmt.Errorf("无法读取音频文件: %w", err)
	}
	defer src.Close()

	audioDir := filepath.Join(dataDir, "audio", fmt.Sprintf("record_%d", recordID))
	if err := os.MkdirAll(audioDir, 0700); err != nil {
		return "", fmt.Errorf("创建音频目录失败: %w", err)
	}

	dateStr := time.Now().Format("20060102_150405")
	srcName := filepath.Base(srcPath)
	ext := filepath.Ext(srcName)
	targetPath := filepath.Join(audioDir, fmt.Sprintf("import_%s%s", dateStr, ext))

	dst, err := os.Create(targetPath)
	if err != nil {
		return "", fmt.Errorf("创建目标文件失败: %w", err)
	}
	defer dst.Close()

	written, err := io.Copy(dst, src)
	if err != nil {
		os.Remove(targetPath)
		return "", fmt.Errorf("复制文件失败: %w", err)
	}

	slog.Info("audio_imported", "src", srcPath, "dst", targetPath, "bytes", written)
	return targetPath, nil
}