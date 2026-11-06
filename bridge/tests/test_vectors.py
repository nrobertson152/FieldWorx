# SPDX-License-Identifier: GPL-3.0-or-later
"""The shared vectors are what the reference implementation computes, and the reference agrees with them."""
import json
import subprocess
import sys

import pytest

from conftest import ROOT, VECTORS
from fieldworx_bridge import events as E
from fieldworx_bridge import fxjson, inspections


def load(name):
    return json.loads((VECTORS / name).read_text(encoding="utf-8"))


def test_vectors_are_up_to_date():
    proc = subprocess.run([sys.executable, str(ROOT / "spec" / "make_vectors.py"), "--check"], capture_output=True,
                          text=True)
    assert proc.returncode == 0, proc.stdout + proc.stderr


@pytest.mark.parametrize("case", load("fxjson.json"), ids=lambda c: c["name"])
def test_fxjson(case):
    if case["canonical"] is None:
        with pytest.raises(fxjson.FxJsonError):
            fxjson.encode(fxjson.parse(case["input"]))
        return
    value = fxjson.parse(case["input"])
    assert fxjson.encode(value).decode("utf-8") == case["canonical"]
    assert fxjson.parse_canonical(case["canonical"].encode("utf-8")) == value
    if case["input"] != case["canonical"]:
        with pytest.raises(fxjson.FxJsonError):
            fxjson.parse_canonical(case["input"].encode("utf-8"))


def test_digests():
    d = load("digests.json")
    for c in d["domain_digests"]:
        assert fxjson.digest_bytes(c["domain"], c["canonical"].encode("utf-8")) == c["digest"]
    for c in d["sha256"]:
        assert fxjson.sha256_hex(bytes.fromhex(c["hex"])) == c["sha256"]


def test_envelopes():
    d = load("envelopes.json")
    for g in d["good"]:
        assert E.from_bytes(g["event"].encode("utf-8")).id == g["id"]
    for b in d["bad"]:
        with pytest.raises(E.EventError):
            E.from_bytes(b["event"].encode("utf-8"))
    for n in d["not_canonical"]:
        with pytest.raises(E.EventError):
            E.from_bytes(n.encode("utf-8"))


@pytest.mark.parametrize("case", load("fieldlog.json"), ids=lambda c: c["name"])
def test_fieldlog(case):
    log = E.FieldLog()
    for step in case["steps"]:
        batch = [E.from_bytes(r.encode("utf-8")) for r in step["events"]]
        if step["result"] == "ok":
            assert [e.id for e in log.import_events(batch)] == step["new"]
        else:
            exc = {"fork": E.ForkError, "missing": E.MissingHistory, "invalid": E.EventError}[step["result"]]
            before = dict(log.events)
            with pytest.raises(exc):
                log.import_events(batch)
            assert log.events == before
    assert log.heads() == case["heads"]
    assert {e: log.entity_heads(e) for e in sorted(log.by_entity)} == case["entity_heads"]


@pytest.mark.parametrize("case", load("inspections.json"), ids=lambda c: c["name"])
def test_inspections(case):
    log = E.FieldLog()
    log.import_events([E.from_bytes(r.encode("utf-8")) for r in case["events"]])
    assert fxjson.encode(inspections.reduce(log, case["entity"])) == fxjson.encode(case["state"])


def test_templates():
    d = load("templates.json")
    for t in d["good"]:
        inspections.check_template(t)
    for b in d["bad"]:
        with pytest.raises(inspections.TemplateError):
            inspections.check_template(b["template"])


def test_decimals():
    from decimal import Decimal
    for c in load("decimals.json"):
        a, b = Decimal(c["a"]), Decimal(c["b"])
        assert (a > b) - (a < b) == c["cmp"]
