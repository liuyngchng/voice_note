//go:build windows

// Package main implements a self-extracting launcher that bundles the real
// Voice Note app, the sherpa-onnx DLLs, and (transitively, via the app) the
// offline ASR models into a single .exe.
//
// Windows resolves DLL imports from the PE import table *before* any Go code
// runs, so the CGo-linked sherpa-onnx DLLs cannot be embedded inside the app
// binary itself. Instead, this launcher embeds the app + DLLs, extracts them
// once to a persistent cache directory, and launches the app from there.
package main

import (
	"embed"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"unsafe"
)

//go:embed payload/*
var payload embed.FS

const appExe = "voice-note-desktop.exe"

func main() {
	if err := run(); err != nil {
		messageBox("语音笔记启动失败", err.Error())
		os.Exit(1)
	}
}

func run() error {
	base := filepath.Join(localAppData(), "VoiceNote", "bin")
	if err := extract(base); err != nil {
		return err
	}

	exe := filepath.Join(base, appExe)
	cmd := exec.Command(exe)
	cmd.Dir = base // DLLs resolve from the app's own directory

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("启动应用失败: %w", err)
	}
	return nil
}

// extract writes the embedded payload files into base, reusing any file that
// already exists with a matching size (so the ~1GB app is only written once).
func extract(base string) error {
	if err := os.MkdirAll(base, 0700); err != nil {
		return fmt.Errorf("创建目录失败: %w", err)
	}

	entries, err := fs.ReadDir(payload, "payload")
	if err != nil {
		return fmt.Errorf("读取内嵌资源失败: %w", err)
	}

	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		src := "payload/" + e.Name()
		dst := filepath.Join(base, e.Name())

		data, err := fs.ReadFile(payload, src)
		if err != nil {
			return fmt.Errorf("读取内嵌资源 %s 失败: %w", e.Name(), err)
		}
		if st, statErr := os.Stat(dst); statErr == nil && st.Size() == int64(len(data)) {
			continue // already extracted, reuse
		}
		if err := os.WriteFile(dst, data, 0755); err != nil {
			return fmt.Errorf("写入 %s 失败: %w", e.Name(), err)
		}
	}
	return nil
}

func localAppData() string {
	if v := os.Getenv("LOCALAPPDATA"); v != "" {
		return v
	}
	return os.TempDir()
}

// messageBox shows a native error dialog without pulling in cgo.
func messageBox(title, text string) {
	user32 := syscall.NewLazyDLL("user32.dll")
	msgBox := user32.NewProc("MessageBoxW")
	titlePtr, _ := syscall.UTF16PtrFromString(title)
	textPtr, _ := syscall.UTF16PtrFromString(text)
	// MB_OK | MB_ICONERROR
	msgBox.Call(0,
		uintptr(unsafe.Pointer(textPtr)),
		uintptr(unsafe.Pointer(titlePtr)),
		0x10)
}
