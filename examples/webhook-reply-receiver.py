#!/usr/bin/env python3
"""Capture one ZeroClaw webhook reply on loopback, then exit."""

from __future__ import annotations

import argparse
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any

MAX_BODY_BYTES = 1_048_576


class ReplyHandler(BaseHTTPRequestHandler):
    server: "ReplyServer"

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/replies":
            self.send_error(404)
            return

        raw_length = self.headers.get("Content-Length")
        try:
            length = int(raw_length or "")
        except ValueError:
            self.send_error(400, "invalid Content-Length")
            return
        if length < 1 or length > MAX_BODY_BYTES:
            self.send_error(413, "reply body size is out of bounds")
            return

        raw = self.rfile.read(length)
        try:
            payload: Any = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError):
            self.send_error(400, "reply body must be JSON")
            return
        if not isinstance(payload, dict) or not isinstance(payload.get("content"), str):
            self.send_error(400, "reply JSON must contain string content")
            return

        output = self.server.output_path
        output.parent.mkdir(parents=True, exist_ok=True)
        temporary = output.with_suffix(output.suffix + ".tmp")
        temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        os.replace(temporary, output)

        self.send_response(204)
        self.end_headers()
        self.server.captured = True

    def log_message(self, message: str, *args: object) -> None:
        print(f"receiver: {message % args}")


class ReplyServer(HTTPServer):
    output_path: Path
    captured: bool


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Capture one ZeroClaw webhook reply on 127.0.0.1 and exit."
    )
    parser.add_argument("--port", type=int, default=8091)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if not 1024 <= args.port <= 65535:
        raise SystemExit("port must be between 1024 and 65535")

    server = ReplyServer(("127.0.0.1", args.port), ReplyHandler)
    server.output_path = args.output.resolve()
    server.captured = False
    print(f"receiver: listening on http://127.0.0.1:{args.port}/replies")
    server.handle_request()
    server.server_close()
    if not server.captured:
        raise SystemExit("receiver: first request was not a valid ZeroClaw reply")
    print(f"receiver: captured one reply at {server.output_path}")


if __name__ == "__main__":
    main()
