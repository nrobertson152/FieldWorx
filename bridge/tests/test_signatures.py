# SPDX-License-Identifier: GPL-3.0-or-later
"""Signed field records (docs/PROTOCOL.md section 12): version 2 envelopes, what a reader checks, and that a copy takes in
only records whose signatures hold, checking each once, when it is new."""
import json
import os
import subprocess
import sys

import pytest

from conftest import ROOT, VECTORS
from fieldworx_bridge import archive, ed25519, events as E, fxjson
from fieldworx_bridge.hub import Hub, HubError

DEV = "dev_" + "1f" * 16
SEED = bytes(range(32))
OTHER = bytes(range(1, 33))
ENT = "ins_" + "aa" * 16


def load(name):
    return json.loads((VECTORS / name).read_text(encoding="utf-8"))


class Phone:
    def __init__(self, seed=SEED, dev=DEV):
        self.seed, self.dev, self.seq, self.prev, self.events = seed, dev, 0, "", []

    def rec(self, body, deps=()):
        self.seq += 1
        ev = E.make(self.dev, self.seq, self.prev, "Tess", "inspection.note", ENT, list(deps), body, seed=self.seed)
        self.prev = ev.id
        self.events.append(ev)
        return ev


def tampered(ev: E.Event, **changes) -> E.Event:
    """``ev`` with fields changed after it was signed, written as a broken phone or a person editing the file would."""
    data = {**ev.data, **changes}
    raw = fxjson.encode(data)
    return E.Event(E._id(data, raw), raw, data)


def field_log(path, events, **created_by):
    archive.write(path, "fieldlog", archive_id=E.new_id("flg"), title="t", created=E.utc_now(),
                  created_by={"device": DEV, **created_by}, events=events)
    return path


# ---------------------------------------------------------------------------------------------------- the vectors
def test_signature_vectors():
    v = load("signatures.json")
    for c in v["rfc8032"]:
        seed = bytes.fromhex(c["seed"])
        assert ed25519.public_key(seed).hex() == c["public"]
        assert ed25519.sign(seed, bytes.fromhex(c["message"])).hex() == c["signature"]
        assert ed25519.verify(bytes.fromhex(c["public"]), bytes.fromhex(c["message"]), bytes.fromhex(c["signature"]))
    for c in v["fingerprints"]:
        assert E.fingerprint(c["public"]) == c["fingerprint"]
    for c in v["events"]:
        assert E.signature_message(c["event"]).hex() == c["message"]
        assert ed25519.sign(bytes.fromhex(c["seed"]), bytes.fromhex(c["message"])).hex() == c["signature"]
    for c in v["bad"]:
        assert not ed25519.verify(bytes.fromhex(c["public"]), bytes.fromhex(c["message"]), bytes.fromhex(c["signature"]))


def test_a_signed_envelope_vector():
    g = load("envelopes.json")["good"][1]
    ev = E.from_bytes(g["event"].encode("utf-8"))
    assert (ev.version, ev.id) == (2, g["id"]) and ev.id == g["unsigned_digest"]
    assert E.signature_holds(ev)


# ---------------------------------------------------------------------------------------------------- reading
def test_a_signed_record_round_trips_and_its_id_leaves_out_the_signature():
    ev = Phone().rec({"x": 1})
    assert ev.version == 2 and ev.key == ed25519.public_key(SEED).hex() and len(ev.sig) == 128
    unsigned = {k: v for k, v in ev.data.items() if k != "sig"}
    assert ev.id == fxjson.digest("event/v2", unsigned)
    assert ed25519.verify(bytes.fromhex(ev.key), b"fieldworx/event-signature/v1\0" + ev.id.encode(), bytes.fromhex(ev.sig))
    again = E.from_bytes(ev.raw, ev.id)
    assert again.raw == ev.raw and again.id == ev.id
    assert E.make(DEV, 1, "", "Tess", "inspection.note", ENT, [], {"x": 1}, ev.time, seed=SEED).raw == ev.raw  # deterministic


@pytest.mark.parametrize("change", [{"body": {"x": 2}}, {"actor": "Mallory"}, {"sig": "00" * 64},
                                    {"key": ed25519.public_key(OTHER).hex()}])
def test_a_record_changed_after_it_was_signed_is_refused(change):
    ev = Phone().rec({"x": 1})
    bad = tampered(ev, **change)
    with pytest.raises(E.EventError, match="signature doesn't hold"):
        E.from_bytes(bad.raw)
    assert E.from_bytes(bad.raw, check_sig=False).id == bad.id       # its own store, checked when it came in


def test_one_key_per_device_and_no_unsigned_record_after_a_signed_one():
    phone = Phone()
    first = phone.rec({"x": 1})
    log = E.FieldLog()
    log.import_events([first])
    other = E.make(DEV, 2, first.id, "Tess", "inspection.note", ENT, [first.id], {"x": 2}, seed=OTHER)
    with pytest.raises(E.EventError, match="two different keys"):
        log.import_events([other])
    unsigned = E.make(DEV, 2, first.id, "Tess", "inspection.note", ENT, [first.id], {"x": 2})
    with pytest.raises(E.EventError, match="isn't signed"):
        log.import_events([unsigned])
    assert len(log) == 1
    log.import_events([phone.rec({"x": 2}, [first.id])])
    assert len(log) == 2


# ---------------------------------------------------------------------------------------------------- archives and the hub
def test_an_archive_refuses_a_record_whose_signature_doesnt_hold(tmp_path):
    phone = Phone()
    good = phone.rec({"x": 1})
    bad = tampered(phone.rec({"x": 2}, [good.id]), body={"x": "edited"})
    path = field_log(tmp_path / "bad.fieldlog", [good, bad], key=good.key)
    with pytest.raises(archive.ArchiveError, match="signature doesn't hold"):
        archive.read(path)
    with archive.read(path, check_signatures=False) as arc:          # left to the importer, which checks the new ones
        assert [e.id for e in arc.events] == [good.id, bad.id]
        hub = Hub.open(tmp_path / "hub", create=True)
        with pytest.raises(HubError, match="signature doesn't hold"):
            hub.import_archive(arc)
    assert len(hub.load()) == 0


def test_the_hub_checks_new_records_once_and_keeps_its_own_copy_of_known_ones(tmp_path, monkeypatch):
    phone = Phone()
    first = phone.rec({"x": 1})
    hub = Hub.open(tmp_path / "hub", create=True)
    with archive.read(field_log(tmp_path / "1.fieldlog", [first]), check_signatures=False) as arc:
        assert hub.import_archive(arc).new_events == 1
    second = phone.rec({"x": 2}, [first.id])
    checked = []
    real = E.signature_holds
    monkeypatch.setattr(E, "signature_holds", lambda ev: checked.append(ev.id) or real(ev))
    forged_copy = tampered(first, sig="00" * 64)                     # same record, a signature that doesn't hold
    with archive.read(field_log(tmp_path / "2.fieldlog", [forged_copy, second]), check_signatures=False) as arc:
        report = hub.import_archive(arc)
    assert (report.new_events, report.known_events) == (1, 1) and checked == [second.id]
    stored = hub.load()
    assert stored.get(first.id).raw == first.raw and stored.get(second.id).raw == second.raw


def test_verify_checks_every_signature(tmp_path):
    phone = Phone()
    good = phone.rec({"x": 1})
    ok = field_log(tmp_path / "ok.fieldlog", [good], key=good.key)
    bad = field_log(tmp_path / "bad.fieldlog", [tampered(good, actor="Mallory")])
    run = [sys.executable, "-m", "fieldworx_bridge", "verify"]
    env = {**os.environ, "PYTHONPATH": str(ROOT / "bridge")}
    done = subprocess.run([*run, str(ok)], capture_output=True, text=True, env=env)
    assert done.returncode == 0 and "intact fieldlog" in done.stdout, done.stdout + done.stderr
    done = subprocess.run([*run, str(bad)], capture_output=True, text=True, env=env)
    assert done.returncode == 1 and "signature doesn't hold" in done.stdout, done.stdout + done.stderr


def test_the_signed_sample_field_log_names_its_key():
    with archive.read(VECTORS / "signed.fieldlog") as arc:
        created_by = arc.manifest["created_by"]
        mine = [e for e in arc.events if e.device == created_by["device"]]
        assert mine and all(e.key == created_by["key"] for e in mine)
