# SPDX-License-Identifier: GPL-3.0-or-later
"""The hub: the desktop's copy of everything recorded in the field (docs/ARCHITECTURE.md, ADR-005).

A folder, ``.fieldworx`` beside ``.revisionworx`` by default:

    hub.json                          identity, written once
    events/<device>/<seq>.json        one file per event, canonical bytes, written once
    objects/sha256/<aa>/<sha256>      photos and other files, named by their content, written once
    receipts/<field log id>.json      what each imported field log brought, written once

Nothing in it is ever edited or replaced, so several computers can import into one shared hub folder without a lock:
two that write the same event write the same bytes under the same name, and only one of them gets the name. A
different file already at that name is a forked history, and the import stops (fail closed).
"""
from __future__ import annotations

import hashlib
import json
import os
import zipfile
import zlib
from dataclasses import dataclass
from pathlib import Path

from . import archive, events as ev_mod, fxjson, safefile

HUB_FORMAT = "fieldworx.hub"


class HubError(Exception):
    pass


@dataclass
class ImportReport:
    archive_id: str
    new_events: int
    known_events: int
    new_objects: int
    devices: list[str]
    missing_objects: list[str]

    def text(self) -> str:
        s = (f"{self.new_events} new record(s), {self.known_events} already here, {self.new_objects} new file(s) "
             f"from {len(self.devices)} device(s)")
        if self.missing_objects:
            s += f"; {len(self.missing_objects)} photo(s) not received yet"
        return s


class Hub:
    def __init__(self, root: Path):
        self.root = Path(root)

    @classmethod
    def location_for(cls, folder: Path) -> Path:
        return Path(folder) / ".fieldworx"

    @classmethod
    def open(cls, root: Path, create: bool = False) -> "Hub":
        root = Path(root)
        meta = root / "hub.json"
        if not meta.exists():
            if not create:
                raise HubError(f"{root} is not a FieldWorx hub (no hub.json). Import a field log first, or say where "
                               "the hub is with --hub")
            root.mkdir(parents=True, exist_ok=True)
            body = {"format": HUB_FORMAT, "version": 1, "id": ev_mod.new_id("hub"), "created": ev_mod.utc_now()}
            try:
                safefile.publish_new(meta, fxjson.encode(body))
            except safefile.AlreadyExists:
                pass                                   # another computer made it first; use theirs
        try:
            body = fxjson.parse(meta.read_bytes())
        except (OSError, fxjson.FxJsonError) as exc:
            raise HubError(f"{meta} is unreadable: {exc}") from None
        if not isinstance(body, dict) or body.get("format") != HUB_FORMAT:
            raise HubError(f"{meta} is not a FieldWorx hub")
        if body.get("version") != 1:
            raise HubError(f"{root} is a newer hub format; update the bridge")
        hub = cls(root)
        hub.id = body["id"]
        return hub

    # ------------------------------------------------------------------------------------------------ reading
    def load(self) -> ev_mod.FieldLog:
        """Every event in the hub, checked. A damaged or out-of-place file stops the load (fail closed). Signatures were
        checked when each event came in (``import_archive``), so they aren't checked again on every load."""
        log = ev_mod.FieldLog()
        edir = self.root / "events"
        if not edir.is_dir():
            return log
        batch = []
        for ddir in sorted(edir.iterdir()):
            if not ddir.is_dir() or not ev_mod.RE_DEVICE.match(ddir.name):
                continue
            files = sorted(f for f in ddir.iterdir() if f.suffix == ".json" and not f.name.startswith("."))
            for f in files:
                raw = f.read_bytes()
                try:
                    ev = ev_mod.from_bytes(raw, check_sig=False)
                except ev_mod.EventError as exc:
                    raise HubError(f"{f} is damaged: {exc}") from None
                if ev.device != ddir.name or f.name != f"{ev.seq:010d}.json":
                    raise HubError(f"{f} holds record {ev.seq} of {ev.device}; it is in the wrong place")
                batch.append(ev)
        try:
            log.import_events(batch)
        except ev_mod.EventError as exc:
            raise HubError(f"the hub's records don't fit together: {exc}") from None
        return log

    def object_path(self, sha: str) -> Path:
        return self.root / "objects" / "sha256" / sha[:2] / sha

    def has_object(self, sha: str) -> bool:
        return self.object_path(sha).is_file()

    # ------------------------------------------------------------------------------------------------ writing
    def _write_event(self, ev: ev_mod.Event) -> bool:
        final = self.root / "events" / ev.device / f"{ev.seq:010d}.json"
        try:
            safefile.publish_new(final, ev.raw)
            return True
        except safefile.AlreadyExists:
            if final.read_bytes() != ev.raw:
                raise ev_mod.ForkError(f"device {ev.device[:12]} record {ev.seq} differs from the one in the hub; its "
                                       "history was forked. Import stopped") from None
            return False

    def _write_object(self, arc: archive.Archive, sha: str) -> bool:
        final = self.object_path(sha)
        if final.is_file():
            return False
        final.parent.mkdir(parents=True, exist_ok=True)
        tmp = safefile.temp_name(final)
        h = hashlib.sha256()
        try:
            with arc.open_object(sha) as src, open(tmp, "xb") as dst:
                while chunk := src.read(1 << 20):
                    h.update(chunk)
                    dst.write(chunk)
                dst.flush()
                os.fsync(dst.fileno())
        except (zipfile.BadZipFile, zlib.error, EOFError, archive.ArchiveError) as exc:
            tmp.unlink(missing_ok=True)             # the file went bad after it was checked: nothing of it is kept
            raise HubError(f"file {sha[:12]} couldn't be read from the archive ({exc}); no field records were "
                           "imported") from None
        except BaseException:
            tmp.unlink(missing_ok=True)
            raise
        if h.hexdigest() != sha:
            tmp.unlink()
            raise HubError(f"file {sha[:12]} changed while it was imported")
        try:
            safefile.publish_file(tmp, final)
        except safefile.AlreadyExists:
            return False
        return True

    def import_archive(self, arc: archive.Archive) -> ImportReport:
        """Bring a field log (or the events of a package) into the hub. Every event is checked against everything
        already here, and every new one's signature, before anything is written; then files first, records second."""
        log = self.load()
        before = set(log.events)
        new = log.import_events(arc.events)              # all-or-nothing; raises before anything is written
        for ev in new:
            if not ev_mod.signature_holds(ev):
                raise HubError(f"record {ev.id[:12]} of device {ev.device[:12]}: its signature doesn't hold. It was "
                               "changed after it was signed, or wasn't signed with the key it carries; no field records "
                               "were imported")
        new_objects = sum(1 for sha in sorted(arc.objects) if self._write_object(arc, sha))
        for ev in new:
            self._write_event(ev)
        missing = sorted({e.body["object"] for e in log.events.values()
                          if e.type.endswith(".attach") and isinstance(e.body.get("object"), str)
                          and not self.has_object(e.body["object"])})
        report = ImportReport(arc.id, len(new), sum(1 for e in arc.events if e.id in before), new_objects,
                              sorted({e.device for e in arc.events}), missing)
        receipt = {"archive": arc.id, "digest": arc.digest, "kind": arc.kind, "created": arc.manifest["created"],
                   "created_by": arc.manifest["created_by"], "imported": ev_mod.utc_now(),
                   "new_events": report.new_events, "new_objects": report.new_objects}
        try:
            safefile.publish_new(self.root / "receipts" / f"{arc.id}.json",
                                 json.dumps(receipt, indent=1, ensure_ascii=False).encode("utf-8"))
        except safefile.AlreadyExists:
            pass
        return report

    def export_events(self) -> list[ev_mod.Event]:
        return self.load().ordered()
