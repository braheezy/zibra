#!/usr/bin/env bash
set -euo pipefail

# Run Zibra inside the base container and capture a screenshot.
# Optional: first arg is the URL to open (default: about:blank).

URL="${1:-about:blank}"
REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
OUT_DIR="$REPO_ROOT/out/screenshot"
LOG_DIR="$OUT_DIR/logs"
BIN_DIR="$OUT_DIR/bin"
IMAGE="zibra-screenshot-base"
BIN_PATH="$BIN_DIR/zibra-linux"

if [[ ! -f "$BIN_PATH" ]]; then
  echo "Missing $BIN_PATH. Run setup_zibra_screenshot.sh first." >&2
  exit 1
fi

mkdir -p "$LOG_DIR"

# Run the already-built binary under Xvfb and capture.
docker run --rm \
  -e DISPLAY=:99 \
  -e SDL_VIDEODRIVER=x11 \
  -e SDL_RENDER_DRIVER=software \
  -v "$BIN_PATH":/opt/zibra:ro \
  -v "$OUT_DIR":/workspace/out/screenshot \
  "$IMAGE" \
  bash -lc "\
    Xvfb :99 -screen 0 1280x720x24 >/tmp/xvfb.log 2>&1 & \
    XVFB_PID=\$!; \
    /opt/zibra '$URL' >'/workspace/out/screenshot/logs/zibra.log' 2>&1 & \
    ZIBRA_PID=\$!; \
    sleep 5; \
    import -window root '/workspace/out/screenshot/zibra.png'; \
    kill \$ZIBRA_PID >/dev/null 2>&1 || true; \
    kill \$XVFB_PID >/dev/null 2>&1 || true; \
  "

echo "$OUT_DIR/zibra.png"
