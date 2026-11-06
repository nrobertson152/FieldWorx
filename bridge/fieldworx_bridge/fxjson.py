# FieldWorx - field companion to the RevisionWorx family
# SPDX-License-Identifier: GPL-3.0-or-later
"""Canonical JSON: the exact bytes FieldWorx hashes, stores and exchanges (docs/PROTOCOL.md section 2).

The Dart implementation (core/lib/src/fxjson.dart) must produce the same bytes for the same value; the shared
vectors in spec/vectors/ keep the two honest.

Values are null, booleans, integers within +/-(2**53 - 1), strings, arrays and objects with string keys. There are
no floats anywhere in the protocol: decimals (measurements, quantities) travel as strings. Object keys are sorted by
code point, there is no whitespace, and strings escape only what JSON requires.
"""
from __future__ import annotations

import hashlib
import json
from typing import Any

MAX_SAFE_INT = 2**53 - 1
MAX_DEPTH = 64


class FxJsonError(ValueError):
    """The value or the bytes are not canonical FieldWorx JSON. Nothing was used."""


_ESCAPES = {'"': '\\"', "\\": "\\\\", "\b": "\\b", "\f": "\\f", "\n": "\\n", "\r": "\\r", "\t": "\\t"}


def _string(s: str, out: list[str]) -> None:
    parts = ['"']
    for ch in s:
        o = ord(ch)
        if ch in _ESCAPES:
            parts.append(_ESCAPES[ch])
        elif o < 0x20:
            parts.append(f"\\u{o:04x}")
        elif 0xD800 <= o <= 0xDFFF:
            raise FxJsonError("text contains an unpaired surrogate")
        else:
            parts.append(ch)
    parts.append('"')
    out.append("".join(parts))


def _encode(v: Any, out: list[str], depth: int) -> None:
    if depth > MAX_DEPTH:
        raise FxJsonError(f"nested more than {MAX_DEPTH} levels")
    if v is None:
        out.append("null")
    elif v is True:
        out.append("true")
    elif v is False:
        out.append("false")
    elif isinstance(v, int):
        if not -MAX_SAFE_INT <= v <= MAX_SAFE_INT:
            raise FxJsonError(f"integer {v} is outside +/-(2**53 - 1)")
        out.append(str(int(v)))
    elif isinstance(v, float):
        raise FxJsonError("floating-point numbers are not allowed; send decimals as text")
    elif isinstance(v, str):
        _string(v, out)
    elif isinstance(v, (list, tuple)):
        out.append("[")
        for i, item in enumerate(v):
            if i:
                out.append(",")
            _encode(item, out, depth + 1)
        out.append("]")
    elif isinstance(v, dict):
        for k in v:
            if not isinstance(k, str):
                raise FxJsonError("object keys must be text")
        out.append("{")
        for i, k in enumerate(sorted(v, key=_key_order)):
            if i:
                out.append(",")
            _string(k, out)
            out.append(":")
            _encode(v[k], out, depth + 1)
        out.append("}")
    else:
        raise FxJsonError(f"cannot encode {type(v).__name__}")


def _key_order(k: str) -> bytes:
    # Code point order is UTF-8 byte order. Python's own str order is code point order too, but the bytes make the
    # rule explicit and identical to the Dart implementation. Unpaired surrogates are refused by _string first.
    try:
        return k.encode("utf-8")
    except UnicodeEncodeError:
        raise FxJsonError("text contains an unpaired surrogate") from None


def encode(value: Any) -> bytes:
    """Canonical bytes of ``value``. Raises FxJsonError for anything outside the value domain."""
    out: list[str] = []
    _encode(value, out, 0)
    try:
        return "".join(out).encode("utf-8")
    except UnicodeEncodeError:
        raise FxJsonError("text contains an unpaired surrogate") from None


def _no_constant(name: str):
    raise FxJsonError(f"{name} is not allowed")


def _no_float(text: str):
    raise FxJsonError(f"number {text} is not an integer; send decimals as text")


def _pairs(pairs):
    d = {}
    for k, v in pairs:
        if k in d:
            raise FxJsonError(f"key {k!r} appears twice")
        d[k] = v
    return d


def parse(data: bytes | str) -> Any:
    """Parse JSON strictly (no floats, constants or duplicate keys). It need not be canonical."""
    if isinstance(data, bytes):
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            raise FxJsonError("not UTF-8") from None
    else:
        text = data
    try:
        value = json.loads(text, object_pairs_hook=_pairs, parse_float=_no_float, parse_constant=_no_constant)
    except FxJsonError:
        raise
    except (ValueError, RecursionError) as exc:
        raise FxJsonError(f"not valid JSON: {exc}") from None
    encode(value)  # range, depth and surrogate checks
    return value


def parse_canonical(data: bytes) -> Any:
    """Parse bytes that must already be canonical: re-encoding must give exactly the same bytes."""
    value = parse(data)
    if encode(value) != data:
        raise FxJsonError("not in canonical form")
    return value


def digest(domain: str, value: Any) -> str:
    """SHA-256 (hex) of ``fieldworx/<domain>\\0`` followed by the canonical bytes of ``value``."""
    return digest_bytes(domain, encode(value))


def digest_bytes(domain: str, canonical: bytes) -> str:
    h = hashlib.sha256()
    h.update(b"fieldworx/" + domain.encode("ascii") + b"\0")
    h.update(canonical)
    return h.hexdigest()


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()
