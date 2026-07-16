#!/usr/bin/env python3
"""Merge the repository's managed Codex TUI notification keys into config.toml."""

from __future__ import annotations

import re
import sys
from pathlib import Path


MANAGED_KEYS = (
    "notifications",
    "notification_method",
    "notification_condition",
)
TABLE_RE = re.compile(r"^\s*\[([^\[\]]+)\]\s*(?:#.*)?(?:\r?\n)?$")
ASSIGNMENT_RE = re.compile(r"^\s*([A-Za-z0-9_-]+)\s*=.*$")


class MergeError(ValueError):
    """Raised when a config cannot be merged without ambiguity."""


def read_text(path: Path) -> str:
    with path.open("r", encoding="utf-8", newline="") as handle:
        return handle.read()


def parse_fragment(fragment: str) -> tuple[str, dict[str, str]]:
    lines = fragment.splitlines(keepends=True)
    if not lines or not TABLE_RE.match(lines[0]) or TABLE_RE.match(lines[0]).group(1).strip() != "tui":
        raise MergeError("notification fragment must start with [tui]")

    managed: dict[str, str] = {}
    for line in lines[1:]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if TABLE_RE.match(line):
            raise MergeError("notification fragment must contain only one [tui] table")
        match = ASSIGNMENT_RE.match(line)
        if not match:
            raise MergeError(f"unsupported notification fragment line: {line.rstrip()}")
        key = match.group(1)
        if key not in MANAGED_KEYS:
            raise MergeError(f"unsupported notification fragment key: {key}")
        if key in managed:
            raise MergeError(f"duplicate notification fragment key: {key}")
        managed[key] = line if line.endswith(("\n", "\r")) else f"{line}\n"

    missing = [key for key in MANAGED_KEYS if key not in managed]
    if missing:
        raise MergeError(f"notification fragment is missing keys: {', '.join(missing)}")

    canonical = "[tui]\n" + "".join(managed[key] for key in MANAGED_KEYS)
    return canonical, managed


def table_name(line: str) -> str | None:
    match = TABLE_RE.match(line)
    return match.group(1).strip() if match else None


def managed_value_spans_multiple_lines(line: str) -> bool:
    value = line.split("=", 1)[1].split("#", 1)[0].strip()
    if value.startswith("[") and not value.endswith("]"):
        return True
    for delimiter in ('"""', "'''"):
        if value.startswith(delimiter) and value.count(delimiter) < 2:
            return True
    return False


def merge_config(fragment: str, existing: str) -> str:
    canonical, managed = parse_fragment(fragment)
    if not existing:
        return canonical

    lines = existing.splitlines(keepends=True)
    tui_headers: list[int] = []
    first_nested_tui: int | None = None
    section: str | None = None

    for index, line in enumerate(lines):
        name = table_name(line)
        if name is not None:
            section = name
            if name == "tui":
                tui_headers.append(index)
            elif name.startswith("tui.") and first_nested_tui is None:
                first_nested_tui = index
            continue

        if section is None:
            if re.match(r"^\s*tui\s*=", line):
                raise MergeError("top-level inline tui tables are not safe to merge")
            if re.match(r"^\s*tui\s*\.", line):
                raise MergeError("top-level dotted tui keys are not safe to merge")

    if len(tui_headers) > 1:
        raise MergeError("duplicate [tui] tables are not safe to merge")

    if not tui_headers:
        if first_nested_tui is None:
            separator = "" if existing.endswith(("\n\n", "\r\n\r\n")) else "\n"
            return f"{existing}{separator}{canonical}"

        insert_at = first_nested_tui
        prefix = lines[:insert_at]
        suffix = lines[insert_at:]
        if prefix and prefix[-1].strip():
            prefix.append("\n")
        return "".join(prefix) + canonical + "\n" + "".join(suffix)

    start = tui_headers[0]
    end = len(lines)
    for index in range(start + 1, len(lines)):
        if table_name(lines[index]) is not None:
            end = index
            break

    seen: set[str] = set()
    for index in range(start + 1, end):
        match = ASSIGNMENT_RE.match(lines[index])
        if not match:
            continue
        key = match.group(1)
        if key not in managed:
            continue
        if managed_value_spans_multiple_lines(lines[index]):
            raise MergeError(f"multiline [tui] key is not safe to merge: {key}")
        if key in seen:
            raise MergeError(f"duplicate [tui] key is not safe to merge: {key}")
        lines[index] = managed[key]
        seen.add(key)

    missing = [key for key in MANAGED_KEYS if key not in seen]
    if missing:
        insert_at = end
        while insert_at > start + 1 and not lines[insert_at - 1].strip():
            insert_at -= 1
        lines[insert_at:insert_at] = [managed[key] for key in missing]

    return "".join(lines)


def main(argv: list[str]) -> int:
    if len(argv) not in (2, 3):
        print(f"usage: {argv[0]} FRAGMENT [EXISTING_CONFIG]", file=sys.stderr)
        return 2

    fragment_path = Path(argv[1])
    existing_path = Path(argv[2]) if len(argv) == 3 else None
    try:
        fragment = read_text(fragment_path)
        existing = read_text(existing_path) if existing_path and existing_path.exists() else ""
        merged = merge_config(fragment, existing)
    except (OSError, UnicodeError, MergeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    sys.stdout.write(merged)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
