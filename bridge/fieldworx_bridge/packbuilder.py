# SPDX-License-Identifier: GPL-3.0-or-later
"""Build a FieldWorx package: a read-only snapshot of engineering for the phones (docs/ARCHITECTURE.md, ADR-003).

What goes in, per document of the chosen projects:
* every revision's metadata (label, state, author, SHA-256), so the phone can say what it doesn't have;
* the content of the released revision, the latest one too with ``unreleased=True``, and every revision an asset
  register names as built; PDFs are shown as they are, DraftWorx drawings through ``draftworx pdf``;
* BOMs (read by RevisionWorx's BOM reader), RevisionWorx parts lists, inspection templates (``*.fwtemplate.csv`` or
  ``.json``) and asset registers (``*.fwassets.csv``), all from their released revisions;
* stock on hand from an OpenMeridian company file, labelled with when it was read.

Everything left out is said in the package's notices. A revision whose content doesn't match the SHA-256 RevisionWorx
recorded stops the build (fail closed).
"""
from __future__ import annotations

import getpass
import hashlib
import platform
import re
import tempfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from . import __version__, archive, catalog as cat_mod, events as ev_mod, fxjson, inspections, sources

TEMPLATE_SUFFIXES = (".fwtemplate.csv", ".fwtemplate.json")
ASSET_SUFFIX = ".fwassets.csv"
TABLE_EXT = (".csv", ".xlsx", ".json")
MEDIA = {".pdf": "application/pdf", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg"}


@dataclass
class PackOptions:
    workspace: Path | None = None
    projects: list[str] = field(default_factory=list)        # ids, numbers or names; empty = every project
    unreleased: bool = False
    meridian: Path | None = None
    templates_dir: Path | None = None                          # uncontrolled templates (labelled as such)
    assets_csv: Path | None = None                             # uncontrolled asset register
    title: str = ""
    revisionworx: str | None = None
    draftworx: str | None = None
    field_events: list[ev_mod.Event] = field(default_factory=list)


def _lower_name(doc: dict) -> str:
    return Path(doc.get("path") or "").name.casefold()


def _ext(doc: dict) -> str:
    name = _lower_name(doc)
    for s in TEMPLATE_SUFFIXES + (ASSET_SUFFIX,):
        if name.endswith(s):
            return s
    return Path(name).suffix


def _rev(r: dict) -> dict:
    return {"id": r["id"], "label": r.get("label", ""), "state": r.get("state", ""),
            "state_name": r.get("state_name", ""), "sha256": r["sha256"], "size": int(r.get("size", 0)),
            "created": r.get("created", ""), "author": r.get("author", ""),
            "description": (r.get("description") or "")[:4000]}


class PackBuilder:
    def __init__(self, opts: PackOptions, log=print):
        self.o = opts
        self.log = log
        self.notices: list[str] = []
        self.objects: dict[str, archive.ObjectSource] = {}
        self.work = Path(tempfile.mkdtemp(prefix="fieldworx-pack-"))

    def note(self, text: str) -> None:
        if text not in self.notices:
            self.notices.append(text)

    # -------------------------------------------------------------------------------------------------- build
    def build(self) -> tuple[dict, dict, list[archive.ObjectSource]]:
        rwx = sources.RevisionWorxSource(self.o.workspace, self.o.revisionworx)
        dwx = sources.DraftWorx(self.o.draftworx)
        all_projects = rwx.projects()
        info = rwx.info
        chosen = self._choose_projects(all_projects)
        self.log(f"RevisionWorx {rwx.version}, workspace {info.get('name', '')}: {len(chosen)} project(s)")

        documents: list[dict] = []
        histories: dict[str, list[dict]] = {}
        meta: dict[str, dict] = {}
        for p in chosen:
            for d in rwx.documents(p["id"]):
                full = rwx.document(d["id"])
                histories[d["id"]] = [_rev(r) for r in full.get("history", [])]
                meta[d["id"]] = {**d, "project_id": p["id"]}
        # Units from RevisionWorx's unit register: those of the chosen projects and everything fitted in them. A document
        # a unit uses comes along even from another project, so the unit's page is complete (docs/PROTOCOL.md 6.4).
        units = self._choose_units(rwx.units(), chosen)
        extra_projects: dict[str, dict] = {}
        by_project = {p["id"]: p for p in all_projects}
        for u in units:
            if u["project"] and u["project"]["id"] not in {c["id"] for c in chosen}:
                extra_projects.setdefault(u["project"]["id"], by_project.get(u["project"]["id"], u["project"]))
            for row in u["documents"]:
                did = row["document"]["id"]
                if did in meta or "missing" in row["flags"]:
                    continue
                full = rwx.document(did)
                histories[did] = [_rev(r) for r in full.get("history", [])]
                meta[did] = {**full, "project_id": full["project"]["id"]}
                if full["project"]["id"] not in {c["id"] for c in chosen}:
                    extra_projects.setdefault(full["project"]["id"], by_project.get(full["project"]["id"], full["project"]))
                self.note(f"{full.get('number') or did} is from project {full['project'].get('number') or ''}, which "
                          "wasn't chosen; it is included because a unit in this package uses it.")
        by_number = {meta[i]["number"].casefold(): i for i in meta if meta[i].get("number")}

        # Which revisions are needed with content.
        wanted: dict[str, set[str]] = {i: set() for i in meta}
        for u in units:
            for row in u["documents"]:
                if row["revision"] and "missing" not in row["flags"] and row["document"]["id"] in wanted:
                    wanted[row["document"]["id"]].add(row["revision"]["id"])
        for i, d in meta.items():
            sel = self._selected(d)
            if sel:
                wanted[i].add(sel["id"])

        # Asset registers come first: they say which (older) revisions must come along as built.
        asset_rows: list[tuple[dict, str, str]] = []           # row, register label, state
        for i, d in sorted(meta.items(), key=lambda kv: kv[1].get("number", "")):
            if _ext(d) != ASSET_SUFFIX:
                continue
            sel = self._selected(d)
            if not sel:
                self.note(f"Asset register {d.get('number')} has no released revision; it was not used.")
                continue
            path = rwx.fetch(i, sel["label"], sel["sha256"], self.work)
            try:
                for row in sources.parse_assets_csv(sources.as_text(path)):
                    asset_rows.append((row, f"{d.get('number')} rev {sel['label']}", sel["state"]))
            except sources.SourceError as exc:
                self.note(f"Asset register {d.get('number')} was not used: {exc}")
        if self.o.assets_csv:
            for row in sources.parse_assets_csv(sources.as_text(self.o.assets_csv)):
                asset_rows.append((row, f"{self.o.assets_csv.name} (uncontrolled)", "uncontrolled"))
        for row, src, _ in asset_rows:
            resolved = []
            for ref in row["as_built"]:
                num, _, label = ref.partition("@")
                did = by_number.get(num.strip().casefold())
                hit = None
                if did:
                    hit = next((r for r in histories[did] if r["label"].casefold() == label.strip().casefold()), None)
                if hit is None:
                    self.note(f"{row['tag'] or row['serial']}: as-built {ref} isn't a revision in this package "
                              f"({src}); left out.")
                    continue
                wanted[did].add(hit["id"])
                resolved.append(hit["id"])
            row["_as_built_ids"] = resolved

        # Content, renditions, and the documents that are data (BOMs, parts lists, templates).
        structures: list[tuple[str, dict]] = []
        parts_rows: list[tuple[str, dict]] = []
        templates: list[dict] = []
        for i in sorted(meta, key=lambda k: meta[k].get("number", "")):
            d = meta[i]
            ext = _ext(d)
            revs = []
            for r in histories[i]:
                rend = None
                if r["id"] in wanted[i]:
                    rend, path = self._content(rwx, dwx, i, d, r, ext)
                    if path is not None and r["id"] == (self._selected(d) or {}).get("id"):
                        self._data_document(rwx, d, r, ext, path, structures, parts_rows, templates)
                revs.append({**r, "ext": ext, "rendition": rend})
            released = (d.get("released") or {}).get("id", "")
            latest = (d.get("latest") or {}).get("id", "")
            documents.append({"id": i, "number": d.get("number", ""), "title": d.get("title", ""),
                              "type": d.get("type", ""), "project": d["project_id"], "path": Path(d.get("path") or "").name,
                              "released": released if any(r["id"] == released for r in revs) else "",
                              "latest": latest if any(r["id"] == latest for r in revs) else "",
                              "revisions": revs})
            if not released:
                self.note(f"{d.get('number') or d.get('title')} has no released revision"
                          + ("; its latest is included and marked as not released." if self.o.unreleased
                             else "; only its details are included."))
        if self.o.templates_dir:
            for f in sorted(self.o.templates_dir.iterdir()):
                if f.name.casefold().endswith(TEMPLATE_SUFFIXES):
                    try:
                        t = self._template(f, f.name.split(".")[0], f.name.split(".")[0], "")
                        templates.append({"template": t, "document": "", "revision": "", "state": "uncontrolled"})
                    except (inspections.TemplateError, sources.SourceError) as exc:
                        self.note(f"Template {f.name} was not used: {exc}")

        parts, bom = self._parts_and_bom(structures, parts_rows, by_number, meta)
        part_by_num = {p["number"].casefold(): p["id"] for p in parts}
        projects = [{"id": p["id"], "number": p.get("number", ""), "name": p.get("name", ""),
                     "customer": p.get("customer", "")} for p in chosen]
        projects += [{"id": pid, "number": p.get("number", "") or "", "name": p.get("name", "") or "",
                      "customer": p.get("customer", "") or ""} for pid, p in sorted(extra_projects.items())]
        proj_by_num = {p["number"].casefold(): p["id"] for p in projects if p["number"]}
        project_ids = {p["id"] for p in projects}
        rev_doc = {r["id"]: i for i in meta for r in histories[i]}
        assets = [self._unit_asset(u, units, part_by_num, project_ids, rev_doc) for u in units]
        held = {a["id"] for a in assets} | {x for a in assets for x in a["aliases"]}
        held_codes = {(i["scheme"], i["value"].casefold()) for a in assets for i in a["identifiers"] if i["active"]}
        for row, src, _state in asset_rows:
            aid = asset_id(info.get("id", ""), row["tag"] or row["serial"])
            label = row["tag"] or row["serial"]
            if aid in held or ("tag", row["tag"].casefold()) in held_codes or ("serial", row["serial"].casefold()) in held_codes:
                self.note(f"{label} ({src}) is in RevisionWorx's unit register, which is the record for it; the register row "
                          "was not used.")
                continue
            pid = part_by_num.get(row["part"].casefold(), "") if row["part"] else ""
            if row["part"] and not pid:
                self.note(f"{label}: part {row['part']} isn't in this package.")
            prj = proj_by_num.get(row["project"].casefold(), "") if row["project"] else ""
            assets.append({
                "id": aid, "aliases": [], "label": label[:200], "class": "product", "name": row["name"][:200],
                "model": row["part"][:100], "part": pid, "project": prj, "customer": "", "site": "",
                "location": row["location"][:200], "status": "",
                "identifiers": [{"scheme": s, "issuer": "", "value": row[s][:100], "active": True}
                                for s in ("tag", "serial") if row[s]],
                "parent": None, "standard": None,
                "documents": [{"document": rev_doc[r], "revision": r, "source": "register", "basis": "legacy"}
                              for r in row["_as_built_ids"]],
                "components": [], "milestones": {"built": row["built"][:32]} if row["built"] else {}, "history": [],
                "changes": [],
                "notes": row["notes"][:4000], "source": src[:200]})
            held.add(aid)
        seen_assets: set[str] = set()
        for a in list(assets):
            if a["id"] in seen_assets:
                self.note(f"Asset {a['label']} appears in two registers; the first was used.")
                assets.remove(a)
            seen_assets.add(a["id"])

        catalog = {"format": cat_mod.FORMAT, "version": cat_mod.VERSION, "projects": projects,
                   "documents": documents, "parts": parts, "bom": bom, "assets": assets,
                   "templates": self._dedupe_templates(templates)}
        cat_mod.check_catalog(fxjson.parse(fxjson.encode(catalog)))
        source = {"system": "revisionworx", "workspace": info.get("id", ""), "name": info.get("name", ""),
                  "version": rwx.version, "projects": ",".join(sorted(p["id"] for p in chosen))}
        if self.o.meridian:
            source["stock"] = f"OpenMeridian {self.o.meridian.name}"
        return catalog, source, list(self.objects.values())

    # ------------------------------------------------------------------------------------------------ helpers
    def _choose_projects(self, all_projects: list[dict]) -> list[dict]:
        if not self.o.projects:
            return [p for p in all_projects if not p.get("archived")]
        out = []
        for ref in self.o.projects:
            r = ref.casefold()
            hits = [p for p in all_projects if r in (p["id"].casefold(), (p.get("number") or "").casefold(),
                                                     (p.get("name") or "").casefold())]
            if len(hits) != 1:
                raise sources.SourceError(f"project {ref!r} " + ("not found" if not hits else "is ambiguous"))
            if hits[0] not in out:
                out.append(hits[0])
        return out

    def _choose_units(self, register: list[dict] | None, chosen: list[dict]) -> list[dict]:
        """The register's units of the chosen projects, and every unit fitted in one of them, however deep."""
        if register is None:
            return []
        by_id = {u["id"]: u for u in register}
        every = not self.o.projects
        chosen_ids = {p["id"] for p in chosen}
        picked = [u for u in register if every or (u["project"] and u["project"]["id"] in chosen_ids)]
        out, seen = [], set()
        queue = list(picked)
        while queue:
            u = queue.pop(0)
            if u["id"] in seen:
                continue
            seen.add(u["id"])
            out.append(u)
            queue += [by_id[c["unit"]] for c in u["components"] if c["unit"] in by_id]
        left = len([u for u in register if u["id"] not in seen])
        if left:
            self.note(f"{left} unit(s) of RevisionWorx's unit register belong to other projects (or none) and were left "
                      "out; pack without --project to include every unit.")
        return sorted(out, key=lambda u: (u["label"].casefold(), u["id"]))

    @staticmethod
    def _unit_changes(u: dict) -> list[dict]:
        """The engineering changes RevisionWorx says reach a unit (its ``unit-changes`` feature), as PROTOCOL.md section 6.4
        keeps them: what the phone needs to show where each stands, nothing it could change."""
        out = []
        for c in (u.get("changes") or [])[:200]:
            out.append({"change": str(c["change"])[:64], "number": str(c["number"])[:64],
                        "title": str(c.get("title", ""))[:200], "kind": c.get("kind", ""), "required": bool(c["required"]),
                        "state": c["state"], "since": str(c.get("since", ""))[:32],
                        "documents": [{"number": str(d.get("number", ""))[:64], "from": str(d.get("from_label", ""))[:64],
                                       "to": str(d.get("to_label", ""))[:64]} for d in (c.get("documents") or [])[:100]]})
        return out

    def _unit_asset(self, u: dict, units: list[dict], part_by_num: dict, project_ids: set, rev_doc: dict) -> dict:
        """One unit of RevisionWorx's register as a version 2 catalog asset (docs/PROTOCOL.md section 6.4)."""
        included = {x["id"] for x in units}
        docs = []
        for row in u["documents"]:
            did = row["document"]["id"]
            rev = (row["revision"] or {}).get("id", "") if row["applies"] else ""
            if "missing" in row["flags"] or did not in rev_doc.values() or (rev and rev_doc.get(rev) != did):
                self.note(f"{u['label']}: {row['document'].get('number') or did} can't be found in RevisionWorx (a "
                          "damaged reference); it is left off the unit's page. Run 'revisionworx unit verify'.")
                continue
            docs.append({"document": did, "revision": rev, "source": row["source"], "basis": row["basis"]})
        comps = []
        for c in u["components"]:
            comps.append({"position": c["position"][:64], "part": part_by_num.get((c["number"] or "").casefold(), ""),
                          "number": (c["number"] or c.get("label") or "")[:200],
                          "asset": c["unit"] if c["unit"] in included else "", "serial": c["serial"][:200],
                          "lot": c["lot"][:200], "since": c["since"][:200], "basis": c["basis"]})
        history = [{"n": h["n"], "type": h["type"][:64], "summary": h["summary"][:500], "effective": h["effective"][:32],
                    "time": h["time"][:32],
                    "actor": (h["actor"].get("name") or h["actor"].get("account") or h["actor"].get("user") or "")[:200],
                    "basis": h["basis"], "voided": bool(h["voided"])} for h in u.get("history", [])]
        if len(history) > 1000:
            self.note(f"{u['label']}: only the latest 1000 of its {len(history)} history events are included.")
            history = history[-1000:]
        parent = u["parent"]
        if parent and parent["unit"] not in included:
            parent = None
        project = (u["project"] or {}).get("id", "")
        std = u["standard"]
        return {"id": u["id"], "aliases": sorted(set(u.get("aliases", []))), "label": u["label"][:200],
                "class": u["class"], "name": u["name"][:200], "model": u["model"]["number"][:100],
                "part": part_by_num.get(u["model"]["number"].casefold(), "") if u["model"]["number"] else "",
                "project": project if project in project_ids else "", "customer": u["customer"][:200],
                "site": u["site"][:200], "location": u["location"][:200], "status": u["status"],
                "identifiers": [{"scheme": i["scheme"], "issuer": i["issuer"][:200], "value": i["value"][:100],
                                 "active": bool(i["active"])} for i in u["identifiers"]
                                if i["scheme"] in cat_mod.SCHEMES][:100],
                "parent": {"asset": parent["unit"], "position": parent["position"][:64]} if parent else None,
                "standard": {"number": std["number"][:64], "title": std["title"][:200]} if std else None,
                "documents": docs, "components": comps,
                "milestones": {k: v["date"][:32] for k, v in u["milestones"].items() if k in cat_mod.MILESTONES},
                "history": history, "changes": self._unit_changes(u), "notes": u["notes"][:4000], "source": "revisionworx"}

    def _selected(self, d: dict) -> dict | None:
        """The revision the phone should show: the released one, or the latest with ``unreleased``."""
        rel, lat = d.get("released"), d.get("latest")
        if self.o.unreleased and lat and (not rel or lat["id"] != rel["id"]):
            return lat
        return rel

    def _add_object(self, path: Path, media: str) -> str:
        src = archive.ObjectSource.from_path(path, media)
        self.objects.setdefault(src.sha256, src)
        return src.sha256

    def _content(self, rwx, dwx, doc_id, d, r, ext):
        path = rwx.fetch(doc_id, r["label"], r["sha256"], self.work)
        if ext == ".pdf":
            return {"object": self._add_object(path, "application/pdf"), "media_type": "application/pdf",
                    "via": "content"}, path
        if ext in sources.DraftWorx.EXTENSIONS:
            if dwx.available():
                out = dwx.pdf(path, path.with_suffix(".rendition.pdf"))
                if out is not None:
                    return {"object": self._add_object(out, "application/pdf"), "media_type": "application/pdf",
                            "via": f"draftworx pdf {dwx.version}"}, path
                self.note(f"DraftWorx could not print {d.get('number')} rev {r['label']}.")
            else:
                self.note("DraftWorx is not installed: DXF and DraftWorx drawings have no phone view.")
        return None, path

    def _template(self, path: Path, tid: str, title: str, revision: str) -> dict:
        name = path.name.casefold()
        if name.endswith(".json"):
            t = fxjson.parse(path.read_bytes())
            if isinstance(t, dict):
                t = {**t, "id": tid, "revision": revision}
            return inspections.check_template(t)
        return inspections.template_from_csv(sources.as_text(path), tid, title, revision)

    def _data_document(self, rwx, d, r, ext, path, structures, parts_rows, templates) -> None:
        label = f"{d.get('number') or d.get('title')} rev {r['label']}"
        if ext in TEMPLATE_SUFFIXES:
            try:
                t = self._template(path, d.get("number") or Path(path).stem, d.get("title") or d.get("number"),
                                   r["label"])
                templates.append({"template": t, "document": d["id"], "revision": r["id"], "state": r["state"]})
            except (inspections.TemplateError, sources.SourceError, fxjson.FxJsonError) as exc:
                self.note(f"Template {label} was not used: {exc}")
            return
        if ext not in TABLE_EXT:
            return
        if ext == ".csv":
            try:
                text = sources.as_text(path)
            except sources.SourceError:
                return
            if sources.looks_like_parts_csv(text):
                try:
                    for row in sources.parse_parts_csv(text):
                        parts_rows.append((f"{d['id']}@{r['id']}", row))
                except sources.SourceError as exc:
                    self.note(f"Parts list {label} was not used: {exc}")
                return
        s = rwx.bom_convert(path, self.work)
        if s is not None:
            structures.append((f"{d['id']}@{r['id']}", s))

    def _parts_and_bom(self, structures, parts_rows, by_number, meta):
        parts: dict[str, dict] = {}

        def part(number: str) -> dict:
            k = number.casefold()
            if k not in parts:
                parts[k] = {"id": "", "number": number, "description": "", "unit": "", "kind": "", "revision": "",
                            "status": "", "manufacturers": [], "vendors": [], "documents": [], "attributes": {},
                            "stock": None}
            return parts[k]

        # Parts lists first: they are the richest source.
        for src, row in parts_rows:
            p = part(row["number"])
            if row["part_id"].startswith("prt_") and not p["id"]:
                p["id"] = row["part_id"]
            for k in ("description", "unit", "kind", "revision", "status"):
                if row[k] and not p[k]:
                    p[k] = row[k]
                elif row[k] and p[k] != row[k] and k == "revision":
                    self.note(f"{row['number']}: parts lists disagree on its revision ({p[k]} and {row[k]}).")
            for m in row["manufacturers"]:
                if m not in p["manufacturers"]:
                    p["manufacturers"].append(m)
            for v in row["vendors"]:
                if v not in p["vendors"]:
                    p["vendors"].append(v)
            for dl in row["documents"]:
                if dl["document"] in meta and dl not in p["documents"]:
                    p["documents"].append(dl)
                elif dl["document"] not in meta:
                    self.note(f"{row['number']}: linked document {dl['document']} isn't in this package.")
            for k, v in row["attributes"].items():
                p["attributes"].setdefault(k, v)

        bom: list[dict] = []
        owner: dict[str, str] = {}
        for src, s in sorted(structures, key=lambda x: x[0]):
            pinfo = {pp["part_id"]: pp for pp in s.get("parts", [])}
            for pp in s.get("parts", []):
                p = part(pp["number"])
                if pp.get("resolved") and str(pp.get("part_id", "")).startswith("prt_") and not p["id"]:
                    p["id"] = pp["part_id"]
                for k in ("description", "unit", "kind", "revision"):
                    if pp.get(k) and not p[k]:
                        p[k] = pp[k]
                if pp.get("revision") and p["revision"] and pp["revision"].casefold() != p["revision"].casefold():
                    self.note(f"{pp['number']}: a BOM names revision {pp['revision']} but the parts list has "
                              f"{p['revision']}.")
            parents = sorted({ln["parent_id"] for ln in s.get("lines", [])})
            for parent in parents:
                pnum = pinfo.get(parent, {}).get("number", parent)
                key = pnum.casefold()
                if key in owner and owner[key] != src:
                    self.note(f"{pnum}'s BOM appears in more than one BOM document; the first one was used.")
                    continue
                owner[key] = src
                for ln in s["lines"]:
                    if ln["parent_id"] != parent:
                        continue
                    cnum = pinfo.get(ln["child_id"], {}).get("number", ln["child_id"])
                    part(pnum), part(cnum)
                    bom.append({"parent": pnum, "child": cnum, "quantity": ln["quantity"], "unit": ln.get("unit", ""),
                                "find_number": ln.get("find_number", ""),
                                "refdes": list(ln.get("reference_designators", [])), "note": ln.get("note", ""),
                                "provenance": ln.get("provenance", ""), "source": src})

        if self.o.meridian:
            items, company = sources.read_meridian(self.o.meridian)
            as_of = datetime.fromtimestamp(self.o.meridian.stat().st_mtime, timezone.utc).strftime(
                "%Y-%m-%dT%H:%M:%SZ")
            for k, it in items.items():
                p = part(it["number"])
                for f in ("description", "unit"):
                    if not p[f]:
                        p[f] = it[f]
                p["stock"] = {"on_hand": it["on_hand"], "unit": it["unit"], "bin": it["bin"], "as_of": as_of,
                              "source": f"OpenMeridian ({company})" if company else "OpenMeridian"}
            self.note(f"Stock figures are from OpenMeridian as of {as_of[:16].replace('T', ' ')} UTC; they are not "
                      "live.")

        for p in parts.values():
            if not p["id"]:
                p["id"] = "pn:" + p["number"].casefold()
            if not p["unit"]:
                p["unit"] = "EA"
        id_of = {k: p["id"] for k, p in parts.items()}
        for ln in bom:
            ln["parent"] = id_of[ln["parent"].casefold()]
            ln["child"] = id_of[ln["child"].casefold()]
        ordered = sorted(parts.values(), key=lambda p: p["number"].casefold())
        return ordered, bom

    def _dedupe_templates(self, templates: list[dict]) -> list[dict]:
        out, seen = [], set()
        for t in templates:
            key = (t["template"]["id"].casefold(), t["template"]["revision"].casefold())
            if key in seen:
                self.note(f"Template {t['template']['id']} rev {t['template']['revision']} appears twice; the first "
                          "was used.")
                continue
            seen.add(key)
            out.append(t)
        return out


def asset_id(workspace_id: str, tag_or_serial: str) -> str:
    """An asset's id: stable for its tag (or, without one, its serial number) within one RevisionWorx workspace, so
    records made against it keep pointing at it when the register is edited or the package rebuilt."""
    return "ast_" + hashlib.sha256(f"{workspace_id}\0{tag_or_serial.casefold()}".encode()).hexdigest()[:32]


def series_key(source: dict, catalog: dict) -> str:
    """Packages with the same series replace each other on a phone: same workspace, same chosen projects (documents a
    unit borrows from another project don't make it another series)."""
    chosen = source.get("projects")
    ids = chosen.split(",") if isinstance(chosen, str) and chosen else [p["id"] for p in catalog["projects"]]
    proj = ",".join(sorted(ids))
    return hashlib.sha256(f"{source.get('system')}\0{source.get('workspace')}\0{proj}".encode()).hexdigest()[:32]


def build_package(opts: PackOptions, out: Path, overwrite: bool = False, log=print) -> dict:
    b = PackBuilder(opts, log=log)
    catalog, source, objects = b.build()
    titles = ", ".join(f"{p['number']} {p['name']}".strip() for p in catalog["projects"])
    title = opts.title or titles or "FieldWorx package"
    created = ev_mod.utc_now()
    manifest = archive.write(
        out, "package", archive_id=ev_mod.new_id("pkg"), title=title[:200], created=created,
        created_by={"user": getpass.getuser(), "host": platform.node(), "tool": f"fieldworx-bridge {__version__}"},
        source=source, series=series_key(source, catalog), catalog=catalog, events=opts.field_events,
        objects=objects, notices=b.notices, overwrite=overwrite)
    return manifest
