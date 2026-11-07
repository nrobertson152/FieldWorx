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
VERSION = 2                     # what this writes; READS is what it reads (docs/PROTOCOL.md section 6)
READS = (1, 2)
RE_SHA = re.compile(r"[0-9a-f]{64}\Z")
RE_ASSET_ID = re.compile(r"(unt|ast)_[0-9a-f]{32}\Z")
RE_ALIAS = re.compile(r"ast_[0-9a-f]{32}\Z")
ASSET_V1 = {"id", "tag", "serial", "name", "part", "project", "location", "built", "notes", "as_built"}
ASSET_V2 = {"id", "aliases", "label", "class", "name", "model", "part", "project", "customer", "site", "location", "status",
            "identifiers", "parent", "standard", "documents", "components", "milestones", "history", "changes", "notes",
            "source"}
CLASSES = ("product", "component", "instrument", "tool")
STATUSES = ("", "planned", "in-build", "built", "in-service", "out-of-service", "retired", "scrapped")
SCHEMES = ("serial", "tag", "other")
SOURCES = ("standard", "unit", "register")
BASES = ("verified", "reported", "declared", "legacy")
MILESTONES = ("built", "shipped", "installed", "commissioned", "decommissioned")
CHANGE_KINDS = ("", "production", "retrofit-required", "retrofit-optional", "unit", "documentation")
CHANGE_STATES = ("pending", "offered", "accepted", "scheduled", "deferred", "declined", "installed", "verified",
                 "not-applicable", "reversed")
CHANGE_DONE = ("verified", "not-applicable")
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
    if c["version"] not in READS:
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

    if c["version"] == 1:
        for a in _list(c["assets"], "assets"):
            _keys(a, ASSET_V1, "asset")
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
    else:
        _check_assets_v2(_list(c["assets"], "assets"), unique, projects, docs, parts, revs)

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


def _choice(v: Any, choices: tuple, what: str) -> str:
    if v not in choices:
        raise CatalogError(f"{what} must be one of {', '.join(c or '(empty)' for c in choices)}")
    return v


def _bool(v: Any, what: str) -> bool:
    if not isinstance(v, bool):
        raise CatalogError(f"{what} must be true or false")
    return v


def _check_assets_v2(assets: list, unique, projects: set, docs: set, parts: set, revs: dict) -> None:
    ids: set[str] = set()
    parents: dict[str, str] = {}
    for a in assets:
        _keys(a, ASSET_V2, "asset")
        what = f"asset {a.get('label') or a.get('id')}"
        if not isinstance(a["id"], str) or not RE_ASSET_ID.match(a["id"]):
            raise CatalogError(f"{what}: id must be unt_ or ast_ and 32 hex digits")
        unique(a["id"], "asset")
        ids.add(a["id"])
        aliases = _list(a["aliases"], f"{what} aliases", 100)
        if any(not isinstance(x, str) or not RE_ALIAS.match(x) for x in aliases) or aliases != sorted(set(aliases)):
            raise CatalogError(f"{what}: aliases must be ast_ ids, sorted and unique")
        for x in aliases:
            unique(x, "asset")
        for k in ("label", "name", "customer", "site", "location", "source"):
            _s(a[k], f"{what} {k}", 200)
        _s(a["model"], f"{what} model", 100)
        _s(a["notes"], f"{what} notes", 4000)
        _choice(a["class"], CLASSES, f"{what} class")
        _choice(a["status"], STATUSES, f"{what} status")
        _s(a["part"], f"{what} part", 64)
        _s(a["project"], f"{what} project", 64)
        if a["part"] and a["part"] not in parts:
            raise CatalogError(f"{what} names a part that isn't in the package")
        if a["project"] and a["project"] not in projects:
            raise CatalogError(f"{what} names a project that isn't in the package")
        for i in _list(a["identifiers"], f"{what} identifiers", 100):
            _keys(i, {"scheme", "issuer", "value", "active"}, "identifier")
            _choice(i["scheme"], SCHEMES, "identifier scheme")
            _s(i["issuer"], "identifier issuer", 200)
            if not _s(i["value"], "identifier value", 100):
                raise CatalogError(f"{what}: an identifier has no value")
            _bool(i["active"], "identifier active")
        if a["parent"] is not None:
            _keys(a["parent"], {"asset", "position"}, "parent")
            _s(a["parent"]["asset"], "parent asset", 64)
            _s(a["parent"]["position"], "parent position", 64)
            parents[a["id"]] = a["parent"]["asset"]
        if a["standard"] is not None:
            _keys(a["standard"], {"number", "title"}, "standard")
            _s(a["standard"]["number"], "standard number", 64)
            _s(a["standard"]["title"], "standard title", 200)
        seen_docs: set[str] = set()
        for d in _list(a["documents"], f"{what} documents", 2000):
            _keys(d, {"document", "revision", "source", "basis"}, "asset document")
            doc, rev = _s(d["document"], "asset document", 64), _s(d["revision"], "asset revision", 64)
            if doc in seen_docs:
                raise CatalogError(f"{what} names a document twice")
            seen_docs.add(doc)
            if doc not in docs:
                raise CatalogError(f"{what} names a document that isn't in the package")
            if rev and revs.get(rev) != doc:
                raise CatalogError(f"{what} names a revision that isn't in the package (or isn't of its document)")
            _choice(d["source"], SOURCES, "document source")
            _choice(d["basis"], BASES, "document basis")
        positions: set[str] = set()
        for comp in _list(a["components"], f"{what} components", 1000):
            _keys(comp, {"position", "part", "number", "asset", "serial", "lot", "since", "basis"}, "component")
            pos = _s(comp["position"], "component position", 64)
            if not pos or pos in positions:
                raise CatalogError(f"{what}: component positions must be given and unique")
            positions.add(pos)
            for k in ("part", "number", "asset", "serial", "lot", "since"):
                _s(comp[k], f"component {k}", 200)
            if comp["part"] and comp["part"] not in parts:
                raise CatalogError(f"{what}: a component names a part that isn't in the package")
            _choice(comp["basis"], BASES, "component basis")
        ms = a["milestones"]
        if not isinstance(ms, dict) or set(ms) - set(MILESTONES):
            raise CatalogError(f"{what}: milestones are built, shipped, installed, commissioned, decommissioned")
        for v in ms.values():
            _s(v, "milestone date", 32)
        last = 0
        for h in _list(a["history"], f"{what} history", 1000):
            _keys(h, {"n", "type", "summary", "effective", "time", "actor", "basis", "voided"}, "history entry")
            if not isinstance(h["n"], int) or isinstance(h["n"], bool) or h["n"] <= last:
                raise CatalogError(f"{what}: history numbers must increase")
            last = h["n"]
            _s(h["type"], "history type", 64)
            _s(h["summary"], "history summary", 500)
            for k in ("effective", "time"):
                _s(h[k], f"history {k}", 32)
            _s(h["actor"], "history actor", 200)
            _choice(h["basis"], BASES, "history basis")
            _bool(h["voided"], "history voided")
        seen_changes: set[str] = set()
        for ch in _list(a["changes"], f"{what} changes", 200):
            _keys(ch, {"change", "number", "title", "kind", "required", "state", "since", "documents"}, "change")
            cid = _s(ch["change"], "change id", 64)
            if not cid or cid in seen_changes:
                raise CatalogError(f"{what}: each change is given once, with its id")
            seen_changes.add(cid)
            _s(ch["number"], "change number", 64)
            _s(ch["title"], "change title", 200)
            _choice(ch["kind"], CHANGE_KINDS, "change kind")
            _bool(ch["required"], "change required")
            _choice(ch["state"], CHANGE_STATES, "change state")
            _s(ch["since"], "change since", 32)
            for row in _list(ch["documents"], "change documents", 100):
                _keys(row, {"number", "from", "to"}, "change document")
                for k in ("number", "from", "to"):
                    _s(row[k], f"change document {k}", 64)
    for a in assets:
        for ref in [c["asset"] for c in a["components"] if c["asset"]] + ([a["parent"]["asset"]] if a["parent"] else []):
            if ref not in ids:
                raise CatalogError(f"asset {a['label'] or a['id']} names an asset that isn't in the package")
    for start in parents:                               # nothing is fitted inside itself
        seen, cur = {start}, parents.get(start)
        while cur is not None:
            if cur in seen:
                raise CatalogError("assets are fitted inside each other in a loop")
            seen.add(cur)
            cur = parents.get(cur)



def asset_view(a: dict, version: int, revision_document: dict[str, str]) -> dict:
    """An asset as version 2 describes it, whatever the version of its catalog (docs/PROTOCOL.md section 6.4)."""
    if version != 1:
        return a
    idents = [{"scheme": s, "issuer": "", "value": a[s], "active": True} for s in ("tag", "serial") if a[s]]
    return {"id": a["id"], "aliases": [], "label": a["tag"] or a["serial"], "class": "product", "name": a["name"],
            "model": "", "part": a["part"], "project": a["project"], "customer": "", "site": "",
            "location": a["location"], "status": "", "identifiers": idents, "parent": None, "standard": None,
            "documents": [{"document": revision_document[r], "revision": r, "source": "register", "basis": "legacy"}
                          for r in a["as_built"]],
            "components": [], "milestones": {"built": a["built"]} if a["built"] else {}, "history": [], "changes": [],
            "notes": a["notes"], "source": ""}


def assets_view(c: dict) -> list[dict]:
    """Every asset of a checked catalog in the version 2 shape."""
    owner = {r["id"]: d["id"] for d in c["documents"] for r in d["revisions"]}
    return [asset_view(a, c["version"], owner) for a in c["assets"]]


def empty() -> dict:
    return {"format": FORMAT, "version": VERSION, "projects": [], "documents": [], "parts": [], "bom": [],
            "assets": [], "templates": []}
