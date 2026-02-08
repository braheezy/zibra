#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
OUT_DIR="$REPO_ROOT/out/screenshot"
LOG_DIR="$OUT_DIR/logs"
BIN_DIR="$OUT_DIR/bin"
IMAGE="zibra-screenshot-base"

mkdir -p "$LOG_DIR" "$BIN_DIR"

cat > "$LOG_DIR/Dockerfile.screenshot-base" <<'DOCKER'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
     ca-certificates \
     curl \
     git \
     xz-utils \
     xvfb \
     imagemagick \
     scrot \
     fonts-dejavu-core \
     fonts-noto-core \
     fonts-noto-cjk \
     fonts-noto-color-emoji \
     fonts-liberation \
     libsdl2-2.0-0 \
     libsdl2-ttf-2.0-0 \
     libsdl2-ttf-dev \
     libfreetype6 \
     libfontconfig1 \
     libharfbuzz0b \
     libpng16-16 \
     libjpeg-turbo8 \
     libssl3 \
     libstdc++6 \
  && rm -rf /var/lib/apt/lists/*

# Provide flat font paths that Zibra's Linux font loader expects.
RUN mkdir -p /usr/share/fonts/google-noto \
    /usr/share/fonts/google-noto-sans-cjk-vf-fonts \
    /usr/share/fonts/google-noto-color-emoji-fonts \
  && cp -f /usr/share/fonts/truetype/noto/NotoSans-Regular.ttf /usr/share/fonts/google-noto/NotoSans-Regular.ttf \
  && cp -f /usr/share/fonts/truetype/noto/NotoSans-Bold.ttf /usr/share/fonts/google-noto/NotoSans-Bold.ttf \
  && cp -f /usr/share/fonts/truetype/noto/NotoSans-Italic.ttf /usr/share/fonts/google-noto/NotoSans-Italic.ttf \
  && cp -f /usr/share/fonts/truetype/noto/NotoSans-BoldItalic.ttf /usr/share/fonts/google-noto/NotoSans-BoldItalic.ttf \
  && cp -f /usr/share/fonts/truetype/noto/NotoColorEmoji.ttf /usr/share/fonts/google-noto-color-emoji-fonts/NotoColorEmoji.ttf \
  && cp -f /usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc /usr/share/fonts/google-noto-sans-cjk-vf-fonts/NotoSansCJK-VF.ttc \
  && cp -f /usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf /usr/share/fonts/google-noto/DejaVuSansMono.ttf \
  && cp -f /usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf /usr/share/fonts/google-noto/DejaVuSansMono-Bold.ttf \
  && cp -f /usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf /usr/share/fonts/google-noto/DejaVuSansMono-Oblique.ttf \
  && cp -f /usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf /usr/share/fonts/google-noto/DejaVuSansMono-BoldOblique.ttf

# Install Zig
RUN case "$TARGETARCH" in \
      amd64) ZIG_ARCH=x86_64 ;; \
      arm64) ZIG_ARCH=aarch64 ;; \
      *) echo "Unsupported arch: $TARGETARCH" && exit 1 ;; \
    esac \
  && ZIG_VERSION=0.15.2 \
  && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
  && mkdir -p /opt/zig \
  && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
  && rm /tmp/zig.tar.xz

ENV PATH="/opt/zig:${PATH}"
WORKDIR /workspace
DOCKER

docker build -f "$LOG_DIR/Dockerfile.screenshot-base" -t "$IMAGE" "$REPO_ROOT"

# Build the Linux binary inside the container and copy it out.
docker run --rm \
  -v "$REPO_ROOT":/workspace \
  -v "$BIN_DIR":/out \
  -v "${HOME}/.cache/zig":/zig-cache \
  "$IMAGE" \
  bash -lc "\
    cd /workspace; \
    ZIG_GLOBAL_CACHE_DIR=/zig-cache ZIG_LOCAL_CACHE_DIR=/workspace/.zig-cache-local zig build >'/out/zig-build.log' 2>&1; \
    cp /workspace/zig-out/bin/zibra /out/zibra-linux; \
  "

echo "$BIN_DIR/zibra-linux"
