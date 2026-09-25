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
  echo "ERROR: run this script from the desktop_fun_asr_client/ directory"
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
    chown \$HOST_UID:\$HOST_GID '$BINARY' && \
    echo 'Build complete.'
  "

echo "Binary: $SCRIPT_DIR/$BINARY"