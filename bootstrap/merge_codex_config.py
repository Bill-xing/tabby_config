#!/usr/bin/env python3
"""Safely merge repository-managed Codex TOML assignments into config.toml."""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from datetime import date, datetime, time
from pathlib import Path

try:
    import tomllib
except ImportError:  # pragma: no cover - structural validation is used below.
    tomllib = None  # type: ignore[assignment]


BARE_KEY_RE = re.compile(r"^[A-Za-z0-9_-]+$")
DECIMAL_INTEGER_RE = re.compile(r"[+-]?(?:0|[1-9](?:_?\d)*)$")
BASE_INTEGER_RE = re.compile(
    r"(?:0x[0-9A-Fa-f](?:_?[0-9A-Fa-f])*|0o[0-7](?:_?[0-7])*|0b[01](?:_?[01])*)$"
)
FLOAT_RE = re.compile(
    r"[+-]?(?:(?:0|[1-9](?:_?\d)*)\.\d(?:_?\d)*"
    r"(?:[eE][+-]?\d(?:_?\d)*)?"
    r"|(?:0|[1-9](?:_?\d)*)[eE][+-]?\d(?:_?\d)*|inf|nan)$"
)
LOCAL_DATE_RE = re.compile(r"\d{4}-\d{2}-\d{2}$")
LOCAL_TIME_RE = re.compile(r"\d{2}:\d{2}:\d{2}(?:\.\d+)?$")
DATE_TIME_RE = re.compile(
    r"\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(?:\.\d+)?"
    r"(?:Z|[+-]\d{2}:\d{2})?$"
)


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


@dataclass
class NamespaceNode:
    kind: str


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


def validate_fallback_characters(text: str, label: str) -> None:
    for index, char in enumerate(text):
        codepoint = ord(char)
        forbidden = (
            codepoint <= 0x08
            or codepoint in (0x0B, 0x0C)
            or 0x0E <= codepoint <= 0x1F
            or codepoint == 0x7F
        )
        if forbidden:
            line = text.count("\n", 0, index) + 1
            raise MergeError(
                f"malformed {label}: forbidden control character "
                f"U+{codepoint:04X} on line {line}"
            )


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
            next_segment = index
            while next_segment < len(expression) and expression[next_segment].isspace():
                next_segment += 1
            if next_segment == len(expression) or expression[next_segment] == ".":
                raise MergeError(f"empty dotted TOML key segment: {expression}")
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


class FallbackValueParser:
    """Validate the common TOML subset used by Codex without reserializing it.

    The fallback accepts strings, numbers, booleans, ISO-style date/time values,
    arrays, and single-line inline tables. Unsupported forms fail closed.
    """

    def __init__(self, text: str, label: str) -> None:
        self.text = text
        self.label = label
        self.index = 0
        self.inline_depth = 0

    def error(self, message: str) -> MergeError:
        return MergeError(f"malformed {self.label} value: {message}")

    def parse(self) -> None:
        self.skip_space_and_comments()
        self.parse_value()
        self.skip_space_and_comments()
        if self.index != len(self.text):
            raise self.error("unexpected content after value")

    def skip_space_and_comments(self) -> None:
        while self.index < len(self.text):
            char = self.text[self.index]
            if char in " \t\r\n":
                if self.inline_depth and char in "\r\n":
                    raise self.error("inline tables must stay on one line")
                self.index += 1
            elif char == "#":
                if self.inline_depth:
                    raise self.error("comments are not supported inside inline tables")
                newline = self.text.find("\n", self.index)
                self.index = len(self.text) if newline < 0 else newline + 1
            else:
                return

    def parse_value(self) -> None:
        if self.index >= len(self.text):
            raise self.error("missing value")
        if self.text.startswith('"""', self.index):
            self.parse_basic_string(multiline=True)
        elif self.text.startswith("'''", self.index):
            self.parse_literal_string(multiline=True)
        elif self.text[self.index] == '"':
            self.parse_basic_string(multiline=False)
        elif self.text[self.index] == "'":
            self.parse_literal_string(multiline=False)
        elif self.text[self.index] == "[":
            self.parse_array()
        elif self.text[self.index] == "{":
            self.parse_inline_table()
        else:
            self.parse_bare_value()

    def parse_basic_string(self, *, multiline: bool) -> None:
        if multiline and self.inline_depth:
            raise self.error("multiline strings are not supported inside inline tables")
        delimiter = '"""' if multiline else '"'
        self.index += len(delimiter)
        while self.index < len(self.text):
            if self.text.startswith(delimiter, self.index):
                self.index += len(delimiter)
                return
            char = self.text[self.index]
            if char == "\\":
                self.index += 1
                if self.index >= len(self.text):
                    raise self.error("unterminated escape sequence")
                escaped = self.text[self.index]
                if multiline and escaped in "\r\n":
                    if escaped == "\r" and self.index + 1 < len(self.text):
                        if self.text[self.index + 1] == "\n":
                            self.index += 1
                    self.index += 1
                    while self.index < len(self.text) and self.text[self.index] in " \t\r\n":
                        self.index += 1
                    continue
                if escaped in '"\\btnfr':
                    self.index += 1
                    continue
                if escaped in "uU":
                    digits = 4 if escaped == "u" else 8
                    codepoint = self.text[self.index + 1 : self.index + 1 + digits]
                    if len(codepoint) != digits or not re.fullmatch(
                        rf"[0-9A-Fa-f]{{{digits}}}", codepoint
                    ):
                        raise self.error("invalid Unicode escape")
                    value = int(codepoint, 16)
                    if value > 0x10FFFF or 0xD800 <= value <= 0xDFFF:
                        raise self.error("invalid Unicode code point")
                    self.index += digits + 1
                    continue
                raise self.error(f"invalid escape sequence: \\{escaped}")
            if not multiline and char in "\r\n":
                raise self.error("basic string crosses a line boundary")
            if (ord(char) < 0x20 and char not in ("\t", "\n", "\r")) or ord(char) == 0x7F:
                raise self.error("control character in basic string")
            self.index += 1
        raise self.error("unterminated basic string")

    def parse_literal_string(self, *, multiline: bool) -> None:
        if multiline and self.inline_depth:
            raise self.error("multiline strings are not supported inside inline tables")
        delimiter = "'''" if multiline else "'"
        self.index += len(delimiter)
        closing = self.text.find(delimiter, self.index)
        if closing < 0:
            raise self.error("unterminated literal string")
        content = self.text[self.index : closing]
        if not multiline and any(char in content for char in "\r\n"):
            raise self.error("literal string crosses a line boundary")
        if any(
            (ord(char) < 0x20 and char not in ("\t", "\n", "\r"))
            or ord(char) == 0x7F
            for char in content
        ):
            raise self.error("control character in literal string")
        self.index = closing + len(delimiter)

    def parse_array(self) -> None:
        self.index += 1
        self.skip_space_and_comments()
        if self.consume("]"):
            return
        while True:
            self.parse_value()
            self.skip_space_and_comments()
            if self.consume("]"):
                return
            if not self.consume(","):
                raise self.error("array values must be comma-separated")
            self.skip_space_and_comments()
            if self.consume("]"):
                return

    def parse_inline_table(self) -> None:
        self.index += 1
        self.inline_depth += 1
        paths: set[tuple[str, ...]] = set()
        try:
            self.skip_space_and_comments()
            if self.consume("}"):
                return
            while True:
                key = self.parse_inline_key()
                if any(is_prefix(key, path) or is_prefix(path, key) for path in paths):
                    raise self.error(f"duplicate or colliding inline-table key: {key}")
                paths.add(key)
                self.skip_space_and_comments()
                if not self.consume("="):
                    raise self.error("inline-table key is missing '='")
                self.skip_space_and_comments()
                self.parse_value()
                self.skip_space_and_comments()
                if self.consume("}"):
                    return
                if not self.consume(","):
                    raise self.error("inline-table values must be comma-separated")
                self.skip_space_and_comments()
                if self.index < len(self.text) and self.text[self.index] == "}":
                    raise self.error("inline tables cannot have a trailing comma")
        finally:
            self.inline_depth -= 1

    def parse_inline_key(self) -> tuple[str, ...]:
        start = self.index
        quote: str | None = None
        escaped = False
        while self.index < len(self.text):
            char = self.text[self.index]
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
            elif char == "=":
                expression = self.text[start:self.index].strip()
                if not expression:
                    raise self.error("empty inline-table key")
                return parse_key_path(expression)
            elif char in "\r\n#},":
                raise self.error("invalid inline-table key")
            self.index += 1
        raise self.error("unterminated inline table")

    def parse_bare_value(self) -> None:
        start = self.index
        while self.index < len(self.text) and self.text[self.index] not in " \t\r\n,#]}":
            self.index += 1
        token = self.text[start:self.index]
        if not token or not self.valid_bare_token(token):
            raise self.error(f"invalid bare value: {token or '<empty>'}")

    @staticmethod
    def valid_bare_token(token: str) -> bool:
        if token in ("true", "false", "+inf", "-inf", "inf", "+nan", "-nan", "nan"):
            return True
        if DECIMAL_INTEGER_RE.fullmatch(token) or BASE_INTEGER_RE.fullmatch(token):
            return True
        if FLOAT_RE.fullmatch(token):
            return True
        if DATE_TIME_RE.fullmatch(token):
            normalized = token[:-1] + "+00:00" if token.endswith("Z") else token
            parser = datetime.fromisoformat
        elif LOCAL_DATE_RE.fullmatch(token):
            normalized = token
            parser = date.fromisoformat
        elif LOCAL_TIME_RE.fullmatch(token):
            normalized = token
            parser = time.fromisoformat
        else:
            return False
        try:
            parser(normalized)
        except ValueError:
            return False
        return True

    def consume(self, expected: str) -> bool:
        if self.text.startswith(expected, self.index):
            self.index += len(expected)
            return True
        return False


class FallbackNamespace:
    """Reject duplicate/colliding paths while preserving simple array tables.

    Repeated array-of-table headers and their direct keys are supported. Tables
    nested below an array element are deliberately rejected by this fallback.
    """

    def __init__(self, label: str) -> None:
        self.label = label
        self.symbols: dict[tuple[str, ...], NamespaceNode] = {}
        self.array_counts: dict[tuple[str, ...], int] = {}
        self.array_scopes: dict[
            tuple[tuple[str, ...], int], dict[tuple[str, ...], NamespaceNode]
        ] = {}

    def error(self, message: str, path: tuple[str, ...]) -> MergeError:
        return MergeError(f"malformed {self.label}: {message}: {path}")

    def define_table(
        self, path: tuple[str, ...], is_array: bool
    ) -> tuple[tuple[str, ...], int] | None:
        for length in range(1, len(path)):
            prefix = path[:length]
            node = self.symbols.get(prefix)
            if node and node.kind in ("value", "dotted", "array"):
                raise self.error(
                    "table parent collides with an existing value or sealed table",
                    prefix,
                )
            self.symbols.setdefault(prefix, NamespaceNode("implicit"))

        node = self.symbols.get(path)
        if is_array:
            if node is None or node.kind == "implicit":
                self.symbols[path] = NamespaceNode("array")
            elif node.kind != "array":
                raise self.error("array table collides with an existing symbol", path)
            count = self.array_counts.get(path, 0) + 1
            self.array_counts[path] = count
            scope = (path, count)
            self.array_scopes[scope] = {}
            return scope

        if node is None or node.kind == "implicit":
            self.symbols[path] = NamespaceNode("table")
            return None
        raise self.error("duplicate or colliding table", path)

    def define_assignment(
        self,
        table: tuple[str, ...],
        key: tuple[str, ...],
        array_scope: tuple[tuple[str, ...], int] | None,
    ) -> None:
        if array_scope is not None and table == array_scope[0]:
            symbols = self.array_scopes[array_scope]
            self.define_value_path(symbols, key, ())
            return
        self.define_value_path(self.symbols, table + key, table)

    def define_value_path(
        self,
        symbols: dict[tuple[str, ...], NamespaceNode],
        path: tuple[str, ...],
        table: tuple[str, ...],
    ) -> None:
        for length in range(1, len(path)):
            prefix = path[:length]
            node = symbols.get(prefix)
            if node and node.kind in ("value", "array"):
                raise self.error("key parent collides with an existing value", prefix)
            if node is None:
                kind = "implicit" if is_prefix(prefix, table) else "dotted"
                symbols[prefix] = NamespaceNode(kind)
        if path in symbols:
            raise self.error("duplicate or colliding key", path)
        symbols[path] = NamespaceNode("value")


def validate_fallback_document(document: Document, label: str) -> None:
    namespace = FallbackNamespace(label)
    headers = {header.index: header for header in document.headers}
    assignments = {assignment.start: assignment for assignment in document.assignments}
    current_array_scope: tuple[tuple[str, ...], int] | None = None

    for index in range(len(document.lines)):
        header = headers.get(index)
        if header is not None:
            current_array_scope = namespace.define_table(header.path, header.is_array)
            continue
        assignment = assignments.get(index)
        if assignment is None:
            continue
        FallbackValueParser(assignment.rhs, label).parse()
        namespace.define_assignment(assignment.table, assignment.key, current_array_scope)


def parse_document(text: str, label: str) -> Document:
    if tomllib is None:
        validate_fallback_characters(text, label)
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
        validate_fallback_document(Document(lines, headers, assignments), label)

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
        if any(is_prefix(path, header.path) for path in managed_paths):
            raise MergeError(f"table conflicts with managed scalar key: {header.path}")
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
        result = fragment if fragment.endswith(("\n", "\r")) else f"{fragment}{newline}"
        parse_document(result, "merged result")
        return result

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
    parse_document(result, "merged result")
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
