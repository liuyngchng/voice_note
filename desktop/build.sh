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

# ── Model sources (edit to point to your model files) ───────────
# Linux: point to the directory containing model.onnx, tokens.txt, etc.
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
echo "Building $BINARY (in Docker)..."
# Run as root inside the container so CGo (stdlib.h etc.) works fine.
# GOCACHE uses /tmp so it is cleaned up each run — small price for correctness.
docker run --rm \
  -v "$SCRIPT_DIR":/workspace \
  -w /workspace \
  -e GOFLAGS="-buildvcs=false" \
  -e GOCACHE=/tmp/gocache \
  -e GOPROXY="https://goproxy.cn,direct" \
  ${DOCKER_RUN_ENV[@]+"${DOCKER_RUN_ENV[@]}"} \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  "$IMAGE" \
  bash -c "
    go build -o '$BINARY' . && \
    patchelf --set-rpath '\$ORIGIN' '$BINARY' && \
    chown \$HOST_UID:\$HOST_GID '$BINARY' && \
    echo 'RPATH fixed to \$ORIGIN'
  "

# ── 5. Package into tar.gz ─────────────────────────────────────────
echo "Packaging..."

# Check model files exist
MODEL_FILES=("model.onnx" "tokens.txt" "silero_vad.onnx" "punct_ct_transformer.onnx")
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
TMP_DIR=$(mktemp -d)
trap "rm -rf '$TMP_DIR'" EXIT

PKG_NAME="voice-note-desktop-$(date +%Y%m%d)"
PKG_DIR="$TMP_DIR/$PKG_NAME"
mkdir -p "$PKG_DIR/models"

# Binary and .so — small, copy is fine
cp "$BINARY" "$PKG_DIR/"
cp "$SCRIPT_DIR"/*.so "$PKG_DIR/"

# Models — symlink to avoid duplicating 1.2GB on disk
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
for f in model.onnx tokens.txt silero_vad.onnx punct_ct_transformer.onnx; do
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

ARCHIVE="$SCRIPT_DIR/build/$PKG_NAME.tar"
mkdir -p "$SCRIPT_DIR/build"
tar -cf "$ARCHIVE" -C "$TMP_DIR" --dereference "$PKG_NAME"

echo "Package: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
echo "Binary + .so also available in $SCRIPT_DIR/ for local run."