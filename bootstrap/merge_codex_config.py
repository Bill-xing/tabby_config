#!/usr/bin/env python3
"""Safely merge repository-managed Codex TOML assignments into config.toml."""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

try:
    import tomllib
except ImportError:  # pragma: no cover - structural validation is used below.
    tomllib = None  # type: ignore[assignment]


BARE_KEY_RE = re.compile(r"^[A-Za-z0-9_-]+$")


class MergeError(ValueError):
    """Raised when a document cannot be merged without ambiguity."""


@dataclass(frozen=True)
class Header:
    index: int
    path: tuple[str, ...]
    is_array: bool


@dataclass(frozen=True)
class Assignment:
    start: int
    end: int
    table: tuple[str, ...]
    key: tuple[str, ...]
    rhs: str

    @property
    def full_path(self) -> tuple[str, ...]:
        return self.table + self.key


@dataclass
class Document:
    lines: list[str]
    headers: list[Header]
    assignments: list[Assignment]


@dataclass
class ManagedGroup:
    path: tuple[str, ...]
    header: str | None
    keys: list[tuple[str, ...]]
    assignments: dict[tuple[str, ...], str]


def read_text(path: Path) -> str:
    with path.open("r", encoding="utf-8", newline="") as handle:
        return handle.read()


def validate_toml(text: str, label: str) -> None:
    if tomllib is None:
        return
    try:
        tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        raise MergeError(f"malformed {label}: {exc}") from exc


def strip_line_ending(line: str) -> str:
    if line.endswith("\r\n"):
        return line[:-2]
    if line.endswith(("\n", "\r")):
        return line[:-1]
    return line


def newline_style(text: str) -> str:
    for index, char in enumerate(text):
        if char == "\n":
            return "\r\n" if index and text[index - 1] == "\r" else "\n"
        if char == "\r":
            return "\r\n" if index + 1 < len(text) and text[index + 1] == "\n" else "\r"
    return "\n"


def extract_single_path(value: object, *, array_header: bool = False) -> tuple[str, ...]:
    path: list[str] = []
    current = value
    while isinstance(current, dict) and len(current) == 1:
        key, current = next(iter(current.items()))
        path.append(key)
    if array_header and isinstance(current, list) and len(current) == 1:
        current = current[0]
    if current != {}:
        raise MergeError("unsupported TOML key expression")
    return tuple(path)


def parse_key_path(expression: str) -> tuple[str, ...]:
    if tomllib is None:
        path: list[str] = []
        index = 0
        while index < len(expression):
            while index < len(expression) and expression[index].isspace():
                index += 1
            if index >= len(expression):
                break
            if expression[index] in ('"', "'"):
                quote = expression[index]
                index += 1
                value: list[str] = []
                escaped = False
                while index < len(expression):
                    char = expression[index]
                    if quote == '"' and escaped:
                        escapes = {
                            '"': '"',
                            "\\": "\\",
                            "b": "\b",
                            "t": "\t",
                            "n": "\n",
                            "f": "\f",
                            "r": "\r",
                        }
                        if char not in escapes:
                            raise MergeError(f"unsupported quoted TOML key: {expression}")
                        value.append(escapes[char])
                        escaped = False
                    elif quote == '"' and char == "\\":
                        escaped = True
                    elif char == quote:
                        index += 1
                        break
                    else:
                        value.append(char)
                    index += 1
                else:
                    raise MergeError(f"unterminated quoted TOML key: {expression}")
                path.append("".join(value))
            else:
                start = index
                while index < len(expression) and expression[index] not in ". \t":
                    index += 1
                key = expression[start:index]
                if not BARE_KEY_RE.fullmatch(key):
                    raise MergeError(f"unsupported TOML key expression: {expression}")
                path.append(key)
            while index < len(expression) and expression[index].isspace():
                index += 1
            if index == len(expression):
                break
            if expression[index] != ".":
                raise MergeError(f"unsupported TOML key expression: {expression}")
            index += 1
        if not path:
            raise MergeError("empty TOML key expression")
        return tuple(path)
    try:
        parsed = tomllib.loads(f"{expression} = {{}}\n")
    except tomllib.TOMLDecodeError as exc:
        raise MergeError(f"unsupported TOML key expression: {expression}") from exc
    return extract_single_path(parsed)


def parse_header_path(expression: str, is_array: bool) -> tuple[str, ...]:
    if tomllib is None:
        return parse_key_path(expression)
    marker = "[[" if is_array else "["
    closer = "]]" if is_array else "]"
    try:
        parsed = tomllib.loads(f"{marker}{expression}{closer}\n")
    except tomllib.TOMLDecodeError as exc:
        raise MergeError(f"unsupported TOML table header: {expression}") from exc
    return extract_single_path(parsed, array_header=is_array)


def find_unquoted(text: str, target: str) -> int | None:
    quote: str | None = None
    escaped = False
    for index, char in enumerate(text):
        if quote == '"':
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
        elif quote == "'":
            if char == quote:
                quote = None
        elif char in ('"', "'"):
            quote = char
        elif char == target:
            return index
    return None


def parse_header_line(line: str) -> tuple[str, bool] | None:
    stripped = strip_line_ending(line).lstrip()
    if not stripped.startswith("["):
        return None
    is_array = stripped.startswith("[[")
    opening = 2 if is_array else 1
    quote: str | None = None
    escaped = False
    index = opening
    while index < len(stripped):
        char = stripped[index]
        if quote == '"':
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
        elif quote == "'":
            if char == quote:
                quote = None
        elif char in ('"', "'"):
            quote = char
        elif char == "]":
            closing = 2 if is_array else 1
            if is_array and stripped[index : index + 2] != "]]":
                index += 1
                continue
            rest = stripped[index + closing :].lstrip()
            if rest and not rest.startswith("#"):
                raise MergeError(f"unsupported table header line: {stripped}")
            return stripped[opening:index], is_array
        index += 1
    raise MergeError(f"unterminated table header: {stripped}")


def value_is_complete(rhs: str) -> bool:
    if tomllib is None:
        value = rhs.lstrip()
        if not value:
            return False
        if value.startswith(('"""', "'''")):
            delimiter = value[:3]
            return value.find(delimiter, 3) >= 0
        if value[0] in ('"', "'"):
            quote = value[0]
            escaped = False
            for index, char in enumerate(value[1:], 1):
                if quote == '"' and escaped:
                    escaped = False
                elif quote == '"' and char == "\\":
                    escaped = True
                elif char == quote:
                    rest = value[index + 1 :].strip()
                    return not rest or rest.startswith("#")
            return False
        if value[0] in "[{":
            pairs = {"[": "]", "{": "}"}
            stack: list[str] = []
            quote: str | None = None
            escaped = False
            comment = False
            for index, char in enumerate(value):
                if comment:
                    if char in "\r\n":
                        comment = False
                    continue
                if quote == '"':
                    if escaped:
                        escaped = False
                    elif char == "\\":
                        escaped = True
                    elif char == quote:
                        quote = None
                    continue
                if quote == "'":
                    if char == quote:
                        quote = None
                    continue
                if char in ('"', "'"):
                    quote = char
                elif char == "#":
                    comment = True
                elif char in pairs:
                    stack.append(pairs[char])
                elif char in "]}":
                    if not stack or stack.pop() != char:
                        return False
                    if not stack:
                        rest = value[index + 1 :].strip()
                        return not rest or rest.startswith("#")
            return False
        return bool(value.split("#", 1)[0].strip())
    try:
        tomllib.loads(f"__codex_merge_value = {rhs}")
    except tomllib.TOMLDecodeError:
        return False
    return True


def parse_document(text: str, label: str) -> Document:
    validate_toml(text, label)
    lines = text.splitlines(keepends=True)
    headers: list[Header] = []
    assignments: list[Assignment] = []
    current_table: tuple[str, ...] = ()
    index = 0

    while index < len(lines):
        content = strip_line_ending(lines[index])
        stripped = content.strip()
        if not stripped or stripped.startswith("#"):
            index += 1
            continue

        header = parse_header_line(lines[index])
        if header is not None:
            expression, is_array = header
            current_table = parse_header_path(expression, is_array)
            headers.append(Header(index, current_table, is_array))
            index += 1
            continue

        equals = find_unquoted(content, "=")
        if equals is None:
            raise MergeError(f"unsupported {label} line: {content}")
        key = parse_key_path(content[:equals].strip())
        end = index + 1
        rhs = lines[index][equals + 1 :]
        while not value_is_complete(rhs) and end < len(lines):
            rhs += lines[end]
            end += 1
        if not value_is_complete(rhs):
            raise MergeError(f"unsupported multiline value in {label}")
        assignments.append(Assignment(index, end, current_table, key, rhs))
        index = end

    if tomllib is None:
        ordinary_tables: set[tuple[str, ...]] = set()
        for header in headers:
            if not header.is_array:
                if header.path in ordinary_tables:
                    raise MergeError(f"duplicate table in {label}: {header.path}")
                ordinary_tables.add(header.path)
        assigned: set[tuple[str, ...]] = set()
        for assignment in assignments:
            if assignment.full_path in assigned:
                raise MergeError(f"duplicate key in {label}: {assignment.full_path}")
            assigned.add(assignment.full_path)

    return Document(lines, headers, assignments)


def unsafe_managed_value(assignment: Assignment) -> bool:
    value = assignment.rhs.lstrip()
    return assignment.end != assignment.start + 1 or value.startswith(
        ("{", '"""', "'''")
    )


def parse_fragment(fragment: str) -> tuple[list[ManagedGroup], dict[tuple[str, ...], str]]:
    document = parse_document(fragment, "fragment")
    if not document.assignments:
        raise MergeError("fragment must contain at least one managed assignment")
    if any(header.is_array for header in document.headers):
        raise MergeError("array-of-table fragment headers are not safe to merge")

    header_lines = {
        header.path: strip_line_ending(document.lines[header.index]).strip()
        for header in document.headers
    }
    if len(header_lines) != len(document.headers):
        raise MergeError("duplicate fragment tables are not safe to merge")

    group_order: list[tuple[str, ...]] = []
    if any(assignment.table == () for assignment in document.assignments):
        group_order.append(())
    for header in document.headers:
        if header.path not in group_order:
            group_order.append(header.path)

    groups = {
        path: ManagedGroup(path, None if not path else header_lines[path], [], {})
        for path in group_order
    }
    managed_lines: dict[tuple[str, ...], str] = {}
    for assignment in document.assignments:
        if assignment.table not in groups:
            raise MergeError("fragment table without an explicit header is not safe to merge")
        if len(assignment.key) != 1:
            raise MergeError("dotted fragment keys are not safe to merge")
        if unsafe_managed_value(assignment):
            raise MergeError(
                "multiline or inline-table fragment value is not safe to merge: "
                f"{assignment.full_path}"
            )
        if assignment.full_path in managed_lines:
            raise MergeError(f"duplicate fragment key is not safe to merge: {assignment.full_path}")
        line = strip_line_ending(document.lines[assignment.start])
        groups[assignment.table].keys.append(assignment.key)
        groups[assignment.table].assignments[assignment.key] = line
        managed_lines[assignment.full_path] = line

    empty_tables = [group.header for group in groups.values() if not group.keys]
    if empty_tables:
        raise MergeError(f"fragment tables must contain managed keys: {empty_tables[0]}")
    return [groups[path] for path in group_order], managed_lines


def is_prefix(prefix: tuple[str, ...], path: tuple[str, ...]) -> bool:
    return len(prefix) <= len(path) and path[: len(prefix)] == prefix


def check_existing_safety(
    document: Document,
    groups: list[ManagedGroup],
    managed_lines: dict[tuple[str, ...], str],
) -> dict[tuple[str, ...], Assignment]:
    group_paths = {group.path for group in groups if group.path}
    managed_paths = set(managed_lines)
    table_counts: dict[tuple[str, ...], int] = {}

    for header in document.headers:
        if header.path in group_paths:
            table_counts[header.path] = table_counts.get(header.path, 0) + 1
            if header.is_array:
                raise MergeError(f"managed table cannot be an array: {header.path}")
        if header.is_array and any(
            is_prefix(header.path, path) or is_prefix(path, header.path)
            for path in group_paths | managed_paths
        ):
            raise MergeError(f"array table conflicts with managed config: {header.path}")
    duplicates = [path for path, count in table_counts.items() if count > 1]
    if duplicates:
        raise MergeError(f"duplicate managed table is not safe to merge: {duplicates[0]}")

    found: dict[tuple[str, ...], Assignment] = {}
    for assignment in document.assignments:
        full_path = assignment.full_path
        exact_managed = full_path in managed_paths
        if exact_managed:
            if len(assignment.key) != 1:
                raise MergeError(f"dotted managed key is not safe to merge: {full_path}")
            if unsafe_managed_value(assignment):
                raise MergeError(
                    "multiline or inline-table managed value is not safe to merge: "
                    f"{full_path}"
                )
            if full_path in found:
                raise MergeError(f"duplicate managed key is not safe to merge: {full_path}")
            found[full_path] = assignment
            continue

        if any(is_prefix(full_path, path) or is_prefix(path, full_path) for path in managed_paths):
            raise MergeError(f"assignment conflicts with managed key: {full_path}")
        for group_path in group_paths:
            if is_prefix(full_path, group_path):
                raise MergeError(f"assignment conflicts with managed table: {full_path}")
            if is_prefix(group_path, full_path) and not is_prefix(group_path, assignment.table):
                raise MergeError(f"dotted assignment conflicts with managed table: {full_path}")

    return found


def section_end(document: Document, path: tuple[str, ...]) -> int:
    if not path:
        return document.headers[0].index if document.headers else len(document.lines)
    for header_index, header in enumerate(document.headers):
        if header.path == path and not header.is_array:
            if header_index + 1 < len(document.headers):
                return document.headers[header_index + 1].index
            return len(document.lines)
    raise MergeError(f"managed table was not found: {path}")


def line_for_output(line: str, newline: str) -> str:
    return f"{strip_line_ending(line)}{newline}"


def apply_owned_keys(
    document: Document,
    groups: list[ManagedGroup],
    managed_lines: dict[tuple[str, ...], str],
    found: dict[tuple[str, ...], Assignment],
    newline: str,
) -> list[str]:
    lines = list(document.lines)
    if lines and not lines[-1].endswith(("\n", "\r")):
        lines[-1] += newline
    replacements = {
        assignment.start: line_for_output(managed_lines[path], newline)
        for path, assignment in found.items()
    }
    insertions: dict[int, list[str]] = {}
    existing_tables = {header.path for header in document.headers if not header.is_array}

    for group in groups:
        if group.path and group.path not in existing_tables:
            continue
        missing = [key for key in group.keys if group.path + key not in found]
        if not missing:
            continue
        insertion = section_end(document, group.path)
        while insertion > 0 and not strip_line_ending(document.lines[insertion - 1]).strip():
            insertion -= 1
        insertions.setdefault(insertion, []).extend(
            line_for_output(group.assignments[key], newline) for key in missing
        )

    output: list[str] = []
    for index in range(len(lines) + 1):
        output.extend(insertions.get(index, ()))
        if index < len(lines):
            output.append(replacements.get(index, lines[index]))
    return output


def insert_missing_table(lines: list[str], group: ManagedGroup, newline: str) -> list[str]:
    current = parse_document("".join(lines), "intermediate result")
    insert_at = len(lines)
    for header in current.headers:
        if len(header.path) > len(group.path) and is_prefix(group.path, header.path):
            insert_at = header.index
            break

    block = [line_for_output(group.header or "", newline)]
    block.extend(line_for_output(group.assignments[key], newline) for key in group.keys)
    if insert_at > 0 and strip_line_ending(lines[insert_at - 1]).strip():
        block.insert(0, newline)
    if insert_at < len(lines) and strip_line_ending(lines[insert_at]).strip():
        block.append(newline)
    return lines[:insert_at] + block + lines[insert_at:]


def merge_config(fragment: str, existing: str) -> str:
    groups, managed_lines = parse_fragment(fragment)
    if not existing:
        newline = newline_style(fragment)
        return fragment if fragment.endswith(("\n", "\r")) else f"{fragment}{newline}"

    document = parse_document(existing, "existing config")
    found = check_existing_safety(document, groups, managed_lines)
    newline = newline_style(existing)
    lines = apply_owned_keys(document, groups, managed_lines, found, newline)
    existing_tables = {header.path for header in document.headers if not header.is_array}
    for group in groups:
        if group.path and group.path not in existing_tables:
            lines = insert_missing_table(lines, group, newline)

    result = "".join(lines)
    if not result.endswith(("\n", "\r")):
        result += newline
    validate_toml(result, "merged result")
    return result


def main(argv: list[str]) -> int:
    if len(argv) not in (2, 3):
        print(f"usage: {argv[0]} FRAGMENT [EXISTING_CONFIG]", file=sys.stderr)
        return 2

    fragment_path = Path(argv[1])
    existing_path = Path(argv[2]) if len(argv) == 3 else None
    try:
        if not fragment_path.is_file():
            raise MergeError(f"fragment is not a readable file: {fragment_path}")
        if existing_path is not None and not existing_path.is_file():
            raise MergeError(f"existing config is not a readable file: {existing_path}")
        fragment = read_text(fragment_path)
        existing = read_text(existing_path) if existing_path is not None else ""
        merged = merge_config(fragment, existing)
    except (OSError, UnicodeError, MergeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    sys.stdout.write(merged)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
