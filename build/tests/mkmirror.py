#!/usr/bin/env python3
"""Build a static mirror that looks like Nexus Repository 3 for smoke tests.

  mkmirror.py --out DIR [--uv-lock LOCK ...] [--npm-lock LOCK ...]

PyPI: DIR/pypi/simple/<name>/index.html links to
      ../../packages/<name>/<version>/<file>#sha256=<hex>  (Nexus PyPI proxy layout)
npm:  DIR/npm/<package path>/-/<file>.tgz             (npm registry tarball layout)

Artifacts are downloaded once from their original public URLs and verified
against the lock hashes; serve DIR with serve.py.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import html
import json
import tomllib
import urllib.parse
import urllib.request
from pathlib import Path

PYPI_INDEX = "https://pypi.org/simple"
NPM_REGISTRY = "https://registry.npmjs.org/"


def download(url: str, dest: Path, check) -> None:
    if dest.is_file() and check(dest.read_bytes()):
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url, timeout=120) as response:
        data = response.read()
    if not check(data):
        raise SystemExit(f"hash mismatch for {url}")
    dest.write_bytes(data)


def pypi(out: Path, lock: Path) -> None:
    data = tomllib.loads(lock.read_text(encoding="utf-8"))
    pages: dict[str, list[str]] = {}
    for package in data.get("package", []):
        if package.get("source", {}).get("registry") != PYPI_INDEX:
            continue
        name, version = package["name"], package["version"]
        for artifact in ([package["sdist"]] if "sdist" in package else []) + package.get("wheels", []):
            filename = urllib.parse.unquote(artifact["url"].rsplit("/", 1)[-1])
            digest = artifact["hash"].partition(":")[2]
            download(artifact["url"], out / "pypi/packages" / name / version / filename,
                     lambda b, d=digest: hashlib.sha256(b).hexdigest() == d)
            href = f"../../packages/{name}/{version}/{urllib.parse.quote(filename)}#sha256={digest}"
            pages.setdefault(name, []).append(f'<a href="{html.escape(href)}">{html.escape(filename)}</a><br/>')
    for name, links in pages.items():
        page = out / "pypi/simple" / name / "index.html"
        page.parent.mkdir(parents=True, exist_ok=True)
        page.write_text("<!DOCTYPE html><html><body>\n" + "\n".join(links) + "\n</body></html>\n", encoding="utf-8")
    index = out / "pypi/simple/index.html"
    names = sorted(p.name for p in (out / "pypi/simple").iterdir() if p.is_dir())
    index.write_text("<!DOCTYPE html><html><body>\n"
                     + "\n".join(f'<a href="{n}/">{n}</a><br/>' for n in names) + "\n</body></html>\n",
                     encoding="utf-8")


def npm(out: Path, lock: Path) -> None:
    data = json.loads(lock.read_text(encoding="utf-8"))
    for key, entry in data.get("packages", {}).items():
        url = entry.get("resolved", "")
        if not url.startswith(NPM_REGISTRY):
            continue
        algorithm, _, expected = entry["integrity"].partition("-")
        download(url, out / "npm" / url[len(NPM_REGISTRY):],
                 lambda b, a=algorithm, e=expected: base64.b64encode(hashlib.new(a, b).digest()).decode() == e)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--uv-lock", type=Path, action="append", default=[])
    parser.add_argument("--npm-lock", type=Path, action="append", default=[])
    args = parser.parse_args()
    for lock in args.uv_lock:
        pypi(args.out, lock)
    for lock in args.npm_lock:
        npm(args.out, lock)
    print(f"mirror ready in {args.out}")


if __name__ == "__main__":
    main()
