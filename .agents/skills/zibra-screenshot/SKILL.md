---
name: zibra-screenshot
description: Capture a screenshot of Zibra running a page using a headless Linux Xvfb Docker container. Provides a setup step that builds a base container and a Linux Zibra binary, then a fast capture step that runs the prebuilt binary inside the container.
---

# Zibra Screenshot

## Overview

This skill captures a screenshot of Zibra rendering a page using a Linux Xvfb Docker container. It has a setup step to build the base container and produce a Linux binary on the host, then a fast capture step that runs that binary inside the container.

Output path:

`out/screenshot/zibra.png`

## Setup (Run Once or When Dependencies Change)

```bash
bash .agents/skills/zibra-screenshot/scripts/setup_zibra_screenshot.sh
```

This builds the base container and produces:

`out/screenshot/bin/zibra-linux`

## Capture (Fast Path)

```bash
bash .agents/skills/zibra-screenshot/scripts/capture_zibra_container.sh
```

Open a specific URL:

```bash
bash .agents/skills/zibra-screenshot/scripts/capture_zibra_container.sh "https://example.org"
```

## Outputs

- Screenshot file: `out/screenshot/zibra.png`
- Logs: `out/screenshot/logs/`
- Linux binary: `out/screenshot/bin/zibra-linux`

## Notes

- The setup step is required before the first capture.
- Re-run setup after changes to Zig toolchain, SDL dependencies, or if the binary becomes stale.

## Resources

### scripts/

- `scripts/setup_zibra_screenshot.sh`: Build base container and Linux binary
- `scripts/capture_zibra_container.sh`: Run prebuilt binary in container and capture
