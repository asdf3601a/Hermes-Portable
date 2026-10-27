#!/usr/bin/env python3
"""Static HTTP(S) server for smoke tests.

  serve.py --root DIR --port N [--cert CERT --key KEY] [--log FILE] [--ready FILE]

Serves DIR (directory index.html files answer `/simple/<name>/`), appends
every request path to --log so tests can prove downloads came from the mirror,
and writes --ready once listening.
"""
from __future__ import annotations

import argparse
import functools
import http.server
import ssl
from pathlib import Path


class Handler(http.server.SimpleHTTPRequestHandler):
    log_file: Path | None = None

    def log_message(self, format, *args):  # noqa: A002 - stdlib signature
        if self.log_file is not None:
            with self.log_file.open("a", encoding="utf-8") as stream:
                stream.write(f"{self.command} {self.path} {args[1] if len(args) > 1 else ''}\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--cert")
    parser.add_argument("--key")
    parser.add_argument("--log", type=Path)
    parser.add_argument("--ready", type=Path)
    args = parser.parse_args()
    Handler.log_file = args.log
    handler = functools.partial(Handler, directory=str(args.root))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), handler)
    if args.cert:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(args.cert, args.key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    if args.ready:
        args.ready.write_text("ready\n", encoding="utf-8")
    server.serve_forever()


if __name__ == "__main__":
    main()
