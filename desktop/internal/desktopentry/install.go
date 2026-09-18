// Package desktopentry manages the Linux .desktop launcher integration.
//
// The application icon (256x256 PNG, Apple-style squircle) is embedded via
// go:embed.  The CreateShortcut function writes:
//   - ${HOME}/.local/share/icons/hicolor/256x256/apps/voice-note.png
//   - ${HOME}/.local/share/applications/voice-note.desktop
//
// All paths are under $HOME, so no root privileges are required.
package desktopentry

import (
	_ "embed"
	"fmt"
	"os"
	"path/filepath"
)

//go:embed icon.png
var iconPNG []byte

const (
	appID   = "voice-note"
	appName = "语音笔记"
	comment = "离线语音笔记，支持 AI 转录与翻译"
)

// IsInstalled reports whether both the desktop file and the icon exist.
func IsInstalled() bool {
	_, err1 := os.Stat(desktopPath())
	_, err2 := os.Stat(iconPath())
	return err1 == nil && err2 == nil
}

// CreateShortcut installs the .desktop file and application icon under $HOME.
// The binaryPath argument should be the absolute path to the running
// executable (os.Executable() is fine).
func CreateShortcut(binaryPath string) error {
	if err := installIcon(); err != nil {
		return fmt.Errorf("desktopentry: install icon: %w", err)
	}
	if err := installDesktopFile(binaryPath); err != nil {
		return fmt.Errorf("desktopentry: install desktop file: %w", err)
	}
	return nil
}

// RemoveShortcut deletes the .desktop file and icon created by CreateShortcut.
func RemoveShortcut() error {
	// Best-effort removal — if one fails try the other anyway.
	err1 := os.Remove(desktopPath())
	err2 := os.Remove(iconPath())
	if err1 != nil && err2 != nil {
		return fmt.Errorf("desktopentry: remove failed: desktop=%w icon=%w", err1, err2)
	}
	return nil
}

// ---- internals ----

func homeDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return home
}

func desktopDir() string {
	return filepath.Join(homeDir(), ".local", "share", "applications")
}

func desktopPath() string {
	return filepath.Join(desktopDir(), appID+".desktop")
}

func iconDir() string {
	return filepath.Join(homeDir(), ".local", "share", "icons", "hicolor", "256x256", "apps")
}

func iconPath() string {
	return filepath.Join(iconDir(), appID+".png")
}

func installIcon() error {
	dir := iconDir()
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("mkdir %s: %w", dir, err)
	}
	// Always overwrite — ensures icon stays up to date.
	if err := os.WriteFile(iconPath(), iconPNG, 0644); err != nil {
		return fmt.Errorf("write icon: %w", err)
	}
	return nil
}

func installDesktopFile(binaryPath string) error {
	dir := desktopDir()
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("mkdir %s: %w", dir, err)
	}

	content := fmt.Sprintf(`[Desktop Entry]
Name=%s
Name[zh_CN]=%s
Comment=%s
Comment[zh_CN]=%s
Keywords=voice;note;transcription;ASR
Exec=%s
Icon=%s
Terminal=false
Type=Application
Categories=Utility;Office;
StartupNotify=true
`, appName, appName, comment, comment, binaryPath, iconPath())

	if err := os.WriteFile(desktopPath(), []byte(content), 0644); err != nil {
		return fmt.Errorf("write desktop file: %w", err)
	}
	return nil
}