#!/usr/bin/env python3
"""Run a program as a plain Windows child process and exit with its status.

  spawn.py PROGRAM [ARGS...]

build/smoke-test.sh starts the bundled Git Bash through this native hop, as the
.cmd launchers do through cmd.exe. Called straight from another MSYS
installation (the runner's Git Bash), the bundled bash would be treated as an
MSYS child: the environment does not arrive and the caller waits for every
background descendant.

Every argument is double-quoted (MSVC escaping): the MSYS runtime parses the
command line itself and also takes ' as a quote outside double quotes.
"""
from __future__ import annotations

import subprocess
import sys

BACKSLASH = chr(92)


def quote(arg: str) -> str:
    out, slashes = ['"'], 0
    for ch in arg:
        if ch == BACKSLASH:
            slashes += 1
            continue
        out.append(BACKSLASH * (2 * slashes + 1) + '"' if ch == '"' else BACKSLASH * slashes + ch)
        slashes = 0
    out.append(BACKSLASH * (2 * slashes) + '"')
    return "".join(out)


if __name__ == "__main__":
    sys.exit(subprocess.call(" ".join(quote(arg) for arg in sys.argv[1:])))
