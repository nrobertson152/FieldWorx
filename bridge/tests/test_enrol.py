# SPDX-License-Identifier: GPL-3.0-or-later
"""Enrolling phones to RevisionWorx accounts, and accepting what they signed as verified (docs/PROTOCOL.md sections 12.4
and 12.5). The end-to-end tests run the real RevisionWorx in a workspace set up for a team (skipped without it, or
without its ``field-signatures`` feature): an administrator enrols a phone from its field log, and a finding the phone
signed goes into the unit's history as verified in the phone owner's name, with RevisionWorx checking the signature
itself; anything it can't check is refused or reported, never verified."""
import json
import os
import subprocess

import pytest

from conftest import have_revisionworx
from fieldworx_bridge import accept as acc, archive, ed25519, enrol, events as E, findings
from fieldworx_bridge.cli import main
from fieldworx_bridge.rwx_client import RevisionWorx, find_command

DEV = "dev_" + "4c" * 16
SEED = bytes(range(32, 64))
KEY = ed25519.public_key(SEED).hex()
PASSWORD = "correct horse battery"


class Phone:
    def __init__(self, seed=SEED, dev=DEV):
        self.seed, self.dev, self.seq, self.prev, self.events, self.heads = seed, dev, 0, "", [], {}

    def _rec(self, type_, ent, b):
        self.seq += 1
        ev = E.make(self.dev, self.seq, self.prev, "Riley Smith", type_, ent, self.heads.get(ent, []), b, seed=self.seed)
        self.prev, self.heads[ent] = ev.id, [ev.id]
        self.events.append(ev)
        return ev

    def finding(self, b) -> str:
        ent = E.new_id("fnd")
        self._rec("finding.record", ent, b)
        return ent

    def field_log(self, path, **created_by):
        made_by = {"device": self.dev, "key": ed25519.public_key(self.seed).hex(), "user": "Riley Smith", **created_by}
        archive.write(path, "fieldlog", archive_id=E.new_id("flg"), title="phone", created=E.utc_now(),
                      created_by=made_by, events=self.events, objects=[])
        return path


# --------------------------------------------------------------------------------------------- no RevisionWorx needed
def test_a_fingerprint_is_read_as_people_type_it():
    assert enrol.normal_fingerprint("3f2a 91c0-77b1 04de") == "3F2A-91C0-77B1-04DE"
    assert enrol.normal_fingerprint("3F2A91C077B104DE") == "3F2A-91C0-77B1-04DE"
    for bad in ("3F2A-91C0-77B1", "3F2A-91C0-77B1-04DG", ""):
        with pytest.raises(enrol.EnrolError):
            enrol.normal_fingerprint(bad)


def test_the_phone_is_the_one_that_wrote_the_field_log(tmp_path):
    phone = Phone()
    phone.finding(findings.record_body("unt_" + "0c" * 16, "note", text="x"))
    with archive.read(phone.field_log(tmp_path / "ok.fieldlog")) as arc:
        assert enrol.phone_of(arc) == (DEV, KEY)
    other = ed25519.public_key(bytes(32)).hex()
    with archive.read(phone.field_log(tmp_path / "liar.fieldlog", key=other)) as arc:
        with pytest.raises(enrol.EnrolError, match="signed with another"):
            enrol.phone_of(arc)
    with archive.read(phone.field_log(tmp_path / "old.fieldlog", key="")) as arc:
        with pytest.raises(enrol.EnrolError, match="from before phones had keys"):
            enrol.phone_of(arc)
    assert main(["enrol", str(tmp_path / "ok.fieldlog"), "-w", str(tmp_path), "--account", "riley",
                 "--fingerprint", "0000-0000-0000-0000"]) == 2, "a wrong fingerprint stops before RevisionWorx is asked"


# --------------------------------------------------------------------------------------- end to end, for real
def have_field_signatures() -> bool:
    return have_revisionworx() and "field-signatures" in (RevisionWorx().version().get("features") or [])


@pytest.fixture
def team(tmp_path):
    """A RevisionWorx team workspace (boss, an administrator, logged in here; riley, whose phone this is), unit NH-26-0001
    with PMP-10 serial 111 at P1, and a hub holding the phone's signed findings."""
    if not have_field_signatures():
        pytest.skip("this RevisionWorx can't enrol phones (link version doesn't list 'field-signatures')")
    ws = tmp_path / "ws"
    env = dict(os.environ)

    def rwx(*args, stdin=None, ok=True):
        proc = subprocess.run(find_command() + [*map(str, args)], capture_output=True, text=True, env=env, input=stdin)
        if ok:
            assert proc.returncode == 0, proc.stdout + proc.stderr
        return proc

    rwx("init", ws, "--name", "Site")
    rwx("-w", ws, "team", "enable", "--admin", "boss", "--password-stdin", stdin=PASSWORD + "\n")
    rwx("-w", ws, "user", "add", "riley", "--display", "Riley Smith", "--password-stdin", stdin=PASSWORD + "!\n")
    rwx("-w", ws, "unit", "new", "--serial", "NH-26-0001", "--model", "HPU-75", "--status", "in-service")
    rwx("-w", ws, "unit", "fit", "NH-26-0001", "P1", "--part-number", "PMP-10", "--serial", "111")
    uid = json.loads(rwx("-w", ws, "link", "unit", "NH-26-0001").stdout)["unit"]["id"]
    phone = Phone()
    made = {"replaced": phone.finding(findings.record_body(uid, "replaced", on="2026-11-07", position="P1",
                                                           removed={"number": "PMP-10", "serial": "111", "lot": ""},
                                                           fitted={"number": "PMP-11", "serial": "222", "lot": ""},
                                                           disposition="repair")),
            "note": phone.finding(findings.record_body(uid, "note", text="Guard on P1 loose; tightened")),
            "another": phone.finding(findings.record_body(uid, "note", text="Oil dark"))}
    log = phone.field_log(tmp_path / "phone.fieldlog")
    assert main(["import", "-w", str(ws), str(log)]) == 0
    return ws, made, rwx, log


def history(rwx, ws):
    return json.loads(rwx("-w", ws, "link", "unit", "NH-26-0001").stdout)["unit"]["history"]


def test_an_enrolled_phones_finding_is_accepted_as_verified_in_its_owners_name(team, capsys):
    ws, made, rwx, log = team
    capsys.readouterr()
    assert main(["enrol", str(log), "-w", str(ws), "--account", "riley", "--fingerprint", E.fingerprint(KEY).lower(),
                 "--name", "Riley's phone"]) == 0
    assert f"enrolled Riley's phone ({DEV}, {E.fingerprint(KEY)}) to riley" in capsys.readouterr().out
    assert main(["enrol", str(log), "-w", str(ws), "--account", "riley", "--fingerprint", E.fingerprint(KEY)]) == 0
    assert "was already enrolled to riley" in capsys.readouterr().out

    assert main(["findings", "-w", str(ws)]) == 0
    assert "signed on Riley's phone, enrolled to riley: accepting records it as verified" in capsys.readouterr().out
    assert main(["accept", made["replaced"], "-w", str(ws)]) == 0
    assert "verified: signed on Riley's phone, enrolled to riley" in capsys.readouterr().out
    written = [h for h in history(rwx, ws) if h["type"] in ("component.removed", "component.installed")][-2:]
    for h in written:
        assert h["basis"] == "verified" and h["actor"]["account"] == "boss"
        kinds = {e["kind"]: e for e in h["evidence"]}
        assert set(kinds) == {"fieldworx-event", "field-signature", "field-signer"}
        assert kinds["field-signer"]["ref"] == "riley" and kinds["field-signature"]["ref"].startswith(DEV + ":")
    assert rwx("-w", ws, "unit", "verify").returncode == 0           # RevisionWorx checks the signature again

    assert main(["accept", made["note"], "-w", str(ws), "--basis", "reported"]) == 0
    assert ", reported" in capsys.readouterr().out
    note = [h for h in history(rwx, ws) if h["type"] == "note"][-1]
    assert note["basis"] == "reported" and [e["kind"] for e in note["evidence"]] == ["fieldworx-event"]


def test_a_wrong_fingerprint_or_a_phone_not_enrolled_verifies_nothing(team, capsys):
    ws, made, rwx, log = team
    capsys.readouterr()
    assert main(["enrol", str(log), "-w", str(ws), "--account", "riley", "--fingerprint", "0000-0000-0000-0000"]) == 2
    assert "nothing was enrolled" in capsys.readouterr().err
    assert json.loads(rwx("-w", ws, "link", "devices").stdout)["devices"] == []
    assert main(["findings", "-w", str(ws)]) == 0
    assert "signed on a phone that isn't enrolled to anyone" in capsys.readouterr().out
    assert main(["accept", made["note"], "-w", str(ws)]) == 0
    assert ", reported" in capsys.readouterr().out
    note = [h for h in history(rwx, ws) if h["type"] == "note"][-1]
    assert note["basis"] == "reported" and "field-signature" not in [e["kind"] for e in note["evidence"]]


def test_a_revoked_phone_is_reported_and_revisionworx_refuses_its_signature(team, capsys, monkeypatch):
    ws, made, rwx, log = team
    assert main(["enrol", str(log), "-w", str(ws), "--account", "riley", "--fingerprint", E.fingerprint(KEY)]) == 0
    rwx("-w", ws, "user", "device", "revoke", "riley", DEV, "--reason", "lost on site")
    capsys.readouterr()
    assert main(["findings", "-w", str(ws)]) == 0
    assert "whose signatures don't count now (revoked: lost on site)" in capsys.readouterr().out
    # The bridge's view is out of date (revoked a moment after it looked): RevisionWorx refuses, and nothing is written.
    real = acc.phones
    monkeypatch.setattr(acc, "phones", lambda src: {d: {**r, "active": True} for d, r in real(src).items()})
    before = len(history(rwx, ws))
    assert main(["accept", made["another"], "-w", str(ws)]) == 2
    err = capsys.readouterr().err
    assert "didn't accept the phone's signature" in err and "was revoked" in err and "--basis reported" in err
    assert len(history(rwx, ws)) == before
    monkeypatch.setattr(acc, "phones", real)
    assert main(["accept", made["another"], "-w", str(ws)]) == 0
    assert ", reported" in capsys.readouterr().out
