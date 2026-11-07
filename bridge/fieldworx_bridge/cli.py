# SPDX-License-Identifier: GPL-3.0-or-later
"""``fieldworx-bridge``: the desktop side of FieldWorx.

    fieldworx-bridge pack -w WORKSPACE [--project J-2001] -o hpu.fieldworx      package for the phones
    fieldworx-bridge import -w WORKSPACE phone.fieldlog                        bring field records back
    fieldworx-bridge report -w WORKSPACE -o reports/                            inspection register and records
    fieldworx-bridge status -w WORKSPACE                                        what the hub holds
    fieldworx-bridge verify FILE                                                check a package or field log

The hub (field records) lives in WORKSPACE/.fieldworx unless --hub says otherwise. Exit codes: 0 done, 1 problems
found (verify, status), 2 refused (nothing was changed).
"""
from __future__ import annotations

import argparse
import sys
from collections import Counter
from pathlib import Path

from . import __version__, archive, catalog as cat_mod, events as ev_mod, inspections, report, safefile, sources
from .hub import Hub, HubError
from .packbuilder import PackOptions, build_package


def _hub_path(a) -> Path:
    if getattr(a, "hub", None):
        return Path(a.hub)
    if getattr(a, "workspace", None):
        return Hub.location_for(Path(a.workspace))
    raise SystemExit("say where the field records are kept: -w WORKSPACE or --hub FOLDER")


def cmd_pack(a) -> int:
    events: list[ev_mod.Event] = []
    hub_dir = Path(a.hub) if a.hub else (Hub.location_for(Path(a.workspace)) if a.workspace else None)
    if hub_dir is not None and (hub_dir / "hub.json").exists() and not a.no_field_records:
        events = Hub.open(hub_dir).export_events()
    opts = PackOptions(workspace=Path(a.workspace) if a.workspace else None, projects=a.project,
                       unreleased=a.unreleased, meridian=Path(a.meridian) if a.meridian else None,
                       templates_dir=Path(a.templates) if a.templates else None,
                       assets_csv=Path(a.assets) if a.assets else None, title=a.title or "",
                       revisionworx=a.revisionworx, draftworx=a.draftworx, field_events=events)
    out = Path(a.output)
    manifest = build_package(opts, out, overwrite=a.overwrite, log=lambda s: print(s, file=sys.stderr))
    arc = archive.read(out)
    c = arc.catalog
    arc.close()
    print(f"wrote {out}: {len(c['documents'])} document(s), {len(c['parts'])} part(s), {len(c['assets'])} asset(s), "
          f"{len(c['templates'])} template(s), {len(manifest['objects'])} file(s), {len(manifest['events'])} field "
          f"record(s)")
    print(f"package {manifest['id']}  digest {arc.digest[:16]}")
    for n in manifest["notices"]:
        print(f"  note: {n}")
    return 0


def cmd_import(a) -> int:
    hub = Hub.open(_hub_path(a), create=True)
    rc = 0
    for f in a.files:
        try:
            with archive.read(Path(f)) as arc:
                rep = hub.import_archive(arc)
            print(f"{f}: {rep.text()}")
        except (archive.ArchiveError, ev_mod.EventError, HubError, OSError) as exc:
            print(f"{f}: refused, nothing imported: {exc}", file=sys.stderr)
            rc = 2
    return rc


def cmd_status(a) -> int:
    hub = Hub.open(_hub_path(a))
    log = hub.load()
    states = report.states(log)
    print(f"hub {hub.root}: {len(log)} record(s) from {len(log.streams)} device(s)")
    counts = Counter((s["status"], s.get("outcome", "")) for s in states if s["valid"])
    for (status, outcome), n in sorted(counts.items()):
        print(f"  inspections {status:<10} {outcome:<11} {n}")
    bad = [s for s in states if not s["valid"] or s["problems"] or (s.get("completion") or {}).get("stale")
           or s["status"] == "conflict" or s.get("outcome") == "conflict"]
    for s in bad:
        why = "; ".join(s["problems"]) or ("completion is stale" if (s.get("completion") or {}).get("stale")
                                           else "conflicting answers")
        print(f"  attention {s['entity']}: {why}")
    return 1 if bad else 0


def cmd_report(a) -> int:
    hub = Hub.open(_hub_path(a))
    written = report.write_reports(hub, Path(a.output))
    print(f"wrote {len(written)} file(s) to {a.output}")
    return 0


def cmd_verify(a) -> int:
    try:
        arc = archive.read(Path(a.file))
    except archive.ArchiveError as exc:
        print(f"{a.file}: NOT usable: {exc}")
        return 1
    with arc:
        m = arc.manifest
        print(f"{a.file}: intact {m['kind']} {m['id']} ({m['title']}), digest {arc.digest[:16]}")
        print(f"  made {m['created']} by {m['created_by']}")
        if arc.catalog is not None:
            try:
                cat_mod.check_catalog(arc.catalog)
            except cat_mod.CatalogError as exc:
                print(f"  catalog NOT usable: {exc}")
                return 1
            c = arc.catalog
            print(f"  {len(c['projects'])} project(s), {len(c['documents'])} document(s), {len(c['parts'])} part(s), "
                  f"{len(c['bom'])} BOM line(s), {len(c['assets'])} asset(s), {len(c['templates'])} template(s)")
        print(f"  {len(arc.events)} field record(s), {len(arc.objects)} file(s)")
        log = ev_mod.FieldLog()
        try:
            log.import_events(arc.events)
        except ev_mod.EventError as exc:
            print(f"  field records do not fit together: {exc}")
            return 1
        for n in m["notices"]:
            print(f"  note: {n}")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="fieldworx-bridge", description=__doc__.split("\n\n")[0])
    p.add_argument("--version", action="version", version=f"fieldworx-bridge {__version__}")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("pack", help="build a package for the phones")
    s.add_argument("-w", "--workspace", help="RevisionWorx workspace folder (default: as RevisionWorx finds it)")
    s.add_argument("--project", action="append", default=[], help="project id, number or name (repeatable; "
                                                                   "default: every active project)")
    s.add_argument("-o", "--output", required=True, help="the .fieldworx file to write")
    s.add_argument("--unreleased", action="store_true", help="include latest revisions that aren't released yet "
                                                              "(marked as not released on the phone)")
    s.add_argument("--meridian", help="OpenMeridian company file for stock on hand (read-only)")
    s.add_argument("--templates", help="folder of uncontrolled inspection templates (*.fwtemplate.csv/json)")
    s.add_argument("--assets", help="uncontrolled asset register (*.fwassets.csv)")
    s.add_argument("--hub", help="field records to include (default: WORKSPACE/.fieldworx if it exists)")
    s.add_argument("--no-field-records", action="store_true", help="leave field records out")
    s.add_argument("--title", help="what the phone calls this package")
    s.add_argument("--revisionworx", help="the revisionworx program (default: REVISIONWORX_CLI or PATH)")
    s.add_argument("--draftworx", help="the draftworx program (default: DRAFTWORX_CLI or PATH)")
    s.add_argument("--overwrite", action="store_true", help="replace OUTPUT if it exists")
    s.set_defaults(fn=cmd_pack)

    s = sub.add_parser("import", help="bring field logs from phones into the hub")
    s.add_argument("files", nargs="+")
    s.add_argument("-w", "--workspace")
    s.add_argument("--hub")
    s.set_defaults(fn=cmd_import)

    s = sub.add_parser("status", help="what the hub holds, and what needs attention")
    s.add_argument("-w", "--workspace")
    s.add_argument("--hub")
    s.set_defaults(fn=cmd_status)

    s = sub.add_parser("report", help="inspection register (CSV) and one HTML record per inspection")
    s.add_argument("-w", "--workspace")
    s.add_argument("--hub")
    s.add_argument("-o", "--output", required=True, help="folder to write into")
    s.set_defaults(fn=cmd_report)

    s = sub.add_parser("verify", help="check a package or field log without changing anything")
    s.add_argument("file")
    s.set_defaults(fn=cmd_verify)

    a = p.parse_args(argv)
    try:
        return a.fn(a)
    except (sources.SourceError, HubError, archive.ArchiveError, ev_mod.EventError, cat_mod.CatalogError,
            inspections.TemplateError, safefile.AlreadyExists, OSError) as exc:
        msg = f"{exc} already exists (use --overwrite)" if isinstance(exc, safefile.AlreadyExists) else str(exc)
        print(f"error: {msg}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
