# SPDX-License-Identifier: GPL-3.0-or-later
"""Units from RevisionWorx's unit register (RevisionWorx docs/UNITS.md) packed as version 2 catalog assets
(docs/PROTOCOL.md section 6.4), through RevisionWorx's own command line. Skipped where RevisionWorx has no unit register."""
import os
import subprocess

import pytest

from conftest import have_revisionworx
from fieldworx_bridge import archive, catalog as cat_mod, cli
from fieldworx_bridge.packbuilder import asset_id
from fieldworx_bridge.rwx_client import RevisionWorx, find_command

pytestmark = pytest.mark.revisionworx


def have_unit_register() -> bool:
    return have_revisionworx() and "units" in (RevisionWorx().version().get("features") or [])


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
