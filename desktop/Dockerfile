# Build image for compiling voice_note desktop (Go + Fyne + sherpa-onnx).
# Fyne requires OpenGL + X11/Wayland development headers at compile time.
# sherpa-onnx-go ships prebuilt .so files; ALSA headers are needed for audio capture.
#
# The Go toolchain tarball is cached in build/deps/ (downloaded once by the
# host) and copied into the image, so rebuilds never hit the network.

FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    # Go + CGo essentials
    ca-certificates gcc pkg-config \
    # Fyne: OpenGL rendering
    libgl1-mesa-dev libegl1-mesa-dev libgles2-mesa-dev \
    # Fyne: X11 window system
    libx11-dev libxrandr-dev libxcursor-dev libxinerama-dev libxi-dev \
    # Fyne: Wayland
    libwayland-dev wayland-protocols libxkbcommon-dev \
    # Audio capture (ALSA)
    libasound2-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.24 from the host-cached tarball (see build/deps/).
ARG GO_VERSION=1.24.13
COPY build/deps/go${GO_VERSION}.linux-amd64.tar.gz /tmp/go.tar.gz
RUN tar -C /usr/local -xzf /tmp/go.tar.gz && rm /tmp/go.tar.gz

ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOTOOLCHAIN=local

WORKDIR /workspace