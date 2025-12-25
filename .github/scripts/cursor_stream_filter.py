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
import re
import sys


_TOKEN_REDACTIONS: list[tuple[re.Pattern[str], str]] = [
    # Match the same token-in-url pattern we already redact elsewhere in the workflow.
    (re.compile(r"(https://x-access-token:)[^@]+@"), r"\1***@"),
    # Common GitHub token prefixes.
    (re.compile(r"\b(ghp|github_pat)_[A-Za-z0-9_]+\b"), r"\1_***"),
]


def _redact(s: str) -> str:
    out = s
    for pattern, repl in _TOKEN_REDACTIONS:
        out = pattern.sub(repl, out)
    return out


def _extract_assistant_text(obj: dict) -> str | None:
    msg = obj.get("message")
    if not isinstance(msg, dict):
        return None
    content = msg.get("content")
    if not isinstance(content, list):
        return None
    parts: list[str] = []
    for item in content:
        if not isinstance(item, dict):
            continue
        if item.get("type") == "text":
            text = item.get("text")
            if isinstance(text, str) and text:
                parts.append(text)
    if not parts:
        return None
    return "\n".join(parts)


def _summarize_tool_call(obj: dict) -> str | None:
    tool_call = obj.get("tool_call")
    if not isinstance(tool_call, dict):
        return None

    # The cursor stream often wraps specific tool calls under keys like shellToolCall/grepToolCall.
    # We summarize conservatively and avoid dumping full JSON.
    if "shellToolCall" in tool_call and isinstance(tool_call["shellToolCall"], dict):
        args = tool_call["shellToolCall"].get("args")
        if isinstance(args, dict):
            cmd = args.get("command")
            if isinstance(cmd, str) and cmd.strip():
                return f"[tool:shell] { _redact(cmd.strip()) }"
        return "[tool:shell]"

    if "grepToolCall" in tool_call and isinstance(tool_call["grepToolCall"], dict):
        args = tool_call["grepToolCall"].get("args")
        if isinstance(args, dict):
            pat = args.get("pattern")
            path = args.get("path")
            if isinstance(pat, str) and isinstance(path, str):
                return f"[tool:grep] pattern={pat!r} path={path!r}"
        return "[tool:grep]"

    if "readToolCall" in tool_call and isinstance(tool_call["readToolCall"], dict):
        args = tool_call["readToolCall"].get("args")
        if isinstance(args, dict):
            p = args.get("path")
            if isinstance(p, str):
                return f"[tool:read] {p}"
        return "[tool:read]"

    if "updateTodosToolCall" in tool_call and isinstance(tool_call["updateTodosToolCall"], dict):
        return "[tool:todos] update"

    return "[tool]"


def main() -> int:
    in_thinking = False
    last_session_id: str | None = None

    def end_thinking_if_needed() -> None:
        nonlocal in_thinking, last_session_id
        if in_thinking:
            sys.stdout.write("\n")
            sys.stdout.flush()
            in_thinking = False
            last_session_id = None

    for raw in sys.stdin:
        line = raw.rstrip("\n")

        # We only try to parse JSON for dict-like lines; everything else is passthrough.
        obj: object | None = None
        if line.startswith("{") and '"type"' in line:
            try:
                obj = json.loads(line)
            except Exception:
                obj = None

        if isinstance(obj, dict):
            typ = obj.get("type")
            subtype = obj.get("subtype")

            if typ == "thinking" and subtype == "delta":
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

            # Hide the thinking "completed" JSON line; just end the stitched block.
            if typ == "thinking" and subtype == "completed":
                end_thinking_if_needed()
                continue

            # Render assistant messages as plain text.
            if typ == "assistant":
                end_thinking_if_needed()
                text = _extract_assistant_text(obj)
                if isinstance(text, str) and text:
                    sys.stdout.write(text)
                    if not text.endswith("\n"):
                        sys.stdout.write("\n")
                    sys.stdout.flush()
                    continue
                # If we can't extract text, fall through to a minimal summary.

            # Render tool call lifecycle events as one-liners.
            if typ == "tool_call":
                end_thinking_if_needed()
                summary = _summarize_tool_call(obj)
                if subtype == "started":
                    sys.stdout.write(f"{summary} (started)\n")
                    sys.stdout.flush()
                    continue
                if subtype == "completed":
                    sys.stdout.write(f"{summary} (completed)\n")
                    sys.stdout.flush()
                    continue

            # Render "result" messages as plain text if present.
            if typ == "result":
                end_thinking_if_needed()
                result = obj.get("result")
                if isinstance(result, str) and result:
                    sys.stdout.write(result)
                    if not result.endswith("\n"):
                        sys.stdout.write("\n")
                    sys.stdout.flush()
                    continue

            # Hide common noisy envelope events.
            if typ in {"system", "user"}:
                end_thinking_if_needed()
                continue

            # Unknown JSON event: print a minimal summary instead of full JSON.
            end_thinking_if_needed()
            if isinstance(typ, str):
                if isinstance(subtype, str) and subtype:
                    sys.stdout.write(f"[{typ}:{subtype}]\n")
                else:
                    sys.stdout.write(f"[{typ}]\n")
                sys.stdout.flush()
                continue

        sys.stdout.write(raw)
        sys.stdout.flush()

    # Ensure we don't leave the prompt stuck on the same line.
    end_thinking_if_needed()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())


