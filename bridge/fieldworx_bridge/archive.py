# SPDX-License-Identifier: GPL-3.0-or-later
"""FieldWorx archives: packages (engineering to the field) and field logs (the field back), docs/PROTOCOL.md section 3.

Both are ZIP files with the same layout, so one reader serves both:

    mimetype            application/x-fieldworx-package | application/x-fieldworx-fieldlog (first, stored)
    manifest.json       canonical JSON listing every member below with its size and hash
    catalog.json        packages only: the engineering snapshot (canonical JSON)
    events/<id>         field events, canonical bytes, named by their id
    objects/<sha256>    files (drawings as PDF, photos), named by the SHA-256 of their bytes

A reader checks every listed member before anything is used and refuses the whole archive on any mismatch. Members
it does not list are ignored, as OpenSchematix readers ignore members they don't know.
"""
from __future__ import annotations

import hashlib
import io
import re
import zipfile
import zlib
from dataclasses import dataclass, field
from pathlib import Path
from typing import BinaryIO, Iterable

from . import events as ev_mod
from . import fxjson, safefile

MIME = {"package": "application/x-fieldworx-package", "fieldlog": "application/x-fieldworx-fieldlog"}
EXTENSION = {"package": ".fieldworx", "fieldlog": ".fieldlog"}
FORMAT = "fieldworx.archive"
VERSION = 1
MAX_MANIFEST = 16 * 1024 * 1024
MAX_CATALOG = 256 * 1024 * 1024
MAX_OBJECT = 2 * 1024 * 1024 * 1024
MAX_MEMBERS = 200_000
RE_ARCHIVE_ID = re.compile(r"(pkg|flg)_[0-9a-f]{32}\Z")
RE_MEDIA = re.compile(r"[a-z0-9][a-z0-9.+\-]*/[a-z0-9][a-z0-9.+\-]*\Z")
STORED_MEDIA = ("application/pdf", "image/jpeg", "image/png", "image/webp", "image/heic", "application/zip")
MANIFEST_KEYS = {"format", "version", "kind", "id", "title", "series", "created", "created_by", "source", "catalog",
                 "events", "objects", "notices"}


class ArchiveError(ValueError):
    """The archive can't be used. Nothing from it was used."""


@dataclass
class Archive:
    kind: str
    manifest: dict
    manifest_bytes: bytes
    catalog: dict | None
    events: list[ev_mod.Event]
    objects: dict[str, dict]                 # sha256 -> {"size", "media_type"}
    _zip: zipfile.ZipFile | None = field(default=None, repr=False)

    @property
    def id(self) -> str:
        return self.manifest["id"]

    @property
    def digest(self) -> str:
        """SHA-256 of the manifest: identifies this exact archive."""
        return hashlib.sha256(self.manifest_bytes).hexdigest()

    def open_object(self, sha: str) -> BinaryIO:
        if self._zip is None:
            raise ArchiveError("archive is closed")
        return self._zip.open(f"objects/{sha}")

    def close(self) -> None:
        if self._zip is not None:
            self._zip.close()
            self._zip = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def _member_name_ok(name: str) -> bool:
    if not name or len(name.encode("utf-8")) > 255 or name.startswith("/") or "\\" in name or ":" in name:
        return False
    return all(part not in ("", ".", "..") for part in name.split("/"))


def check_manifest(m: object) -> dict:
    if not isinstance(m, dict) or set(m) != MANIFEST_KEYS:
        raise ArchiveError("manifest fields wrong")
    if m["format"] != FORMAT:
        raise ArchiveError("not a FieldWorx archive")
    if m["version"] != VERSION:
        raise ArchiveError(f"archive version {m['version']!r} is newer than this program understands; update it")
    if m["kind"] not in MIME:
        raise ArchiveError("unknown archive kind")
    if not isinstance(m["id"], str) or not RE_ARCHIVE_ID.match(m["id"]) or m["id"][:3] != {"package": "pkg",
                                                                                          "fieldlog": "flg"}[m["kind"]]:
        raise ArchiveError("archive id malformed")
    for k, limit in (("title", 200), ("series", 128), ("created", 40)):
        if not isinstance(m[k], str) or len(m[k]) > limit:
            raise ArchiveError(f"{k} malformed")
    if not ev_mod.RE_TIME.match(m["created"]):
        raise ArchiveError("created must be a UTC time")
    for k in ("created_by", "source"):
        if not isinstance(m[k], dict) or not all(isinstance(v, str) and len(v) <= 200 for v in m[k].values()):
            raise ArchiveError(f"{k} must be an object of short texts")
    if m["kind"] == "package":
        c = m["catalog"]
        if not isinstance(c, dict) or set(c) != {"sha256", "size"} or not _sha_ok(c["sha256"]) or not _size_ok(
                c["size"], MAX_CATALOG):
            raise ArchiveError("a package must describe its catalog")
    elif m["catalog"] is not None:
        raise ArchiveError("a field log has no catalog")
    if not isinstance(m["events"], list) or not isinstance(m["objects"], list) or not isinstance(m["notices"], list):
        raise ArchiveError("events, objects and notices must be lists")
    if len(m["events"]) + len(m["objects"]) > MAX_MEMBERS:
        raise ArchiveError("too many members")
    ids = set()
    for e in m["events"]:
        if not isinstance(e, dict) or set(e) != {"id", "size"} or not _sha_ok(e["id"]) or not _size_ok(
                e["size"], ev_mod.MAX_EVENT_BYTES):
            raise ArchiveError("event entry malformed")
        if e["id"] in ids:
            raise ArchiveError("an event is listed twice")
        ids.add(e["id"])
    shas = set()
    for o in m["objects"]:
        if (not isinstance(o, dict) or set(o) != {"sha256", "size", "media_type"} or not _sha_ok(o["sha256"])
                or not _size_ok(o["size"], MAX_OBJECT) or not isinstance(o["media_type"], str)
                or not RE_MEDIA.match(o["media_type"])):
            raise ArchiveError("object entry malformed")
        if o["sha256"] in shas:
            raise ArchiveError("an object is listed twice")
        shas.add(o["sha256"])
    if [o["sha256"] for o in m["objects"]] != sorted(shas):
        raise ArchiveError("objects must be listed in hash order")
    if not all(isinstance(n, str) and len(n) <= 1000 for n in m["notices"]):
        raise ArchiveError("notices must be short texts")
    return m


def _sha_ok(s) -> bool:
    return isinstance(s, str) and bool(ev_mod.RE_HASH.match(s))


def _size_ok(n, limit: int) -> bool:
    return isinstance(n, int) and not isinstance(n, bool) and 0 <= n <= limit


def _read_exact(z: zipfile.ZipFile, info: zipfile.ZipInfo, size: int, limit: int) -> bytes:
    if info.file_size != size or size > limit:
        raise ArchiveError(f"{info.filename} has the wrong size")
    with z.open(info) as f:
        data = f.read(size + 1)
    if len(data) != size:
        raise ArchiveError(f"{info.filename} has the wrong size")
    return data


def read(path: Path | str | BinaryIO, verify_objects: bool = True) -> Archive:
    """Open and check an archive. Objects stay in the ZIP (``open_object``); everything else is loaded."""
    try:
        z = zipfile.ZipFile(path)
    except (zipfile.BadZipFile, OSError) as exc:
        raise ArchiveError(f"not a readable FieldWorx file: {exc}") from None
    try:
        return _read(z, verify_objects)
    except ArchiveError:
        z.close()
        raise
    except (zipfile.BadZipFile, zlib.error, OSError, EOFError, NotImplementedError, RuntimeError) as exc:
        z.close()                                   # zlib.error: compressed data that doesn't decompress
        raise ArchiveError(f"damaged FieldWorx file: {exc}") from None


def _read(z: zipfile.ZipFile, verify_objects: bool) -> Archive:
    infos = z.infolist()
    if len(infos) > MAX_MEMBERS + 3:
        raise ArchiveError("too many members")
    names = {}
    for info in infos:
        if not _member_name_ok(info.filename):
            raise ArchiveError(f"member name {info.filename!r} is not allowed")
        if info.filename in names:
            raise ArchiveError(f"member {info.filename} appears twice")
        names[info.filename] = info
    if not infos or infos[0].filename != "mimetype" or infos[0].compress_type != zipfile.ZIP_STORED:
        raise ArchiveError("not a FieldWorx file (no mimetype first)")
    mime = _read_exact(z, infos[0], infos[0].file_size, 100).decode("ascii", "replace")
    kind = next((k for k, v in MIME.items() if v == mime), None)
    if kind is None:
        raise ArchiveError("not a FieldWorx file")
    if "manifest.json" not in names:
        raise ArchiveError("manifest missing")
    mi = names["manifest.json"]
    if mi.file_size > MAX_MANIFEST:
        raise ArchiveError("manifest too large")
    mbytes = _read_exact(z, mi, mi.file_size, MAX_MANIFEST)
    try:
        manifest = fxjson.parse_canonical(mbytes)
    except fxjson.FxJsonError as exc:
        raise ArchiveError(f"manifest unreadable: {exc}") from None
    check_manifest(manifest)
    if manifest["kind"] != kind:
        raise ArchiveError("mimetype and manifest disagree")

    catalog = None
    if kind == "package":
        c = manifest["catalog"]
        info = names.get("catalog.json")
        if info is None:
            raise ArchiveError("catalog missing")
        cbytes = _read_exact(z, info, c["size"], MAX_CATALOG)
        if hashlib.sha256(cbytes).hexdigest() != c["sha256"]:
            raise ArchiveError("catalog does not match the manifest")
        try:
            catalog = fxjson.parse_canonical(cbytes)
        except fxjson.FxJsonError as exc:
            raise ArchiveError(f"catalog unreadable: {exc}") from None

    evs = []
    for e in manifest["events"]:
        info = names.get(f"events/{e['id']}")
        if info is None:
            raise ArchiveError(f"event {e['id'][:12]} missing")
        raw = _read_exact(z, info, e["size"], ev_mod.MAX_EVENT_BYTES)
        try:
            evs.append(ev_mod.from_bytes(raw, e["id"]))
        except ev_mod.EventError as exc:
            raise ArchiveError(f"event {e['id'][:12]}: {exc}") from None

    objects = {}
    for o in manifest["objects"]:
        info = names.get(f"objects/{o['sha256']}")
        if info is None:
            raise ArchiveError(f"file {o['sha256'][:12]} missing")
        if info.file_size != o["size"]:
            raise ArchiveError(f"file {o['sha256'][:12]} has the wrong size")
        if verify_objects:
            h = hashlib.sha256()
            n = 0
            with z.open(info) as f:
                while chunk := f.read(1 << 20):
                    n += len(chunk)
                    if n > o["size"]:
                        break
                    h.update(chunk)
            if n != o["size"] or h.hexdigest() != o["sha256"]:
                raise ArchiveError(f"file {o['sha256'][:12]} is damaged")
        objects[o["sha256"]] = {"size": o["size"], "media_type": o["media_type"]}
    return Archive(kind, manifest, mbytes, catalog, evs, objects, z)


class ObjectSource:
    """Where a writer gets an object's bytes from: a path or bytes in memory."""

    def __init__(self, sha256: str, size: int, media_type: str, path: Path | None = None, data: bytes | None = None):
        self.sha256, self.size, self.media_type, self.path, self.data = sha256, size, media_type, path, data

    @classmethod
    def from_bytes(cls, data: bytes, media_type: str) -> "ObjectSource":
        return cls(hashlib.sha256(data).hexdigest(), len(data), media_type, data=data)

    @classmethod
    def from_path(cls, path: Path, media_type: str) -> "ObjectSource":
        h, n = hashlib.sha256(), 0
        with open(path, "rb") as f:
            while chunk := f.read(1 << 20):
                h.update(chunk)
                n += len(chunk)
        return cls(h.hexdigest(), n, media_type, path=Path(path))


def write(out: Path, kind: str, *, archive_id: str, title: str, created: str, created_by: dict, source: dict | None = None,
          series: str = "", catalog: dict | None = None, events: Iterable[ev_mod.Event] = (),
          objects: Iterable[ObjectSource] = (), notices: Iterable[str] = (), overwrite: bool = False) -> dict:
    """Write an archive all-or-nothing to ``out``. Returns its manifest."""
    events = list(events)
    objs = {o.sha256: o for o in objects}
    cbytes = fxjson.encode(catalog) if catalog is not None else None
    manifest = {"format": FORMAT, "version": VERSION, "kind": kind, "id": archive_id, "title": title,
                "series": series, "created": created, "created_by": dict(created_by), "source": dict(source or {}),
                "catalog": ({"sha256": hashlib.sha256(cbytes).hexdigest(), "size": len(cbytes)}
                            if cbytes is not None else None),
                "events": [{"id": e.id, "size": len(e.raw)} for e in events],
                "objects": [{"sha256": s, "size": objs[s].size, "media_type": objs[s].media_type} for s in sorted(objs)],
                "notices": list(notices)}
    check_manifest(manifest)
    mbytes = fxjson.encode(manifest)

    def fill(f):
        with zipfile.ZipFile(f, "w", allowZip64=True) as z:
            z.writestr(zipfile.ZipInfo("mimetype", date_time=(2026, 1, 1, 0, 0, 0)), MIME[kind].encode("ascii"),
                       compress_type=zipfile.ZIP_STORED)
            _put(z, "manifest.json", mbytes, zipfile.ZIP_DEFLATED)
            if cbytes is not None:
                _put(z, "catalog.json", cbytes, zipfile.ZIP_DEFLATED)
            for e in events:
                _put(z, f"events/{e.id}", e.raw, zipfile.ZIP_DEFLATED)
            for s in sorted(objs):
                o = objs[s]
                method = zipfile.ZIP_STORED if o.media_type in STORED_MEDIA else zipfile.ZIP_DEFLATED
                info = zipfile.ZipInfo(f"objects/{s}", date_time=(2026, 1, 1, 0, 0, 0))
                info.compress_type = method
                if o.data is not None:
                    z.writestr(info, o.data)
                else:
                    h = hashlib.sha256()
                    with open(o.path, "rb") as src, z.open(info, "w", force_zip64=o.size > 2**31) as dst:
                        while chunk := src.read(1 << 20):
                            h.update(chunk)
                            dst.write(chunk)
                    if h.hexdigest() != s:
                        raise ArchiveError(f"{o.path} changed while it was being packed")

    safefile.write_output(Path(out), fill, overwrite=overwrite)
    return manifest


def _put(z: zipfile.ZipFile, name: str, data: bytes, method: int) -> None:
    info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
    info.compress_type = method
    z.writestr(info, data)


def read_bytes(data: bytes, verify_objects: bool = True) -> Archive:
    return read(io.BytesIO(data), verify_objects)
