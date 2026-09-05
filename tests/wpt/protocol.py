"""Framing shared by the WPT runner and real-browser fixture validator."""

import json


def parse_json_record(stdout: str) -> dict:
    # JSONL is delimited by LF, not Unicode's broader notion of a line break.
    # In particular U+0085/U+2028/U+2029 are legal inside JSON strings.
    lines = stdout.split("\n")
    if lines[-1] == "":
        lines.pop()
    if len(lines) != 1 or not lines[0].strip():
        raise ValueError(
            f"expected exactly one JSON result line, received {len(lines)}"
        )
    try:
        record = json.loads(lines[0])
    except json.JSONDecodeError as error:
        raise ValueError(f"invalid JSON result: {error.msg}") from error
    if not isinstance(record, dict):
        raise ValueError("JSON result must be an object")
    return record
