#!/usr/bin/env python3
"""
Filters cursor-agent NDJSON stream output for readability.

- For {"type":"thinking","subtype":"delta",...,"text":"..."} lines:
  prints only the .text field *without* an extra newline (so deltas stitch together).
- Everything else passes through unchanged.

This is intentionally conservative: it only changes console rendering and does not
try to interpret other event types.
"""

from __future__ import annotations

import json
import sys


def main() -> int:
    in_thinking = False
    last_session_id: str | None = None

    for raw in sys.stdin:
        line = raw.rstrip("\n")

        # Fast-path: only attempt JSON parsing when it looks like the specific event.
        if (
            line.startswith("{")
            and '"type":"thinking"' in line
            and '"subtype":"delta"' in line
            and '"text"' in line
        ):
            try:
                obj = json.loads(line)
            except Exception:
                obj = None

            if isinstance(obj, dict) and obj.get("type") == "thinking" and obj.get("subtype") == "delta":
                text = obj.get("text")
                if isinstance(text, str) and text:
                    session_id = obj.get("session_id")
                    if isinstance(session_id, str) and session_id:
                        if in_thinking and last_session_id and session_id != last_session_id:
                            sys.stdout.write("\n")
                        last_session_id = session_id

                    in_thinking = True
                    sys.stdout.write(text)
                    # If a delta ends a sentence, start a new line for whatever follows.
                    # (This improves readability of stitched thinking output.)
                    if text.endswith("."):
                        sys.stdout.write("\n")
                        in_thinking = False
                    sys.stdout.flush()
                    continue

        # Any non-thinking line ends the stitched thinking output (add newline once).
        if in_thinking:
            sys.stdout.write("\n")
            sys.stdout.flush()
            in_thinking = False
            last_session_id = None

        sys.stdout.write(raw)
        sys.stdout.flush()

    # Ensure we don't leave the prompt stuck on the same line.
    if in_thinking:
        sys.stdout.write("\n")
        sys.stdout.flush()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())


