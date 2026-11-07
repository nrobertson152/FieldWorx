# SPDX-License-Identifier: GPL-3.0-or-later
"""Findings (docs/PROTOCOL.md section 11): what a phone records about a unit, and accepting it into RevisionWorx's unit
register. The plan is checked against the register as ``revisionworx link unit`` answers it; the end-to-end tests run the
real RevisionWorx (skipped without it, or without its ``unit-records`` feature): a phone's field log goes into the hub,
the bridge accepts it, and RevisionWorx's history holds it as reported, with the field record as evidence, once."""
import json
import os
import subprocess

import pytest

from conftest import VECTORS, have_revisionworx
from fieldworx_bridge import accept as acc, archive, events as E, findings
from fieldworx_bridge.cli import main
from fieldworx_bridge.hub import Hub
from fieldworx_bridge.rwx_client import RevisionWorx, find_command

DEV = "dev_" + "3d" * 16
UNIT = "unt_" + "0c" * 16


def body(what, **k):
    return findings.record_body(UNIT, what, **k)


def part(number="", serial="", lot=""):
    return {"number": number, "serial": serial, "lot": lot}


def state_of(b, voids=()):
    """The reduced state of a finding recorded with body ``b`` (and voided for each reason in ``voids``)."""
    ent = E.new_id("fnd")
    rec = E.make(DEV, 1, "", "Alex Morgan", "finding.record", ent, [], b, "2026-11-03T09:00:00.000Z")
    evs, prev = [rec], rec
    for i, reason in enumerate(voids, start=2):
        prev = E.make(DEV, i, prev.id, "Alex Morgan", "finding.void", ent, [prev.id], {"reason": reason})
        evs.append(prev)
    log = E.FieldLog()
    log.import_events(evs)
    return findings.reduce(log, ent)


def unit(*components, uid=UNIT, history=()):
    return {"id": uid, "label": "NH-26-0001", "aliases": [], "identifiers": [], "components": list(components),
            "history": list(history), "events": {"count": 3}}


def comp(position, number="", serial="", lot="", unit_id="", label=""):
    return {"position": position, "number": number, "serial": serial, "lot": lot, "unit": unit_id, "label": label}


REPLACED = dict(position="P1", removed=part("PMP-10", "111"), fitted=part("PMP-11", "222"), disposition="repair")


# ------------------------------------------------------------------------------------------------- the record
def test_every_vector_body_gets_the_same_verdict():
    v = json.loads((VECTORS / "findings.json").read_text(encoding="utf-8"))
    for b in v["good"]:
        findings.check_record(b)
    for case in v["bad"]:
        with pytest.raises(findings.FindingError):
            findings.check_record(case["body"])
    assert {c["name"] for c in v["scenarios"]} >= {"a replacement with a photo", "voided on two phones", "two records"}


def test_the_txid_and_evidence_come_from_the_record():
    s = state_of(body("replaced", on="2026-11-02", **REPLACED))
    rec = s["recorded"]["event"]
    t = findings.accept_txid(rec)
    assert len(t) == 32 and int(t, 16) >= 0 and t == findings.accept_txid(rec) != findings.accept_txid("f" * 64)
    assert findings.evidence(s) == f"fieldworx-event:{rec}=reported by Alex Morgan on 2026-11-02", \
        "the day the work was done, when the phone says"
    assert findings.evidence(state_of(body("note", text="x"))).endswith("on 2026-11-03"), "else the day it was recorded"


# ------------------------------------------------------------------------------------------------ the plan
@pytest.mark.parametrize("now, action, words", [
    ([comp("P1", "PMP-10", "111")], "fit", "replaces PMP-10 serial 111"),
    ([comp("p1", "pmp-11", "222")], "nothing", "already has pmp-11 serial 222 at P1"),   # as people type them
    ([comp("P1", "PMP-10", "999")], "conflict", "the register has PMP-10 serial 999 at P1; the phone says PMP-10 "
                                                "serial 111 came out"),
    ([], "conflict", "the register has nothing at P1"),
    ([comp("P1", "PMP-11", "222")], "nothing", "the register already has PMP-11 serial 222 at P1"),
    ([comp("P1", "", "", unit_id="unt_" + "0d" * 16, label="111")], "fit", "replaces"),
])
def test_a_replacement_is_checked_against_what_the_register_has(now, action, words):
    s = state_of(body("replaced", **REPLACED))
    plan = findings.accept_plan(s, unit(*now))
    assert plan["action"] == action, plan
    if words:
        assert words in plan["why"]
    if action == "fit":
        assert (plan["position"], plan["part_number"], plan["serial"], plan["replace"], plan["disposition"]) == \
            ("P1", "PMP-11", "222", True, "repair")


def test_what_came_out_may_be_unknown():
    s = state_of(body("replaced", position="P1", removed=part(), fitted=part("PMP-11"), disposition="unknown"))
    assert findings.accept_plan(s, unit())["action"] == "fit", "nothing recorded there, nothing known to contradict"
    plan = findings.accept_plan(s, unit(comp("P1", "PMP-10", "111")))
    assert (plan["action"], plan["replace"]) == ("fit", True), "something was there, and it was replaced"


def test_a_find_fills_an_empty_position_and_a_person_settles_a_contradiction():
    s = state_of(body("found", position="V3", fitted=part("VLV-20", lot="L-7")))
    plan = findings.accept_plan(s, unit())
    assert (plan["action"], plan["replace"], plan["lot"]) == ("fit", False, "L-7")
    assert findings.accept_plan(s, unit(comp("V3", "VLV-20", lot="L-7")))["action"] == "nothing"
    other = unit(comp("V3", "VLV-21"))
    assert findings.accept_plan(s, other)["action"] == "conflict"
    forced = findings.accept_plan(s, other, as_="fit")
    assert (forced["action"], forced["replace"], forced["disposition"]) == ("fit", True, "unknown")
    noted = findings.accept_plan(s, other, as_="note")
    assert noted["action"] == "note" and noted["text"] == "Found at V3: VLV-20 lot L-7."


def test_changes_and_notes():
    s = state_of(body("change", change="ECO-0042", text="Lugs welded on."))
    assert findings.accept_plan(s, unit()) == {"action": "change", "change": "ECO-0042",
                                               "why": "ECO-0042 carried out"}
    with pytest.raises(findings.FindingError):
        findings.accept_plan(s, unit(), as_="fit")
    assert findings.accept_plan(s, unit(), as_="note")["text"] == "Reported carried out: ECO-0042. Lugs welded on."
    n = state_of(body("note", text="Guard on P1\nmissing"))
    assert findings.accept_plan(n, unit()) == {"action": "note", "text": "Guard on P1\nmissing",
                                               "why": "kept as a note in the unit's history"}


def test_what_cant_be_accepted_says_why():
    with pytest.raises(findings.FindingError, match="voided on the phone: wrong unit"):
        findings.accept_plan(state_of(body("note", text="x"), voids=["wrong unit"]), unit())
    with pytest.raises(findings.FindingError, match="not NH-26-0001"):
        findings.accept_plan(state_of(body("note", text="x")), unit(uid="unt_" + "0d" * 16))
    alias = unit(uid="unt_" + "0d" * 16)
    alias["identifiers"] = [{"scheme": "fieldworx", "value": UNIT, "issuer": "", "active": True}]
    assert findings.accept_plan(state_of(body("note", text="x")), alias)["action"] == "note", \
        "a unit that carries the finding's FieldWorx id is the one"
    with pytest.raises(findings.FindingError, match="damaged"):
        findings.accept_plan({"entity": "fnd_x", "valid": False, "problems": ["no finding record"]}, unit())


def test_where_a_finding_was_accepted():
    s = state_of(body("note", text="x"))
    ref = s["recorded"]["event"]
    u = unit(history=[{"n": 4, "evidence": [{"kind": "fieldworx-event", "ref": ref, "label": ""}]},
                      {"n": 5, "evidence": [{"kind": "work-order", "ref": ref, "label": ""}]}])
    assert findings.accepted_as(s, u) == [4]


# --------------------------------------------------------------------------------------- end to end, for real
def have_unit_records() -> bool:
    return have_revisionworx() and "unit-records" in (RevisionWorx().version().get("features") or [])


@pytest.fixture
def site(tmp_path):
    """A RevisionWorx workspace with unit NH-26-0001 (PMP-10 serial 111 at P1), and a hub holding a phone's findings."""
    if not have_unit_records():
        pytest.skip("this RevisionWorx can't record findings (link version doesn't list 'unit-records')")
    ws = tmp_path / "ws"
    env = dict(os.environ)

    def rwx(*args):
        proc = subprocess.run(find_command() + [*map(str, args)], capture_output=True, text=True, env=env)
        assert proc.returncode == 0, proc.stdout + proc.stderr
        return proc.stdout

    rwx("init", ws, "--name", "Site")
    rwx("-w", ws, "unit", "new", "--serial", "NH-26-0001", "--model", "HPU-75", "--status", "in-service")
    rwx("-w", ws, "unit", "fit", "NH-26-0001", "P1", "--part-number", "PMP-10", "--serial", "111")
    uid = json.loads(rwx("-w", ws, "link", "unit", "NH-26-0001"))["unit"]["id"]
    phone = Phone()
    made = {
        "replaced": phone.finding(findings.record_body(uid, "replaced", on="2026-11-03", **REPLACED)),
        "found": phone.finding(findings.record_body(uid, "found", position="V3", fitted=part("VLV-20", lot="L-7"))),
        "clash": phone.finding(findings.record_body(uid, "found", position="P2", fitted=part("FLT-3"))),
        "note": phone.finding(findings.record_body(uid, "note", text="Guard on P1 missing")),
        "voided": phone.finding(findings.record_body(uid, "note", text="wrong one")),
    }
    phone.void(made["voided"], "recorded on the wrong unit")
    rwx("-w", ws, "unit", "fit", "NH-26-0001", "P2", "--part-number", "FLT-2")
    log = tmp_path / "phone.fieldlog"
    archive.write(log, "fieldlog", archive_id=E.new_id("flg"), title="phone", created=E.utc_now(),
                  created_by={"device": DEV, "user": "Alex Morgan"}, events=phone.events, objects=[])
    assert main(["import", "-w", str(ws), str(log)]) == 0
    return ws, made, rwx


class Phone:
    def __init__(self):
        self.seq, self.prev, self.events, self.heads = 0, "", [], {}

    def _rec(self, type_, ent, b):
        self.seq += 1
        ev = E.make(DEV, self.seq, self.prev, "Alex Morgan", type_, ent, self.heads.get(ent, []), b)
        self.prev, self.heads[ent] = ev.id, [ev.id]
        self.events.append(ev)
        return ev

    def finding(self, b) -> str:
        ent = E.new_id("fnd")
        self._rec("finding.record", ent, b)
        return ent

    def void(self, ent, reason):
        self._rec("finding.void", ent, {"reason": reason})


def test_accepting_findings_into_revisionworx(site, capsys):
    ws, made, rwx = site
    capsys.readouterr()
    assert main(["findings", "-w", str(ws)]) == 0
    listed = capsys.readouterr().out
    assert "to accept: replaces PMP-10 serial 111" in listed and "needs a decision: the register has FLT-2 at P2" in listed
    assert "voided: voided on the phone: recorded on the wrong unit" in listed

    before = json.loads(rwx("-w", ws, "link", "unit", "NH-26-0001"))["unit"]["events"]["count"]
    assert main(["accept", made["replaced"], "-w", str(ws), "--dry-run"]) == 0
    assert "would record on NH-26-0001: replaces PMP-10 serial 111 (nothing was written)" in capsys.readouterr().out
    assert json.loads(rwx("-w", ws, "link", "unit", "NH-26-0001"))["unit"]["events"]["count"] == before

    assert main(["accept", made["replaced"][:16], "-w", str(ws)]) == 0, "the start of an id is enough"
    assert "accepted into NH-26-0001's history" in capsys.readouterr().out
    u = json.loads(rwx("-w", ws, "link", "unit", "NH-26-0001"))["unit"]
    p1 = next(c for c in u["components"] if c["position"] == "P1")
    assert (p1["number"], p1["serial"], p1["basis"]) == ("PMP-11", "222", "reported")
    written = [h for h in u["history"] if h["type"] in ("component.removed", "component.installed")][-2:]
    for h in written:
        assert h["basis"] == "reported" and h["effective"] == "2026-11-03"
        assert [e["kind"] for e in h["evidence"]] == ["fieldworx-event"]
        assert h["evidence"][0]["label"] == "reported by Alex Morgan on 2026-11-03"

    count = u["events"]["count"]
    assert main(["accept", made["replaced"], "-w", str(ws)]) == 0
    assert "already accepted: NH-26-0001, event" in capsys.readouterr().out
    assert json.loads(rwx("-w", ws, "link", "unit", "NH-26-0001"))["unit"]["events"]["count"] == count, \
        "accepting twice records nothing"

    assert main(["accept", made["found"], "-w", str(ws)]) == 0
    assert main(["accept", made["note"], "-w", str(ws)]) == 0
    assert main(["accept", made["clash"], "-w", str(ws)]) == 2
    assert "nothing was recorded: the register has FLT-2 at P2; the phone found FLT-3" in capsys.readouterr().err
    assert main(["accept", made["clash"], "-w", str(ws), "--as", "note"]) == 0
    assert main(["accept", made["voided"], "-w", str(ws)]) == 2
    assert "can't be accepted: voided on the phone" in capsys.readouterr().err

    u = json.loads(rwx("-w", ws, "link", "unit", "NH-26-0001"))["unit"]
    assert {c["position"]: c["number"] for c in u["components"]} == {"P1": "PMP-11", "P2": "FLT-2", "V3": "VLV-20"}
    assert [h["summary"] for h in u["history"] if h["type"] == "note"][-2:] == \
        ["Guard on P1 missing", "Found at P2: FLT-3."]
    capsys.readouterr()
    assert main(["findings", "-w", str(ws)]) == 0
    out = capsys.readouterr().out
    assert out.count("accepted: event") == 4 and "needs a decision" not in out


def test_a_unit_that_changed_since_it_was_read_is_refused(site, monkeypatch, capsys):
    """The bridge decides on the unit as it read it; something recorded between that read and the write makes RevisionWorx
    refuse, and nothing is written."""
    ws, made, rwx = site
    real = acc._unit

    def stale(src, ref):
        u = real(src, ref)
        rwx("-w", ws, "unit", "note", "NH-26-0001", "recorded meanwhile")
        return u

    monkeypatch.setattr(acc, "_unit", stale)
    before = json.loads(rwx("-w", ws, "link", "unit", "NH-26-0001"))["unit"]["components"]
    assert main(["accept", made["found"], "-w", str(ws)]) == 2
    assert "changed in RevisionWorx while this was being accepted" in capsys.readouterr().err
    assert json.loads(rwx("-w", ws, "link", "unit", "NH-26-0001"))["unit"]["components"] == before


def test_findings_without_revisionworx_are_listed(tmp_path, capsys):
    phone = Phone()
    phone.finding(findings.record_body(UNIT, "note", text="Oil dark"))
    log = tmp_path / "phone.fieldlog"
    archive.write(log, "fieldlog", archive_id=E.new_id("flg"), title="phone", created=E.utc_now(),
                  created_by={"device": DEV, "user": "Alex Morgan"}, events=phone.events, objects=[])
    hub = Hub.open(tmp_path / "hub", create=True)
    with archive.read(log) as arc:
        hub.import_archive(arc)
    capsys.readouterr()
    assert main(["findings", "--hub", str(tmp_path / "hub")]) == 0
    out = capsys.readouterr().out
    assert f"{UNIT}  note: Oil dark  (Alex Morgan," in out
    with pytest.raises(SystemExit):
        main(["accept", "fnd_", "--hub", str(tmp_path / "hub")])      # accepting needs the workspace
