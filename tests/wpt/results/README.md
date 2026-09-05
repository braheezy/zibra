# Local WPT history

`run.py --report` writes one JSON report per run here. The Compose dashboard
mounts this directory read-only and keeps its history across container
restarts. Use timestamped filenames so later runs do not overwrite earlier
ones:

```sh
python3 tests/wpt/run.py tests/wpt/manifest.yaml \
  --mode all --browser ./zig-out/bin/zibra \
  --report tests/wpt/results/$(date -u +%Y%m%dT%H%M%SZ).json
```

The directory is ignored by Git because reports are generated artifacts. Back
it up or copy it to durable storage if the history must survive checkout or
machine changes.
