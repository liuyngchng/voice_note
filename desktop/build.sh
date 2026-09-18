#!/usr/bin/env bash
set -euo pipefail

# Build script for voice_note desktop (Go + Fyne + sherpa-onnx).
# Compiles inside Docker using an image with all X11/GL/Wayland -dev headers,
# producing: voice-note-desktop

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE="voice_note_fyne:1.0"
BINARY="voice-note-desktop"
GO_VERSION="1.24.13"
GO_TAR="go${GO_VERSION}.linux-amd64.tar.gz"
GO_URL="https://golang.google.cn/dl/${GO_TAR}"
DEPS_DIR="$SCRIPT_DIR/build/deps"

cd "$SCRIPT_DIR"

# ── 1. Check prerequisites ──────────────────────────────────────
if [[ ! -f "main.go" ]] || [[ ! -f "go.mod" ]]; then
  echo "ERROR: run this script from the desktop/ directory"
  exit 1
fi

if ! command -v docker &>/dev/null; then
  echo "ERROR: docker not found"
  exit 1
fi

# ── 2. Cache Go toolchain ───────────────────────────────────────
mkdir -p "$DEPS_DIR"
if [[ ! -f "$DEPS_DIR/$GO_TAR" ]]; then
  echo "Downloading Go $GO_VERSION ..."
  wget -q --show-progress "$GO_URL" -O "$DEPS_DIR/$GO_TAR"
  echo "Go tarball cached at build/deps/$GO_TAR"
else
  echo "Go $GO_VERSION cached ($(du -h "$DEPS_DIR/$GO_TAR" | cut -f1))"
fi

# ── 3. Build Docker image if missing ────────────────────────────
if ! docker image inspect "$IMAGE" &>/dev/null; then
  echo "Building Docker image $IMAGE ..."
  docker build -t "$IMAGE" -f Dockerfile .
  echo "Docker image $IMAGE built"
else
  echo "Docker image $IMAGE ready"
fi

# ── 4. Build in Docker ──────────────────────────────────────────
echo "Building $BINARY (in Docker)..."
# Run as root inside the container so CGo (stdlib.h etc.) works fine.
# GOCACHE uses /tmp so it is cleaned up each run — small price for correctness.
docker run --rm \
  -v "$SCRIPT_DIR":/workspace \
  -w /workspace \
  -e GOFLAGS="-buildvcs=false" \
  -e GOCACHE=/tmp/gocache \
  -e GOPROXY="https://goproxy.cn,direct" \
  "$IMAGE" \
  go build -o "$BINARY" .

# ── 5. Verify ───────────────────────────────────────────────────
if [[ -f "$BINARY" ]]; then
  echo "$BINARY built ($(du -h "$BINARY" | cut -f1))"
  echo "Note: binary is owned by root. Run: sudo chown \$USER:\$USER $BINARY"
else
  echo "Build failed: $BINARY not found"
  exit 1
fi

echo "Done: $BINARY"