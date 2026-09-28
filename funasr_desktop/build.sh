#!/usr/bin/env bash
set -euo pipefail

# Build script for funasr-desktop-client (Go + Fyne).
# Compiles inside Docker using the same image as voice-note-desktop.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE="voice_note_fyne:1.0"
BINARY="funasr-desktop-client"
GO_VERSION="1.24.13"
GO_TAR="go${GO_VERSION}.linux-amd64.tar.gz"
GO_URL="https://golang.google.cn/dl/${GO_TAR}"
DEPS_DIR="$SCRIPT_DIR/build/deps"

# ── Optional proxy ──
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
HTTP_PROXY_VAL="${HTTP_PROXY_VAL:-${HTTP_PROXY:-${http_proxy:-}}}"
HTTPS_PROXY_VAL="${HTTPS_PROXY_VAL:-${HTTPS_PROXY:-${https_proxy:-}}}"
NO_PROXY_VAL="${NO_PROXY_VAL:-${NO_PROXY:-${no_proxy:-}}}"

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

# ── 1. Check prerequisites ──
if [[ ! -f "main.go" ]] || [[ ! -f "go.mod" ]]; then
  echo "ERROR: run this script from the fun_asr_desktop_client/ directory"
  exit 1
fi

if ! command -v docker &>/dev/null; then
  echo "ERROR: docker not found"
  exit 1
fi

# ── 2. Cache Go toolchain ──
# Reuse the tarball already cached by the voice-note-desktop build if present.
mkdir -p "$DEPS_DIR"
if [[ ! -f "$DEPS_DIR/$GO_TAR" && -f "/home/rd/workspace/voice_note/desktop/build/deps/$GO_TAR" ]]; then
  echo "Reusing Go $GO_VERSION tarball from desktop/build/deps"
  ln -s "/home/rd/workspace/voice_note/desktop/build/deps/$GO_TAR" "$DEPS_DIR/$GO_TAR" 2>/dev/null \
    || cp "/home/rd/workspace/voice_note/desktop/build/deps/$GO_TAR" "$DEPS_DIR/$GO_TAR"
fi
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

# ── 3. Build Docker image if missing ──
if ! docker image inspect "$IMAGE" &>/dev/null; then
  echo "Building Docker image $IMAGE ..."
  docker build "${DOCKER_BUILD_ARGS[@]}" -t "$IMAGE" -f Dockerfile .
  echo "Docker image $IMAGE built"
else
  echo "Docker image $IMAGE ready"
fi

# ── 4. Build in Docker ──
echo "Building $BINARY (in Docker)..."

# Persistent Go caches on the host so deps aren't re-downloaded every build.
GOCACHE_DIR="$SCRIPT_DIR/build/gocache"
GOMODCACHE_DIR="$SCRIPT_DIR/build/gomodcache"
mkdir -p "$GOCACHE_DIR" "$GOMODCACHE_DIR"

docker run --rm \
  -v "$SCRIPT_DIR":/workspace \
  -v "$GOCACHE_DIR":/tmp/gocache \
  -v "$GOMODCACHE_DIR":/go/pkg/mod \
  -w /workspace \
  -e GOFLAGS="-buildvcs=false" \
  -e GOCACHE=/tmp/gocache \
  -e GOMODCACHE=/go/pkg/mod \
  -e GOPROXY="https://goproxy.cn,direct" \
  ${DOCKER_RUN_ENV[@]+"${DOCKER_RUN_ENV[@]}"} \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  "$IMAGE" \
  bash -c "
    go build -o '$BINARY' . && \
    chown \$HOST_UID:\$HOST_GID '$BINARY' && \
    echo 'Build complete.'
  "

echo "Binary: $SCRIPT_DIR/$BINARY"

# ── 5. Install desktop integration (optional, host-side) ──
# Registers the app so docks show the proper (Chinese) name and icon. The
# WM_CLASS set in main.go must stay in sync with StartupWMClass below.
DESKTOP_FILE="$SCRIPT_DIR/funasr-desktop-client.desktop"
DESKTOP_INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/512x512/apps"

if [[ -f "$DESKTOP_FILE" ]]; then
  mkdir -p "$DESKTOP_INSTALL_DIR"
  # Set an absolute path so the entry works regardless of the launch directory.
  sed "s|^Exec=.*|Exec=$SCRIPT_DIR/$BINARY|" "$DESKTOP_FILE" > "$DESKTOP_INSTALL_DIR/funasr-desktop-client.desktop"
  echo "Installed desktop entry: $DESKTOP_INSTALL_DIR/funasr-desktop-client.desktop"

  # Install an icon if one is provided.
  for src in "$SCRIPT_DIR"/icon.png "$SCRIPT_DIR"/icon.svg; do
    if [[ -f "$src" ]]; then
      mkdir -p "$ICON_DIR"
      cp "$src" "$ICON_DIR/funasr-desktop-client.${src##*.}"
      echo "Installed icon: $ICON_DIR/funasr-desktop-client.${src##*.}"
      break
    fi
  done

  if command -v update-desktop-database &>/dev/null; then
    update-desktop-database "$DESKTOP_INSTALL_DIR" 2>/dev/null || true
  fi
fi