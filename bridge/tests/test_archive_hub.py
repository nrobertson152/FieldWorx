# SPDX-License-Identifier: GPL-3.0-or-later
"""Archives refuse anything damaged; the hub takes field logs all-or-nothing, idempotently, and fails closed."""
import hashlib
import io
import json
import threading
import zipfile

import pytest

from fieldworx_bridge import archive, events as E, fxjson, inspections, report
from fieldworx_bridge.hub import Hub, HubError

DEV = "dev_" + "1f" * 16
DEV2 = "dev_" + "2e" * 16
TEMPLATE = {"format": "fieldworx.template", "version": 1, "id": "T-1", "revision": "A", "title": "Test", "description": "",
            "sections": [{"title": "S", "items": [
                {"id": "1", "kind": "check", "prompt": "Ok?", "required": True, "photo": "optional", "help": ""},
                {"id": "2", "kind": "measure", "prompt": "Gap", "unit": "mm", "nominal": "1", "min": "0.9", "max": "1.1",
                 "required": True, "photo": "none", "help": ""}]}]}
JPEG = b"\xff\xd8\xff\xe0" + b"photo-bytes" * 50 + b"\xff\xd9"


class Phone:
    def __init__(self, dev, actor="Tess"):
        self.dev, self.actor, self.seq, self.prev, self.events = dev, actor, 0, "", []

    def rec(self, type_, entity, deps, body):
        self.seq += 1
        ev = E.make(self.dev, self.seq, self.prev, self.actor, type_, entity, deps, body)
        self.prev = ev.id
        self.events.append(ev)
        return ev


def an_inspection(phone, photo=True):
    ins = E.new_id("ins")
    s = phone.rec("inspection.start", ins, [], {"template": TEMPLATE, "title": "Unit 7", "package": "",
                                                "subject": {"kind": "", "id": "", "label": ""}})
    a = phone.rec("inspection.answer", ins, [s.id], {"item": "1", "value": {"result": "pass"}, "note": ""})
    b = phone.rec("inspection.answer", ins, [a.id], {"item": "2", "value": {"measured": "1.05"}, "note": ""})
    last = b
    if photo:
        last = phone.rec("inspection.attach", ins, [b.id], {"object": hashlib.sha256(JPEG).hexdigest(),
                                                            "size": len(JPEG), "media_type": "image/jpeg", "item": "1",
                                                            "caption": "guard"})
    phone.rec("inspection.complete", ins, [last.id], {"result": "pass", "summary": ""})
    return ins


def write_log(path, phone, objects=(JPEG,)):
    archive.write(path, "fieldlog", archive_id=E.new_id("flg"), title="from phone", created=E.utc_now(),
                  created_by={"device": phone.dev, "user": phone.actor},
                  events=phone.events, objects=[archive.ObjectSource.from_bytes(o, "image/jpeg") for o in objects])


def test_round_trip(tmp_path):
    p = Phone(DEV)
    an_inspection(p)
    write_log(tmp_path / "a.fieldlog", p)
    with archive.read(tmp_path / "a.fieldlog") as arc:
        assert arc.kind == "fieldlog"
        assert [e.id for e in arc.events] == [e.id for e in p.events]
        assert arc.open_object(hashlib.sha256(JPEG).hexdigest()).read() == JPEG


def _rewrite(src, dst, change):
    with zipfile.ZipFile(src) as z:
        members = [(i, z.read(i.filename)) for i in z.infolist()]
    members = change(members)
    with zipfile.ZipFile(dst, "w") as out:
        for info, data in members:
            out.writestr(info, data)


@pytest.mark.parametrize("damage", ["object bytes", "missing event", "event bytes", "manifest whitespace",
                                    "mimetype", "traversal name", "duplicate name"])
def test_damage_is_refused(tmp_path, damage):
    p = Phone(DEV)
    an_inspection(p)
    good = tmp_path / "good.fieldlog"
    write_log(good, p)

    def change(members):
        out = []
        for info, data in members:
            n = info.filename
            if damage == "object bytes" and n.startswith("objects/"):
                data = data[:-1] + b"X"
            if damage == "missing event" and n.startswith("events/") and not any(
                    o.filename.startswith("events/") for o, _ in out):
                continue
            if damage == "event bytes" and n.startswith("events/"):
                data = data.replace(b'"Tess"', b'"Mallory"')
            if damage == "manifest whitespace" and n == "manifest.json":
                data = b"{ " + data[1:]
            if damage == "mimetype" and n == "mimetype":
                data = b"application/zip"
            out.append((info, data))
        if damage == "traversal name":
            out.append((zipfile.ZipInfo("../evil"), b"x"))
        if damage == "duplicate name":
            out.append((zipfile.ZipInfo("manifest.json"), b"{}"))
        return out

    bad = tmp_path / "bad.fieldlog"
    import warnings
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        _rewrite(good, bad, change)
    with pytest.raises(archive.ArchiveError):
        archive.read(bad)


def test_unlisted_members_are_ignored(tmp_path):
    p = Phone(DEV)
    an_inspection(p)
    good = tmp_path / "good.fieldlog"
    write_log(good, p)
    extra = tmp_path / "extra.fieldlog"
    _rewrite(good, extra, lambda m: m + [(zipfile.ZipInfo("future/thing.json"), b"{}")])
    with archive.read(extra) as arc:
        assert len(arc.events) == len(p.events)


def test_hub_import_is_idempotent_and_reports(tmp_path):
    p = Phone(DEV)
    ins = an_inspection(p)
    log = tmp_path / "a.fieldlog"
    write_log(log, p)
    hub = Hub.open(tmp_path / "hub", create=True)
    with archive.read(log) as arc:
        r1 = hub.import_archive(arc)
    with archive.read(log) as arc:
        r2 = hub.import_archive(arc)
    assert (r1.new_events, r1.new_objects) == (5, 1)
    assert (r2.new_events, r2.known_events, r2.new_objects) == (0, 5, 0)
    state = inspections.reduce(hub.load(), ins)
    assert state["status"] == "completed" and state["outcome"] == "pass"
    files = report.write_reports(hub, tmp_path / "out")
    page = (tmp_path / "out" / f"{ins}.html").read_text(encoding="utf-8")
    assert "data:image/jpeg;base64," in page and "Completed by Tess" in page
    assert len(files) == 2


def test_photo_sent_later(tmp_path):
    p = Phone(DEV)
    ins = an_inspection(p)
    hub = Hub.open(tmp_path / "hub", create=True)
    write_log(tmp_path / "1.fieldlog", p, objects=())
    with archive.read(tmp_path / "1.fieldlog") as arc:
        rep = hub.import_archive(arc)
    assert rep.missing_objects == [hashlib.sha256(JPEG).hexdigest()]
    assert "photo not received yet" in report.inspection_html(hub, hub.load(), ins)
    write_log(tmp_path / "2.fieldlog", p)
    with archive.read(tmp_path / "2.fieldlog") as arc:
        assert hub.import_archive(arc).missing_objects == []


def test_gap_and_fork_are_refused_and_change_nothing(tmp_path):
    p = Phone(DEV)
    an_inspection(p)
    hub = Hub.open(tmp_path / "hub", create=True)
    later = Phone(DEV)
    later.events = p.events[2:]
    write_log(tmp_path / "gap.fieldlog", later)
    with archive.read(tmp_path / "gap.fieldlog") as arc, pytest.raises(E.MissingHistory):
        hub.import_archive(arc)
    assert len(hub.load()) == 0
    write_log(tmp_path / "ok.fieldlog", p)
    with archive.read(tmp_path / "ok.fieldlog") as arc:
        hub.import_archive(arc)
    restored = Phone(DEV)                                  # same device id, history restarted: a fork
    an_inspection(restored)
    write_log(tmp_path / "fork.fieldlog", restored)
    with archive.read(tmp_path / "fork.fieldlog") as arc, pytest.raises(E.ForkError):
        hub.import_archive(arc)
    assert len(hub.load()) == 5


def test_two_computers_import_into_one_hub_at_once(tmp_path):
    phones = [Phone(DEV, "A"), Phone(DEV2, "B")]
    for ph in phones:
        for _ in range(3):
            an_inspection(ph, photo=False)
    logs = []
    for i, ph in enumerate(phones):
        write_log(tmp_path / f"{i}.fieldlog", ph, objects=())
        logs.append(tmp_path / f"{i}.fieldlog")
    Hub.open(tmp_path / "hub", create=True)
    errors = []

    def worker(path):
        try:
            with archive.read(path) as arc:
                Hub.open(tmp_path / "hub").import_archive(arc)
        except Exception as exc:  # noqa: BLE001
            errors.append(exc)

    threads = [threading.Thread(target=worker, args=(logs[i % 2],)) for i in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert not errors
    log = Hub.open(tmp_path / "hub").load()
    assert len(log) == 24 and log.heads()[DEV]["seq"] == 12


def test_damaged_hub_file_stops_loading(tmp_path):
    p = Phone(DEV)
    an_inspection(p)
    write_log(tmp_path / "a.fieldlog", p)
    hub = Hub.open(tmp_path / "hub", create=True)
    with archive.read(tmp_path / "a.fieldlog") as arc:
        hub.import_archive(arc)
    f = tmp_path / "hub" / "events" / DEV / "0000000002.json"
    f.write_bytes(f.read_bytes().replace(b"Tess", b"Tesx"))
    with pytest.raises(HubError):
        hub.load()


def test_concurrent_edits_show_as_conflicts_in_the_register(tmp_path):
    a, b = Phone(DEV, "A"), Phone(DEV2, "B")
    ins = E.new_id("ins")
    s = a.rec("inspection.start", ins, [], {"template": TEMPLATE, "title": "x", "package": "",
                                            "subject": {"kind": "", "id": "", "label": ""}})
    b.events.append(s)
    a.rec("inspection.answer", ins, [s.id], {"item": "2", "value": {"measured": "1.0"}, "note": ""})
    b.rec("inspection.answer", ins, [s.id], {"item": "2", "value": {"measured": "1.2"}, "note": ""})
    hub = Hub.open(tmp_path / "hub", create=True)
    for i, ph in enumerate((a, b)):
        write_log(tmp_path / f"{i}.fieldlog", ph, objects=())
        with archive.read(tmp_path / f"{i}.fieldlog") as arc:
            hub.import_archive(arc)
    csv_text = report.register_csv(hub.load())
    assert ",conflict," in csv_text and ",1," in csv_text
