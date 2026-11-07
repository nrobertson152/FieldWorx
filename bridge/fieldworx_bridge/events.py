# SPDX-License-Identifier: GPL-3.0-or-later
"""Field events: immutable, attributable records made in the field (docs/PROTOCOL.md section 4).

Every event belongs to one device's stream (``device``, ``seq``, ``prev``: a hash chain) and to one entity
(``entity``, ``deps``: the events of that entity its author had seen). Its id is the SHA-256 of its canonical bytes,
so an event cannot change without becoming a different event.

``FieldLog`` is the in-memory set every node keeps. ``import_events`` is all-or-nothing: a batch either fits on to
what is already known (chains continue, dependencies exist, no device has two different events at one sequence
number) or nothing from it is used. The Dart implementation (core/lib/src/events.dart) applies the same rules.
"""
from __future__ import annotations

import re
import secrets
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Iterable

from . import fxjson

EVENT_DOMAIN = "event/v1"
MAX_EVENT_BYTES = 256 * 1024
MAX_DEPS = 64
ENVELOPE_KEYS = frozenset({"v", "device", "seq", "prev", "time", "actor", "type", "entity", "deps", "body"})

RE_DEVICE = re.compile(r"dev_[0-9a-f]{32}\Z")
RE_ENTITY = re.compile(r"[a-z]{3}_[0-9a-f]{32}\Z")
RE_HASH = re.compile(r"[0-9a-f]{64}\Z")
RE_TIME = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z\Z")
RE_TYPE = re.compile(r"[a-z][a-z0-9]*(\.[a-z][a-z0-9_]*)+\Z")


class EventError(ValueError):
    """An event, or a batch of them, cannot be used. Nothing from the batch was used."""


class ForkError(EventError):
    """A device has two different events with the same sequence number: its history has been forked (for example a
    phone restored from a backup kept recording). Nothing from the batch was used."""


class MissingHistory(EventError):
    """A batch continues a history this node does not have yet. Nothing from the batch was used."""


def new_id(prefix: str) -> str:
    """``<prefix>_<32 random hex>``, as RevisionWorx makes its ids."""
    if not re.fullmatch(r"[a-z]{3}", prefix):
        raise ValueError("id prefixes are three lowercase letters")
    return f"{prefix}_{secrets.token_hex(16)}"


def utc_now() -> str:
    t = datetime.now(timezone.utc)
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}Z"


def _text_ok(s: Any, limit: int) -> bool:
    return isinstance(s, str) and len(s) <= limit and not any(ord(c) < 0x20 or ord(c) == 0x7F for c in s)


def check_envelope(ev: Any) -> None:
    """Raise EventError unless ``ev`` is a well-formed version 1 event. Bodies are checked when they are used."""
    if not isinstance(ev, dict):
        raise EventError("an event is a JSON object")
    keys = set(ev)
    if keys != ENVELOPE_KEYS:
        missing, extra = ENVELOPE_KEYS - keys, keys - ENVELOPE_KEYS
        raise EventError(f"event fields wrong (missing {sorted(missing)}, unknown {sorted(extra)})")
    if ev["v"] != 1:
        raise EventError(f"event version {ev['v']!r} is not supported by this FieldWorx; update it")
    if not isinstance(ev["device"], str) or not RE_DEVICE.match(ev["device"]):
        raise EventError("device id malformed")
    seq = ev["seq"]
    if not isinstance(seq, int) or isinstance(seq, bool) or seq < 1:
        raise EventError("seq must be a positive integer")
    prev = ev["prev"]
    if seq == 1:
        if prev != "":
            raise EventError("the first event of a device has no prev")
    elif not isinstance(prev, str) or not RE_HASH.match(prev):
        raise EventError("prev must be the id of the device's previous event")
    if not isinstance(ev["time"], str) or not RE_TIME.match(ev["time"]):
        raise EventError("time must be UTC, like 2026-11-06T21:42:00.123Z")
    if not _text_ok(ev["actor"], 200):
        raise EventError("actor must be text of at most 200 characters, without control characters")
    if not isinstance(ev["type"], str) or len(ev["type"]) > 64 or not RE_TYPE.match(ev["type"]):
        raise EventError("type malformed")
    if not isinstance(ev["entity"], str) or not RE_ENTITY.match(ev["entity"]):
        raise EventError("entity id malformed")
    deps = ev["deps"]
    if not isinstance(deps, list) or len(deps) > MAX_DEPS:
        raise EventError(f"deps must be a list of at most {MAX_DEPS} event ids")
    for d in deps:
        if not isinstance(d, str) or not RE_HASH.match(d):
            raise EventError("deps must be event ids")
    if deps != sorted(set(deps)):
        raise EventError("deps must be sorted and unique")
    if not isinstance(ev["body"], dict):
        raise EventError("body must be an object")


@dataclass(frozen=True)
class Event:
    id: str
    raw: bytes                  # canonical bytes, exactly as stored and exchanged
    data: dict = field(repr=False)

    @property
    def device(self) -> str:
        return self.data["device"]

    @property
    def seq(self) -> int:
        return self.data["seq"]

    @property
    def prev(self) -> str:
        return self.data["prev"]

    @property
    def type(self) -> str:
        return self.data["type"]

    @property
    def entity(self) -> str:
        return self.data["entity"]

    @property
    def deps(self) -> list[str]:
        return self.data["deps"]

    @property
    def body(self) -> dict:
        return self.data["body"]

    @property
    def time(self) -> str:
        return self.data["time"]

    @property
    def actor(self) -> str:
        return self.data["actor"]


def event_id(raw: bytes) -> str:
    return fxjson.digest_bytes(EVENT_DOMAIN, raw)


def from_bytes(raw: bytes, expected_id: str | None = None) -> Event:
    """Check canonical form, envelope and (if given) the id. Raises EventError."""
    if len(raw) > MAX_EVENT_BYTES:
        raise EventError(f"event larger than {MAX_EVENT_BYTES} bytes")
    try:
        data = fxjson.parse_canonical(raw)
    except fxjson.FxJsonError as exc:
        raise EventError(f"event is not canonical JSON: {exc}") from None
    check_envelope(data)
    eid = event_id(raw)
    if expected_id is not None and eid != expected_id:
        raise EventError(f"event content does not match its id {expected_id[:12]}")
    return Event(eid, raw, data)


def make(device: str, seq: int, prev: str, actor: str, type_: str, entity: str, deps: Iterable[str], body: dict,
         time: str | None = None) -> Event:
    data = {"v": 1, "device": device, "seq": seq, "prev": prev, "time": time or utc_now(), "actor": actor,
            "type": type_, "entity": entity, "deps": sorted(set(deps)), "body": body}
    check_envelope(data)
    raw = fxjson.encode(data)
    if len(raw) > MAX_EVENT_BYTES:
        raise EventError(f"event larger than {MAX_EVENT_BYTES} bytes")
    return Event(event_id(raw), raw, data)


class FieldLog:
    """Every event a node knows, indexed by device stream and by entity."""

    def __init__(self) -> None:
        self.events: dict[str, Event] = {}
        self.streams: dict[str, list[str]] = {}
        self.by_entity: dict[str, list[str]] = {}

    def __len__(self) -> int:
        return len(self.events)

    def __contains__(self, eid: str) -> bool:
        return eid in self.events

    def get(self, eid: str) -> Event:
        return self.events[eid]

    def heads(self) -> dict[str, dict]:
        return {d: {"seq": len(ids), "id": ids[-1]} for d, ids in sorted(self.streams.items())}

    def entity_events(self, entity: str) -> list[Event]:
        return [self.events[i] for i in self.by_entity.get(entity, [])]

    def entity_heads(self, entity: str) -> list[str]:
        """Events of ``entity`` that no other event of it depends on: what a new event should depend on."""
        ids = self.by_entity.get(entity, [])
        depended = {d for i in ids for d in self.events[i].deps}
        return sorted(i for i in ids if i not in depended)

    def ordered(self) -> list[Event]:
        """All events in an order in which they can be imported elsewhere (the order they were added here)."""
        return list(self.events.values())

    # --------------------------------------------------------------------------------------------- adding
    def _check_fits(self, ev: Event, pending: dict[str, Event]) -> str | None:
        """None if ``ev`` can be added now; otherwise why not (a missing predecessor). Raises on a fork."""
        stream = self.streams.get(ev.device, [])
        if ev.seq <= len(stream):
            if stream[ev.seq - 1] != ev.id:
                raise ForkError(f"device {ev.device[:12]} has two different records numbered {ev.seq}; its history "
                                "was forked (was the phone restored from a backup?). Nothing was imported")
            return "known"
        if ev.seq != len(stream) + 1:
            return f"record {len(stream) + 1} of device {ev.device[:12]}"
        if ev.seq > 1 and stream[-1] != ev.prev:
            raise ForkError(f"device {ev.device[:12]}: record {ev.seq} does not follow record {ev.seq - 1} here; its "
                            "history was forked. Nothing was imported")
        for d in ev.deps:
            dep = self.events.get(d) or pending.get(d)
            if dep is None:
                return f"record {d[:12]} that record {ev.id[:12]} depends on"
            if dep.entity != ev.entity:
                raise EventError(f"record {ev.id[:12]} depends on a record of another entity")
        return None

    def _add(self, ev: Event) -> None:
        self.events[ev.id] = ev
        self.streams.setdefault(ev.device, []).append(ev.id)
        self.by_entity.setdefault(ev.entity, []).append(ev.id)

    def append(self, ev: Event) -> None:
        """Add one event that must fit now (used for a node's own new events)."""
        why = self._check_fits(ev, {})
        if why == "known":
            return
        if why is not None:
            raise MissingHistory(f"cannot add record {ev.id[:12]}: missing {why}")
        self._add(ev)

    def import_events(self, batch: Iterable[Event]) -> list[Event]:
        """Add a batch all-or-nothing. Returns the events that were new, in the order they were added."""
        batch = list(batch)
        seen: dict[str, Event] = {}
        for ev in batch:
            seen.setdefault(ev.id, ev)
        # Work on a scratch copy so a failure leaves this log untouched.
        scratch = FieldLog()
        scratch.events = dict(self.events)
        scratch.streams = {k: list(v) for k, v in self.streams.items()}
        scratch.by_entity = {k: list(v) for k, v in self.by_entity.items()}
        todo = [ev for ev in seen.values()]
        added: list[Event] = []
        while todo:
            progress, waiting, reasons = False, [], []
            for ev in todo:
                why = scratch._check_fits(ev, {})
                if why == "known":
                    progress = True
                    continue
                if why is None:
                    scratch._add(ev)
                    added.append(ev)
                    progress = True
                else:
                    waiting.append(ev)
                    reasons.append(why)
            if not progress:
                raise MissingHistory(f"{len(waiting)} record(s) continue a history this copy does not have (first "
                                     f"missing: {reasons[0]}). Import the earlier field log first. Nothing was "
                                     "imported")
            todo = waiting
        self.events, self.streams, self.by_entity = scratch.events, scratch.streams, scratch.by_entity
        return added


def ancestors(log: FieldLog, entity: str) -> dict[str, set[str]]:
    """For each event of ``entity``, the set of its ancestors through ``deps`` (not including itself)."""
    memo: dict[str, set[str]] = {}
    ids = log.by_entity.get(entity, [])
    for start in ids:
        if start in memo:
            continue
        stack = [(start, False)]
        while stack:
            eid, expanded = stack.pop()
            if eid in memo:
                continue
            deps = log.events[eid].deps
            if expanded:
                acc: set[str] = set()
                for d in deps:
                    acc.add(d)
                    acc |= memo[d]
                memo[eid] = acc
            else:
                stack.append((eid, True))
                for d in deps:
                    if d not in memo:
                        stack.append((d, False))
    return memo
