# SPDX-License-Identifier: GPL-3.0-or-later
"""Inspection templates and the state of an inspection worked out from its events (docs/PROTOCOL.md section 5).

``reduce`` is deterministic: any two nodes with the same events get the same state, byte for byte, whichever order
the events arrived in. It never picks a winner between two answers recorded without knowledge of each other (on two
phones offline, say): both are kept and the item shows a conflict until someone records a value that has seen both.
A completion covers exactly the answers and photos in its own history; anything else makes it stale.

The Dart implementation (core/lib/src/inspection.dart) must produce the same state; spec/vectors/inspections.json
holds the cases both run.
"""
from __future__ import annotations

import csv
import io
import re
from decimal import Decimal, InvalidOperation
from typing import Any

from . import events as ev_mod
from . import fxjson

TEMPLATE_FORMAT = "fieldworx.template"
KINDS = ("check", "measure", "text", "choice")
PHOTO = ("none", "optional", "required")
RE_DECIMAL = re.compile(r"-?(0|[1-9]\d{0,14})(\.\d{1,9})?\Z")
RE_ITEM_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._\-]{0,31}\Z")
CHECK_RESULTS = ("pass", "fail", "na")
STATUS_TYPES = ("inspection.complete", "inspection.reopen", "inspection.void")
CONTENT_TYPES = ("inspection.answer", "inspection.attach")
KNOWN_TYPES = ("inspection.start", "inspection.answer", "inspection.note", "inspection.attach") + STATUS_TYPES


class TemplateError(ValueError):
    pass


def _text(v: Any, what: str, limit: int, required: bool = False, multiline: bool = False) -> str:
    if not isinstance(v, str):
        raise TemplateError(f"{what} must be text")
    if len(v) > limit:
        raise TemplateError(f"{what} is longer than {limit} characters")
    allowed = "\n\t" if multiline else ""
    if any((ord(c) < 0x20 and c not in allowed) or ord(c) == 0x7F for c in v):
        raise TemplateError(f"{what} contains control characters")
    if required and not v.strip():
        raise TemplateError(f"{what} is empty")
    return v


def is_decimal(s: Any) -> bool:
    return isinstance(s, str) and bool(RE_DECIMAL.match(s))


def check_template(t: Any) -> dict:
    """Return ``t`` if it is a valid version 1 template, else raise TemplateError naming the problem."""
    if not isinstance(t, dict):
        raise TemplateError("a template is a JSON object")
    want = {"format", "version", "id", "revision", "title", "description", "sections"}
    if set(t) != want:
        raise TemplateError("template fields wrong")
    if t["format"] != TEMPLATE_FORMAT or t["version"] != 1:
        raise TemplateError("not a version 1 FieldWorx template")
    _text(t["id"], "template id", 64, required=True)
    _text(t["revision"], "template revision", 16)
    _text(t["title"], "template title", 200, required=True)
    _text(t["description"], "template description", 4000, multiline=True)
    if not isinstance(t["sections"], list) or not t["sections"]:
        raise TemplateError("a template needs at least one section")
    seen: set[str] = set()
    count = 0
    for si, s in enumerate(t["sections"]):
        if not isinstance(s, dict) or set(s) != {"title", "items"}:
            raise TemplateError(f"section {si + 1} must have exactly title and items")
        _text(s["title"], f"section {si + 1} title", 200)
        if not isinstance(s["items"], list) or not s["items"]:
            raise TemplateError(f"section {si + 1} has no items")
        for it in s["items"]:
            _check_item(it, seen)
            count += 1
    if count > 1000:
        raise TemplateError("a template has at most 1000 items")
    return t


def _check_item(it: Any, seen: set[str]) -> None:
    base = {"id", "kind", "prompt", "required", "photo", "help"}
    if not isinstance(it, dict):
        raise TemplateError("an item is a JSON object")
    iid = it.get("id")
    if not isinstance(iid, str):
        raise TemplateError("an item id must be text")
    if not RE_ITEM_ID.match(iid):
        raise TemplateError(f"item id '{iid}' must be 1-32 letters, digits, '.', '_' or '-'")
    if iid.lower() in seen:
        raise TemplateError(f"item id {iid} appears twice")
    seen.add(iid.lower())
    kind = it.get("kind")
    if kind not in KINDS:
        raise TemplateError(f"item {iid}: kind must be one of {', '.join(KINDS)}")
    extra = {"measure": {"unit", "nominal", "min", "max"}, "choice": {"choices"}}.get(kind, set())
    if set(it) != base | extra:
        raise TemplateError(f"item {iid}: fields wrong for a {kind} item")
    _text(it["prompt"], f"item {iid} prompt", 500, required=True)
    if not isinstance(it["required"], bool):
        raise TemplateError(f"item {iid}: required must be true or false")
    if it["photo"] not in PHOTO:
        raise TemplateError(f"item {iid}: photo must be none, optional or required")
    _text(it["help"], f"item {iid} help", 2000, multiline=True)
    if kind == "measure":
        _text(it["unit"], f"item {iid} unit", 16)
        for k in ("nominal", "min", "max"):
            if it[k] != "" and not is_decimal(it[k]):
                raise TemplateError(f"item {iid}: {k} must be a plain decimal like 12.5 or -0.05, or empty")
        if it["min"] and it["max"] and Decimal(it["min"]) > Decimal(it["max"]):
            raise TemplateError(f"item {iid}: min is above max")
    if kind == "choice":
        ch = it["choices"]
        if not isinstance(ch, list) or not 2 <= len(ch) <= 20:
            raise TemplateError(f"item {iid}: a choice item needs 2 to 20 choices")
        for c in ch:
            _text(c, f"item {iid} choice", 100, required=True)
        if len({c.lower() for c in ch}) != len(ch):
            raise TemplateError(f"item {iid}: choices repeat")


def items(t: dict) -> list[dict]:
    return [it for s in t["sections"] for it in s["items"]]


CSV_COLUMNS = ("section", "id", "kind", "prompt", "unit", "nominal", "min", "max", "required", "photo", "choices",
               "help")


def template_from_csv(text: str, template_id: str, title: str, revision: str = "", description: str = "") -> dict:
    """A template from a spreadsheet: one row per item, columns ``CSV_COLUMNS`` (only section, id, kind and prompt
    are needed). Rows with the same section text in a row make one section. All-or-nothing."""
    text = text.lstrip("﻿")
    reader = csv.DictReader(io.StringIO(text, newline=""))
    header = [(h or "").strip().casefold() for h in (reader.fieldnames or [])]
    unknown = set(header) - set(CSV_COLUMNS)
    if unknown:
        raise TemplateError(f"unknown columns: {', '.join(sorted(unknown))}")
    for need in ("id", "kind", "prompt"):
        if need not in header:
            raise TemplateError(f"the column {need} is missing")
    reader.fieldnames = header
    sections: list[dict] = []
    for n, row in enumerate(reader, start=2):
        if None in row:
            raise TemplateError(f"row {n}: more cells than columns")
        cells = {k: (v or "").strip() for k, v in row.items()}
        for k, v in list(cells.items()):
            if v.startswith("'") and len(v) > 1 and v[1] in "=+-@\t\r":
                cells[k] = v[1:]          # spreadsheet formula guard, as RevisionWorx writes it
        if not any(cells.values()):
            continue
        kind = cells.get("kind", "").casefold()
        it = {"id": cells.get("id", ""), "kind": kind, "prompt": cells.get("prompt", ""),
              "required": cells.get("required", "yes").casefold() in ("yes", "y", "true", "1", "x"),
              "photo": cells.get("photo", "").casefold() or "none", "help": cells.get("help", "")}
        if kind == "measure":
            it.update(unit=cells.get("unit", ""), nominal=cells.get("nominal", ""), min=cells.get("min", ""),
                      max=cells.get("max", ""))
        elif kind == "choice":
            it["choices"] = [c.strip() for c in cells.get("choices", "").split(";") if c.strip()]
        title_s = cells.get("section", "")
        if not sections or sections[-1]["title"] != title_s:
            sections.append({"title": title_s, "items": []})
        sections[-1]["items"].append(it)
    t = {"format": TEMPLATE_FORMAT, "version": 1, "id": template_id, "revision": revision, "title": title,
         "description": description, "sections": sections}
    try:
        return check_template(t)
    except TemplateError as exc:
        raise TemplateError(f"{exc}") from None


# ----------------------------------------------------------------------------------------------- evaluation
def evaluate_measure(item: dict, measured: str) -> str:
    """'pass' or 'fail' for a measured decimal against the item's limits (inclusive). Exact: no floating point."""
    m = Decimal(measured)
    if item["min"] and m < Decimal(item["min"]):
        return "fail"
    if item["max"] and m > Decimal(item["max"]):
        return "fail"
    return "pass"


def _valid_value(item: dict, value: Any) -> bool:
    if not isinstance(value, dict):
        return False
    if value == {}:
        return True                                    # cleared
    kind = item["kind"]
    if kind == "check":
        return set(value) == {"result"} and value["result"] in CHECK_RESULTS
    if kind == "measure":
        if set(value) == {"result"}:
            return value["result"] == "na"
        return set(value) == {"measured"} and is_decimal(value["measured"])
    if kind == "text":
        return set(value) == {"text"} and isinstance(value["text"], str) and len(value["text"]) <= 4000
    if kind == "choice":
        return set(value) == {"choice"} and value["choice"] in item["choices"]
    return False


def item_outcome(item: dict, value: dict | None) -> str:
    """open, pass, fail, na or done (text and choice items)."""
    if not value:
        return "open"
    kind = item["kind"]
    if kind == "check":
        return value["result"]
    if kind == "measure":
        if value.get("result") == "na":
            return "na"
        return evaluate_measure(item, value["measured"])
    return "done"


def _who(e: ev_mod.Event) -> dict:
    return {"event": e.id, "actor": e.actor, "device": e.device, "time": e.time}


def _current(writes: list[ev_mod.Event], anc: dict[str, set[str]]) -> list[ev_mod.Event]:
    """Writes that no other write to the same register has seen: one value, or a conflict."""
    out = [w for w in writes if not any(w.id in anc[o.id] for o in writes if o.id != w.id)]
    return sorted(out, key=lambda e: e.id)


def reduce(log: ev_mod.FieldLog, entity: str) -> dict:
    """The state of inspection ``entity`` from its events. Returns a canonical-JSON-able dict."""
    evs = sorted(log.entity_events(entity), key=lambda e: e.id)      # never depend on arrival order
    problems: list[str] = []
    starts = [e for e in evs if e.type == "inspection.start"]
    if len(starts) != 1:
        return {"entity": entity, "valid": False,
                "problems": ["no start record" if not starts else "more than one start record"]}
    start = starts[0]
    body = start.body
    try:
        if set(body) != {"template", "title", "subject", "package"}:
            raise TemplateError("start record fields wrong")
        template = check_template(body["template"])
        _text(body["title"], "title", 200)
        _text(body["package"], "package", 64)
        subj = body["subject"]
        if (not isinstance(subj, dict) or set(subj) != {"kind", "id", "label"}
                or subj["kind"] not in ("", "asset", "part", "document", "project")):
            raise TemplateError("subject malformed")
        _text(subj["id"], "subject id", 128)
        _text(subj["label"], "subject label", 200)
    except TemplateError as exc:
        return {"entity": entity, "valid": False, "problems": [f"start record unusable: {exc}"]}
    anc = ev_mod.ancestors(log, entity)
    by_item = {it["id"]: it for it in items(template)}

    answers: dict[str, list[ev_mod.Event]] = {}
    status_writes: list[ev_mod.Event] = []
    notes: list[dict] = []
    attachments: list[dict] = []
    content_events: list[ev_mod.Event] = []
    for e in evs:
        t, b = e.type, e.body
        if t == "inspection.start":
            continue
        if t not in KNOWN_TYPES:
            problems.append(f"record {e.id[:12]} is of a kind this version doesn't know ({t}); update FieldWorx")
            continue
        if t == "inspection.answer":
            ok = (set(b) == {"item", "value", "note"} and isinstance(b["item"], str) and b["item"] in by_item
                  and _valid_value(by_item[b["item"]], b["value"]) and isinstance(b["note"], str)
                  and len(b["note"]) <= 2000)
            if not ok:
                problems.append(f"answer record {e.id[:12]} is malformed and was ignored")
                continue
            answers.setdefault(b["item"], []).append(e)
            content_events.append(e)
        elif t == "inspection.note":
            if not (set(b) == {"text", "item"} and isinstance(b["text"], str) and 0 < len(b["text"]) <= 4000
                    and isinstance(b["item"], str) and (b["item"] == "" or b["item"] in by_item)):
                problems.append(f"note record {e.id[:12]} is malformed and was ignored")
                continue
            notes.append({"text": b["text"], "item": b["item"], **_who(e)})
        elif t == "inspection.attach":
            if not (set(b) == {"object", "size", "media_type", "item", "caption"} and isinstance(b["object"], str)
                    and ev_mod.RE_HASH.match(b["object"]) and isinstance(b["size"], int)
                    and not isinstance(b["size"], bool) and b["size"] >= 0 and isinstance(b["media_type"], str)
                    and len(b["media_type"]) <= 100 and isinstance(b["caption"], str) and len(b["caption"]) <= 500
                    and isinstance(b["item"], str) and (b["item"] == "" or b["item"] in by_item)):
                problems.append(f"photo record {e.id[:12]} is malformed and was ignored")
                continue
            attachments.append({"object": b["object"], "size": b["size"], "media_type": b["media_type"],
                                "item": b["item"], "caption": b["caption"], **_who(e)})
            content_events.append(e)
        else:  # status
            ok = ((t == "inspection.complete" and set(b) == {"result", "summary"} and b["result"] in ("pass", "fail")
                   and isinstance(b["summary"], str) and len(b["summary"]) <= 4000)
                  or (t in ("inspection.reopen", "inspection.void") and set(b) == {"reason"}
                      and isinstance(b["reason"], str) and len(b["reason"]) <= 2000))
            if not ok:
                problems.append(f"status record {e.id[:12]} is malformed and was ignored")
                continue
            status_writes.append(e)

    out_items = []
    outcomes = []
    for it in items(template):
        cur = _current(answers.get(it["id"], []), anc)
        values = [{"value": c.body["value"], "note": c.body["note"], **_who(c)} for c in cur]
        if len(cur) > 1:
            outcome = "conflict"
        else:
            outcome = item_outcome(it, cur[0].body["value"] if cur else None)
            if (outcome not in ("open", "na") and it["photo"] == "required"
                    and not any(a["item"] == it["id"] for a in attachments)):
                outcome = "photo-missing"
        outcomes.append((it, outcome))
        out_items.append({"id": it["id"], "outcome": outcome, "values": values})

    if any(o == "conflict" for _, o in outcomes):
        overall = "conflict"
    elif any(o == "fail" for _, o in outcomes):
        overall = "fail"
    elif any(it["required"] and o in ("open", "photo-missing") for it, o in outcomes):
        overall = "incomplete"
    else:
        overall = "pass"

    cur_status = _current(status_writes, anc)
    completion = None
    if not cur_status:
        status = "open"
    elif len(cur_status) > 1:
        status = "conflict"
    else:
        s = cur_status[0]
        status = {"inspection.complete": "completed", "inspection.reopen": "open", "inspection.void": "voided"}[s.type]
        if s.type == "inspection.complete":
            covered = anc[s.id]
            uncovered = sorted(e.id for e in content_events if e.id not in covered)
            completion = {"result": s.body["result"], "summary": s.body["summary"], **_who(s),
                          "stale": bool(uncovered), "uncovered": uncovered}

    notes.sort(key=lambda n: (n["time"], n["event"]))
    attachments.sort(key=lambda a: (a["time"], a["event"]))
    return {"entity": entity, "valid": True, "title": body["title"], "subject": body["subject"],
            "package": body["package"],
            "template": {"id": template["id"], "revision": template["revision"], "title": template["title"],
                         "digest": fxjson.digest("template/v1", template)},
            "started": _who(start), "status": status, "outcome": overall, "completion": completion,
            "items": out_items, "notes": notes, "attachments": attachments, "problems": problems,
            "heads": log.entity_heads(entity)}


def inspection_entities(log: ev_mod.FieldLog) -> list[str]:
    return sorted(ent for ent, ids in log.by_entity.items()
                  if ent.startswith("ins_") and any(log.events[i].type == "inspection.start" for i in ids))
