//go:build embed

// Package embedres embeds offline ASR model files into the binary.
//
// When built with the `embed` build tag, the contents of ./embed_models are
// compiled into the executable via go:embed. At runtime, EnsureModels()
// extracts them into a directory on disk (sherpa-onnx loads models from
// file paths) and returns that directory.
package embedres

import (
	"embed"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
)

//go:embed all:embed_models
var embeddedFS embed.FS

// Available reports whether models were embedded at build time.
func Available() bool { return true }

// EnsureModels extracts embedded model files to destDir (which must already
// exist) and returns the directory containing model.onnx / tokens.txt / etc.
// It is idempotent: files that already exist with a matching size are reused.
func EnsureModels(destDir string) (string, error) {
	modelDir := filepath.Join(destDir, "models")
	if err := os.MkdirAll(modelDir, 0700); err != nil {
		return "", fmt.Errorf("embedres: create model dir: %w", err)
	}

	if err := extractTree(embeddedFS, "embed_models", modelDir); err != nil {
		return "", err
	}
	return modelDir, nil
}

// extractTree recurses into the embedded directory rooted at srcDir and
// copies every regular file to dstDir. Uses streaming to avoid loading
// large models (900MB+) entirely into memory.
func extractTree(efs fs.ReadDirFS, srcDir, dstDir string) error {
	entries, err := fs.ReadDir(efs, srcDir)
	if err != nil {
		return fmt.Errorf("embedres: read embedded dir %q: %w", srcDir, err)
	}
	for _, entry := range entries {
		src := filepath.ToSlash(filepath.Join(srcDir, entry.Name()))
		dst := filepath.Join(dstDir, entry.Name())
		if entry.IsDir() {
			if err := os.MkdirAll(dst, 0700); err != nil {
				return err
			}
			if err := extractTree(efs, src, dst); err != nil {
				return err
			}
			continue
		}
		if err := streamOut(efs, src, dst); err != nil {
			return err
		}
	}
	return nil
}

// streamOut copies an embedded file to disk using a 32MB buffer, avoiding
// a full in-memory read of multi-hundred-MB model files.
func streamOut(efs fs.ReadFileFS, src, dst string) error {
	fi, err := fs.Stat(efs, src)
	if err != nil {
		return fmt.Errorf("embedres: stat %q: %w", src, err)
	}
	expectedSize := fi.Size()

	// Reuse if already on disk with matching size.
	if st, statErr := os.Stat(dst); statErr == nil && st.Size() == expectedSize {
		slog.Debug("embedres: reuse", "file", dst)
		return nil
	}

	f, err := efs.Open(src)
	if err != nil {
		return fmt.Errorf("embedres: open embedded %q: %w", src, err)
	}
	defer f.Close()

	out, err := os.Create(dst)
	if err != nil {
		return fmt.Errorf("embedres: create %q: %w", dst, err)
	}
	defer out.Close()

	written, err := io.CopyBuffer(out, f, make([]byte, 32*1024*1024)) // 32 MiB buffer
	if err != nil {
		os.Remove(dst)
		return fmt.Errorf("embedres: copy %q: %w", dst, err)
	}
	if written != expectedSize {
		os.Remove(dst)
		return fmt.Errorf("embedres: wrote %d bytes for %q, expected %d", written, dst, expectedSize)
	}
	slog.Info("embedres: extracted", "file", dst, "bytes", written)
	return nil
}