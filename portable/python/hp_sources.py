#!/usr/bin/env python3
"""Hermes Portable package-source switcher (stdlib only).

Switches the lock files themselves between their original public sources and
a Nexus (or any PEP 503 / npm-compatible) mirror. Names, versions and hashes
never change; only download locations do, so `uv sync --frozen` and `npm ci`
fetch from the mirror while still verifying every artifact against the
original lock's hashes.

  hp_sources.py --root DIR status [--json]
  hp_sources.py --root DIR pypi use-nexus [--index-url URL] [--mode discover|rewrite]
                                          [--files-template nexus|artifactory|TEMPLATE]
                                          [--allow-missing] [--no-probe] [--no-backup]
  hp_sources.py --root DIR pypi use-original
  hp_sources.py --root DIR npm use-nexus [--registry URL] [--no-probe] [--no-backup]
  hp_sources.py --root DIR npm use-original
  hp_sources.py --root DIR verify
  hp_sources.py --root DIR status --check        (exit 1 if locks disagree with HP_* settings)
  hp_sources.py --root DIR check-url URL...      (reachability through the configured network)

PyPI locks: DIR/uv.lock and DIR/pm/uv.lock. npm locks: every package-lock.json
under DIR (node_modules skipped). The first switch keeps the original next to
each lock as <lock>.upstream; use-original restores it byte for byte.

Network settings come from the environment prepared by portable/lib/network.sh:
HTTPS_PROXY/NO_PROXY, SSL_CERT_FILE and HP_SSL_INSECURE=1.
"""
from __future__ import annotations

import argparse
import base64
import concurrent.futures
import html.parser
import json
import os
import re
import ssl
import sys
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

PYPI_INDEX = "https://pypi.org/simple"
NPM_REGISTRY = "https://registry.npmjs.org/"
BACKUP_SUFFIX = ".upstream"
FILES_TEMPLATES = {
    # Nexus Repository 3 PyPI proxy links: ../../packages/<name>/<version>/<file>
    "nexus": "{index_root}/packages/{name}/{version}/{filename}",
    # Artifactory PyPI remote keeps the files.pythonhosted.org path under packages/
    "artifactory": "{index_root}/packages/{path}",
}
SKIP_DIRS = {"node_modules", ".git", "__pycache__"}


class SourceError(Exception):
    pass


# --- network -----------------------------------------------------------------

def split_credentials(url: str) -> tuple[str, str | None]:
    """URL without userinfo, plus a Basic Authorization header value if it had one."""
    parts = urllib.parse.urlsplit(url)
    if not parts.username:
        return url, None
    user = urllib.parse.unquote(parts.username)
    password = urllib.parse.unquote(parts.password or "")
    netloc = parts.hostname or ""
    if parts.port:
        netloc += f":{parts.port}"
    token = base64.b64encode(f"{user}:{password}".encode()).decode()
    return urllib.parse.urlunsplit(parts._replace(netloc=netloc)), f"Basic {token}"


def ssl_context() -> ssl.SSLContext:
    if os.environ.get("HP_SSL_INSECURE", "").strip().lower() in ("1", "true", "yes"):
        context = ssl._create_unverified_context()  # noqa: S323 - explicit opt-in
        return context
    cafile = os.environ.get("SSL_CERT_FILE") or None
    # On Windows the default context also loads the system certificate store.
    return ssl.create_default_context(cafile=cafile)


_OPENER = None


def opener() -> urllib.request.OpenerDirector:
    global _OPENER
    if _OPENER is None:
        _OPENER = urllib.request.build_opener(
            urllib.request.ProxyHandler(),
            urllib.request.HTTPSHandler(context=ssl_context()),
        )
    return _OPENER


def http_get(url: str, auth: str | None, *, method: str = "GET", accept: str | None = None,
             timeout: float = 60) -> tuple[int, str, bytes]:
    headers = {"User-Agent": "hermes-portable-sources/1"}
    if auth:
        headers["Authorization"] = auth
    if accept:
        headers["Accept"] = accept
    if method == "RANGE":
        method, headers["Range"] = "GET", "bytes=0-0"
    request = urllib.request.Request(url, headers=headers, method=method)
    try:
        with opener().open(request, timeout=timeout) as response:
            body = response.read() if method == "GET" else b""
            return response.status, response.geturl(), body
    except urllib.error.HTTPError as exc:
        return exc.code, url, b""
    except (urllib.error.URLError, OSError) as exc:
        raise SourceError(f"cannot reach {url}: {exc}") from exc


def probe(urls: list[str], auth: str | None) -> list[str]:
    """Return the URLs that are not downloadable (HEAD, then a 1-byte range GET)."""
    failed = []
    for url in urls:
        try:
            status = http_get(url, auth, method="HEAD")[0]
            if status >= 400:
                status = http_get(url, auth, method="RANGE")[0]
        except SourceError:
            status = 599
        if status >= 400:
            failed.append(f"{url} (HTTP {status})")
    return failed


def sample(items: list[str], count: int = 4) -> list[str]:
    if len(items) <= count:
        return list(items)
    step = (len(items) - 1) / (count - 1)
    return [items[round(i * step)] for i in range(count)]


# --- file helpers -------------------------------------------------------------

def backup_path(lock: Path) -> Path:
    return lock.with_name(lock.name + BACKUP_SUFFIX)


def original_bytes(lock: Path) -> bytes:
    backup = backup_path(lock)
    return backup.read_bytes() if backup.is_file() else lock.read_bytes()


def write_lock(lock: Path, data: bytes, *, keep_backup: bool) -> None:
    backup = backup_path(lock)
    if keep_backup and not backup.exists():
        backup.write_bytes(lock.read_bytes())
    temporary = lock.with_name(lock.name + ".tmp")
    temporary.write_bytes(data)
    os.replace(temporary, lock)


def rel(root: Path, path: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return str(path)


def pypi_locks(root: Path) -> list[Path]:
    return [p for p in (root / "uv.lock", root / "pm" / "uv.lock") if p.is_file()]


def npm_locks(root: Path) -> list[Path]:
    found = []
    for directory, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        if "package-lock.json" in files:
            found.append(Path(directory) / "package-lock.json")
    return found


# --- PyPI locks ---------------------------------------------------------------

def normalize_index(url: str) -> str:
    return url.strip().rstrip("/")


def index_root(index: str) -> str:
    return index[: -len("/simple")] if index.endswith("/simple") else index


def pypi_registries(text: str) -> set[str]:
    return set(re.findall(r'registry = "([^"]+)"', text))


def pypi_state(text: str) -> str:
    registries = pypi_registries(text)
    return "original" if registries <= {PYPI_INDEX} else "mirror"


def pypi_files(data: bytes) -> list[dict]:
    """Every downloadable artifact of a PyPI-registry package in a uv.lock."""
    lock = tomllib.loads(data.decode("utf-8"))
    files = []
    for package in lock.get("package", []):
        if package.get("source", {}).get("registry") != PYPI_INDEX:
            continue
        artifacts = [package["sdist"]] if "sdist" in package else []
        artifacts += package.get("wheels", [])
        for artifact in artifacts:
            if "url" not in artifact:
                continue
            files.append({"name": package["name"], "version": package["version"],
                          "url": artifact["url"], "hash": artifact.get("hash", ""),
                          "filename": urllib.parse.unquote(artifact["url"].rsplit("/", 1)[-1])})
    return files


def direct_references(data: bytes) -> list[str]:
    lock = tomllib.loads(data.decode("utf-8"))
    refs = []
    for package in lock.get("package", []):
        source = package.get("source", {})
        for kind in ("git", "url"):
            if kind in source:
                refs.append(f"{package['name']} ({kind})")
    return refs


def template_mapping(files: list[dict], template: str, index: str) -> dict[str, str]:
    root = index_root(index)
    mapping = {}
    for item in files:
        path = urllib.parse.urlsplit(item["url"]).path.lstrip("/")
        mapping[item["url"]] = template.format(index_root=root, index=index, name=item["name"],
                                               version=item["version"], filename=item["filename"],
                                               path=path)
    return mapping


class _Links(html.parser.HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            href = dict(attrs).get("href")
            if href:
                self.links.append(href)


def simple_page(index: str, name: str, auth: str | None) -> dict[str, tuple[str, str]]:
    """filename -> (absolute URL without fragment, sha256 or '') from a PEP 503 page."""
    project = re.sub(r"[-_.]+", "-", name).lower()
    page = f"{index}/{project}/"
    status, final, body = http_get(page, auth, accept="text/html")
    if status >= 400:
        raise SourceError(f"{page}: HTTP {status}")
    parser = _Links()
    parser.feed(body.decode("utf-8", "replace"))
    links = {}
    for href in parser.links:
        absolute = urllib.parse.urljoin(final, href)
        url, _, fragment = absolute.partition("#")
        digest = fragment.split("=", 1)[1].lower() if fragment.startswith("sha256=") else ""
        links[urllib.parse.unquote(url.rsplit("/", 1)[-1])] = (split_credentials(url)[0], digest)
    return links


def discover_mapping(files: list[dict], index: str, auth: str | None, jobs: int):
    """Map every locked artifact to the URL the mirror's own index serves for it."""
    names = sorted({item["name"] for item in files})
    pages: dict[str, dict] = {}
    errors = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = {pool.submit(simple_page, index, name, auth): name for name in names}
        for future in concurrent.futures.as_completed(futures):
            name = futures[future]
            try:
                pages[name] = future.result()
            except SourceError as exc:
                errors.append(str(exc))
    if errors:
        raise SourceError("mirror index lookups failed:\n  " + "\n  ".join(sorted(errors)[:20]))
    mapping, missing, mismatched = {}, [], []
    for item in files:
        found = pages[item["name"]].get(item["filename"])
        if found is None:
            missing.append(f"{item['name']} {item['version']}: {item['filename']}")
            continue
        url, digest = found
        locked = item["hash"].partition(":")[2].lower()
        if digest and locked and digest != locked:
            mismatched.append(f"{item['filename']}: index sha256 {digest} != lock {locked}")
            continue
        mapping[item["url"]] = url
    return mapping, missing, mismatched


def rewrite_pypi(text: str, mapping: dict[str, str], index: str) -> str:
    text = re.sub(r'(\burl = ")([^"]+)(")', lambda m: m.group(1) + mapping.get(m.group(2), m.group(2)) + m.group(3), text)
    return text.replace(f'registry = "{PYPI_INDEX}"', f'registry = "{index}"')


def cmd_pypi_use_nexus(root: Path, args) -> int:
    raw = args.index_url or os.environ.get("HP_PYPI_INDEX_URL", "")
    if not raw:
        raise SourceError("no PyPI mirror: pass --index-url or set HP_PYPI_INDEX_URL in config/portable.env")
    clean, auth = split_credentials(normalize_index(raw))
    index = normalize_index(clean)
    if index == PYPI_INDEX:
        raise SourceError("the mirror URL is PyPI itself; use `pypi use-original` instead")
    locks = pypi_locks(root)
    if not locks:
        raise SourceError(f"no uv.lock under {root}")
    results = []
    for lock in locks:
        current = lock.read_bytes().decode("utf-8")
        if pypi_state(current) != "original" and not backup_path(lock).is_file():
            raise SourceError(f"{rel(root, lock)} is already switched and has no {BACKUP_SUFFIX} original; restore it first")
        data = original_bytes(lock)
        files = pypi_files(data)
        if args.mode == "rewrite":
            template = FILES_TEMPLATES.get(args.files_template, args.files_template)
            mapping, missing, mismatched = template_mapping(files, template, index), [], []
        else:
            mapping, missing, mismatched = discover_mapping(files, index, auth, args.jobs)
        if mismatched:
            raise SourceError(f"{rel(root, lock)}: the mirror serves different files than the lock:\n  "
                              + "\n  ".join(mismatched[:20]))
        if missing and not args.allow_missing:
            raise SourceError(f"{rel(root, lock)}: {len(missing)} locked files are not on the mirror "
                              "(--allow-missing keeps their original URLs):\n  " + "\n  ".join(missing[:20]))
        if not args.no_probe:
            failed = probe(sample(sorted(set(mapping.values()))), auth)
            if failed:
                hint = ("\nTry another --files-template (nexus, artifactory or a custom template) or --mode discover."
                        if args.mode == "rewrite" else "")
                raise SourceError(f"{rel(root, lock)}: mirror download probe failed:\n  " + "\n  ".join(failed) + hint)
        results.append((lock, rewrite_pypi(data.decode("utf-8"), mapping, index), len(mapping), len(missing)))
    for lock, text, switched, missing in results:
        write_lock(lock, text.encode("utf-8"), keep_backup=not args.no_backup)
        note = f", {missing} kept on original URLs" if missing else ""
        print(f"switched {rel(root, lock)} -> {index} ({switched} files{note})")
    return 0


def cmd_pypi_use_original(root: Path, args) -> int:
    for lock in pypi_locks(root):
        backup = backup_path(lock)
        if backup.is_file():
            lock.write_bytes(backup.read_bytes())
            print(f"restored {rel(root, lock)} from {backup.name}")
        elif pypi_state(lock.read_text(encoding="utf-8")) == "original":
            print(f"{rel(root, lock)} already uses the original sources")
        else:
            raise SourceError(f"{rel(root, lock)} is switched but {backup.name} is missing")
    return 0


# --- npm locks ----------------------------------------------------------------

RESOLVED = re.compile(r'("resolved":\s*")([^"]+)(")')


def npm_hosts(text: str) -> set[str]:
    return {urllib.parse.urlsplit(url).netloc for _, url, _ in RESOLVED.findall(text)
            if url.startswith(("http://", "https://"))}


def npm_state(text: str) -> str:
    return "original" if npm_hosts(text) <= {"registry.npmjs.org"} else "mirror"


def cmd_npm_use_nexus(root: Path, args) -> int:
    raw = args.registry or os.environ.get("HP_NPM_REGISTRY", "")
    if not raw:
        raise SourceError("no npm mirror: pass --registry or set HP_NPM_REGISTRY in config/portable.env")
    clean, auth = split_credentials(raw.strip())
    registry = clean.rstrip("/") + "/"
    if registry == NPM_REGISTRY:
        raise SourceError("the mirror URL is the public npm registry; use `npm use-original` instead")
    locks = npm_locks(root)
    if not locks:
        print(f"no package-lock.json under {root}; nothing to switch (.npmrc still applies)")
        return 0
    results = []
    for lock in locks:
        current = lock.read_text(encoding="utf-8")
        if npm_state(current) != "original" and not backup_path(lock).is_file():
            raise SourceError(f"{rel(root, lock)} is already switched and has no {BACKUP_SUFFIX} original; restore it first")
        text = original_bytes(lock).decode("utf-8")
        switched = []

        def replace(match):
            url = match.group(2)
            if url.startswith(NPM_REGISTRY):
                url = registry + url[len(NPM_REGISTRY):]
                switched.append(url)
            return match.group(1) + url + match.group(3)

        results.append((lock, RESOLVED.sub(replace, text), switched))
    if not args.no_probe:
        tarballs = [url for _, _, switched in results for url in switched]
        failed = probe(sample(sorted(set(tarballs)), 2), auth) if tarballs else []
        if failed:
            raise SourceError("npm mirror download probe failed:\n  " + "\n  ".join(failed))
    for lock, text, switched in results:
        write_lock(lock, text.encode("utf-8"), keep_backup=not args.no_backup)
        print(f"switched {rel(root, lock)} -> {registry} ({len(switched)} tarballs)")
    return 0


def cmd_npm_use_original(root: Path, args) -> int:
    for lock in npm_locks(root):
        backup = backup_path(lock)
        if backup.is_file():
            lock.write_bytes(backup.read_bytes())
            print(f"restored {rel(root, lock)} from {backup.name}")
        elif npm_state(lock.read_text(encoding="utf-8")) != "original":
            raise SourceError(f"{rel(root, lock)} is switched but {backup.name} is missing")
    return 0


# --- status / verify ------------------------------------------------------------

def status(root: Path) -> list[dict]:
    rows = []
    for lock in pypi_locks(root):
        data = lock.read_bytes()
        text = data.decode("utf-8")
        registries = sorted(pypi_registries(text))
        rows.append({"kind": "pypi", "lock": rel(root, lock), "state": pypi_state(text),
                     "sources": registries, "direct_references": direct_references(data),
                     "backup": backup_path(lock).is_file()})
    for lock in npm_locks(root):
        text = lock.read_text(encoding="utf-8")
        rows.append({"kind": "npm", "lock": rel(root, lock), "state": npm_state(text),
                     "sources": sorted(npm_hosts(text)), "direct_references": [],
                     "backup": backup_path(lock).is_file()})
    return rows


def consistency(rows: list[dict]) -> list[str]:
    """Warnings where the lock files disagree with HP_PYPI_INDEX_URL / HP_NPM_REGISTRY."""
    warnings = []
    pypi = normalize_index(split_credentials(os.environ.get("HP_PYPI_INDEX_URL", ""))[0]) if os.environ.get("HP_PYPI_INDEX_URL") else ""
    npm = split_credentials(os.environ.get("HP_NPM_REGISTRY", ""))[0]
    npm_host = urllib.parse.urlsplit(npm).netloc if npm else ""
    for row in rows:
        if row["kind"] == "pypi":
            if pypi and row["sources"] != [pypi]:
                warnings.append(f"{row['lock']} does not use HP_PYPI_INDEX_URL; run `hermes-portable sources pypi use-nexus`")
            if not pypi and row["state"] == "mirror":
                warnings.append(f"{row['lock']} points at a mirror but HP_PYPI_INDEX_URL is unset; "
                                "set it or run `hermes-portable sources pypi use-original`")
        elif row["kind"] == "npm":
            if npm_host and row["sources"] and row["sources"] != [npm_host]:
                warnings.append(f"{row['lock']} does not use HP_NPM_REGISTRY; run `hermes-portable sources npm use-nexus`")
            if not npm_host and row["state"] == "mirror":
                warnings.append(f"{row['lock']} points at a mirror but HP_NPM_REGISTRY is unset; "
                                "set it or run `hermes-portable sources npm use-original`")
    return warnings


def cmd_status(root: Path, args) -> int:
    rows = status(root)
    if args.json:
        print(json.dumps({"locks": rows, "warnings": consistency(rows)}, indent=2))
        return 0
    for row in rows:
        print(f"[{row['kind']}] {row['lock']}: {row['state']} ({', '.join(row['sources']) or '-'})"
              + ("" if row["backup"] else "  [no .upstream backup]"))
        if row["direct_references"]:
            print(f"    not switchable (fetched from their own URLs): {', '.join(row['direct_references'])}")
    warnings = consistency(rows)
    for warning in warnings:
        print(f"WARNING: {warning}")
    return 1 if args.check and warnings else 0


def cmd_check_url(root: Path, args) -> int:
    failed = 0
    for raw in args.urls:
        url, auth = split_credentials(raw)
        try:
            status_code = http_get(url, auth, timeout=20)[0]
            ok = status_code < 400
            detail = f"HTTP {status_code}"
        except SourceError as exc:
            ok, detail = False, str(exc)
        failed += not ok
        print(f"{'OK  ' if ok else 'FAIL'} {url}  ({detail})")
    return 1 if failed else 0


def pypi_identity(data: bytes) -> set[tuple[str, str, str, str]]:
    return {(f["name"], f["version"], f["filename"], f["hash"]) for f in pypi_files(data)}


def cmd_verify(root: Path, args) -> int:
    problems = []
    for lock in pypi_locks(root):
        backup = backup_path(lock)
        if not backup.is_file():
            print(f"[pypi] {rel(root, lock)}: no {backup.name}; nothing to compare")
            continue
        current, original = lock.read_bytes(), backup.read_bytes()
        # Every PyPI artifact must survive with identical name/version/file/hash.
        # (Switched files leave the PYPI_INDEX registry, so compare by content.)
        original_set = pypi_identity(original)
        current_lock = tomllib.loads(current.decode("utf-8"))
        current_set = set()
        for package in current_lock.get("package", []):
            for artifact in ([package["sdist"]] if "sdist" in package else []) + package.get("wheels", []):
                if "url" in artifact:
                    current_set.add((package["name"], package["version"],
                                     urllib.parse.unquote(artifact["url"].rsplit("/", 1)[-1]),
                                     artifact.get("hash", "")))
        lost = original_set - current_set
        names = lambda data: {(p["name"], p["version"]) for p in tomllib.loads(data.decode("utf-8")).get("package", [])}
        if names(current) != names(original):
            problems.append(f"{rel(root, lock)}: package set or versions differ from the original")
        if lost:
            problems.append(f"{rel(root, lock)}: {len(lost)} artifacts differ from the original, e.g. {sorted(lost)[0]}")
        print(f"[pypi] {rel(root, lock)}: {'OK' if not lost else 'MISMATCH'} ({len(original_set)} artifacts)")
    for lock in npm_locks(root):
        backup = backup_path(lock)
        if not backup.is_file():
            continue
        current = json.loads(lock.read_text(encoding="utf-8")).get("packages", {})
        original = json.loads(backup.read_text(encoding="utf-8")).get("packages", {})
        differ = [key for key in original
                  if key not in current
                  or {k: v for k, v in original[key].items() if k != "resolved"}
                  != {k: v for k, v in current[key].items() if k != "resolved"}]
        if differ or set(current) != set(original):
            problems.append(f"{rel(root, lock)}: {len(differ)} entries differ beyond 'resolved'")
        print(f"[npm] {rel(root, lock)}: {'OK' if not differ else 'MISMATCH'} ({len(original)} entries)")
    for problem in problems:
        print(f"ERROR: {problem}", file=sys.stderr)
    return 1 if problems else 0


# --- CLI ------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="hp_sources", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, required=True, help="directory holding uv.lock")
    sub = parser.add_subparsers(dest="command", required=True)
    status_parser = sub.add_parser("status")
    status_parser.add_argument("--json", action="store_true")
    status_parser.add_argument("--check", action="store_true", help="exit 1 on config/lock disagreement")
    sub.add_parser("verify")
    check_parser = sub.add_parser("check-url")
    check_parser.add_argument("urls", nargs="+")
    for ecosystem in ("pypi", "npm"):
        eco = sub.add_parser(ecosystem).add_subparsers(dest="action", required=True)
        use = eco.add_parser("use-nexus")
        use.add_argument("--no-probe", action="store_true", help="skip the download probe")
        use.add_argument("--no-backup", action="store_true", help="do not keep <lock>.upstream (git checkouts)")
        if ecosystem == "pypi":
            use.add_argument("--index-url", help="mirror simple index (default: HP_PYPI_INDEX_URL)")
            use.add_argument("--mode", choices=("discover", "rewrite"), default="discover",
                             help="discover: read the mirror's index pages (default); rewrite: offline URL template")
            use.add_argument("--files-template", default=os.environ.get("HP_PYPI_FILES_TEMPLATE") or "nexus",
                             help="rewrite mode: nexus, artifactory, or a template using "
                                  "{index_root} {index} {name} {version} {filename} {path}")
            use.add_argument("--allow-missing", action="store_true",
                             help="keep original URLs for files the mirror does not list")
            use.add_argument("--jobs", type=int, default=8, help="parallel index lookups (discover)")
        else:
            use.add_argument("--registry", help="mirror registry (default: HP_NPM_REGISTRY)")
        eco.add_parser("use-original")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    handlers = {
        ("status", None): cmd_status, ("verify", None): cmd_verify, ("check-url", None): cmd_check_url,
        ("pypi", "use-nexus"): cmd_pypi_use_nexus, ("pypi", "use-original"): cmd_pypi_use_original,
        ("npm", "use-nexus"): cmd_npm_use_nexus, ("npm", "use-original"): cmd_npm_use_original,
    }
    try:
        return handlers[(args.command, getattr(args, "action", None))](root, args)
    except SourceError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
