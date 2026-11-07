# SPDX-License-Identifier: GPL-3.0-or-later
"""Write spec/vectors/*.json from the Python reference implementation (bridge/fieldworx_bridge).

Both implementations run every vector: the bridge's tests check that these files are exactly what this script
writes (so the reference and the vectors can't drift), and the Dart core's tests check that it computes the same
bytes, ids, verdicts and inspection states. Change the protocol here first, regenerate, then make Dart agree.

    python spec/make_vectors.py            # rewrite the vectors
    python spec/make_vectors.py --check    # exit 1 if they are out of date
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "bridge"))

from fieldworx_bridge import events as E  # noqa: E402
from fieldworx_bridge import fxjson, inspections  # noqa: E402

OUT = HERE / "vectors"
DEV_A = "dev_" + "a1" * 16
DEV_B = "dev_" + "b2" * 16
DEV_C = "dev_" + "c3" * 16
INS = "ins_" + "0f" * 16


def t(n: int) -> str:
    return f"2026-11-06T10:{n // 60:02d}:{n % 60:02d}.000Z"


# ------------------------------------------------------------------------------------------------------- fxjson
def fxjson_vectors() -> list[dict]:
    cases = [
        ("empty object", "{}", "{}"),
        ("empty array", "[ ]", "[]"),
        ("literals", '[true, false, null]', "[true,false,null]"),
        ("integers", "[0, -1, 1, 9007199254740991, -9007199254740991]",
         "[0,-1,1,9007199254740991,-9007199254740991]"),
        ("minus zero is zero", "-0", "0"),
        ("key order", '{"b":1,"a":2,"aa":3,"A":4,"_":5}', '{"A":4,"_":5,"a":2,"aa":3,"b":1}'),
        ("key order by code point, not UTF-16", '{"\\ufffd":1,"\\ud83d\\ude00":2,"\\u00e9":3,"z":4}',
         '{"z":4,"é":3,"�":1,"😀":2}'),
        ("escapes", '"quote \\" backslash \\\\ slash \\/ tab \\t nl \\n cr \\r bs \\b ff \\f"',
         '"quote \\" backslash \\\\ slash / tab \\t nl \\n cr \\r bs \\b ff \\f"'),
        ("other controls", '"\\u0000\\u0001\\u001f"', '"\\u0000\\u0001\\u001f"'),
        ("not escaped", '"\\u007f \\u2028 \\u2029 é 中 😀"', '"\x7f     é 中 😀"'),
        ("nesting", '{"a":[{"c":3,"b":[]}],"b":{"y":null,"x":"1.50"}}',
         '{"a":[{"b":[],"c":3}],"b":{"x":"1.50","y":null}}'),
        ("whitespace removed", ' { "a" : [ 1 , 2 ] } ', '{"a":[1,2]}'),
    ]
    out = [{"name": n, "input": i, "canonical": c} for n, i, c in cases]
    for n, i, c in cases:
        assert fxjson.encode(fxjson.parse(i)).decode("utf-8") == c, n
    errors = [
        ("float", "1.5"), ("float with zero fraction", "1.0"), ("exponent", "1e5"), ("negative float", "-0.0"),
        ("too big", "9007199254740992"), ("too small", "-9007199254740992"), ("NaN", "NaN"),
        ("Infinity", "Infinity"), ("duplicate key", '{"a":1,"a":2}'), ("lone surrogate", '"\\ud800"'),
        ("trailing comma", "[1,]"), ("single quotes", "{'a':1}"), ("not JSON", "hello"),
        ("deep nesting", "[" * 70 + "]" * 70),
    ]
    for n, i in errors:
        try:
            fxjson.encode(fxjson.parse(i))
        except fxjson.FxJsonError:
            pass
        else:
            raise AssertionError(f"{n} should fail")
        out.append({"name": n, "input": i, "canonical": None})
    return out


def digest_vectors() -> dict:
    values = [{"a": 1}, [], "fieldworx", {"z": "é", "a": [1, 2, {"b": None}]}]
    raws = [b"", b"abc", b"The quick brown fox jumps over the lazy dog", bytes(range(256)) * 5, b"a" * 1000]
    return {"domain_digests": [{"domain": d, "canonical": fxjson.encode(v).decode("utf-8"),
                                "digest": fxjson.digest(d, v)}
                               for d in ("event/v1", "template/v1") for v in values],
            "sha256": [{"hex": r.hex(), "sha256": hashlib.sha256(r).hexdigest()} for r in raws]}


# ------------------------------------------------------------------------------------------------------- events
TEMPLATE = {
    "format": "fieldworx.template", "version": 1, "id": "ITP-TEST", "revision": "B", "title": "Vector template",
    "description": "",
    "sections": [
        {"title": "Checks", "items": [
            {"id": "1", "kind": "check", "prompt": "Guards fitted", "required": True, "photo": "none", "help": ""},
            {"id": "2", "kind": "measure", "prompt": "Offset", "unit": "mm", "nominal": "0", "min": "-0.05",
             "max": "0.05", "required": True, "photo": "none", "help": ""},
            {"id": "3", "kind": "measure", "prompt": "Insulation", "unit": "MΩ", "nominal": "", "min": "100",
             "max": "", "required": True, "photo": "none", "help": ""}]},
        {"title": "Records", "items": [
            {"id": "4", "kind": "text", "prompt": "Remarks", "required": False, "photo": "optional", "help": ""},
            {"id": "5", "kind": "choice", "prompt": "Frame revision", "choices": ["A", "B"], "required": True,
             "photo": "none", "help": ""},
            {"id": "6", "kind": "check", "prompt": "Nameplate", "required": True, "photo": "required", "help": ""}]},
    ]}


class Device:
    def __init__(self, dev: str, actor: str):
        self.dev, self.actor, self.seq, self.prev = dev, actor, 0, ""

    def make(self, type_, body, deps, time, entity=INS) -> E.Event:
        self.seq += 1
        ev = E.make(self.dev, self.seq, self.prev, self.actor, type_, entity, [d.id for d in deps], body, time)
        self.prev = ev.id
        return ev


def start_body() -> dict:
    return {"template": TEMPLATE, "title": "HPU-0002 final inspection",
            "subject": {"kind": "asset", "id": "ast_" + "11" * 16, "label": "HPU-0002"}, "package": "pkg_" + "22" * 16}


def answer(item, value, note=""):
    return {"item": item, "value": value, "note": note}


def inspection_scenarios() -> list[dict]:
    scenarios = []

    def add(name: str, evs: list[E.Event], note: str):
        log = E.FieldLog()
        log.import_events(evs)
        state = inspections.reduce(log, INS)
        # The same state whatever order the events arrive in (reverse order exercises the pending queue).
        log2 = E.FieldLog()
        log2.import_events(list(reversed(evs)))
        assert fxjson.encode(inspections.reduce(log2, INS)) == fxjson.encode(state), name
        scenarios.append({"name": name, "note": note, "entity": INS, "events": [e.raw.decode("utf-8") for e in evs],
                          "state": state})

    a, b = Device(DEV_A, "Alex Morgan"), Device(DEV_B, "Sam Ortiz")
    s = a.make("inspection.start", start_body(), [], t(0))
    a1 = a.make("inspection.answer", answer("1", {"result": "pass"}), [s], t(1))
    a2 = a.make("inspection.answer", answer("2", {"measured": "0.03"}), [a1], t(2))
    a3 = a.make("inspection.answer", answer("3", {"measured": "85"}, "lowest phase L2"), [a2], t(3))
    a4 = a.make("inspection.answer", answer("5", {"choice": "B"}), [a3], t(4))
    a5 = a.make("inspection.answer", answer("6", {"result": "pass"}), [a4], t(5))
    a6 = a.make("inspection.attach", {"object": "ab" * 32, "size": 12345, "media_type": "image/jpeg", "item": "6",
                                      "caption": "Nameplate"}, [a5], t(6))
    a7 = a.make("inspection.complete", {"result": "fail", "summary": "Insulation low"}, [a6], t(7))
    add("single device, completed", [s, a1, a2, a3, a4, a5, a6, a7],
        "item 3 measures 85 against a minimum of 100: the outcome is fail; the completion saw everything")

    a, b = Device(DEV_A, "Alex Morgan"), Device(DEV_B, "Sam Ortiz")
    s = a.make("inspection.start", start_body(), [], t(0))
    x = a.make("inspection.answer", answer("2", {"measured": "0.02"}), [s], t(1))
    y = b.make("inspection.answer", answer("2", {"measured": "0.07"}), [s], t(2))
    add("concurrent answers conflict", [s, x, y], "two phones answered item 2 without seeing each other")
    z = a.make("inspection.answer", answer("2", {"measured": "0.04"}, "re-measured"), [x, y], t(3))
    add("conflict resolved by a later answer", [s, x, y, z], "an answer that has seen both settles it")

    a, b = Device(DEV_A, "Alex Morgan"), Device(DEV_B, "Sam Ortiz")
    s = a.make("inspection.start", start_body(), [], t(0))
    evs = [s]
    prev = s
    for item, val in (("1", {"result": "pass"}), ("2", {"measured": "0"}), ("3", {"measured": "250"}),
                      ("5", {"choice": "A"}), ("6", {"result": "pass"})):
        prev = a.make("inspection.answer", answer(item, val), [prev], t(len(evs)))
        evs.append(prev)
    att = a.make("inspection.attach", {"object": "cd" * 32, "size": 999, "media_type": "image/jpeg", "item": "6",
                                       "caption": ""}, [prev], t(10))
    evs.append(att)
    done = a.make("inspection.complete", {"result": "pass", "summary": ""}, [att], t(11))
    late = b.make("inspection.answer", answer("1", {"result": "fail"}, "guard loose"), [att], t(12))
    add("completion made stale by a concurrent answer", evs + [done, late],
        "the second phone answered item 1 again without having seen the completion: its answer replaces the first "
        "(it had seen it), and the completion no longer covers what was recorded")

    a, b = Device(DEV_A, "Alex Morgan"), Device(DEV_B, "Sam Ortiz")
    s = a.make("inspection.start", start_body(), [], t(0))
    c1 = a.make("inspection.complete", {"result": "pass", "summary": ""}, [s], t(1))
    v1 = b.make("inspection.void", {"reason": "wrong unit"}, [s], t(2))
    add("status conflict", [s, c1, v1], "completed on one phone, voided on another, neither saw the other")
    r1 = a.make("inspection.reopen", {"reason": "voided by Sam; reopened"}, [c1, v1], t(3))
    add("reopen settles the status", [s, c1, v1, r1], "the reopen has seen both")

    a = Device(DEV_A, "Alex Morgan")
    s = a.make("inspection.start", start_body(), [], t(0))
    bad1 = a.make("inspection.answer", answer("99", {"result": "pass"}), [s], t(1))
    bad2 = a.make("inspection.answer", answer("1", {"result": "maybe"}), [bad1], t(2))
    bad3 = a.make("inspection.answer", answer("2", {"measured": "1e3"}), [bad2], t(3))
    newer = a.make("inspection.signature", {"svg": "..."}, [bad3], t(4))
    ok = a.make("inspection.answer", answer("6", {"result": "na"}), [newer], t(5))
    note = a.make("inspection.note", {"text": "Customer present", "item": ""}, [ok], t(6))
    add("malformed and newer records are reported, not used", [s, bad1, bad2, bad3, newer, ok, note],
        "unknown item, unknown result, exponent decimal, a record type from a newer version")

    a = Device(DEV_A, "Alex Morgan")
    s = a.make("inspection.start", start_body(), [], t(0))
    p1 = a.make("inspection.answer", answer("6", {"result": "pass"}), [s], t(1))
    m1 = a.make("inspection.answer", answer("3", {"result": "na"}), [p1], t(2))
    c1 = a.make("inspection.answer", answer("1", {"result": "pass"}), [m1], t(3))
    c2 = a.make("inspection.answer", answer("1", {}), [c1], t(4))
    add("photo missing, n/a measure, cleared answer", [s, p1, m1, c1, c2],
        "item 6 needs a photo; item 3 is N/A; item 1 was answered then cleared, so it's open again")

    a = Device(DEV_A, "Alex Morgan")
    s = a.make("inspection.start", start_body(), [], t(0))
    m = a.make("inspection.answer", answer("2", {"measured": "-0.05"}), [s], t(1))
    m2 = a.make("inspection.answer", answer("3", {"measured": "100.000"}), [m], t(2))
    add("limits are inclusive", [s, m, m2], "-0.05 against min -0.05 and 100.000 against min 100 both pass")
    return scenarios


def fieldlog_scenarios() -> list[dict]:
    a, b = Device(DEV_A, "A"), Device(DEV_B, "B")
    ent = "ins_" + "aa" * 16
    a1 = a.make("inspection.start", {"x": 1}, [], t(0), ent)
    a2 = a.make("inspection.note", {"x": 2}, [a1], t(1), ent)
    b1 = b.make("inspection.note", {"x": 3}, [a2], t(2), ent)
    a3 = a.make("inspection.note", {"x": 4}, [b1], t(3), ent)
    fork = E.make(DEV_A, 2, a1.id, "A", "inspection.note", ent, [a1.id], {"x": "forked"}, t(9))
    ent2 = "ins_" + "bb" * 16
    other = Device(DEV_C, "C")
    c1 = other.make("inspection.start", {"x": 5}, [], t(4), ent2)
    cross = E.make(DEV_C, 2, c1.id, "C", "inspection.note", ent2, [a1.id], {"x": 6}, t(5))

    def raw(evs):
        return [e.raw.decode("utf-8") for e in evs]

    cases = []

    def case(name, steps, note):
        log = E.FieldLog()
        out_steps = []
        for batch in steps:
            try:
                new = log.import_events(batch)
                out_steps.append({"events": raw(batch), "result": "ok", "new": [e.id for e in new]})
            except E.ForkError:
                out_steps.append({"events": raw(batch), "result": "fork"})
            except E.MissingHistory:
                out_steps.append({"events": raw(batch), "result": "missing"})
            except E.EventError:
                out_steps.append({"events": raw(batch), "result": "invalid"})
        cases.append({"name": name, "note": note, "steps": out_steps, "heads": log.heads(),
                      "entity_heads": {e: log.entity_heads(e) for e in sorted(log.by_entity)}})

    case("in order", [[a1, a2, b1, a3]], "")
    case("any order", [[a3, b1, a2, a1]], "a batch can arrive in any order")
    case("twice", [[a1, a2], [a1, a2, b1]], "known records are skipped")
    case("gap is refused whole", [[a1], [a3, b1]], "a3 needs a2, which this log doesn't have: nothing is added")
    case("fork is refused whole", [[a1, a2], [fork, b1]], "device A has two different record 2s")
    case("deps across entities are invalid", [[a1, c1], [cross]], "a record may only depend on its own entity")
    case("missing dependency", [[b1]], "b1 depends on a2 from another device")
    return cases


def envelope_vectors() -> dict:
    good = E.make(DEV_A, 1, "", "Alex", "inspection.start", INS, [], {"k": "v"}, t(0))
    base = good.data
    bad = []

    def b(name, **changes):
        d = dict(base)
        for k, v in changes.items():
            if v is ...:
                d.pop(k)
            else:
                d[k] = v
        bad.append({"name": name, "event": fxjson.encode(d).decode("utf-8")})

    b("version 2", v=2)
    b("missing body", body=...)
    b("extra field", extra=1)
    b("device malformed", device="dev_XYZ")
    b("seq zero", seq=0)
    b("seq 1 with prev", prev="ab" * 32)
    b("seq 2 without prev", seq=2)
    b("time without zone", time="2026-11-06T10:00:00")
    b("actor with newline", actor="a\nb")
    b("actor too long", actor="x" * 201)
    b("type malformed", type="Inspection")
    b("entity malformed", entity="ins_123")
    b("deps unsorted", deps=["bb" * 32, "aa" * 32])
    b("deps duplicate", deps=["aa" * 32, "aa" * 32])
    b("deps not ids", deps=["x"])
    b("body not object", body=[])
    for x in bad:
        try:
            E.check_envelope(fxjson.parse(x["event"]))
        except E.EventError:
            continue
        raise AssertionError(x["name"])
    noncanon = good.raw.decode("utf-8").replace('{"actor"', '{ "actor"')
    return {"good": [{"event": good.raw.decode("utf-8"), "id": good.id}],
            "bad": bad, "not_canonical": [noncanon]}


def template_vectors() -> dict:
    good = [TEMPLATE]
    bad = []

    def b(name, fn):
        tt = json.loads(json.dumps(TEMPLATE))
        fn(tt)
        bad.append({"name": name, "template": tt})

    b("wrong format", lambda x: x.update(format="other"))
    b("no sections", lambda x: x.update(sections=[]))
    b("duplicate item id (case)", lambda x: x["sections"][1]["items"].append(dict(x["sections"][0]["items"][0])))
    b("measure min above max", lambda x: x["sections"][0]["items"][1].update(min="1", max="0"))
    b("measure decimal with exponent", lambda x: x["sections"][0]["items"][1].update(min="1e2"))
    b("choice with one choice", lambda x: x["sections"][1]["items"][1].update(choices=["A"]))
    b("unknown kind", lambda x: x["sections"][0]["items"][0].update(kind="slider"))
    b("check with unit", lambda x: x["sections"][0]["items"][0].update(unit="mm"))
    b("photo value", lambda x: x["sections"][0]["items"][0].update(photo="maybe"))
    b("empty prompt", lambda x: x["sections"][0]["items"][0].update(prompt="  "))
    for x in bad:
        try:
            inspections.check_template(x["template"])
        except inspections.TemplateError:
            continue
        raise AssertionError(x["name"])
    return {"good": good, "bad": bad}


def decimal_vectors() -> list[dict]:
    cases = []
    for a_, b_ in (("0", "-0"), ("1", "1.0"), ("-0.05", "-0.050"), ("0.049", "0.05"), ("100", "99.999999999"),
                   ("-1", "1"), ("123456789012345", "123456789012345.000000001"), ("-2.5", "-2.49"),
                   ("10", "9"), ("0.1", "0.09")):
        from decimal import Decimal
        da, db = Decimal(a_), Decimal(b_)
        cases.append({"a": a_, "b": b_, "cmp": (da > db) - (da < db)})
    return cases


PDF = (b"%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n2 0 obj << /Type /Pages /Kids [] /Count 0 >> "
       b"endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n")
JPEG = b"\xff\xd8\xff\xe0\x00\x10JFIF\x00" + bytes(range(200)) + b"\xff\xd9"


def sample_catalog() -> dict:
    from fieldworx_bridge import catalog as cat_mod
    pdf_sha = hashlib.sha256(PDF).hexdigest()
    c = {"format": "fieldworx.catalog", "version": 1,
         "projects": [{"id": "prj_" + "01" * 16, "number": "J-2001", "name": "HPU-75", "customer": "Northline"}],
         "documents": [{"id": "doc_" + "02" * 16, "number": "FRM-200", "title": "Skid frame", "type": "pdf",
                        "project": "prj_" + "01" * 16, "path": "FRM-200.pdf", "released": "rev_" + "04" * 16,
                        "latest": "rev_" + "04" * 16,
                        "revisions": [
                            {"id": "rev_" + "03" * 16, "label": "A", "state": "superseded", "state_name": "Superseded",
                             "sha256": "aa" * 32, "size": 10, "created": "2026-02-10T09:00:00+00:00", "author": "am",
                             "description": "First issue", "ext": ".pdf", "rendition": None},
                            {"id": "rev_" + "04" * 16, "label": "B", "state": "released", "state_name": "Released",
                             "sha256": pdf_sha, "size": len(PDF), "created": "2026-06-02T09:00:00+00:00",
                             "author": "am", "description": "Lugs added", "ext": ".pdf",
                             "rendition": {"object": pdf_sha, "media_type": "application/pdf", "via": "content"}}]}],
         "parts": [{"id": "pn:hpu-75", "number": "HPU-75", "description": "Hydraulic power unit", "unit": "EA",
                    "kind": "assembly", "revision": "A", "status": "active", "manufacturers": [], "vendors": [],
                    "documents": [], "attributes": {}, "stock": None},
                   {"id": "pn:frm-200", "number": "FRM-200", "description": "Skid frame, welded", "unit": "EA",
                    "kind": "assembly", "revision": "B", "status": "active",
                    "manufacturers": [{"name": "Ironbridge", "mpn": "IB-200"}], "vendors": [],
                    "documents": [{"document": "doc_" + "02" * 16, "revision": "rev_" + "04" * 16,
                                   "role": "drawing"}], "attributes": {"Material": "S355"},
                    "stock": {"on_hand": "2.5", "unit": "EA", "bin": "C2", "as_of": "2026-11-06T10:00:00Z",
                              "source": "OpenMeridian"}}],
         "bom": [{"parent": "pn:hpu-75", "child": "pn:frm-200", "quantity": "1", "unit": "EA", "find_number": "10",
                  "refdes": [], "note": "", "provenance": "declared", "source": "doc_x@rev_y"}],
         "assets": [{"id": "ast_" + "05" * 16, "tag": "HPU-0001", "serial": "NH-26-0001", "name": "Unit 1",
                     "part": "pn:hpu-75", "project": "prj_" + "01" * 16, "location": "Milltown",
                     "built": "2026-03-18", "notes": "", "as_built": ["rev_" + "03" * 16]}],
         "templates": [{"template": TEMPLATE, "document": "", "revision": "", "state": "uncontrolled"}]}
    cat_mod.check_catalog(c)
    return c


def sample_catalog_v2() -> dict:
    """A version 2 catalog: a unit from RevisionWorx's register (its own revision of one document, a standard's
    revision of another, a document that doesn't apply, a fitted component unit, history) and an asset register row."""
    import copy
    from fieldworx_bridge import catalog as cat_mod
    c = copy.deepcopy(sample_catalog())
    c["version"] = 2
    gad = {"id": "doc_" + "08" * 16, "number": "HPU-75-GA", "title": "General arrangement", "type": "pdf",
           "project": "prj_" + "01" * 16, "path": "HPU-75-GA.pdf", "released": "rev_" + "09" * 16,
           "latest": "rev_" + "09" * 16,
           "revisions": [{"id": "rev_" + "09" * 16, "label": "A", "state": "released", "state_name": "Released",
                          "sha256": "bb" * 32, "size": 12, "created": "2026-02-10T09:00:00+00:00", "author": "am",
                          "description": "First issue", "ext": ".pdf", "rendition": None}]}
    man = {**gad, "id": "doc_" + "0a" * 16, "number": "MAN-HPU-75", "title": "Manual", "path": "MAN.pdf",
           "released": "rev_" + "0b" * 16, "latest": "rev_" + "0b" * 16,
           "revisions": [{**gad["revisions"][0], "id": "rev_" + "0b" * 16, "sha256": "cc" * 32}]}
    c["documents"] += [gad, man]
    hpu, pump, row = "unt_" + "0c" * 16, "unt_" + "0d" * 16, "ast_" + "05" * 16
    c["assets"] = [
        {"id": hpu, "aliases": ["ast_" + "0e" * 16], "label": "NH-26-0001", "class": "product",
         "name": "Hydraulic power unit", "model": "HPU-75", "part": "pn:hpu-75", "project": "prj_" + "01" * 16,
         "customer": "Acme Manufacturing", "site": "Milltown", "location": "Pump house", "status": "in-service",
         "identifiers": [{"scheme": "serial", "issuer": "", "value": "NH-26-0001", "active": True},
                         {"scheme": "tag", "issuer": "Acme", "value": "HPU-0001", "active": True},
                         {"scheme": "other", "issuer": "Previous owner", "value": "OLD-17", "active": False}],
         "parent": None, "standard": {"number": "HPU-75-A", "title": "HPU-75 standard A"},
         "documents": [{"document": "doc_" + "02" * 16, "revision": "rev_" + "03" * 16, "source": "unit",
                        "basis": "verified"},
                       {"document": "doc_" + "08" * 16, "revision": "rev_" + "09" * 16, "source": "standard",
                        "basis": "declared"},
                       {"document": "doc_" + "0a" * 16, "revision": "", "source": "unit", "basis": "declared"}],
         "components": [{"position": "P1", "part": "", "number": "PMP-10", "asset": pump, "serial": "", "lot": "",
                         "since": "2026-03-18", "basis": "reported"},
                        {"position": "M1", "part": "", "number": "MTR-7K5", "asset": "", "serial": "M-998877",
                         "lot": "", "since": "", "basis": "declared"}],
         "milestones": {"built": "2026-03-18", "commissioned": ""},
         "history": [{"n": 1, "type": "unit.registered", "summary": "registered (serial NH-26-0001)", "effective": "",
                      "time": "2026-11-06T10:00:00+00:00", "actor": "Dana Whitfield", "basis": "legacy",
                      "voided": False},
                     {"n": 2, "type": "note", "summary": "wrong unit", "effective": "", "time": "2026-11-06T10:01:00+00:00",
                      "actor": "Dana Whitfield", "basis": "declared", "voided": True}],
         "changes": [{"change": "eco_" + "0a" * 16, "number": "ECO-0042", "title": "Thicker frame gussets",
                      "kind": "retrofit-required", "required": True, "state": "scheduled", "since": "2026-11-20",
                      "documents": [{"number": "FRM-200", "from": "A", "to": "B"}]},
                     {"change": "eco_" + "0b" * 16, "number": "ECO-0040", "title": "Quieter pump mount",
                      "kind": "retrofit-optional", "required": False, "state": "declined", "since": "2026-10-02",
                      "documents": []}],
         "notes": "Line 2", "source": "revisionworx"},
        {"id": pump, "aliases": [], "label": "GP-4471", "class": "component", "name": "", "model": "PMP-10",
         "part": "", "project": "", "customer": "", "site": "", "location": "", "status": "built",
         "identifiers": [{"scheme": "serial", "issuer": "Hydrix", "value": "GP-4471", "active": True}],
         "parent": {"asset": hpu, "position": "P1"}, "standard": None, "documents": [], "components": [],
         "milestones": {}, "history": [], "changes": [], "notes": "", "source": "revisionworx"},
        {"id": row, "aliases": [], "label": "HPU-0002", "class": "product", "name": "Unit 2", "model": "HPU-75",
         "part": "pn:hpu-75", "project": "prj_" + "01" * 16, "customer": "", "site": "", "location": "Bayside",
         "status": "", "identifiers": [{"scheme": "tag", "issuer": "", "value": "HPU-0002", "active": True}],
         "parent": None, "standard": None,
         "documents": [{"document": "doc_" + "02" * 16, "revision": "rev_" + "04" * 16, "source": "register",
                        "basis": "legacy"}],
         "components": [], "milestones": {"built": "2026-06-20"}, "history": [], "changes": [], "notes": "",
         "source": "AST-HPU-75 rev A"}]
    cat_mod.check_catalog(c)
    return c


def catalog_vectors() -> dict:
    """Catalogs both implementations accept (with the version 2 view of their assets) and refuse."""
    import copy
    from fieldworx_bridge import catalog as cat_mod
    v1, v2 = sample_catalog(), sample_catalog_v2()
    accept = [{"name": n, "catalog": c, "assets": cat_mod.assets_view(c)} for n, c in
              (("version 1 asset read as version 2", v1), ("version 2 units and a register row", v2))]

    def bad(name: str, fn) -> dict:
        c = copy.deepcopy(v2)
        fn(c)
        try:
            cat_mod.check_catalog(c)
        except cat_mod.CatalogError:
            return {"name": name, "catalog": c}
        raise AssertionError(f"catalog vector {name!r} was accepted")

    a = lambda c, i: c["assets"][i]  # noqa: E731
    refuse = [
        bad("a newer version", lambda c: c.update(version=3)),
        bad("an id that isn't a unit or asset id", lambda c: a(c, 0).update(id="dev_" + "0c" * 16)),
        bad("an alias that isn't an asset register id", lambda c: a(c, 0).update(aliases=["unt_" + "0f" * 16])),
        bad("aliases out of order", lambda c: a(c, 0).update(aliases=["ast_" + "ff" * 16, "ast_" + "0e" * 16])),
        bad("an alias that is another asset's id", lambda c: a(c, 0).update(aliases=["ast_" + "05" * 16])),
        bad("a revision of another document", lambda c: a(c, 0)["documents"][1].update(revision="rev_" + "03" * 16)),
        bad("a document that isn't there", lambda c: a(c, 0)["documents"][2].update(document="doc_" + "77" * 16)),
        bad("a document twice", lambda c: a(c, 0)["documents"].append(dict(a(c, 0)["documents"][1]))),
        bad("a component asset that isn't there", lambda c: a(c, 0)["components"][0].update(asset="unt_" + "77" * 16)),
        bad("a component position twice", lambda c: a(c, 0)["components"][1].update(position="P1")),
        bad("a part that isn't text", lambda c: a(c, 2).update(part=None)),
        bad("fitted inside itself", lambda c: a(c, 0).update(parent={"asset": "unt_" + "0d" * 16, "position": "X"})),
        bad("an unknown status", lambda c: a(c, 0).update(status="lost")),
        bad("a FieldWorx id as an identifier", lambda c: a(c, 0)["identifiers"][0].update(scheme="fieldworx")),
        bad("an identifier without a value", lambda c: a(c, 0)["identifiers"][0].update(value="")),
        bad("history numbers that don't increase", lambda c: a(c, 0)["history"][1].update(n=1)),
        bad("an unknown milestone", lambda c: a(c, 0)["milestones"].update(delivered="2026-04-01")),
        bad("a version 1 asset in a version 2 catalog", lambda c: c.update(assets=sample_catalog()["assets"])),
        bad("a missing key", lambda c: a(c, 1).pop("site")),
        bad("an unknown change state", lambda c: a(c, 0)["changes"][0].update(state="done")),
        bad("an unknown change kind", lambda c: a(c, 0)["changes"][0].update(kind="recall")),
        bad("required that isn't true or false", lambda c: a(c, 0)["changes"][0].update(required="yes")),
        bad("a change twice", lambda c: a(c, 0)["changes"].append(dict(a(c, 0)["changes"][0]))),
        bad("a change without its id", lambda c: a(c, 0)["changes"][1].update(change="")),
        bad("a change document with an unknown key", lambda c: a(c, 0)["changes"][0]["documents"][0].update(rev="B")),
    ]
    return {"accept": accept, "refuse": refuse}


#: The sample archives: a version 1 package with field records, a field log, and a version 2 package of units.
ARCHIVES = ("sample.fieldworx", "sample.fieldlog", "units.fieldworx")


def write_archives(force: bool) -> dict:
    from fieldworx_bridge import archive
    pkg, flg = OUT / "sample.fieldworx", OUT / "sample.fieldlog"
    scen = inspection_scenarios()[0]
    evs = [E.from_bytes(r.encode("utf-8")) for r in scen["events"]]
    if force or not pkg.exists():
        archive.write(pkg, "package", archive_id="pkg_" + "06" * 16, title="Sample package", created=t(30),
                      created_by={"user": "vectors", "tool": "make_vectors"}, source={"system": "revisionworx"},
                      series="s" * 32, catalog=sample_catalog(), events=evs,
                      objects=[archive.ObjectSource.from_bytes(PDF, "application/pdf")],
                      notices=["Sample only."], overwrite=True)
    if force or not flg.exists():
        archive.write(flg, "fieldlog", archive_id="flg_" + "07" * 16, title="Sample field log", created=t(31),
                      created_by={"device": DEV_A, "user": "Alex Morgan"}, events=evs,
                      objects=[archive.ObjectSource.from_bytes(JPEG, "image/jpeg")], overwrite=True)
    units = OUT / "units.fieldworx"
    if force or not units.exists():
        archive.write(units, "package", archive_id="pkg_" + "0f" * 16, title="Sample units", created=t(32),
                      created_by={"user": "vectors", "tool": "make_vectors"}, source={"system": "revisionworx"},
                      series="u" * 32, catalog=sample_catalog_v2(), events=[],
                      objects=[archive.ObjectSource.from_bytes(PDF, "application/pdf")],
                      notices=["Sample only."], overwrite=True)
    return _archives_summary()


def write_all(check: bool, force_archives: bool = False) -> int:
    OUT.mkdir(exist_ok=True)
    files = {
        "fxjson.json": fxjson_vectors(), "digests.json": digest_vectors(), "envelopes.json": envelope_vectors(),
        "fieldlog.json": fieldlog_scenarios(), "inspections.json": inspection_scenarios(),
        "templates.json": template_vectors(), "decimals.json": decimal_vectors(), "catalogs.json": catalog_vectors(),
        "archives.json": write_archives(force_archives) if not check else _archives_summary(),
    }
    stale = []
    for name, data in files.items():
        text = json.dumps(data, indent=1, ensure_ascii=False, sort_keys=True) + "\n"
        path = OUT / name
        if check:
            if not path.exists() or path.read_text(encoding="utf-8") != text:
                stale.append(name)
        else:
            path.write_text(text, encoding="utf-8", newline="\n")
    if stale:
        print("out of date: " + ", ".join(stale) + " (run python spec/make_vectors.py)")
        return 1
    return 0


def _archives_summary() -> dict:
    from fieldworx_bridge import archive
    out = {}
    for name in ARCHIVES:
        with archive.read(OUT / name) as a:
            out[name] = {"digest": a.digest, "kind": a.kind, "id": a.id, "events": [e.id for e in a.events],
                         "objects": sorted(a.objects),
                         "catalog_digest": fxjson.digest("catalog/v1", a.catalog) if a.catalog else ""}
    return out


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--force-archives", action="store_true", help="rewrite the sample archives too")
    args = ap.parse_args()
    sys.exit(write_all(args.check, args.force_archives))
