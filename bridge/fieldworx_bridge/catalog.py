# SPDX-License-Identifier: GPL-3.0-or-later
"""The engineering snapshot inside a package (docs/PROTOCOL.md section 6).

It is read-only on every phone: authority stays with RevisionWorx (documents, revisions, BOMs) and OpenMeridian
(stock). ``check_catalog`` is the strict reader; the builder runs every catalog through it before writing, and the
Dart reader (core/lib/src/catalog.dart) applies the same rules, so a malformed catalog is refused rather than
half-shown.
"""
from __future__ import annotations

import re
from typing import Any

from . import inspections

FORMAT = "fieldworx.catalog"
VERSION = 1
RE_SHA = re.compile(r"[0-9a-f]{64}\Z")
RE_QTY = re.compile(r"(0|[1-9]\d{0,14})(\.\d{1,9})?\Z")
TOP_KEYS = {"format", "version", "projects", "documents", "parts", "bom", "assets", "templates"}


class CatalogError(ValueError):
    pass


def _s(v: Any, what: str, limit: int = 500) -> str:
    if not isinstance(v, str) or len(v) > limit:
        raise CatalogError(f"{what} must be text of at most {limit} characters")
    return v


def _keys(d: Any, want: set[str], what: str) -> dict:
    if not isinstance(d, dict) or set(d) != want:
        got = set(d) if isinstance(d, dict) else set()
        raise CatalogError(f"{what}: fields wrong (missing {sorted(want - got)}, unknown {sorted(got - want)})")
    return d


def _list(v: Any, what: str, limit: int = 1_000_000) -> list:
    if not isinstance(v, list) or len(v) > limit:
        raise CatalogError(f"{what} must be a list")
    return v


def check_catalog(c: Any) -> dict:
    _keys(c, TOP_KEYS, "catalog")
    if c["format"] != FORMAT:
        raise CatalogError("not a FieldWorx catalog")
    if c["version"] != VERSION:
        raise CatalogError(f"catalog version {c['version']!r} is newer than this program understands; update it")
    ids: set[str] = set()

    def unique(i: str, what: str) -> None:
        if i in ids:
            raise CatalogError(f"{what} id {i} appears twice")
        ids.add(i)

    projects = set()
    for p in _list(c["projects"], "projects"):
        _keys(p, {"id", "number", "name", "customer"}, "project")
        for k in p:
            _s(p[k], f"project {k}", 200)
        unique(p["id"], "project")
        projects.add(p["id"])

    revs: dict[str, str] = {}
    docs = set()
    for d in _list(c["documents"], "documents"):
        _keys(d, {"id", "number", "title", "type", "project", "path", "released", "latest", "revisions"}, "document")
        for k in ("id", "number", "title", "type", "project", "path", "released", "latest"):
            _s(d[k], f"document {k}")
        unique(d["id"], "document")
        docs.add(d["id"])
        if d["project"] and d["project"] not in projects:
            raise CatalogError(f"document {d['number'] or d['id']} names a project that isn't in the package")
        own = set()
        for r in _list(d["revisions"], "revisions", 10_000):
            _keys(r, {"id", "label", "state", "state_name", "sha256", "size", "created", "author", "description",
                      "ext", "rendition"}, "revision")
            for k in ("id", "label", "state", "state_name", "created", "author", "ext"):
                _s(r[k], f"revision {k}", 200)
            _s(r["description"], "revision description", 4000)
            if not RE_SHA.match(r["sha256"]) or not isinstance(r["size"], int) or isinstance(r["size"], bool):
                raise CatalogError("revision hash or size malformed")
            unique(r["id"], "revision")
            revs[r["id"]] = d["id"]
            own.add(r["id"])
            rend = r["rendition"]
            if rend is not None:
                _keys(rend, {"object", "media_type", "via"}, "rendition")
                if not RE_SHA.match(_s(rend["object"], "rendition object")):
                    raise CatalogError("rendition object malformed")
                _s(rend["media_type"], "rendition media type", 100)
                _s(rend["via"], "rendition via", 200)
        for k in ("released", "latest"):
            if d[k] and d[k] not in own:
                raise CatalogError(f"document {d['number'] or d['id']}: {k} revision is not among its revisions")

    parts = set()
    for p in _list(c["parts"], "parts"):
        _keys(p, {"id", "number", "description", "unit", "kind", "revision", "status", "manufacturers", "vendors",
                  "documents", "attributes", "stock"}, "part")
        for k in ("id", "number", "description", "unit", "kind", "revision", "status"):
            _s(p[k], f"part {k}")
        unique(p["id"], "part")
        parts.add(p["id"])
        for m in _list(p["manufacturers"], "manufacturers", 100):
            _keys(m, {"name", "mpn"}, "manufacturer")
            _s(m["name"], "manufacturer", 200), _s(m["mpn"], "MPN", 200)
        for v in _list(p["vendors"], "vendors", 100):
            _keys(v, {"name", "sku"}, "vendor")
            _s(v["name"], "vendor", 200), _s(v["sku"], "SKU", 200)
        for dl in _list(p["documents"], "part documents", 100):
            _keys(dl, {"document", "revision", "role"}, "part document")
            for k in dl:
                _s(dl[k], f"part document {k}", 200)
        if not isinstance(p["attributes"], dict) or len(p["attributes"]) > 200:
            raise CatalogError("part attributes must be an object")
        for k, v in p["attributes"].items():
            _s(k, "attribute name", 100), _s(v, "attribute value", 1000)
        st = p["stock"]
        if st is not None:
            _keys(st, {"on_hand", "unit", "bin", "as_of", "source"}, "stock")
            for k in st:
                _s(st[k], f"stock {k}", 200)
            if not re.fullmatch(r"-?(0|[1-9]\d{0,14})(\.\d{1,9})?", st["on_hand"]):
                raise CatalogError("stock on hand must be a decimal")

    for b in _list(c["bom"], "bom"):
        _keys(b, {"parent", "child", "quantity", "unit", "find_number", "refdes", "note", "provenance", "source"},
              "BOM line")
        for k in ("parent", "child", "quantity", "unit", "find_number", "note", "provenance", "source"):
            _s(b[k], f"BOM line {k}", 1000)
        if b["parent"] not in parts or b["child"] not in parts:
            raise CatalogError("a BOM line names a part that isn't in the package")
        if not RE_QTY.match(b["quantity"]):
            raise CatalogError("BOM quantity must be a positive decimal")
        for r in _list(b["refdes"], "reference designators", 10_000):
            _s(r, "reference designator", 64)

    for a in _list(c["assets"], "assets"):
        _keys(a, {"id", "tag", "serial", "name", "part", "project", "location", "built", "notes", "as_built"}, "asset")
        for k in ("id", "tag", "serial", "name", "part", "project", "location", "built"):
            _s(a[k], f"asset {k}", 200)
        _s(a["notes"], "asset notes", 4000)
        unique(a["id"], "asset")
        if a["part"] and a["part"] not in parts:
            raise CatalogError(f"asset {a['tag'] or a['id']} names a part that isn't in the package")
        if a["project"] and a["project"] not in projects:
            raise CatalogError(f"asset {a['tag'] or a['id']} names a project that isn't in the package")
        for r in _list(a["as_built"], "as-built revisions", 1000):
            if r not in revs:
                raise CatalogError(f"asset {a['tag'] or a['id']} names an as-built revision that isn't in the package")

    tids = set()
    for t in _list(c["templates"], "templates", 10_000):
        _keys(t, {"template", "document", "revision", "state"}, "template entry")
        try:
            inspections.check_template(t["template"])
        except inspections.TemplateError as exc:
            raise CatalogError(f"template: {exc}") from None
        key = (t["template"]["id"].casefold(), t["template"]["revision"].casefold())
        if key in tids:
            raise CatalogError(f"template {t['template']['id']} rev {t['template']['revision']} appears twice")
        tids.add(key)
        for k in ("document", "revision", "state"):
            _s(t[k], f"template {k}", 200)
        if t["document"] and t["document"] not in docs:
            raise CatalogError("a template names a document that isn't in the package")
    return c


def empty() -> dict:
    return {"format": FORMAT, "version": VERSION, "projects": [], "documents": [], "parts": [], "bom": [],
            "assets": [], "templates": []}
