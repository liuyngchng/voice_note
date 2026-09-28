#!/usr/bin/env bash
set -euo pipefail

# Build script for voice_note desktop (Go + Fyne + sherpa-onnx).
# Compiles inside Docker — outputs both Linux and Windows binaries.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE="voice_note_fyne:1.0"
BINARY="voice-note-desktop"
GO_VERSION="1.24.13"
GO_TAR="go${GO_VERSION}.linux-amd64.tar.gz"
GO_URL="https://golang.google.cn/dl/${GO_TAR}"
DEPS_DIR="$SCRIPT_DIR/build/deps"

# ── Model sources (edit to point to your model files) ───────────
# Linux: point to the directory containing model.int8.onnx, tokens.txt, etc.
# Default: ~/.voicenote/models (the app's own data dir)
MODEL_SRC="${MODEL_SRC:-$HOME/.voicenote/models}"

# ── Optional proxy (build.sh http_proxy=... https_proxy=... no_proxy=...) ──
HTTP_PROXY_VAL=""
HTTPS_PROXY_VAL=""
NO_PROXY_VAL=""
for arg in "$@"; do
  case "$arg" in
    http_proxy=*|HTTP_PROXY=*)   HTTP_PROXY_VAL="${arg#*=}" ;;
    https_proxy=*|HTTPS_PROXY=*) HTTPS_PROXY_VAL="${arg#*=}" ;;
    no_proxy=*|NO_PROXY=*)       NO_PROXY_VAL="${arg#*=}" ;;
    *) echo "WARNING: ignoring unknown arg: $arg" ;;
  esac
done
# Fall back to env vars if not passed on command line.
HTTP_PROXY_VAL="${HTTP_PROXY_VAL:-${HTTP_PROXY:-${http_proxy:-}}}"
HTTPS_PROXY_VAL="${HTTPS_PROXY_VAL:-${HTTPS_PROXY:-${https_proxy:-}}}"
NO_PROXY_VAL="${NO_PROXY_VAL:-${NO_PROXY:-${no_proxy:-}}}"

# Ensure http:// scheme (apt / wget / Docker all need it).
add_scheme() { local v="$1"; [[ -z "$v" || "$v" == *"://"* ]] && { printf '%s' "$v"; return; }; printf 'http://%s' "$v"; }
HTTP_PROXY_VAL="$(add_scheme "$HTTP_PROXY_VAL")"
HTTPS_PROXY_VAL="$(add_scheme "$HTTPS_PROXY_VAL")"

DOCKER_BUILD_ARGS=()
DOCKER_RUN_ENV=()
if [[ -n "$HTTP_PROXY_VAL" || -n "$HTTPS_PROXY_VAL" ]]; then
  echo "Proxy: http=${HTTP_PROXY_VAL:-<none>} https=${HTTPS_PROXY_VAL:-<none>} no_proxy=${NO_PROXY_VAL:-<none>}"
  export HTTP_PROXY="$HTTP_PROXY_VAL" HTTPS_PROXY="$HTTPS_PROXY_VAL"
  export http_proxy="$HTTP_PROXY_VAL" https_proxy="$HTTPS_PROXY_VAL"
  export NO_PROXY="$NO_PROXY_VAL"     no_proxy="$NO_PROXY_VAL"
  DOCKER_BUILD_ARGS=(--build-arg "HTTP_PROXY=$HTTP_PROXY_VAL" --build-arg "HTTPS_PROXY=$HTTPS_PROXY_VAL" --build-arg "NO_PROXY=$NO_PROXY_VAL")
  DOCKER_RUN_ENV=(-e "HTTP_PROXY=$HTTP_PROXY_VAL" -e "HTTPS_PROXY=$HTTPS_PROXY_VAL" -e "NO_PROXY=$NO_PROXY_VAL" -e "http_proxy=$HTTP_PROXY_VAL" -e "https_proxy=$HTTPS_PROXY_VAL" -e "no_proxy=$NO_PROXY_VAL")
fi

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
# Note: Go is downloaded here as part of the Docker build environment (see
# Dockerfile), so the container always has a known-good Go version regardless
# of what the host has installed. The tarball is cached in build/deps/ to
# avoid re-downloading every run.
mkdir -p "$DEPS_DIR"
if [[ ! -f "$DEPS_DIR/$GO_TAR" ]]; then
  echo "Downloading Go $GO_VERSION ..."
  if [[ -n "$HTTP_PROXY_VAL" || -n "$HTTPS_PROXY_VAL" ]]; then
    wget -q --show-progress -e use_proxy=yes "$GO_URL" -O "$DEPS_DIR/$GO_TAR"
  else
    wget -q --show-progress "$GO_URL" -O "$DEPS_DIR/$GO_TAR"
  fi
  echo "Go tarball cached at build/deps/$GO_TAR"
else
  echo "Go $GO_VERSION cached ($(du -h "$DEPS_DIR/$GO_TAR" | cut -f1))"
fi

# ── 3. Build Docker image if missing ────────────────────────────
if ! docker image inspect "$IMAGE" &>/dev/null; then
  echo "Building Docker image $IMAGE ..."
  docker build "${DOCKER_BUILD_ARGS[@]}" -t "$IMAGE" -f Dockerfile .
  echo "Docker image $IMAGE built"
else
  echo "Docker image $IMAGE ready"
fi

# ── 4. Build in Docker ──────────────────────────────────────────

# Persistent Go caches on the host so deps aren't re-downloaded every build.
GOCACHE_DIR="$SCRIPT_DIR/build/gocache"
GOMODCACHE_DIR="$SCRIPT_DIR/build/gomodcache"
mkdir -p "$GOCACHE_DIR" "$GOMODCACHE_DIR" "$SCRIPT_DIR/dist"

COMMON_ENV=(
  -e GOFLAGS="-buildvcs=false"
  -e GOCACHE=/tmp/gocache
  -e GOMODCACHE=/go/pkg/mod
  -e GOPROXY="https://goproxy.cn,direct"
  -e CGO_ENABLED=1
  -e HOST_UID="$(id -u)"
  -e HOST_GID="$(id -g)"
)

# ── 4a. Linux binary ────────────────────────────────────────────
echo ""
echo "=== Building ${BINARY} (Linux) ==="
docker run --rm \
  -v "$SCRIPT_DIR":/workspace \
  -v "$GOCACHE_DIR":/tmp/gocache \
  -v "$GOMODCACHE_DIR":/go/pkg/mod \
  -w /workspace \
  "${COMMON_ENV[@]}" \
  ${DOCKER_RUN_ENV[@]+"${DOCKER_RUN_ENV[@]}"} \
  -e GOOS=linux \
  -e GOARCH=amd64 \
  "$IMAGE" \
  bash -c "
    go build -ldflags='-s -w' -o dist/${BINARY} . && \
    patchelf --set-rpath '\$ORIGIN' dist/${BINARY} && \
    chown \$HOST_UID:\$HOST_GID dist/${BINARY} && \
    echo 'Linux build complete (RPATH fixed to \$ORIGIN).'
  "

# ── 4b. Windows .exe ────────────────────────────────────────────
echo ""
echo "=== Building ${BINARY}.exe (Windows) ==="
docker run --rm \
  -v "$SCRIPT_DIR":/workspace \
  -v "$GOCACHE_DIR":/tmp/gocache \
  -v "$GOMODCACHE_DIR":/go/pkg/mod \
  -w /workspace \
  "${COMMON_ENV[@]}" \
  ${DOCKER_RUN_ENV[@]+"${DOCKER_RUN_ENV[@]}"} \
  -e GOOS=windows \
  -e GOARCH=amd64 \
  -e CC=x86_64-w64-mingw32-gcc \
  "$IMAGE" \
  bash -c "
    go build -ldflags='-s -w -H windowsgui' -o dist/${BINARY}.exe . && \
    chown \$HOST_UID:\$HOST_GID dist/${BINARY}.exe && \
    echo 'Windows build complete.'
  "

echo ""
echo "=== Build complete ==="
echo "  Linux:   dist/${BINARY}     ($(du -h "$SCRIPT_DIR/dist/${BINARY}" | cut -f1))"
echo "  Windows: dist/${BINARY}.exe ($(du -h "$SCRIPT_DIR/dist/${BINARY}.exe" | cut -f1))"

# ── 5. Windows packaging (zip with .exe + DLLs) ────────────────────
echo ""
echo "Packaging Windows distribution..."

# Temp directory for packaging (shared with Linux packaging step).
TMP_DIR=$(mktemp -d)
trap "rm -rf '$TMP_DIR'" EXIT

WIN_SHERPA_DLL_DIR="$GOMODCACHE_DIR/github.com/k2-fsa/sherpa-onnx-go-windows@v1.13.6/lib/x86_64-pc-windows-gnu"
# Fall back to host GOPATH in case the project cache doesn't have it yet.
if [[ ! -d "$WIN_SHERPA_DLL_DIR" ]]; then
  WIN_SHERPA_DLL_DIR="$HOME/go/pkg/mod/github.com/k2-fsa/sherpa-onnx-go-windows@v1.13.6/lib/x86_64-pc-windows-gnu"
fi

if [[ -d "$WIN_SHERPA_DLL_DIR" ]]; then
  WIN_PKG_NAME="voice-note-desktop-windows-$(date +%Y%m%d)"
  WIN_PKG_DIR="$TMP_DIR/$WIN_PKG_NAME"
  mkdir -p "$WIN_PKG_DIR"

  cp "dist/${BINARY}.exe" "$WIN_PKG_DIR/"
  cp "$WIN_SHERPA_DLL_DIR"/*.dll "$WIN_PKG_DIR/"

  # Write a README for Windows users.
  cat > "$WIN_PKG_DIR/README.txt" << 'WINEOF'
Voice Note - Windows 版本使用说明
==================================

运行前请确保以下文件在同一目录中：
  voice-note-desktop.exe    主程序
  onnxruntime.dll           ONNX Runtime 运行库
  sherpa-onnx-c-api.dll     Sherpa-ONNX 运行库
  sherpa-onnx-cxx-api.dll   Sherpa-ONNX C++ 运行库

模型文件需要放在以下位置之一：
  1. 程序同目录下的 models/ 目录（便携模式，优先级最高）
  2. %APPDATA%\VoiceNote\models\ 目录

模型文件列表：
  - model.int8.onnx        (SenseVoiceSmall 模型)
  - tokens.txt             (词表)
  - silero_vad.onnx        (语音端点检测，可选)
  - punct_ct_transformer.onnx (标点模型，可选)

用户数据（数据库、设置、录音输出）存放在 %APPDATA%\VoiceNote\ 下。
WINEOF

  WIN_ARCHIVE="$SCRIPT_DIR/dist/$WIN_PKG_NAME.zip"
  rm -f "$WIN_ARCHIVE"
  zip -jr "$WIN_ARCHIVE" "$WIN_PKG_DIR"
  echo "Windows package: dist/$WIN_PKG_NAME.zip ($(du -h "$WIN_ARCHIVE" | cut -f1))"
else
  echo "WARNING: Windows sherpa-onnx DLLs not found; skipping Windows package."
  echo "  Expected at: $WIN_SHERPA_DLL_DIR"
fi

# ── 6. Linux packaging (tar.gz with models + .so) ─────────────────
echo ""
echo "Packaging Linux distribution..."

# Check model files exist
MODEL_FILES=("model.int8.onnx" "tokens.txt" "silero_vad.onnx" "punct_ct_transformer.onnx")
for mf in "${MODEL_FILES[@]}"; do
  if [[ ! -f "$MODEL_SRC/$mf" ]]; then
    echo "ERROR: model file not found: $MODEL_SRC/$mf"
    echo "  Set MODEL_SRC env var to the directory containing model files, or"
    echo "  download them to ~/.voicenote/models/ first."
    exit 1
  fi
done
echo "Model source: $MODEL_SRC"

# Copy .so files alongside binary for local run
SHERPA_LIB_DIR="$HOME/go/pkg/mod/github.com/k2-fsa/sherpa-onnx-go-linux@v1.13.6/lib/x86_64-unknown-linux-gnu"
if [[ -d "$SHERPA_LIB_DIR" ]]; then
  rm -f "$SCRIPT_DIR"/*.so
  cp "$SHERPA_LIB_DIR"/*.so "$SCRIPT_DIR/"
else
  echo "WARNING: sherpa-onnx .so dir not found at $SHERPA_LIB_DIR"
fi

# Create distributable tarball.
# Uses symlinks to avoid copying 1.2GB of model files into a temp directory.

PKG_NAME="voice-note-desktop-$(date +%Y%m%d)"
PKG_DIR="$TMP_DIR/$PKG_NAME"
mkdir -p "$PKG_DIR/models"

# Binary and .so — small, copy is fine
cp "dist/$BINARY" "$PKG_DIR/"
cp "$SCRIPT_DIR"/*.so "$PKG_DIR/"

# Models — symlink to avoid duplicating ~520MB on disk
for mf in "${MODEL_FILES[@]}"; do
  ln -s "$(readlink -f "$MODEL_SRC/$mf")" "$PKG_DIR/models/$mf"
done

# install script
cat > "$PKG_DIR/install.sh" << 'INSTEOF'
#!/usr/bin/env bash
set -euo pipefail
DEST="${1:-$HOME/.local/bin}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$DEST"
cp "$SCRIPT_DIR"/voice-note-desktop "$DEST/"
cp "$SCRIPT_DIR"/*.so "$DEST/"

# Install models to ~/.voicenote/models/ if not already present
MODEL_DIR="$HOME/.voicenote/models"
mkdir -p "$MODEL_DIR"
for f in model.int8.onnx tokens.txt silero_vad.onnx punct_ct_transformer.onnx; do
  if [[ ! -f "$MODEL_DIR/$f" ]]; then
    cp "$SCRIPT_DIR/models/$f" "$MODEL_DIR/"
    echo "Model installed: $f"
  else
    echo "Model already exists: $f"
  fi
done

echo "Voice Note installed to $DEST/voice-note-desktop"
echo "Models at $MODEL_DIR/"
echo ""
echo "Launch the app, then go to Settings → 桌面集成 to create a desktop shortcut."
INSTEOF
chmod +x "$PKG_DIR/install.sh"

ARCHIVE="$SCRIPT_DIR/dist/$PKG_NAME.tar"
mkdir -p "$SCRIPT_DIR/dist"
tar -cf "$ARCHIVE" -C "$TMP_DIR" --dereference "$PKG_NAME"

echo "Linux package: dist/$PKG_NAME.tar ($(du -h "$ARCHIVE" | cut -f1))"
echo "Binary + .so also available in $SCRIPT_DIR/ for local run."