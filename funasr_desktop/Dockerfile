# Build image for compiling funasr-desktop-client (Go + Fyne).
# Fyne requires OpenGL + X11/Wayland development headers at compile time.
# ALSA headers are needed for microphone capture.
#
# The Go toolchain tarball is cached in build/deps/ (downloaded once by the
# host) and copied into the image, so rebuilds never hit the network.

FROM ubuntu:24.04

# Optional proxy for apt-get (passed via --build-arg, e.g. HTTP_PROXY=http://proxy:8080).
ARG HTTP_PROXY=""
ARG HTTPS_PROXY=""
ARG NO_PROXY=""
ENV HTTP_PROXY="$HTTP_PROXY" HTTPS_PROXY="$HTTPS_PROXY" NO_PROXY="$NO_PROXY" \
    http_proxy="$HTTP_PROXY" https_proxy="$HTTPS_PROXY" no_proxy="$NO_PROXY"

RUN if [ -n "$HTTP_PROXY" ]; then \
        echo "Acquire::http::Proxy \"$HTTP_PROXY\";" > /etc/apt/apt.conf.d/01proxy; \
    fi; \
    if [ -n "$HTTPS_PROXY" ]; then \
        echo "Acquire::https::Proxy \"$HTTPS_PROXY\";" >> /etc/apt/apt.conf.d/01proxy; \
    fi

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates gcc libc6-dev pkg-config \
    libgl1-mesa-dev libegl1-mesa-dev libgles2-mesa-dev \
    libx11-dev libxrandr-dev libxcursor-dev libxinerama-dev libxi-dev \
    libxxf86vm-dev \
    libwayland-dev wayland-protocols libxkbcommon-dev \
    libasound2-dev \
    patchelf \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.24 from host-cached tarball.
ARG GO_VERSION=1.24.13
COPY build/deps/go${GO_VERSION}.linux-amd64.tar.gz /tmp/go.tar.gz
RUN tar -C /usr/local -xzf /tmp/go.tar.gz && rm /tmp/go.tar.gz

ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOTOOLCHAIN=local

WORKDIR /workspace