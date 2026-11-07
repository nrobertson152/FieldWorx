# SPDX-License-Identifier: GPL-3.0-or-later
"""A native drawing's phone view is the PDF engineering attached to exactly that revision in RevisionWorx (its ADR-026,
docs/PROTOCOL.md section 6.1), through RevisionWorx's own command line. Skipped where RevisionWorx can't attach PDFs."""
import json
import os
import subprocess

import pytest

from conftest import have_revisionworx
from fieldworx_bridge import archive, catalog as cat_mod, cli
from fieldworx_bridge.sources import sha256_file
from fieldworx_bridge.rwx_client import RevisionWorx, find_command

pytestmark = pytest.mark.revisionworx

PDF = b"%PDF-1.7\n1 0 obj << >> endobj\ntrailer << >>\n%%EOF\n% bracket rev A\n"


@pytest.fixture(scope="module")
def native(tmp_path_factory):
    """The demo, plus BRK-10, an Inventor drawing: rev A released with its PDF attached, rev B checked in without one."""
    if not (have_revisionworx() and "pdf-derivatives" in (RevisionWorx().version().get("features") or [])):
        pytest.skip("this RevisionWorx can't attach PDFs to revisions (link version doesn't list 'pdf-derivatives')")
    import build_demo
    out = tmp_path_factory.mktemp("pdfs") / "demo"
    assert build_demo.main([str(out)]) == 0
    ws = out / "workspace"
    local = out / ".local"
    env = dict(os.environ, XDG_CACHE_HOME=str(local / "cache"), XDG_STATE_HOME=str(local / "state"),
               XDG_CONFIG_HOME=str(local / "config"), LOCALAPPDATA=str(local / "appdata"))

    def rwx(*args):
        proc = subprocess.run(find_command() + ["-w", str(ws), *args], capture_output=True, text=True, env=env)
        assert proc.returncode == 0, proc.stderr
        return proc.stdout

    project = next(p for p in json.loads(rwx("link", "projects"))["projects"] if p["number"] == "J-2001")
    folder = next(ws.glob("Projects/*/J-2001*"))
    drawing = folder / "BRK-10 Bracket.idw"
    drawing.write_bytes(b"IDW rev A")
    rwx("doc", "register", project["id"], str(drawing), "--number", "BRK-10", "--title", "Bracket")
    doc = json.loads(rwx("link", "document", "BRK-10"))["document"]
    for state in ("in_review", "approved", "released"):
        rwx("rev", "transition", doc["history"][0]["id"], state)
    export = out / "BRK-10 rev A.pdf"
    export.write_bytes(PDF)
    rwx("doc", "pdf", "BRK-10@A", str(export), "--tool", "Inventor 2025 export")
    rwx("doc", "checkout", doc["id"])
    drawing.write_bytes(b"IDW rev B")
    rwx("doc", "checkin", doc["id"], "-m", "thicker")
    return out, export


def _pack(demo, tmp_path, *extra):
    out = tmp_path / "pdfs.fieldworx"
    assert cli.main(["pack", "-w", str(demo / "workspace"), "--project", "J-2001", "-o", str(out), *extra]) == 0
    arc = archive.read(out)
    cat_mod.check_catalog(arc.catalog)
    return arc


def test_an_attached_pdf_is_the_phone_view_of_its_revision(native, tmp_path):
    demo, export = native
    with _pack(demo, tmp_path) as arc:                               # the released revision, A
        brk = next(d for d in arc.catalog["documents"] if d["number"] == "BRK-10")
        rev_a = brk["revisions"][0]
        assert rev_a["rendition"]["via"] == "pdf attached in RevisionWorx (Inventor 2025 export)"
        assert rev_a["rendition"]["object"] == sha256_file(export) and rev_a["rendition"]["object"] in arc.objects


def test_a_revision_without_its_own_pdf_never_borrows_another(native, tmp_path):
    demo, export = native
    with _pack(demo, tmp_path, "--unreleased") as arc:               # the latest revision, B, which has no PDF
        brk = next(d for d in arc.catalog["documents"] if d["number"] == "BRK-10")
        assert brk["revisions"][1]["label"] == "B" and brk["revisions"][1]["rendition"] is None
        assert sha256_file(export) not in arc.objects
