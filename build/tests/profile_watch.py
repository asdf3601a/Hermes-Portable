#!/usr/bin/env python3
"""Find what a test run wrote into the real Windows profile.

  profile_watch.py mark STAMP_FILE
  profile_watch.py report STAMP_FILE [--exclude DIR]... ROOT...

`mark` records the current time. `report` walks every ROOT (the real
%USERPROFILE%, %APPDATA% and %LOCALAPPDATA% of the build host) and prints one
line per file created or modified after the mark, and per directory created
after it (its contents are summarized, not listed):

  HARD <path>          a Hermes Portable leak (the portable folder owns all state)
  SOFT <path>          written by Windows itself while programs ran (registry
                       hives, Microsoft\\ caches, the Direct3D shader cache, crash dumps)
  TEMP <count> files   under %TEMP%: not configuration, reported as a count

Reparse points (junctions such as "Application Data") are not followed.
"""
from __future__ import annotations

import os
import stat
import sys
import time
from pathlib import Path

SOFT_PARTS = (
    "\\ntuser.dat", "\\ntuser.ini", "\\appdata\\local\\microsoft\\", "\\appdata\\roaming\\microsoft\\",
    "\\appdata\\local\\d3dscache\\", "\\appdata\\local\\crashdumps\\", "\\appdata\\local\\packages\\",
    "\\appdata\\local\\connecteddevicesplatform\\",
)
LIMIT = 40


def norm(path: str) -> str:
    # realpath expands 8.3 short names: hosted runners set TEMP=C:\Users\RUNNER~1\...
    return os.path.normcase(os.path.realpath(path)).rstrip("\\") + "\\"


def walk(top: str, since: float, excluded: tuple[str, ...], found: dict[str, str]) -> None:
    try:
        entries = list(os.scandir(top))
    except OSError:
        return
    for entry in entries:
        key = norm(entry.path)
        if key.startswith(excluded) or key in found:
            continue
        try:
            st = entry.stat(follow_symlinks=False)
        except OSError:
            continue
        born = getattr(st, "st_birthtime", st.st_ctime)
        if st.st_file_attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT:
            continue
        if entry.is_dir(follow_symlinks=False):
            if born >= since:
                count = sum(len(files) for _, _, files in os.walk(entry.path))
                found[key] = f"{entry.path}\\  (new folder, {count} files)"
            else:
                walk(entry.path, since, excluded, found)
        elif max(born, st.st_mtime) >= since:
            found[key] = entry.path


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[0] == "mark":
        Path(argv[1]).write_text(repr(time.time()), encoding="utf-8")
        return 0
    if len(argv) < 3 or argv[0] != "report":
        print(__doc__, file=sys.stderr)
        return 2
    since = float(Path(argv[1]).read_text(encoding="utf-8"))
    rest, excluded, roots = argv[2:], [], []
    while rest:
        arg = rest.pop(0)
        if arg == "--exclude" and rest:
            excluded.append(norm(rest.pop(0)))
        else:
            roots.append(arg)
    temp = norm(os.environ.get("TEMP") or os.environ.get("TMP") or "")
    found: dict[str, str] = {}
    unique = {norm(r): os.path.abspath(r) for r in roots if r and os.path.isdir(r)}
    outer = [k for k in sorted(unique, key=len) if not any(k != o and k.startswith(o) for o in unique)]
    for key in outer:  # %APPDATA% usually lies inside %USERPROFILE%: walk it once
        walk(unique[key], since, tuple(excluded) + ((temp,) if temp != "\\" else ()), found)
    hard = [p for k, p in sorted(found.items()) if not any(part in k for part in SOFT_PARTS)]
    soft = [p for k, p in sorted(found.items()) if any(part in k for part in SOFT_PARTS)]
    for kind, paths in (("HARD", hard), ("SOFT", soft)):
        for path in paths[:LIMIT]:
            print(f"{kind} {path}")
        if len(paths) > LIMIT:
            print(f"{kind} ... {len(paths) - LIMIT} more")
    if temp != "\\" and os.path.isdir(temp):
        temp_files: dict[str, str] = {}
        walk(temp, since, tuple(excluded), temp_files)
        print(f"TEMP {len(temp_files)} entries under {temp.rstrip(chr(92))}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
