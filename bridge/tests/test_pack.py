# SPDX-License-Identifier: GPL-3.0-or-later
"""Packages built from a real RevisionWorx workspace (the demo), through RevisionWorx's own command line."""
import hashlib
import json
import zipfile

import pytest

from conftest import have_revisionworx
from fieldworx_bridge import archive, catalog as cat_mod, cli, events as E, sources
from fieldworx_bridge.packbuilder import PackOptions, build_package

pytestmark = pytest.mark.revisionworx


def _pack(demo, tmp_path, *extra):
    out = tmp_path / "p.fieldworx"
    args = ["pack", "-w", str(demo / "workspace"), "--project", "J-2001", "-o", str(out), *extra]
    meridian = demo / "northline.meridian"
    if meridian.exists():
        args += ["--meridian", str(meridian)]
    assert cli.main(args) == 0
    arc = archive.read(out)
    cat_mod.check_catalog(arc.catalog)
    return arc


def _doc(c, number):
    return next(d for d in c["documents"] if d["number"] == number)


def test_documents_revisions_and_renditions(demo, tmp_path):
    with _pack(demo, tmp_path) as arc:
        c = arc.catalog
        frm = _doc(c, "FRM-200")
        assert [(r["label"], r["state"]) for r in frm["revisions"]] == [("A", "superseded"), ("B", "released")]
        assert frm["released"] == frm["revisions"][1]["id"]
        for r in frm["revisions"]:
            # B is released; A is shipped because HPU-0001 was built to it.
            assert r["rendition"]["object"] == r["sha256"]
            assert hashlib.sha256(arc.open_object(r["sha256"]).read()).hexdigest() == r["sha256"]
        tnk = _doc(c, "TNK-100")
        assert tnk["released"] == "" and tnk["revisions"][0]["rendition"] is None
        sch = _doc(c, "SCH-HPU-75")
        assert sch["revisions"][0]["ext"] == ".schematix" and sch["revisions"][0]["rendition"] is None
        assert any("TNK-100 has no released revision" in n for n in arc.manifest["notices"])


def test_unreleased_option(demo, tmp_path):
    with _pack(demo, tmp_path, "--unreleased") as arc:
        tnk = _doc(arc.catalog, "TNK-100")
        assert tnk["revisions"][0]["rendition"] is not None and tnk["released"] == ""


def test_parts_bom_assets_templates(demo, tmp_path):
    with _pack(demo, tmp_path) as arc:
        c = arc.catalog
        parts = {p["number"]: p for p in c["parts"]}
        assert parts["PMP-10"]["manufacturers"] == [{"name": "Hydrix", "mpn": "GP10-R-SAE"}]
        assert parts["FRM-200"]["documents"][0]["role"] == "drawing"
        k1 = [ln for ln in c["bom"] if "K1" in ln["refdes"]]
        assert len(k1) == 1 and k1[0]["child"] == parts["CT-09-24DC"]["id"]
        assert k1[0]["parent"] == parts["PNL-24"]["id"]
        assets = {a["tag"]: a for a in c["assets"]}
        frm = _doc(c, "FRM-200")
        rev_a, rev_b = frm["revisions"][0]["id"], frm["revisions"][1]["id"]
        assert rev_a in assets["HPU-0001"]["as_built"] and rev_b in assets["HPU-0002"]["as_built"]
        assert assets["HPU-0001"]["part"] == parts["HPU-75"]["id"]
        t = c["templates"][0]
        assert (t["template"]["id"], t["template"]["revision"], t["state"]) == ("ITP-HPU-75", "1", "released")
        assert sum(len(s["items"]) for s in t["template"]["sections"]) == 16
        if (demo / "northline.meridian").exists():
            assert parts["HSE-08"]["stock"]["on_hand"] == "10"
            assert parts["HSE-08"]["stock"]["bin"] == "B4"


def test_content_that_does_not_match_its_hash_stops_the_build(demo, tmp_path, monkeypatch):
    from pathlib import Path
    from fieldworx_bridge import rwx_client
    real = rwx_client.RevisionWorx.fetch

    def tampered(self, *a, **k):
        res = real(self, *a, **k)
        p = Path(res["path"])
        p.write_bytes(p.read_bytes() + b"x")
        return res

    monkeypatch.setattr(rwx_client.RevisionWorx, "fetch", tampered)
    out = tmp_path / "p.fieldworx"
    rc = cli.main(["pack", "-w", str(demo / "workspace"), "-o", str(out)])
    assert rc == 2 and not out.exists()


def test_existing_output_is_not_replaced_without_overwrite(demo, tmp_path):
    out = tmp_path / "p.fieldworx"
    out.write_bytes(b"keep me")
    assert cli.main(["pack", "-w", str(demo / "workspace"), "-o", str(out)]) == 2
    assert out.read_bytes() == b"keep me"


def test_field_records_travel_in_packages(demo, tmp_path):
    from test_archive_hub import Phone, an_inspection, write_log
    p = Phone("dev_" + "3d" * 16)
    an_inspection(p, photo=False)
    write_log(tmp_path / "in.fieldlog", p, objects=())
    ws = demo / "workspace"
    hub_dir = tmp_path / "hub"
    assert cli.main(["import", "--hub", str(hub_dir), str(tmp_path / "in.fieldlog")]) == 0
    out = tmp_path / "with-records.fieldworx"
    assert cli.main(["pack", "-w", str(ws), "--hub", str(hub_dir), "-o", str(out)]) == 0
    with archive.read(out) as arc:
        assert [e.id for e in arc.events] == [e.id for e in p.events]
    assert cli.main(["verify", str(out)]) == 0


def test_bridge_reports_and_status(demo, tmp_path, capsys):
    from test_archive_hub import Phone, an_inspection, write_log
    p = Phone("dev_" + "4c" * 16)
    an_inspection(p, photo=False)
    write_log(tmp_path / "in.fieldlog", p, objects=())
    hub_dir = tmp_path / "hub"
    assert cli.main(["import", "--hub", str(hub_dir), str(tmp_path / "in.fieldlog")]) == 0
    assert cli.main(["status", "--hub", str(hub_dir)]) == 0
    assert "completed" in capsys.readouterr().out
    assert cli.main(["report", "--hub", str(hub_dir), "-o", str(tmp_path / "r")]) == 0
    assert (tmp_path / "r" / "inspections.csv").read_text(encoding="utf-8-sig").count("\n") == 2
