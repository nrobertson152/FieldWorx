# SPDX-License-Identifier: GPL-3.0-or-later
"""Units from RevisionWorx's unit register (RevisionWorx docs/UNITS.md) packed as version 2 catalog assets
(docs/PROTOCOL.md section 6.4), through RevisionWorx's own command line. Skipped where RevisionWorx has no unit register."""
import os
import re
import subprocess

import pytest

from conftest import have_revisionworx
from fieldworx_bridge import archive, catalog as cat_mod, cli
from fieldworx_bridge.packbuilder import asset_id
from fieldworx_bridge.rwx_client import RevisionWorx, find_command

pytestmark = pytest.mark.revisionworx


def have_unit_register(feature: str = "units") -> bool:
    return have_revisionworx() and feature in (RevisionWorx().version().get("features") or [])


@pytest.fixture(scope="module")
def plant(tmp_path_factory):
    """The demo workspace, with its asset register imported into RevisionWorx's unit register, a build standard for
    rev B frames, a third unit built to it, and a serial-tracked pump fitted in HPU-0001."""
    if not have_unit_register():
        pytest.skip("this RevisionWorx has no unit register (link version doesn't list 'units')")
    import build_demo
    out = tmp_path_factory.mktemp("units") / "demo"
    assert build_demo.main([str(out)]) == 0
    ws = out / "workspace"
    local = out / ".local"
    env = dict(os.environ, XDG_CACHE_HOME=str(local / "cache"), XDG_STATE_HOME=str(local / "state"),
               XDG_CONFIG_HOME=str(local / "config"), LOCALAPPDATA=str(local / "appdata"))

    def unit(*args):
        proc = subprocess.run(find_command() + ["-w", str(ws), "unit", *args], capture_output=True, text=True, env=env)
        assert proc.returncode == 0, proc.stderr
        return proc.stdout

    unit("import", str(out / "source" / "AST-HPU-75 Units built.fwassets.csv"))
    unit("standard", "new", "HPU-75-B", "--title", "HPU-75 with the rev B frame", "--doc", "FRM-200@B",
         "--doc", "HPU-75-GA@A")
    unit("new", "--serial", "NH-26-0003", "--model", "HPU-75", "--project", "J-2001", "--standard", "HPU-75-B",
         "--status", "built", "--built", "2026-09-01", "--name", "Hydraulic power unit")
    unit("new", "--serial", "GP-4471", "--issuer", "Hydrix", "--class", "component", "--model", "PMP-10")
    unit("fit", "HPU-0001", "P1", "--component", "GP-4471", "--effective", "2026-03-18")
    unit("note", "HPU-0001", "Pump serial recorded during service")
    return out


def _pack(plant, tmp_path, *extra):
    out = tmp_path / "units.fieldworx"
    assert cli.main(["pack", "-w", str(plant / "workspace"), "--project", "J-2001", "-o", str(out), *extra]) == 0
    arc = archive.read(out)
    cat_mod.check_catalog(arc.catalog)
    return arc


def test_units_become_version_2_assets_with_their_own_revisions(plant, tmp_path):
    with _pack(plant, tmp_path) as arc:
        c = arc.catalog
        assets = {a["label"]: a for a in c["assets"]}
        assert set(assets) == {"NH-26-0001", "NH-26-0002", "NH-26-0003", "GP-4471"}
        u1 = assets["NH-26-0001"]
        assert u1["id"].startswith("unt_") and u1["source"] == "revisionworx" and u1["status"] == "in-service"
        # The asset register id stays, so inspections recorded against the register row still find the unit.
        assert u1["aliases"] == [asset_id(arc.manifest["source"]["workspace"], "HPU-0001")]
        assert {(i["scheme"], i["value"]) for i in u1["identifiers"]} == {("tag", "HPU-0001"), ("serial", "NH-26-0001")}
        frm = next(d for d in c["documents"] if d["number"] == "FRM-200")
        rev_a = frm["revisions"][0]
        row = next(d for d in u1["documents"] if d["document"] == frm["id"])
        assert (row["revision"], row["source"], row["basis"]) == (rev_a["id"], "unit", "legacy")
        assert rev_a["rendition"] is not None, "the superseded revision a unit uses travels with the package"
        u3 = assets["NH-26-0003"]
        assert u3["standard"] == {"number": "HPU-75-B", "title": "HPU-75 with the rev B frame"}
        assert {d["source"] for d in u3["documents"]} == {"standard"}
        assert u3["milestones"] == {"built": "2026-09-01"} and u3["part"] == u1["part"] != ""
        # The register rows are left out: RevisionWorx's register is the record for those machines.
        assert any("is in RevisionWorx's unit register" in n for n in arc.manifest["notices"])


def test_a_fitted_component_comes_along_with_its_place(plant, tmp_path):
    with _pack(plant, tmp_path) as arc:
        assets = {a["label"]: a for a in arc.catalog["assets"]}
        hpu, pump = assets["NH-26-0001"], assets["GP-4471"]
        assert pump["class"] == "component" and pump["project"] == ""
        assert pump["parent"] == {"asset": hpu["id"], "position": "P1"}
        assert [(x["position"], x["asset"], x["number"]) for x in hpu["components"]] == [("P1", pump["id"], "PMP-10")]
        assert [h["type"] for h in hpu["history"]][-2:] == ["component.installed", "note"]
        assert hpu["history"][-1]["summary"] == "Pump serial recorded during service"
        assert all(not h["voided"] for h in hpu["history"])


def test_without_a_project_choice_every_unit_is_packed(plant, tmp_path):
    out = tmp_path / "all.fieldworx"
    assert cli.main(["pack", "-w", str(plant / "workspace"), "-o", str(out)]) == 0
    with archive.read(out) as arc:
        assert len(arc.catalog["assets"]) == 4


def test_version_1_assets_read_as_version_2():
    """An old package keeps working: its assets are read in the version 2 shape (docs/PROTOCOL.md section 6.4)."""
    import json
    from pathlib import Path
    vectors = json.loads((Path(__file__).resolve().parents[2] / "spec" / "vectors" / "catalogs.json").read_text("utf-8"))
    for case in vectors["accept"]:
        cat_mod.check_catalog(case["catalog"])
        assert cat_mod.assets_view(case["catalog"]) == case["assets"], case["name"]
    for case in vectors["refuse"]:
        with pytest.raises(cat_mod.CatalogError):
            cat_mod.check_catalog(case["catalog"])


@pytest.fixture(scope="module")
def changed(tmp_path_factory):
    """A fresh demo whose asset register is in the unit register, then ECO-0001 revising HPU-75-GA to rev B, decided as a
    required retrofit of every unit that has rev A, and installed on HPU-0001 (reported, not yet verified). All through
    RevisionWorx's own command line."""
    if not have_unit_register("unit-changes"):
        pytest.skip("this RevisionWorx doesn't say which units a change reaches (link version doesn't list 'unit-changes')")
    import build_demo
    out = tmp_path_factory.mktemp("changes") / "demo"
    assert build_demo.main([str(out)]) == 0
    ws = out / "workspace"
    local = out / ".local"
    env = dict(os.environ, XDG_CACHE_HOME=str(local / "cache"), XDG_STATE_HOME=str(local / "state"),
               XDG_CONFIG_HOME=str(local / "config"), LOCALAPPDATA=str(local / "appdata"))

    def rwx(*args):
        proc = subprocess.run(find_command() + ["-w", str(ws), *args], capture_output=True, text=True, env=env)
        assert proc.returncode in (0, 1), proc.stderr
        return proc.stdout

    rwx("unit", "import", str(out / "source" / "AST-HPU-75 Units built.fwassets.csv"))
    rwx("change", "new-request", "Stronger base", "--reason", "cracks at the base", "--doc", "HPU-75-GA")
    for step in ("submit", "review", "approve"):
        rwx("change", step, "ECR-0001")
    rwx("change", "new-order", "ECR-0001")
    rwx("change", "start", "ECO-0001")
    item = re.search(r"item (document:(doc_[0-9a-f]{32}))", rwx("change", "show", "ECO-0001"))
    path = re.search(r"file: (.+)", rwx("doc", "show", item.group(2))).group(1).strip()
    rwx("doc", "checkout", item.group(2))
    with open(path, "ab") as f:
        f.write(b"\n% rev B: stronger base\n")
    rwx("doc", "checkin", item.group(2), "-m", "stronger base")
    rwx("change", "implement", "ECO-0001", item.group(1), "--rev", "B")
    rwx("change", "implemented", "ECO-0001")
    rwx("unit", "change", "decide", "ECO-0001", "--kind", "retrofit-required", "--reason", "cracks at the base")
    rwx("unit", "change", "install", "HPU-0001", "ECO-0001")
    return out


def test_the_changes_that_reach_a_unit_travel_with_it(changed, tmp_path):
    out = tmp_path / "changes.fieldworx"
    assert cli.main(["pack", "-w", str(changed / "workspace"), "--project", "J-2001", "-o", str(out)]) == 0
    with archive.read(out) as arc:
        cat_mod.check_catalog(arc.catalog)
        assets = {a["label"]: a for a in arc.catalog["assets"]}
        done, waiting = assets["NH-26-0001"]["changes"], assets["NH-26-0002"]["changes"]
        assert [(c["number"], c["kind"], c["required"], c["state"]) for c in done] == [
            ("ECO-0001", "retrofit-required", True, "installed")]
        assert done[0]["documents"] == [{"number": "HPU-75-GA", "from": "A", "to": "B"}]
        assert done[0]["title"] == "Stronger base" and done[0]["change"].startswith("eco_")
        assert [c["state"] for c in waiting] == ["pending"]
        # The installation moved the unit's own drawing, flagged reported until engineering verifies it.
        ga = next(d for d in arc.catalog["documents"] if d["number"] == "HPU-75-GA")
        row = next(d for d in assets["NH-26-0001"]["documents"] if d["document"] == ga["id"])
        assert row["revision"] == ga["revisions"][-1]["id"] and row["basis"] == "reported"


@pytest.fixture(scope="module")
def deviated(tmp_path_factory):
    """A fresh demo whose asset register is in the unit register, then a temporary deviation on both units (a substitute
    pump, past its end date) and a permanent concession on HPU-0002, the first cleared on HPU-0001. All through
    RevisionWorx's own command line."""
    if not have_unit_register("unit-deviations"):
        pytest.skip("this RevisionWorx doesn't record deviations (link version doesn't list 'unit-deviations')")
    import build_demo
    out = tmp_path_factory.mktemp("deviations") / "demo"
    assert build_demo.main([str(out)]) == 0
    ws = out / "workspace"
    local = out / ".local"
    env = dict(os.environ, XDG_CACHE_HOME=str(local / "cache"), XDG_STATE_HOME=str(local / "state"),
               XDG_CONFIG_HOME=str(local / "config"), LOCALAPPDATA=str(local / "appdata"))

    def rwx(*args):
        proc = subprocess.run(find_command() + ["-w", str(ws), *args], capture_output=True, text=True, env=env)
        assert proc.returncode in (0, 1), proc.stderr
        return proc.stdout

    rwx("unit", "import", str(out / "source" / "AST-HPU-75 Units built.fwassets.csv"))
    rwx("unit", "deviation", "new", "--kind", "deviation", "--title", "PMP-11 for PMP-10 at P1",
        "--departure", "P1 is a PMP-11 pump, not the PMP-10 the BOM calls for", "--reason", "PMP-10 out of stock",
        "--unit", "HPU-0001", "--unit", "HPU-0002", "--doc", "HPU-75-GA@A", "--temporary", "--until", "2026-01-31")
    rwx("unit", "deviation", "new", "--kind", "concession", "--title", "Weld undercut W4",
        "--departure", "W4 undercut 0.6 mm (0.5 allowed)", "--reason", "load test passed", "--unit", "HPU-0002")
    rwx("unit", "deviation", "clear", "HPU-0001", "DEV-0001", "--reason", "PMP-10 fitted")
    return out


def test_the_deviations_that_cover_a_unit_travel_with_it(deviated, tmp_path):
    out = tmp_path / "deviations.fieldworx"
    assert cli.main(["pack", "-w", str(deviated / "workspace"), "--project", "J-2001", "-o", str(out)]) == 0
    with archive.read(out) as arc:
        cat_mod.check_catalog(arc.catalog)
        assets = {a["label"]: a for a in arc.catalog["assets"]}
        first, second = assets["NH-26-0001"]["deviations"], assets["NH-26-0002"]["deviations"]
        assert [(d["number"], d["kind"], d["state"], d["temporary"], d["until"]) for d in first] == [
            ("DEV-0001", "deviation", "cleared", True, "2026-01-31")]
        assert first[0]["documents"] == [{"number": "HPU-75-GA", "revision": "A"}]
        assert first[0]["departure"] == "P1 is a PMP-11 pump, not the PMP-10 the BOM calls for"
        assert first[0]["deviation"].startswith("udv_") and not cat_mod.deviation_overdue(first[0], "2026-11-07")
        # in effect first, the one past its end date before the permanent one
        assert [(d["number"], d["state"], d["temporary"]) for d in second] == [
            ("DEV-0001", "in-effect", True), ("CON-0001", "in-effect", False)]
        assert cat_mod.deviation_overdue(second[0], "2026-11-07") and not cat_mod.deviation_overdue(second[1], "2099-01-01")
        assert second[1]["until"] == "" and second[1]["documents"] == []


@pytest.fixture(scope="module")
def merged(tmp_path_factory):
    """The demo's asset register imported into the unit register; then a work order registers NH-26-0002 again, as
    NH-26-0009. The office retires the serial issued by mistake, and RevisionWorx merges the two records (its docs/UNITS.md
    section 15)."""
    if not have_unit_register("unit-merges"):
        pytest.skip("this RevisionWorx doesn't merge units (link version doesn't list 'unit-merges')")
    import build_demo
    out = tmp_path_factory.mktemp("merged") / "demo"
    assert build_demo.main([str(out)]) == 0
    ws = out / "workspace"
    local = out / ".local"
    env = dict(os.environ, XDG_CACHE_HOME=str(local / "cache"), XDG_STATE_HOME=str(local / "state"),
               XDG_CONFIG_HOME=str(local / "config"), LOCALAPPDATA=str(local / "appdata"))

    def rwx(*args):
        proc = subprocess.run(find_command() + ["-w", str(ws), *args], capture_output=True, text=True, env=env)
        assert proc.returncode == 0, proc.stderr
        return proc.stdout

    rwx("unit", "import", str(out / "source" / "AST-HPU-75 Units built.fwassets.csv"))
    rwx("unit", "new", "--serial", "NH-26-0009", "--model", "HPU-75", "--project", "J-2001", "--status", "in-service",
        "--name", "Hydraulic power unit")
    import json
    dup = json.loads(rwx("link", "unit", "NH-26-0009"))["unit"]["id"]
    rwx("unit", "id", "retire", "NH-26-0009", "serial", "NH-26-0009", "--reason", "issued by mistake: this is NH-26-0002")
    rwx("unit", "merge", "NH-26-0009", "--into", "HPU-0002", "--reason", "the same machine: NH-26-0002 is on its frame")
    return {"out": out, "dup": dup, "rwx": rwx}


def test_a_merged_unit_is_an_alias_of_the_one_that_stays_never_an_asset(merged, tmp_path):
    with _pack(merged["out"], tmp_path) as arc:
        assets = {a["label"]: a for a in arc.catalog["assets"]}
        assert merged["dup"] not in {a["id"] for a in arc.catalog["assets"]}
        stays = assets["NH-26-0002"]
        register_id = asset_id(arc.manifest["source"]["workspace"], "HPU-0002")
        assert stays["aliases"] == sorted([register_id, merged["dup"]])
        assert ("serial", "NH-26-0009", False) in {(i["scheme"], i["value"], i["active"]) for i in stays["identifiers"]}
    import json
    answer = json.loads(merged["rwx"]("link", "unit", merged["dup"]))      # a label printed with the earlier id
    assert answer["unit"]["id"] == stays["id"] and answer["named"]["unit"] == merged["dup"]
    from fieldworx_bridge.findings import is_about
    assert is_about({"asset": merged["dup"]}, answer["unit"]) and is_about({"asset": register_id}, answer["unit"])
