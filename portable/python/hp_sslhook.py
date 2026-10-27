"""Hermes Portable: process-wide TLS verification off when HP_SSL_INSECURE=1.

Loaded at interpreter start by zz_hermes_portable.pth in the payload venv's
site-packages. Without HP_SSL_INSECURE=1 it does nothing. With it, every
default SSL context skips verification and the HTTP clients Hermes uses
(httpx, requests, aiohttp, urllib) are created with verification disabled;
truststore cannot re-enable it. Safe to load more than once.
"""
from __future__ import annotations

import os
import sys

_TRUTHY = ("1", "true", "yes", "on")


def _unverified(context):
    context.check_hostname = False
    import ssl

    context.verify_mode = ssl.CERT_NONE
    return context


def _patch_httpx(module) -> None:
    for name in ("Client", "AsyncClient", "HTTPTransport", "AsyncHTTPTransport"):
        cls = getattr(module, name, None)
        if cls is None or getattr(cls.__init__, "_hp_insecure", False):
            continue
        original = cls.__init__

        def __init__(self, *args, __original=original, **kwargs):
            kwargs["verify"] = False
            __original(self, *args, **kwargs)

        __init__._hp_insecure = True
        cls.__init__ = __init__


def _patch_requests(module) -> None:
    session = getattr(module, "Session", None)
    if session is None or getattr(session.merge_environment_settings, "_hp_insecure", False):
        return
    original = session.merge_environment_settings

    def merge_environment_settings(self, *args, **kwargs):
        settings = original(self, *args, **kwargs)
        settings["verify"] = False
        return settings

    merge_environment_settings._hp_insecure = True
    session.merge_environment_settings = merge_environment_settings
    try:
        import urllib3

        urllib3.disable_warnings()
    except Exception:
        pass


def _patch_truststore(module) -> None:
    import ssl

    module.inject_into_ssl = lambda *args, **kwargs: None

    def SSLContext(protocol=ssl.PROTOCOL_TLS_CLIENT):  # noqa: N802 - mirrors truststore's API
        return _unverified(ssl.SSLContext(protocol))

    module.SSLContext = SSLContext


_PATCHES = {"httpx": _patch_httpx, "httpx2": _patch_httpx,
            "requests": _patch_requests, "truststore": _patch_truststore}


class _PatchOnImport:
    """Meta-path hook: patch a client library right after it is imported."""

    def find_spec(self, name, path=None, target=None):
        if name not in _PATCHES:
            return None
        for finder in sys.meta_path:
            if finder is self or not hasattr(finder, "find_spec"):
                continue
            spec = finder.find_spec(name, path, target)
            if spec is not None:
                break
        else:
            return None
        loader = spec.loader
        if loader is None or not hasattr(loader, "exec_module"):
            return spec
        original = loader.exec_module

        def exec_module(module, __original=original, __name=name):
            __original(module)
            _PATCHES[__name](module)

        loader.exec_module = exec_module
        return spec


def install() -> None:
    if os.environ.get("HP_SSL_INSECURE", "").strip().lower() not in _TRUTHY:
        return
    import ssl

    if getattr(ssl, "_hp_insecure", False):
        return
    ssl._hp_insecure = True
    original = ssl.create_default_context

    def create_default_context(purpose=ssl.Purpose.SERVER_AUTH, *args, **kwargs):
        context = original(purpose, *args, **kwargs)
        return _unverified(context) if purpose == ssl.Purpose.SERVER_AUTH else context

    ssl.create_default_context = create_default_context
    ssl._create_default_https_context = ssl._create_unverified_context
    for name, patch in _PATCHES.items():
        if name in sys.modules:
            patch(sys.modules[name])
    sys.meta_path.insert(0, _PatchOnImport())
