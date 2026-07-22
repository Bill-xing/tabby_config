#!/usr/bin/env python3
"""Print a credential-free proxy endpoint as host<TAB>port."""

import re
import sys
from urllib.parse import urlsplit


DEFAULT_PORTS = {
    "http": 80,
    "https": 443,
    "socks": 1080,
    "socks5": 1080,
    "socks5h": 1080,
}
HOST_PATTERN = re.compile(r"^[A-Za-z0-9._:-]+$")


def fail() -> None:
    print("invalid proxy URL", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    if len(sys.argv) != 2:
        fail()

    raw_url = sys.stdin.read() if sys.argv[1] == "-" else sys.argv[1]
    raw_url = raw_url.strip()
    if "://" not in raw_url:
        raw_url = f"http://{raw_url}"

    try:
        parsed = urlsplit(raw_url)
        host = parsed.hostname
        port = parsed.port
    except ValueError:
        fail()

    if parsed.netloc.endswith(":"):
        fail()

    if not host or not HOST_PATTERN.fullmatch(host):
        fail()

    if port is None:
        port = DEFAULT_PORTS.get(parsed.scheme.lower())
    if port is None or not 1 <= port <= 65535:
        fail()

    print(f"{host}\t{port}")


if __name__ == "__main__":
    main()
