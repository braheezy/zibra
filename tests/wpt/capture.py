"""Capture one local WPT fixture under the runner's process-group watchdog."""

import argparse
import sys

from run import WATCHDOG_GRACE_SECONDS, _invoke


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("browser")
    parser.add_argument("--wpt-test", required=True)
    parser.add_argument("--wpt-timeout-ms", required=True, type=int)
    args = parser.parse_args()
    if args.wpt_timeout_ms <= 0:
        parser.error("timeout must be positive")
    outcome = _invoke(
        [args.browser, "--wpt-test", args.wpt_test,
         "--wpt-timeout-ms", str(args.wpt_timeout_ms)],
        args.wpt_timeout_ms / 1000 + WATCHDOG_GRACE_SECONDS,
    )
    sys.stdout.write(outcome.stdout)
    sys.stderr.write(outcome.stderr)
    if outcome.infrastructure_error:
        print(outcome.infrastructure_error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
