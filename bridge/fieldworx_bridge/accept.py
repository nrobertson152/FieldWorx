# SPDX-License-Identifier: GPL-3.0-or-later
"""Findings from the field, and accepting them into RevisionWorx's unit register (docs/PROTOCOL.md section 11).

This is the one place the bridge writes to another program, and only when someone in the office asks
(``fieldworx-bridge accept``). It writes through ``revisionworx link`` (feature ``unit-records``, RevisionWorx
docs/INTEGRATION.md), never to RevisionWorx's files, so each fact is one journal entry in the name of whoever is logged
in to RevisionWorx, with the field record as its evidence. A finding the register contradicts isn't recorded until a
person decides how.

A finding signed on a phone enrolled to someone's account (PROTOCOL.md section 12.5) is accepted as *verified* in their
name: the bridge passes the record's signature, and RevisionWorx checks it against the phone enrolled to the account
before it records anything. Anything else is accepted as *reported*, as before.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from . import events as E, findings
from .hub import Hub
from .rwx_client import RwxError
from .sources import RevisionWorxSource, SourceError

FEATURE = "unit-records"
SIGNATURES = "field-signatures"


class AcceptError(Exception):
    """Nothing was recorded. The message says why, and what to do, for the person running the bridge."""


@dataclass
class Row:
    """One finding, and where it stands with RevisionWorx."""
    state: dict
    status: str               # damaged, voided, accepted, nothing, conflict, pending, no-unit, or "" (not looked up)
    detail: str = ""
    unit: dict | None = None
    events: list[int] = field(default_factory=list)
    plan: dict | None = None
    signed: bool = False        # its record is signed (version 2)
    phone: dict | None = None   # the signing phone's enrolment in RevisionWorx (``link devices``), if it has one
    signer: dict | None = None  # the same, when its signatures count now: accepting records the finding as verified

    @property
    def entity(self) -> str:
        return self.state["entity"]


def summary(state: dict) -> str:
    """One line saying what the finding is."""
    if not state.get("valid"):
        return "damaged: " + "; ".join(state.get("problems", []))
    what = state["what"]
    if what == "replaced":
        out = (f"replaced at {state['position']}: {findings.describe(state['removed'])} out "
               f"({state['disposition']}), {findings.describe(state['fitted'])} in")
    elif what == "found":
        out = f"found at {state['position']}: {findings.describe(state['fitted'])}"
    elif what == "change":
        out = f"carried out {state['change']}"
    else:
        out = "note: " + " ".join(state["text"].split())
    return out if len(out) <= 160 else out[:159] + "…"


def _source(workspace: str | Path | None, executable: str | None) -> RevisionWorxSource:
    try:
        src = RevisionWorxSource(workspace, executable)
    except SourceError as exc:
        raise AcceptError(str(exc)) from None
    if not src.has(FEATURE):
        raise AcceptError(f"this RevisionWorx ({src.version}) can't record findings on units: update it (its "
                          f"'link version' doesn't list '{FEATURE}')")
    return src


def _unit(src: RevisionWorxSource, ref: str) -> dict | None:
    try:
        return src.rwx.unit(ref)
    except RwxError as exc:
        if exc.kind == "not-found":
            return None
        raise AcceptError(f"RevisionWorx: {exc}") from None


def look_up(state: dict, src: RevisionWorxSource | None, units: dict | None = None) -> Row:
    """Where finding ``state`` stands: with RevisionWorx when ``src`` is given."""
    if not state.get("valid"):
        return Row(state, "damaged", "; ".join(state.get("problems", [])))
    if src is None:
        return Row(state, "voided" if state["status"] == "voided" else "", "")
    units = {} if units is None else units
    if state["asset"] not in units:
        units[state["asset"]] = _unit(src, state["asset"])
    unit = units[state["asset"]]
    if unit is None:
        return Row(state, "no-unit", f"RevisionWorx's unit register has no unit {state['asset']}: it is an asset "
                                     "register row that isn't in the register (revisionworx unit import)")
    done = findings.accepted_as(state, unit)
    if state["status"] == "voided":
        why = state["voids"][-1]["reason"]
        if done:
            return Row(state, "voided", f"voided on the phone ({why}) after it was accepted as {_events(done)} of "
                                        f"{unit['label']}: if it was a mistake, void those in RevisionWorx "
                                        "(revisionworx unit void)", unit, done)
        return Row(state, "voided", f"voided on the phone: {why}", unit)
    if done:
        return Row(state, "accepted", f"{_events(done)} of {unit['label']}", unit, done)
    try:
        plan = findings.accept_plan(state, unit)
    except findings.FindingError as exc:
        return Row(state, "damaged", str(exc), unit)
    status = {"nothing": "nothing", "conflict": "conflict"}.get(plan["action"], "pending")
    return Row(state, status, plan["why"], unit, plan=plan)


def signed_record(log, state: dict) -> E.Event | None:
    """The finding's record event, if it is signed."""
    rec = (state.get("recorded") or {}).get("event")
    ev = log.events.get(rec) if rec else None
    return ev if ev is not None and ev.version == 2 else None


def phones(src: RevisionWorxSource | None) -> dict[str, dict]:
    """Device id -> its enrolment in RevisionWorx (``link devices``; for a phone enrolled twice, the one whose signatures
    count, if any). Empty when RevisionWorx can't say (no team workspace, or a RevisionWorx without the feature): then
    nothing is accepted as verified on a phone's say-so."""
    if src is None or not src.has(SIGNATURES):
        return {}
    try:
        rows = src.rwx.devices()
    except RwxError:
        return {}
    out: dict[str, dict] = {}
    for r in rows:
        if r["device"] not in out or r.get("active"):
            out[r["device"]] = r
    return out


def _phone(ev: E.Event | None, enrolled: dict[str, dict]) -> dict | None:
    """The enrolment of the phone that signed ``ev``, if it is enrolled with the key ``ev`` carries."""
    row = enrolled.get(ev.device) if ev is not None else None
    return row if row is not None and row.get("key") == ev.key else None


def _signer(ev: E.Event | None, enrolled: dict[str, dict]) -> dict | None:
    row = _phone(ev, enrolled)
    return row if row is not None and row.get("active") else None


def _events(ns: list[int]) -> str:
    return ("event " if len(ns) == 1 else "events ") + ", ".join(str(n) for n in ns)


def review(hub_dir: Path, workspace: str | Path | None = None, executable: str | None = None) -> list[Row]:
    """Every finding in the hub, oldest first, and (with a workspace) where each stands with RevisionWorx."""
    log = Hub.open(hub_dir).load()
    states = [findings.reduce(log, e) for e in findings.finding_entities(log)]
    states.sort(key=lambda s: ((s.get("recorded") or {}).get("time", ""), s["entity"]))
    src = _source(workspace, executable) if workspace is not None else None
    units: dict = {}
    enrolled = phones(src)
    rows = []
    for s in states:
        row = look_up(s, src, units)
        ev = signed_record(log, s)
        row.signed, row.phone, row.signer = ev is not None, _phone(ev, enrolled), _signer(ev, enrolled)
        rows.append(row)
    return rows


def resolve(log, ref: str) -> str:
    """A finding by its id or the start of it (at least 8 characters after ``fnd_``)."""
    ref = ref.strip()
    ids = findings.finding_entities(log)
    if ref in ids:
        return ref
    if not ref.startswith("fnd_") or len(ref) < 12:
        raise AcceptError(f"{ref!r} isn't a finding: give its id (fnd_…) or the start of it, from 'fieldworx-bridge "
                          "findings'")
    hits = [i for i in ids if i.startswith(ref)]
    if len(hits) != 1:
        raise AcceptError(f"no finding {ref}" if not hits else f"{ref} could be {', '.join(hits)}: give more of it")
    return hits[0]


def accept(hub_dir: Path, workspace: str | Path, ref: str, *, as_: str = "", basis: str | None = None,
           dry_run: bool = False, executable: str | None = None) -> dict:
    """Accept one finding into RevisionWorx. Returns ``{"result": "recorded" | "already-recorded" | "nothing" |
    "would-record", "unit", "events", "why", "plan", "basis", "signed_by"}``; raises AcceptError when nothing can be
    recorded, saying why.

    The write is one RevisionWorx entry, with the finding's record as evidence, the txid derived from it (so a retry
    writes nothing twice, and a finding is accepted at most once) and the unit's event count as read (so a fact
    recorded meanwhile is never overwritten by a decision made without it).

    ``basis``: without one, a finding signed on a phone enrolled to someone's account is accepted as verified in their
    name (``signed_by``), with its signature for RevisionWorx to check, and anything else as reported. ``"reported"``
    always reports; ``"verified"`` without a signature that counts means someone in the office saw it."""
    if basis not in (None, "reported", "verified"):
        raise AcceptError("a finding's basis is reported, or verified when someone in the office saw it")
    log = Hub.open(hub_dir).load()
    state = findings.reduce(log, resolve(log, ref))
    src = _source(workspace, executable)
    row = look_up(state, src)
    if row.status in ("damaged", "voided", "no-unit"):
        raise AcceptError(f"{state['entity']} can't be accepted: {row.detail}")
    unit = row.unit
    if row.status == "accepted":
        return {"result": "already-recorded", "unit": unit, "events": row.events, "why": row.detail, "plan": None}
    try:
        plan = findings.accept_plan(state, unit, as_=as_)
    except findings.FindingError as exc:
        raise AcceptError(f"{state['entity']} can't be accepted that way: {exc}") from None
    if plan["action"] == "nothing":
        return {"result": "nothing", "unit": unit, "events": [], "why": plan["why"], "plan": plan}
    if plan["action"] == "conflict":
        raise AcceptError(f"nothing was recorded: {plan['why']}. A person decides: if the phone is right, accept it "
                          "with --as fit; to keep it on record without changing the configuration, --as note")
    signer = None if basis == "reported" else _signer(signed_record(log, state), phones(src))
    use = "verified" if signer is not None else (basis or "reported")
    if dry_run:
        return {"result": "would-record", "unit": unit, "events": [], "why": plan["why"], "plan": plan, "basis": use,
                "signed_by": signer}
    who = state["recorded"]
    common = {"if_events": unit["events"]["count"], "effective": state["on"] or who["time"][:10], "basis": use,
              "evidence": [findings.evidence(state)]}
    if signer is not None:
        ev = signed_record(log, state)
        common["field_signature"] = f"{ev.device}:{ev.id}:{ev.sig}"
    txid = findings.accept_txid(who["event"])
    try:
        if plan["action"] == "fit":
            answer = src.rwx.unit_fit(unit["id"], plan["position"], txid, part_number=plan["part_number"],
                                      serial=plan["serial"], lot=plan["lot"], replace=plan["replace"],
                                      disposition=plan["disposition"] if plan["replace"] else "", **common)
        elif plan["action"] == "change":
            answer = src.rwx.unit_change_install(unit["id"], plan["change"], txid, **common)
        else:
            answer = src.rwx.unit_note(unit["id"], plan["text"], txid, **common)
    except RwxError as exc:
        if exc.kind == "changed":
            raise AcceptError(f"nothing was recorded: {unit['label']} changed in RevisionWorx while this was being "
                              "accepted. Run it again to look at it afresh") from None
        if exc.kind == "txid-used":
            raise AcceptError(f"nothing was recorded: RevisionWorx has already used this finding's txid for something "
                              f"else ({exc})") from None
        if exc.kind == "signature":
            raise AcceptError(f"nothing was recorded: RevisionWorx didn't accept the phone's signature ({exc}). To "
                              "record it as reported instead, accept it with --basis reported") from None
        raise AcceptError(f"nothing was recorded: RevisionWorx: {exc}") from None
    return {"result": answer["result"], "unit": answer.get("unit") or unit, "events": answer.get("events") or [],
            "why": plan["why"], "plan": plan, "warning": answer.get("warning", ""), "basis": use, "signed_by": signer}
