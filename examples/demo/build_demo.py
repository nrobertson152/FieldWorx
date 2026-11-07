# SPDX-License-Identifier: GPL-3.0-or-later
"""Build the FieldWorx demo from scratch: a RevisionWorx workspace for Northline Hydraulics' HPU-75 (the hydraulic
power unit OpenMeridian's sample company builds), an OpenMeridian company file if OpenMeridian is installed, and the
FieldWorx package made from them.

    python examples/demo/build_demo.py OUT_DIR [--history] [--package OUT.fieldworx]

Needs RevisionWorx (``revisionworx`` on PATH, REVISIONWORX_CLI, or the package importable). Everything it writes is
inside OUT_DIR, including RevisionWorx's own cache and state folders, so nothing touches your real workspaces.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import os
import struct
import subprocess
import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent.parent / "bridge"))

import drawings  # noqa: E402
from fieldworx_bridge.rwx_client import RevisionWorx, find_command  # noqa: E402

DEMO_USER = "dwhitfield"

TEMPLATE_CSV = """section,id,kind,prompt,unit,nominal,min,max,required,photo,choices,help
Identification,1.1,text,Serial number on the nameplate,,,,,yes,required,,Photograph the nameplate.
Identification,1.2,choice,FRM-200 frame revision fitted,,,,,yes,none,A;B,Revision stamp on the frame's rear rail.
Mechanical,2.1,check,Guards fitted and secured,,,,,yes,none,,
Mechanical,2.2,check,Frame bolts torqued to 49 Nm (M10 8.8) and marked,,,,,yes,none,,
Mechanical,2.3,measure,Pump/motor coupling alignment: parallel offset,mm,0,-0.05,0.05,yes,none,,Dial indicator on the coupling hub.
Mechanical,2.4,check,"No damage to paint, hoses or fittings",,,,,yes,optional,,
Hydraulic,3.1,measure,Relief valve V2 setting,bar,160,155,165,yes,none,,Read the gauge with the valve dead-headed.
Hydraulic,3.2,check,No leaks after 10 minutes at full pressure,,,,,yes,optional,,
Hydraulic,3.3,text,Oil cleanliness (ISO 4406 code),,,,,no,none,,For example 18/16/13.
Hydraulic,3.4,measure,Oil level in the sight glass,%,,50,100,yes,none,,
Electrical,4.1,check,Motor M1 rotation matches the arrow,,,,,yes,none,,
Electrical,4.2,measure,Motor insulation resistance at 500 V,MΩ,,100,,yes,none,,Each phase to earth; record the lowest.
Electrical,4.3,check,Stop button S1 stops the motor,,,,,yes,none,,
Electrical,4.4,check,Indicator lamps H1 and H2 work,,,,,yes,none,,
Completion,5.1,check,Operating and maintenance manual supplied,,,,,no,none,,
Completion,5.2,text,Remarks,,,,,no,optional,,
"""

BOM_CSV = """parent_number,find_number,child_number,child_revision,quantity,unit,reference_designators,description,part_unit,note
,,HPU-75,A,,,,Hydraulic power unit 7.5 kW,EA,
,,FRM-200,B,,,,Skid frame welded,EA,
,,TNK-100,B,,,,Reservoir 100 L,EA,
,,PMP-10,,,,,Gear pump 10 cc/rev,EA,
,,MTR-7K5,,,,,Electric motor 7.5 kW IE3,EA,
,,MAN-02,A,,,,Valve manifold assembly,EA,
,,VLV-RV160,,,,,Relief valve 160 bar,EA,
,,VLV-D03,,,,,Directional valve 4/3 D03 24 V DC,EA,
,,HSE-08,,,,,Hose kit -08,EA,
,,PNL-24,A,,,,Control panel 24 V DC,EA,
,,CT-09-24DC,,,,,Contactor 9 A 24 V DC coil,EA,
,,MCB-C6,,,,,Miniature circuit breaker C6,EA,
,,FU-2A,,,,,Fuse 2 A,EA,
,,IL-24G,,,,,Indicator lamp green 24 V,EA,
,,IL-24W,,,,,Indicator lamp white 24 V,EA,
,,PB-NC-R,,,,,Pushbutton red NC,EA,
,,PB-NO-G,,,,,Pushbutton green NO,EA,
HPU-75,10,FRM-200,B,1,EA,,,,
HPU-75,20,TNK-100,B,1,EA,,,,
HPU-75,30,PMP-10,,1,EA,P1,,,
HPU-75,40,MTR-7K5,,1,EA,M1,,,
HPU-75,50,MAN-02,A,1,EA,,,,
HPU-75,60,HSE-08,,2,EA,,,,
HPU-75,70,PNL-24,A,1,EA,,,,
MAN-02,10,VLV-RV160,,1,EA,V2,,,set to 160 bar
MAN-02,20,VLV-D03,,1,EA,V1,,,
PNL-24,10,CT-09-24DC,,1,EA,K1,,,
PNL-24,20,MCB-C6,,1,EA,Q1,,,
PNL-24,30,FU-2A,,1,EA,F1,,,
PNL-24,40,IL-24G,,1,EA,H1,,,
PNL-24,50,IL-24W,,1,EA,H2,,,
PNL-24,60,PB-NC-R,,1,EA,S1,,,
PNL-24,70,PB-NO-G,,1,EA,S2,,,
"""

# number, description, unit, kind, revision, manufacturer, mpn, vendor, sku, (document number, role), material
PARTS = [
    ("HPU-75", "Hydraulic power unit 7.5 kW", "EA", "assembly", "A", "", "", "", "", ("HPU-75-GA", "drawing"), ""),
    ("FRM-200", "Skid frame, welded", "EA", "assembly", "B", "", "", "Ironbridge Steel", "IB-FRM-200",
     ("FRM-200", "drawing"), "S355"),
    ("TNK-100", "Reservoir 100 L", "EA", "part", "B", "", "", "Ironbridge Steel", "IB-TNK-100", None, "Steel"),
    ("PMP-10", "Gear pump 10 cc/rev", "EA", "part", "", "Hydrix", "GP10-R-SAE", "Delta Motion Supply", "DMS-44120",
     None, ""),
    ("MTR-7K5", "Electric motor 7.5 kW IE3, 4 pole", "EA", "part", "", "Voltara", "V132M4-7.5", "Delta Motion Supply",
     "DMS-88231", None, ""),
    ("MAN-02", "Valve manifold assembly", "EA", "assembly", "A", "", "", "", "", ("SCH-HPU-75-PDF", "schematic"), ""),
    ("VLV-RV160", "Relief valve 160 bar", "EA", "part", "", "Fluxline", "RV-08-160", "Delta Motion Supply", "DMS-30160",
     None, ""),
    ("VLV-D03", "Directional valve 4/3 D03 24 V DC", "EA", "part", "", "Fluxline", "D03-43C-24DC",
     "Delta Motion Supply", "DMS-30403", None, ""),
    ("HSE-08", "Hose kit -08", "EA", "part", "", "", "", "Delta Motion Supply", "DMS-HK08", None, ""),
    ("PNL-24", "Control panel 24 V DC", "EA", "assembly", "A", "", "", "", "", ("SCH-HPU-75-PDF", "schematic"), ""),
    ("CT-09-24DC", "Contactor 9 A, 24 V DC coil", "EA", "part", "", "Kestrel Electric", "KC-09-24DC", "", "", None, ""),
    ("MCB-C6", "Miniature circuit breaker C6", "EA", "part", "", "Kestrel Electric", "KB-1P-C6", "", "", None, ""),
    ("FU-2A", "Fuse 2 A", "EA", "part", "", "Kestrel Electric", "KF-5x20-2A", "", "", None, ""),
    ("IL-24G", "Indicator lamp green 24 V", "EA", "part", "", "Kestrel Electric", "KL-22-24G", "", "", None, ""),
    ("IL-24W", "Indicator lamp white 24 V", "EA", "part", "", "Kestrel Electric", "KL-22-24W", "", "", None, ""),
    ("PB-NC-R", "Pushbutton red, NC", "EA", "part", "", "Kestrel Electric", "KP-22-R-NC", "", "", None, ""),
    ("PB-NO-G", "Pushbutton green, NO", "EA", "part", "", "Kestrel Electric", "KP-22-G-NO", "", "", None, ""),
]

ASSETS_CSV = """tag,serial,name,part,project,location,built,as_built,notes
HPU-0001,NH-26-0001,HPU-75 for Acme Manufacturing,HPU-75,J-2001,"Acme Manufacturing, Milltown press shop",2026-03-18,HPU-75-GA@A;FRM-200@A;SCH-HPU-75-PDF@A,First unit. Frame to revision A (no lifting lugs).
HPU-0002,NH-26-0002,HPU-75 for Bayside Marine,HPU-75,J-2001,"Bayside Marine, Port Ellis yard",2026-07-09,HPU-75-GA@A;FRM-200@B;SCH-HPU-75-PDF@A,Frame to revision B with lifting lugs.
"""


def run(cmd: list[str], env: dict) -> str:
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        raise SystemExit(f"failed: {' '.join(cmd)}\n{proc.stdout}\n{proc.stderr}")
    return proc.stdout


def csv_cell(v: str) -> str:
    return "'" + v if v[:1] in ("=", "+", "-", "@", "\t", "\r") else v


def parts_csv(doc_ids: dict[str, tuple[str, str]]) -> str:
    out = io.StringIO(newline="")
    w = csv.writer(out, lineterminator="\r\n")
    w.writerow(["part_id", "number", "description", "unit", "kind", "status", "revision", "manual_number",
                "manufacturer_1", "mpn_1", "vendor_1", "sku_1", "document_id_1", "revision_id_1", "role_1",
                "attr:Material"])
    for (num, desc, unit, kind, rev, mfr, mpn, ven, sku, doc, mat) in PARTS:
        did, rid, role = "", "", ""
        if doc:
            did, rid = doc_ids[doc[0]]
            role = doc[1]
        w.writerow([csv_cell(x) for x in ("", num, desc, unit, kind, "active", rev, "no", mfr, mpn, ven, sku, did, rid,
                                          role, mat)])
    return "﻿" + out.getvalue()


def nameplate_png() -> bytes:
    """A small stand-in for a photo of a unit's nameplate (stdlib only: a brushed plate, rivets and lines of 'text')."""
    w, h = 240, 150
    rows = []
    for y in range(h):
        row = bytearray([0])
        for x in range(w):
            v = 200 + (x * 7 + y * 3) % 23 - 11  # brushed metal
            edge = min(x, y, w - 1 - x, h - 1 - y)
            if edge < 4:
                v = 120
            for cx, cy in ((12, 12), (w - 13, 12), (12, h - 13), (w - 13, h - 13)):
                if (x - cx) ** 2 + (y - cy) ** 2 <= 16:
                    v = 90
            for ty, length in ((30, 150), (52, 190), (74, 120), (96, 170), (118, 90)):
                if ty <= y < ty + 9 and 28 <= x < 28 + length and (x // 6) % 4 != 3:
                    v = 40
            row += bytes((v, v, max(v - 6, 0)))
        rows.append(bytes(row))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b""))


def record_history(ws: Path, workspace_id: str) -> None:
    """The final acceptance tests of both units, as the workshop tablet recorded them, imported into the workspace's
    hub (.fieldworx) the way the bridge would import a field log. Packages built from the workspace then carry them."""
    from fieldworx_bridge import archive, events as ev, inspections
    from fieldworx_bridge.hub import Hub
    from fieldworx_bridge.packbuilder import asset_id
    template = inspections.template_from_csv(TEMPLATE_CSV, "ITP-HPU-75", "HPU-75 final inspection and test plan", "1")
    device = "dev_" + "5e" * 16
    photo = nameplate_png()
    photo_sha = hashlib.sha256(photo).hexdigest()
    log: list = []

    def rec(actor: str, type_: str, entity: str, body: dict, time: str) -> None:
        prev = log[-1].id if log else ""
        deps = [log[-1].id] if log and log[-1].data["entity"] == entity else []
        log.append(ev.make(device, len(log) + 1, prev, actor, type_, entity, deps, body, time))

    measured = {"2.3": "0.02", "3.1": "161", "3.4": "80", "4.2": "550"}
    units = (("HPU-0001", "NH-26-0001", "A", "2026-03-18", "Jo Lee", "17/15/12"),
             ("HPU-0002", "NH-26-0002", "B", "2026-07-09", "Sam Ortiz", ""))
    for n, (tag, serial, frame, day, who, oil) in enumerate(units, start=1):
        entity = "ins_" + f"{n:02d}" * 16
        rec(who, "inspection.start", entity, {"template": template, "title": f"{tag} final acceptance test",
            "subject": {"kind": "asset", "id": asset_id(workspace_id, tag), "label": tag}, "package": ""},
            f"{day}T13:00:00.000Z")
        for minute, item in enumerate(inspections.items(template), start=1):
            if item["kind"] == "check":
                value = {"result": "pass"}
            elif item["kind"] == "measure":
                value = {"measured": measured[item["id"]]}
            elif item["kind"] == "choice":
                value = {"choice": frame}
            else:
                value = {"text": {"1.1": serial, "3.3": oil}.get(item["id"], "")}
                if not value["text"]:
                    continue
            rec(who, "inspection.answer", entity, {"item": item["id"], "value": value, "note": ""},
                f"{day}T13:{2 * minute:02d}:00.000Z")
        rec(who, "inspection.attach", entity, {"object": photo_sha, "size": len(photo), "media_type": "image/png",
            "item": "1.1", "caption": "Nameplate"}, f"{day}T13:40:00.000Z")
        rec(who, "inspection.complete", entity, {"result": "pass", "summary": "Accepted."}, f"{day}T13:45:00.000Z")
    fieldlog = ws.parent / "workshop-tablet.fieldlog"
    archive.write(fieldlog, "fieldlog", archive_id="flg_" + "5e" * 16, title="Workshop tablet",
                  created="2026-07-09T14:00:00.000Z", created_by={"device": device, "user": "Workshop tablet"},
                  events=log, objects=[archive.ObjectSource.from_bytes(photo, "image/png")])
    with archive.read(fieldlog) as arc:
        report = Hub.open(Hub.location_for(ws), create=True).import_archive(arc)
    fieldlog.unlink()
    if report.missing_objects:
        raise SystemExit(f"history: objects missing from the hub: {report.missing_objects}")


def main(argv=None) -> int:
    saved = dict(os.environ)
    try:
        return _main(argv)
    finally:  # build_demo also runs inside the bridge's tests: leave the environment as it was
        os.environ.clear()
        os.environ.update(saved)


def _main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("out", type=Path)
    ap.add_argument("--package", type=Path, help="also build the demo package here")
    ap.add_argument("--history", action="store_true",
                    help="record the units' final acceptance tests in the workspace's hub (.fieldworx)")
    a = ap.parse_args(argv)
    out = a.out.resolve()
    if out.exists() and any(out.iterdir()):
        raise SystemExit(f"{out} is not empty")
    out.mkdir(parents=True, exist_ok=True)
    local = out / ".local"
    # RevisionWorx records the login name as each revision's author; the demo's engineer is "dwhitfield".
    env = dict(os.environ, XDG_CACHE_HOME=str(local / "cache"), XDG_STATE_HOME=str(local / "state"),
               XDG_CONFIG_HOME=str(local / "config"), LOCALAPPDATA=str(local / "appdata"),
               LOGNAME=DEMO_USER, USER=DEMO_USER, USERNAME=DEMO_USER)
    os.environ.update(env)
    cmd = find_command()
    if cmd is None:
        raise SystemExit("RevisionWorx is not installed (or set REVISIONWORX_CLI)")
    ws = out / "workspace"
    run(cmd + ["init", str(ws), "--name", "Northline engineering"], env)
    (ws / "Projects").mkdir()
    run(cmd + ["-w", str(ws), "root", "add", "Projects", str(ws / "Projects")], env)
    run(cmd + ["-w", str(ws), "project", "new", "--name", "HPU-75 hydraulic power unit", "--number", "J-2001",
               "--customer", "Northline Hydraulics"], env)
    rwx = RevisionWorx(workspace=str(ws))
    src = out / "source"
    src.mkdir()
    doc_ids: dict[str, tuple[str, str]] = {}

    def publish(path: Path, number: str, title: str, message: str, release: bool = True, document: str = "") -> dict:
        if document:
            res = rwx.publish(str(path), document=document, message=message)
        else:
            res = rwx.publish(str(path), project="J-2001", number=number, title=title, message=message)
        rev = res.get("revision") or res["document"]["latest"]
        if release:
            for state in ("in_review", "approved", "released"):
                run(cmd + ["-w", str(ws), "rev", "transition", rev["id"], state], env)
        doc_ids[number] = (res["document"]["id"], rev["id"])
        return res

    def write(name: str, data: bytes | str) -> Path:
        p = src / name
        p.write_bytes(data.encode("utf-8") if isinstance(data, str) else data)
        return p

    publish(write("HPU-75-GA General arrangement.pdf", drawings.ga_drawing()), "HPU-75-GA",
            "HPU-75 general arrangement", "First issue")
    frm = write("FRM-200 Skid frame.pdf", drawings.frame_drawing("A"))
    publish(frm, "FRM-200", "Skid frame, welded", "First issue")
    frm.write_bytes(drawings.frame_drawing("B"))
    publish(frm, "FRM-200", "", "Pump mount holes moved 25 mm; lifting lugs added", document="FRM-200")
    files = HERE / "files"
    publish(files / "SCH-HPU-75 control and hydraulics.schematix", "SCH-HPU-75", "HPU-75 control and hydraulics",
            "First issue")
    publish(files / "SCH-HPU-75 control and hydraulics.pdf", "SCH-HPU-75-PDF",
            "HPU-75 control and hydraulics (PDF)", "Exported from OpenSchematix")
    publish(write("BOM-HPU-75.csv", BOM_CSV), "BOM-HPU-75", "HPU-75 engineering BOM", "First issue")
    publish(write("PRT-HPU-75 parts.csv", parts_csv(doc_ids)), "PRT-HPU-75", "HPU-75 parts catalog", "First issue")
    publish(write("ITP-HPU-75 Final inspection.fwtemplate.csv", TEMPLATE_CSV), "ITP-HPU-75",
            "HPU-75 final inspection and test plan", "First issue")
    publish(write("AST-HPU-75 Units built.fwassets.csv", ASSETS_CSV), "AST-HPU-75", "HPU-75 units built",
            "Units 0001 and 0002")
    # An unreleased drawing, so the phone shows what "not released" looks like.
    publish(write("TNK-100 Reservoir.pdf", drawings.frame_drawing("A").replace(b"FRM-200", b"TNK-100")
                  .replace(b"SKID FRAME, WELDED", b"RESERVOIR 100 L")), "TNK-100", "Reservoir 100 L",
            "Draft for review", release=False)

    meridian = None
    try:
        from openmeridian import sample  # noqa: WPS433 - optional, only to make demo stock figures
        meridian = out / "northline.meridian"
        sample.build(str(meridian)).close()
    except ImportError:
        print("OpenMeridian not installed: the demo has no stock figures")
    if a.history:
        from fieldworx_bridge.sources import RevisionWorxSource
        record_history(ws, RevisionWorxSource(ws).info["id"])
    summary = {"workspace": str(ws), "meridian": str(meridian) if meridian else "",
               "documents": {k: {"document": v[0], "revision": v[1]} for k, v in doc_ids.items()}}
    (out / "demo.json").write_text(json.dumps(summary, indent=1), encoding="utf-8")
    print(f"workspace {ws}")
    if a.package:
        from fieldworx_bridge import cli
        args = ["pack", "-w", str(ws), "--project", "J-2001", "-o", str(a.package), "--title",
                "HPU-75 demo (Northline Hydraulics)", "--overwrite"]
        if meridian:
            args += ["--meridian", str(meridian)]
        return cli.main(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
