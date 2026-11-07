# SPDX-License-Identifier: GPL-3.0-or-later
"""Inspection records as files people can keep: a CSV register and a self-contained HTML record per inspection
(photos embedded), which prints to PDF from any browser. Both say plainly what isn't settled: conflicts, a completion
made stale by later answers, photos not received yet, and that names are as entered on the device, not verified."""
from __future__ import annotations

import base64
import csv
import html
import io
from pathlib import Path

from . import events as ev_mod, inspections
from .hub import Hub

STATUS_NAMES = {"open": "Open", "completed": "Completed", "voided": "Voided", "conflict": "Status conflict"}
OUTCOME_NAMES = {"pass": "Pass", "fail": "Fail", "incomplete": "Incomplete", "conflict": "Conflict", "open": "Open",
                 "na": "N/A", "done": "Done", "photo-missing": "Photo missing"}


def states(log: ev_mod.FieldLog) -> list[dict]:
    return [inspections.reduce(log, e) for e in inspections.inspection_entities(log)]


def register_csv(log: ev_mod.FieldLog) -> str:
    out = io.StringIO(newline="")
    w = csv.writer(out, lineterminator="\r\n")
    w.writerow(["inspection", "title", "template", "template_revision", "subject", "status", "outcome", "started",
                "started_by", "completed", "completed_by", "stale_completion", "conflicts", "photos", "problems"])
    for s in states(log):
        if not s["valid"]:
            w.writerow([s["entity"], "", "", "", "", "unreadable", "", "", "", "", "", "", "", "",
                        "; ".join(s["problems"])])
            continue
        c = s["completion"] or {}
        w.writerow([s["entity"], _safe(s["title"]), _safe(s["template"]["id"]), _safe(s["template"]["revision"]),
                    _safe(s["subject"]["label"]), s["status"], s["outcome"], s["started"]["time"],
                    _safe(s["started"]["actor"]), c.get("time", ""), _safe(c.get("actor", "")),
                    "yes" if c.get("stale") else "", sum(1 for i in s["items"] if i["outcome"] == "conflict"),
                    len(s["attachments"]), _safe("; ".join(s["problems"]))])
    return "﻿" + out.getvalue()


def _safe(v: str) -> str:
    return "'" + v if v[:1] in ("=", "+", "-", "@", "\t", "\r") else v


def _value_text(item: dict, value: dict) -> str:
    if not value:
        return "(cleared)"
    if "result" in value:
        return OUTCOME_NAMES.get(value["result"], value["result"])
    if "measured" in value:
        return f"{value['measured']} {item.get('unit', '')}".strip()
    if "text" in value:
        return value["text"]
    if "choice" in value:
        return value["choice"]
    return str(value)


def _limits(item: dict) -> str:
    if item["kind"] != "measure":
        return ""
    lo, hi, u = item["min"], item["max"], item["unit"]
    if lo and hi:
        return f"{lo} to {hi} {u}".strip()
    if lo:
        return f"at least {lo} {u}".strip()
    if hi:
        return f"at most {hi} {u}".strip()
    return ""


def inspection_html(hub: Hub | None, log: ev_mod.FieldLog, entity: str) -> str:
    s = inspections.reduce(log, entity)
    e = html.escape
    if not s["valid"]:
        return f"<!doctype html><meta charset='utf-8'><title>{e(entity)}</title><p>Unreadable: " + \
            e("; ".join(s["problems"])) + "</p>"
    start = next(ev for ev in log.entity_events(entity) if ev.type == "inspection.start")
    template = start.body["template"]
    rows = []
    by_id = {i["id"]: i for i in s["items"]}
    for sec in template["sections"]:
        rows.append(f"<tr class='sec'><th colspan='4'>{e(sec['title'])}</th></tr>")
        for it in sec["items"]:
            st = by_id[it["id"]]
            vals = "<br>".join(
                f"{e(_value_text(it, v['value']))}<span class='by'> {e(v['actor'] or 'unknown')}, "
                f"{e(v['time'][:16].replace('T', ' '))}</span>" + (f"<div class='note'>{e(v['note'])}</div>"
                                                                   if v["note"] else "")
                for v in st["values"]) or "<span class='by'>not answered</span>"
            photos = "".join(_img(hub, a) for a in s["attachments"] if a["item"] == it["id"])
            rows.append(f"<tr class='{st['outcome']}'><td>{e(it['id'])}</td><td>{e(it['prompt'])}"
                        f"<div class='lim'>{e(_limits(it))}</div></td><td>{vals}{photos}</td>"
                        f"<td class='oc'>{e(OUTCOME_NAMES.get(st['outcome'], st['outcome']))}</td></tr>")
    general = "".join(_img(hub, a) for a in s["attachments"] if not a["item"])
    notes = "".join(f"<li>{e(n['text'])} <span class='by'>{e(n['actor'] or 'unknown')}, "
                    f"{e(n['time'][:16].replace('T', ' '))}</span></li>" for n in s["notes"])
    c = s["completion"]
    if s["status"] == "completed" and c:
        status = (f"Completed by {e(c['actor'] or 'unknown')} on {e(c['time'][:16].replace('T', ' '))} UTC: "
                  f"<b>{e(OUTCOME_NAMES[c['result']])}</b>")
        if c["stale"]:
            status += (" <span class='warn'>Answers or photos were recorded that this completion did not see; it "
                       "needs completing again.</span>")
    else:
        status = e(STATUS_NAMES.get(s["status"], s["status"]))
    problems = "".join(f"<li>{e(p)}</li>" for p in s["problems"])
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>{e(s['title'] or template['title'])}</title>
<style>
body{{font:14px/1.45 system-ui,sans-serif;color:#14181F;margin:24px;max-width:1000px}}
h1{{font-size:20px;margin:0}} .sub{{color:#56606C}} table{{border-collapse:collapse;width:100%;margin-top:16px}}
td,th{{border:1px solid #E1E5EA;padding:6px 8px;vertical-align:top;text-align:left}}
tr.sec th{{background:#F2F4F7}} .by{{color:#6B7480;font-size:12px}} .lim{{color:#56606C;font-size:12px}}
.note{{font-style:italic}} .oc{{white-space:nowrap;font-weight:600}} tr.fail .oc{{color:#A31F17}}
tr.pass .oc{{color:#14613A}} tr.conflict .oc,tr.photo-missing .oc{{color:#6F4700}} .warn{{color:#6F4700}}
img{{max-width:220px;max-height:220px;margin:4px 4px 0 0;border:1px solid #C6CCD5}}
.box{{background:#F7F8FA;border:1px solid #E1E5EA;border-radius:8px;padding:8px 12px;margin-top:12px}}
</style></head><body>
<h1>{e(s['title'] or template['title'])}</h1>
<div class="sub">{e(template['id'])}{(' rev ' + e(template['revision'])) if template['revision'] else ''} ·
{e(template['title'])}{(' · ' + e(s['subject']['label'])) if s['subject']['label'] else ''}</div>
<div class="box">Outcome: <b>{e(OUTCOME_NAMES.get(s['outcome'], s['outcome']))}</b> · {status}<br>
Started by {e(s['started']['actor'] or 'unknown')} on {e(s['started']['time'][:16].replace('T', ' '))} UTC ·
record {e(entity)}</div>
<table><tr><th>Item</th><th>Check</th><th>Recorded</th><th>Result</th></tr>{''.join(rows)}</table>
{('<h3>Photos</h3>' + general) if general else ''}
{('<h3>Notes</h3><ul>' + notes + '</ul>') if notes else ''}
{('<h3>Problems</h3><ul>' + problems + '</ul>') if problems else ''}
<p class="by">Names are as entered on each device; FieldWorx 0.1 does not verify who used a device. Times are the
devices' own clocks (UTC). Template digest {e(s['template']['digest'])}.</p>
</body></html>
"""


def _img(hub: Hub | None, a: dict) -> str:
    if hub is not None and hub.has_object(a["object"]) and a["media_type"] in ("image/jpeg", "image/png",
                                                                                 "image/webp"):
        data = base64.b64encode(hub.object_path(a["object"]).read_bytes()).decode("ascii")
        cap = html.escape(a["caption"])
        return f"<img src='data:{a['media_type']};base64,{data}' alt='{cap}' title='{cap}'>"
    return "<div class='by'>(photo not received yet)</div>"


def write_reports(hub: Hub, out_dir: Path) -> list[Path]:
    from .safefile import write_output
    log = hub.load()
    out_dir.mkdir(parents=True, exist_ok=True)
    written = []
    reg = out_dir / "inspections.csv"
    data = register_csv(log).encode("utf-8")
    write_output(reg, lambda f: f.write(data), overwrite=True)
    written.append(reg)
    for ent in inspections.inspection_entities(log):
        page = inspection_html(hub, log, ent).encode("utf-8")
        p = out_dir / f"{ent}.html"
        write_output(p, lambda f, d=page: f.write(d), overwrite=True)
        written.append(p)
    return written
