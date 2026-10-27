#!/usr/bin/env python3
"""Integration tests for portable/python/hp_sources.py and hp_sslhook.py.

  python -I build/tests/test_sources.py -v

Builds a local mirror with the Nexus 3 layout from the fixture projects,
serves it over HTTP and over HTTPS (private CA from mkcert.sh), and checks:
discover/rewrite switching, probe failures, verify, byte-exact restore,
`uv sync --frozen` / `npm ci` through a black-hole proxy, TLS trust options,
and that patch 0003 keeps the venv stamp identical across a switch.
Needs network access once (to download the fixture artifacts), uv, Git Bash
(openssl) and optionally npm.
"""
from __future__ import annotations

import ast
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
TESTS = REPO / "build/tests"
SOURCES = REPO / "portable/python/hp_sources.py"
HTTP_PORT, HTTPS_PORT = 18180, 18543
BLACKHOLE = {"HTTP_PROXY": "http://127.0.0.1:9", "HTTPS_PROXY": "http://127.0.0.1:9",
             "http_proxy": "http://127.0.0.1:9", "https_proxy": "http://127.0.0.1:9",
             "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost"}
CLEAN = {k: v for k, v in os.environ.items()
         if not k.upper().startswith(("HP_", "UV_", "SSL_CERT", "NPM_CONFIG", "PIP_"))}


def run(args, *, cwd=None, env=None, check=True):
    result = subprocess.run([str(a) for a in args], cwd=cwd, env={**CLEAN, **(env or {})},
                            capture_output=True, text=True, encoding="utf-8", errors="replace")
    if check and result.returncode:
        raise AssertionError(f"{args} failed ({result.returncode}):\n{result.stdout}\n{result.stderr}")
    return result


def sources(root, *args, env=None, check=True):
    return run([sys.executable, "-I", SOURCES, "--root", root, *args], env=env, check=check)


class SourcesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="hp-sources-"))
        cls.mirror = cls.tmp / "mirror"
        run([sys.executable, "-I", TESTS / "mkmirror.py", "--out", cls.mirror,
             "--uv-lock", TESTS / "fixtures/pypi-project/uv.lock",
             "--npm-lock", TESTS / "fixtures/npm-project/package-lock.json"])
        bash = shutil.which("bash")
        run([bash, (TESTS / "mkcert.sh").as_posix(), (cls.tmp / "pki").as_posix()])
        cls.ca = cls.tmp / "pki/ca.pem"
        cls.servers = [cls._serve(HTTP_PORT, "http.log"),
                       cls._serve(HTTPS_PORT, "https.log", cls.tmp / "pki/server.pem", cls.tmp / "pki/server.key")]
        cls.http = f"http://127.0.0.1:{HTTP_PORT}"
        cls.https = f"https://127.0.0.1:{HTTPS_PORT}"

    @classmethod
    def _serve(cls, port, log, cert=None, key=None):
        ready = cls.tmp / f"ready-{port}"
        args = [sys.executable, "-I", TESTS / "serve.py", "--root", cls.mirror, "--port", port,
                "--log", cls.tmp / log, "--ready", ready]
        if cert:
            args += ["--cert", cert, "--key", key]
        process = subprocess.Popen([str(a) for a in args])
        for _ in range(100):
            if ready.exists():
                return process
            time.sleep(0.1)
        raise RuntimeError(f"server on {port} did not start")

    @classmethod
    def tearDownClass(cls):
        for process in cls.servers:
            process.terminate()
            process.wait(timeout=10)
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def project(self, name="pypi"):
        target = Path(tempfile.mkdtemp(dir=self.tmp)) / name
        shutil.copytree(TESTS / f"fixtures/{name}-project", target)
        return target

    # --- PyPI ------------------------------------------------------------------
    def test_discover_then_uv_sync_through_mirror_only(self):
        project = self.project()
        sources(project, "pypi", "use-nexus", "--index-url", f"{self.http}/pypi/simple")
        lock = (project / "uv.lock").read_text(encoding="utf-8")
        self.assertNotIn("files.pythonhosted.org", lock)
        self.assertIn(f'registry = "{self.http}/pypi/simple"', lock)
        sources(project, "verify")
        run(["uv", "sync", "--frozen", "--python", sys.executable], cwd=project,
            env={**BLACKHOLE, "UV_CACHE_DIR": str(self.tmp / "uvc-http"),
                 "UV_DEFAULT_INDEX": f"{self.http}/pypi/simple"})
        log = (self.tmp / "http.log").read_text(encoding="utf-8")
        self.assertIn("GET /pypi/packages/six/1.17.0/six-1.17.0-py2.py3-none-any.whl", log)

    def test_rewrite_template_and_restore(self):
        project = self.project()
        original = (project / "uv.lock").read_bytes()
        sources(project, "pypi", "use-nexus", "--mode", "rewrite", "--index-url", f"{self.http}/pypi/simple")
        self.assertIn(b"/pypi/packages/idna/3.10/", (project / "uv.lock").read_bytes())
        sources(project, "pypi", "use-original")
        self.assertEqual((project / "uv.lock").read_bytes(), original)
        self.assertEqual((project / "uv.lock.upstream").read_bytes(), original)

    def test_wrong_template_fails_without_writing(self):
        project = self.project()
        original = (project / "uv.lock").read_bytes()
        result = sources(project, "pypi", "use-nexus", "--mode", "rewrite", "--files-template", "artifactory",
                         "--index-url", f"{self.http}/pypi/simple", check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("probe failed", result.stderr)
        self.assertEqual((project / "uv.lock").read_bytes(), original)

    def test_unknown_index_fails(self):
        result = sources(self.project(), "pypi", "use-nexus", "--index-url", f"{self.http}/missing/simple", check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("HTTP 404", result.stderr)

    def test_credentials_never_reach_the_lock(self):
        project = self.project()
        sources(project, "pypi", "use-nexus", "--mode", "rewrite", "--no-probe",
                "--index-url", "https://user:s3cret@nexus.invalid/repository/pypi/simple")
        self.assertNotIn("s3cret", (project / "uv.lock").read_text(encoding="utf-8"))

    def test_status_check_reports_disagreement(self):
        project = self.project()
        result = sources(project, "status", "--check", env={"HP_PYPI_INDEX_URL": f"{self.http}/pypi/simple"}, check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("use-nexus", result.stdout)

    # --- npm --------------------------------------------------------------------
    def test_npm_switch_then_npm_ci_through_mirror_only(self):
        project = self.project("npm")
        sources(project, "npm", "use-nexus", "--registry", f"{self.http}/npm/")
        self.assertNotIn("registry.npmjs.org", (project / "package-lock.json").read_text(encoding="utf-8"))
        sources(project, "verify")
        npm = shutil.which("npm")
        if npm is None:
            self.skipTest("npm not installed")
        run([npm, "ci", "--no-audit", "--no-fund", "--ignore-scripts"], cwd=project,
            env={**BLACKHOLE, "npm_config_cache": str(self.tmp / "npm-cache")})
        self.assertTrue((project / "node_modules/ms/package.json").is_file())
        sources(project, "npm", "use-original")
        self.assertIn("registry.npmjs.org", (project / "package-lock.json").read_text(encoding="utf-8"))

    # --- TLS ----------------------------------------------------------------------
    def test_tls_private_ca(self):
        index = f"{self.https}/pypi/simple"
        self.assertEqual(sources(self.project(), "check-url", f"{index}/six/", check=False).returncode, 1)
        self.assertEqual(sources(self.project(), "check-url", f"{index}/six/",
                                 env={"SSL_CERT_FILE": str(self.ca)}).returncode, 0)
        self.assertEqual(sources(self.project(), "check-url", f"{index}/six/",
                                 env={"HP_SSL_INSECURE": "1"}).returncode, 0)
        project = self.project()
        sources(project, "pypi", "use-nexus", "--index-url", index, env={"SSL_CERT_FILE": str(self.ca)})
        run(["uv", "sync", "--frozen", "--python", sys.executable], cwd=project,
            env={**BLACKHOLE, "SSL_CERT_FILE": str(self.ca), "UV_SYSTEM_CERTS": "1",
                 "UV_CACHE_DIR": str(self.tmp / "uvc-https"), "UV_DEFAULT_INDEX": index})

    def test_ssl_hook(self):
        code = ("import sys, urllib.request; sys.path.insert(0, sys.argv[1]); import hp_sslhook; "
                "hp_sslhook.install(); urllib.request.urlopen(sys.argv[2], timeout=10).read()")
        args = [sys.executable, "-I", "-c", code, REPO / "portable/python", f"{self.https}/pypi/simple/six/"]
        self.assertNotEqual(run(args, check=False).returncode, 0)
        run(args, env={"HP_SSL_INSECURE": "1"})

    # --- patch 0003 -----------------------------------------------------------------
    def test_lock_identity_survives_switch(self):
        work = Path(tempfile.mkdtemp(dir=self.tmp))
        (work / "pm").mkdir()
        shutil.copy(REPO / "upstream/pm/packages.py", work / "pm/packages.py")
        run(["git", "apply", "--include=pm/packages.py", REPO / "patches/0003-pm-source-agnostic-lock.patch"], cwd=work)
        tree = ast.parse((work / "pm/packages.py").read_text(encoding="utf-8"))
        function = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "_uv_lock_identity")
        namespace: dict = {}
        exec(compile(ast.Module([function], []), "patched", "exec"), namespace)
        identity = namespace["_uv_lock_identity"]
        locks = work / "locks"
        (locks / "pm").mkdir(parents=True)
        shutil.copy(REPO / "upstream/uv.lock", locks / "uv.lock")
        shutil.copy(REPO / "upstream/pm/uv.lock", locks / "pm/uv.lock")
        sources(locks, "pypi", "use-nexus", "--mode", "rewrite", "--no-probe",
                "--index-url", "https://nexus.invalid/repository/pypi/simple")
        for name in ("uv.lock", "pm/uv.lock"):
            before = hashlib.sha256(identity((locks / f"{name}.upstream").read_bytes())).hexdigest()
            after = hashlib.sha256(identity((locks / name).read_bytes())).hexdigest()
            self.assertEqual(before, after, name)
        sources(locks, "verify")


if __name__ == "__main__":
    urllib.request.install_opener(urllib.request.build_opener(urllib.request.ProxyHandler({})))
    unittest.main()
