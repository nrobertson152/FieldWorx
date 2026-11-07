# SPDX-License-Identifier: GPL-3.0-or-later
"""Findings: what someone found or changed on a unit in the field (docs/PROTOCOL.md section 11).

A finding is a proposal, never a change: the phone records it, it travels in a field log, and someone in the office
accepts it into RevisionWorx's unit register (``accept_plan`` says what that would record) or doesn't. Nothing here
writes to RevisionWorx.

``reduce`` is deterministic: any two nodes with the same events get the same state, byte for byte, whichever order the
events arrived in. The Dart implementation (core/lib/src/finding.dart) must produce the same state;
spec/vectors/findings.json holds the cases both run.
"""
from __future__ import annotations

import hashlib
import re
from typing import Any

from . import events as ev_mod

PREFIX = "fnd"
WHAT = ("replaced", "found", "change", "note")
DISPOSITIONS = ("scrapped", "returned", "repair", "stock", "reused", "unknown")   # RevisionWorx's, docs/UNITS.md
RECORD_KEYS = frozenset({"asset", "what", "position", "removed", "fitted", "disposition", "change", "on", "text",
                         "package"})
PART_KEYS = frozenset({"number", "serial", "lot"})
KNOWN_TYPES = ("finding.record", "finding.attach", "finding.void")
RE_ASSET = re.compile(r"(unt|ast)_[0-9a-f]{32}\Z")
RE_DATE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}\Z")      # ASCII digits, as in Dart (Python's \d takes any digit)
ACCEPT_DOMAIN = "fieldworx/accept/v1"


class FindingError(ValueError):
    pass


def blank(v: str) -> bool:
    """Nothing but spaces, tabs and newlines: defined here, not by str.strip(), so Dart can agree exactly."""
    return all(c in " \t\n" for c in v)


def _text(v: Any, what: str, limit: int, *, required: bool = False, multiline: bool = False) -> str:
    if not isinstance(v, str):
        raise FindingError(f"{what} must be text")
    if len(v) > limit:
        raise FindingError(f"{what} is longer than {limit} characters")
    allowed = "\n\t" if multiline else ""
    if any((ord(c) < 0x20 and c not in allowed) or ord(c) == 0x7F for c in v):
        raise FindingError(f"{what} contains control characters")
    if required and blank(v):
        raise FindingError(f"{what} is empty")
    return v


def _part(v: Any, what: str, *, required: bool) -> dict | None:
    if v is None and not required:
        return None
    if not isinstance(v, dict) or set(v) != PART_KEYS:
        raise FindingError(f"{what} must be {{number, serial, lot}}")
    for k in ("number", "serial", "lot"):
        _text(v[k], f"{what} {k}", 100)
    return v


def check_record(b: Any) -> dict:
    """Return ``b`` if it is a valid ``finding.record`` body, else raise FindingError naming the problem."""
    if not isinstance(b, dict) or set(b) != RECORD_KEYS:
        raise FindingError("finding fields wrong")
    if not isinstance(b["asset"], str) or not RE_ASSET.match(b["asset"]):
        raise FindingError("a finding is about a unit or asset: unt_ or ast_ and 32 hex digits")
    what = b["what"]
    if what not in WHAT:
        raise FindingError(f"what is one of {', '.join(WHAT)}")
    part_finding = what in ("replaced", "found")
    _text(b["position"], "position", 64, required=part_finding)
    if not part_finding and b["position"] != "":
        raise FindingError("only a replacement or a find has a position")
    removed = _part(b["removed"], "removed", required=what == "replaced")
    if what != "replaced" and removed is not None:
        raise FindingError("only a replacement has something removed")
    fitted = _part(b["fitted"], "fitted", required=part_finding)
    if not part_finding and fitted is not None:
        raise FindingError("only a replacement or a find has something fitted")
    if fitted is not None and blank(fitted["number"]) and blank(fitted["serial"]):
        raise FindingError("say what is fitted: a part number or a serial")
    if what == "replaced":
        if b["disposition"] not in DISPOSITIONS:
            raise FindingError(f"disposition is one of {', '.join(DISPOSITIONS)}")
    elif b["disposition"] != "":
        raise FindingError("only a replacement has a disposition")
    _text(b["change"], "change", 64, required=what == "change")
    if what != "change" and b["change"] != "":
        raise FindingError("only a change has a change number")
    if not isinstance(b["on"], str) or (b["on"] and not RE_DATE.match(b["on"])):
        raise FindingError("on is a date like 2026-11-03, or empty")
    _text(b["text"], "text", 4000, required=what == "note", multiline=True)
    _text(b["package"], "package", 64)
    return b


def record_body(asset: str, what: str, *, position: str = "", removed: dict | None = None, fitted: dict | None = None,
                disposition: str = "", change: str = "", on: str = "", text: str = "", package: str = "") -> dict:
    """A checked ``finding.record`` body."""
    return check_record({"asset": asset, "what": what, "position": position, "removed": removed, "fitted": fitted,
                         "disposition": disposition, "change": change, "on": on, "text": text, "package": package})


def _who(e: ev_mod.Event) -> dict:
    return {"event": e.id, "actor": e.actor, "device": e.device, "time": e.time}


def reduce(log: ev_mod.FieldLog, entity: str) -> dict:
    """The state of finding ``entity`` from its events. Returns a canonical-JSON-able dict."""
    evs = sorted(log.entity_events(entity), key=lambda e: e.id)      # never depend on arrival order
    records = [e for e in evs if e.type == "finding.record"]
    if len(records) != 1:
        return {"entity": entity, "valid": False,
                "problems": ["no finding record" if not records else "more than one finding record"]}
    rec = records[0]
    try:
        body = check_record(rec.body)
    except FindingError as exc:
        return {"entity": entity, "valid": False, "problems": [f"finding record unusable: {exc}"]}
    problems: list[str] = []
    attachments: list[dict] = []
    voids: list[dict] = []
    for e in evs:
        t, b = e.type, e.body
        if t == "finding.record":
            continue
        if t not in KNOWN_TYPES:
            problems.append(f"record {e.id[:12]} is of a kind this version doesn't know ({t}); update FieldWorx")
            continue
        if t == "finding.attach":
            if not (set(b) == {"object", "size", "media_type", "caption"} and isinstance(b["object"], str)
                    and ev_mod.RE_HASH.match(b["object"]) and isinstance(b["size"], int)
                    and not isinstance(b["size"], bool) and b["size"] >= 0 and isinstance(b["media_type"], str)
                    and len(b["media_type"]) <= 100 and isinstance(b["caption"], str) and len(b["caption"]) <= 500):
                problems.append(f"photo record {e.id[:12]} is malformed and was ignored")
                continue
            attachments.append({"object": b["object"], "size": b["size"], "media_type": b["media_type"],
                                "caption": b["caption"], **_who(e)})
        else:  # finding.void
            if not (set(b) == {"reason"} and isinstance(b["reason"], str) and not blank(b["reason"])
                    and len(b["reason"]) <= 2000):
                problems.append(f"void record {e.id[:12]} is malformed and was ignored")
                continue
            voids.append({"reason": b["reason"], **_who(e)})
    attachments.sort(key=lambda a: (a["time"], a["event"]))
    voids.sort(key=lambda v: (v["time"], v["event"]))
    return {"entity": entity, "valid": True, **{k: body[k] for k in sorted(RECORD_KEYS)},
            "recorded": _who(rec), "status": "voided" if voids else "recorded", "voids": voids,
            "attachments": attachments, "problems": problems, "heads": log.entity_heads(entity)}


def finding_entities(log: ev_mod.FieldLog) -> list[str]:
    return sorted(ent for ent, ids in log.by_entity.items()
                  if ent.startswith(PREFIX + "_") and any(log.events[i].type == "finding.record" for i in ids))


# ----------------------------------------------------------------------------------------- into RevisionWorx
def accept_txid(record_event: str) -> str:
    """The txid RevisionWorx records an accepted finding with: the same for every attempt at accepting it, so a lost
    answer is retried without recording it twice, and a finding is accepted at most once (RevisionWorx refuses the same
    txid for anything else)."""
    return hashlib.sha256(f"{ACCEPT_DOMAIN}\0{record_event}".encode("utf-8")).hexdigest()[:32]


def evidence(state: dict) -> str:
    """``KIND:REF=LABEL`` for RevisionWorx: the field record, and who reported it when."""
    who = state["recorded"]
    day = state["on"] or who["time"][:10]
    label = f"reported by {who['actor'] or 'someone'} on {day}"
    return f"fieldworx-event:{who['event']}={label}"


def same(a: str, b: str) -> bool:
    return " ".join(a.split()).casefold() == " ".join(b.split()).casefold()


def _matches(fitted_now: dict, part: dict) -> bool:
    """Whether what the register has at a position (a component as ``link unit`` answers it) is the thing a finding
    names: by serial when both have one (a fitted unit's serial is its label), else by part number, then lot."""
    serial_now = fitted_now.get("serial") or (fitted_now.get("label", "") if fitted_now.get("unit") else "")
    if not blank(part["serial"]) and not blank(serial_now):
        return same(part["serial"], serial_now)
    number_now = fitted_now.get("number", "")
    if not blank(part["number"]) and not blank(number_now):
        if not same(part["number"], number_now):
            return False
        if not blank(part["lot"]) and not blank(fitted_now.get("lot", "")):
            return same(part["lot"], fitted_now["lot"])
        return True
    return False


def accept_plan(state: dict, unit: dict, *, as_: str = "") -> dict:
    """What accepting finding ``state`` into RevisionWorx unit ``unit`` (as ``revisionworx link unit`` answers it) would
    record. One of:

    * ``{"action": "fit", "position", "part_number", "serial", "lot", "replace", "disposition", "why"}``
    * ``{"action": "change", "change", "why"}`` or ``{"action": "note", "text", "why"}``
    * ``{"action": "nothing", "why"}``: the register already says so;
    * ``{"action": "conflict", "why"}``: the register says something else at that position. Nothing is recorded until a
      person decides: ``as_="fit"`` records what the phone says is fitted there now (replacing what the register has),
      ``as_="note"`` keeps the finding as a note and leaves the configuration alone.

    Raises FindingError when the finding can't be accepted at all (damaged, voided, or about another unit)."""
    if not state.get("valid"):
        raise FindingError("this finding is damaged: " + "; ".join(state.get("problems", [])))
    if state["status"] == "voided":
        raise FindingError("it was voided on the phone: " + state["voids"][-1]["reason"])
    if not is_about(state, unit):
        raise FindingError(f"it is about {state['asset']}, not {unit['label']}")
    if as_ not in ("", "fit", "note"):
        raise FindingError("accept it as fit or note, or as the finding says")
    what = state["what"]
    if as_ == "note" or what == "note":
        return {"action": "note", "text": note_text(state), "why": "kept as a note in the unit's history"}
    if what == "change":
        if as_ == "fit":
            raise FindingError("a change is accepted as the change, or as a note")
        return {"action": "change", "change": state["change"], "why": f"{state['change']} carried out"}
    position, fitted = state["position"], state["fitted"]
    now = next((c for c in unit.get("components", []) if same(c["position"], position)), None)

    def fit(replace: bool, why: str) -> dict:
        return {"action": "fit", "position": position, "part_number": fitted["number"], "serial": fitted["serial"],
                "lot": fitted["lot"], "replace": replace, "disposition": state["disposition"] or "unknown", "why": why}

    if now is not None and _matches(now, fitted):
        return {"action": "nothing", "why": f"the register already has {describe(now)} at {position}"}
    if as_ == "fit":
        return fit(now is not None, "recorded as the phone found it, on your decision"
                   + (f"; replaces {describe(now)}" if now is not None else ""))
    if what == "found":
        if now is None:
            return fit(False, f"nothing was recorded at {position}")
        return {"action": "conflict",
                "why": f"the register has {describe(now)} at {position}; the phone found {describe(fitted)}"}
    removed = state["removed"]
    known = not (blank(removed["number"]) and blank(removed["serial"]))
    if now is None:
        if known:
            return {"action": "conflict",
                    "why": f"the register has nothing at {position}; the phone says {describe(removed)} came out"}
        return fit(False, f"nothing was recorded at {position}")
    if known and not _matches(now, removed):
        return {"action": "conflict",
                "why": f"the register has {describe(now)} at {position}; the phone says {describe(removed)} came out"}
    return fit(True, f"replaces {describe(now)}")


def is_about(state: dict, unit: dict) -> bool:
    """Whether a finding names this unit: its id, an earlier id, or the FieldWorx id it carries."""
    a = state["asset"]
    return a == unit["id"] or a in unit.get("aliases", []) or any(
        i.get("scheme") == "fieldworx" and i.get("value") == a for i in unit.get("identifiers", []))


def accepted_as(state: dict, unit: dict) -> list[int]:
    """The events of ``unit``'s history that cite this finding's record as evidence: where it was accepted."""
    ref = state["recorded"]["event"]
    return [h["n"] for h in unit.get("history", [])
            if any(e.get("kind") == "fieldworx-event" and e.get("ref") == ref for e in h.get("evidence", []))]


def describe(p: dict) -> str:
    words = p.get("number") or p.get("label") or "something"
    return words + "".join(f" {k} {p[k]}" for k in ("serial", "lot") if p.get(k))


def note_text(state: dict) -> str:
    what = state["what"]
    if what == "note":
        head = ""
    elif what == "change":
        head = f"Reported carried out: {state['change']}."
    elif what == "found":
        head = f"Found at {state['position']}: {describe(state['fitted'])}."
    else:
        head = (f"Reported at {state['position']}: {describe(state['removed'])} taken out ({state['disposition']}), "
                f"{describe(state['fitted'])} fitted.")
    return " ".join(x for x in (head, state["text"].strip()) if x)[:4000]
