# SPDX-License-Identifier: GPL-3.0-or-later
"""Label sheets: FieldWorx labels (docs/PROTOCOL.md section 7) for what a package holds, as a PDF to print on sheets of
sticky labels or on a label printer. Standard library only: the QR codes come from fwx_label.py, and the PDF is written
here with the Helvetica every PDF reader has, so nothing is embedded or downloaded.

A label says only what doesn't change: what it is, its number, a description, and the code in its QR code written out
so it can be typed. Nothing that changes (a revision's state, a unit's status, where it is or who owns it) is printed;
the phone says that when the label is scanned. Text the built-in font can't show (it covers Western European letters)
prints as "?"; the QR code always holds the exact text.
"""
from __future__ import annotations

import zlib
from dataclasses import dataclass
from typing import Iterable

from .catalog import assets_view
from .fwx_label import encode, label_code

MM = 72 / 25.4                       # points per millimetre
LEVEL = "Q"                          # a quarter of a label's QR code can be dirty or scratched and it still reads
EDGE = 1.0                           # mm of white between a label's edge and its QR code's quiet zone
PAD = 3.0                            # mm of white around the text: keeps it clear of an edge the printer can't reach


class LabelError(ValueError):
    """Nothing was written: the request can't be met as asked."""


@dataclass(frozen=True)
class Layout:
    name: str
    description: str
    page: tuple[float, float]        # width, height in mm
    label: tuple[float, float]       # width, height in mm
    columns: int
    rows: int
    first: tuple[float, float]       # the first label's top-left corner, in mm from the page's top-left corner
    pitch: tuple[float, float]       # mm from one label's top-left corner to the next one's, across and down

    @property
    def per_page(self) -> int:
        return self.columns * self.rows


# Proposed sheets; which ones the family supports is the Director's decision (a gate for phase 3). Each is a common stock:
# the geometry is the label maker's published one, so a test print on plain paper lines up with the sheet.
LAYOUTS = {lay.name: lay for lay in (
    Layout("a4-24", "A4, 24 labels of 70 x 37 mm (3 across, 8 down)", (210.0, 297.0), (70.0, 37.0), 3, 8, (0.0, 0.5),
           (70.0, 37.0)),
    Layout("letter-30", "US Letter, 30 labels of 2-5/8 x 1 in (3 across, 10 down)", (215.9, 279.4), (66.675, 25.4), 3, 10,
           (4.7625, 12.7), (69.85, 25.4)),
    Layout("roll-50x25", "label printer, one 50 x 25 mm label per page", (50.0, 25.0), (50.0, 25.0), 1, 1, (0.0, 0.0),
           (50.0, 25.0)),
)}
DEFAULT_LAYOUT = "a4-24"


@dataclass(frozen=True)
class Label:
    kind: str                        # A, P, D, R or J
    code: str                        # what follows FWX:<kind>:
    heading: str                     # what it is, printed small above the title
    title: str                       # its number or tag, printed large
    detail: str = ""                 # a description

    @property
    def text(self) -> str:
        """What the QR code holds."""
        return label_code(self.kind, self.code)


# ----------------------------------------------------------------------------------------------- choosing labels
KINDS = ("assets", "parts", "documents", "revisions", "projects")


def _norm(s: str) -> str:
    return " ".join(s.split()).casefold()


def _asset_label(a: dict) -> Label:
    unit = a["id"].startswith("unt_")
    code = a["id"] if unit else a["label"]   # a unit's permanent label holds its id; a register row's, its tag or serial
    title = a["label"] or a["name"] or code
    detail = " · ".join(x for x in (a["name"] if a["name"] != title else "", a["model"]) if x)
    return Label("A", code, "Unit" if unit else "Asset", title, detail)


def _asset_names(a: dict) -> set[str]:
    names = {a["id"], a["label"], *a["aliases"]}
    names.update(i["value"] for i in a["identifiers"] if i["active"])
    return {_norm(n) for n in names if n}


def _released(d: dict) -> dict | None:
    return next((r for r in d["revisions"] if r["id"] == d["released"]), None)


def choose(c: dict, kinds: Iterable[str] = ("assets",), only: Iterable[str] = ()) -> tuple[list[Label], list[str]]:
    """The labels for a checked catalog: one for each thing of the kinds asked for, in the catalog's order, or only for
    the things ``only`` names, in that order. A name that matches nothing is an error, so a sheet never leaves a label
    out without saying so. Returns the labels and notices about what had to be left out."""
    kinds = list(kinds)
    for k in kinds:
        if k not in KINDS:
            raise LabelError(f"labels are for {', '.join(KINDS)}, not {k!r}")
    order = [k for k in KINDS if k in kinds]
    notices: list[str] = []
    found: dict[str, list[tuple[set[str], Label]]] = {k: [] for k in order}
    skipped = {"number": 0, "released": 0}
    if "assets" in found:
        found["assets"] = [(_asset_names(a), _asset_label(a)) for a in assets_view(c) if a["id"].startswith("unt_")
                           or a["label"]]
    if "parts" in found:
        for p in c["parts"]:
            if not p["number"]:
                skipped["number"] += 1
                continue
            found["parts"].append(({_norm(p["number"]), _norm(p["id"])},
                                   Label("P", p["number"], "Part", p["number"], p["description"])))
    for d in c["documents"] if "documents" in found or "revisions" in found else []:
        if not d["number"]:
            skipped["number"] += 1
            continue
        if "documents" in found:
            found["documents"].append(({_norm(d["number"]), _norm(d["id"])},
                                       Label("D", d["number"], "Document", d["number"], d["title"])))
        if "revisions" in found:
            rel = _released(d)
            for r in d["revisions"]:
                names = {_norm(f"{d['number']}@{r['label']}"), _norm(r["id"])}
                if r is rel:
                    names |= {_norm(d["number"]), _norm(d["id"])}
                if r is rel or only:
                    found["revisions"].append((names, Label("R", f"{d['number']}@{r['label']}", "Revision",
                                                            f"{d['number']} rev {r['label']}", d["title"])))
            if rel is None and not only:
                skipped["released"] += 1
    if "projects" in found:
        for j in c["projects"]:
            if not j["number"]:
                skipped["number"] += 1
                continue
            found["projects"].append(({_norm(j["number"]), _norm(j["id"])},
                                      Label("J", j["number"], "Project", j["number"], j["name"])))
    if skipped["number"]:
        notices.append(f"{skipped['number']} without a number left out: a label needs one")
    if skipped["released"]:
        notices.append(f"{skipped['released']} document(s) with no released revision in the package left out "
                       f"(name one as DOCUMENT@REVISION to print it)")
    only = [o for o in only if o.strip()]
    if not only:
        return [lab for k in order for _, lab in found[k]], notices
    out: list[Label] = []
    for name in only:
        hits = [lab for k in order for names, lab in found[k] if _norm(name) in names]
        unreleased = [d for d in c["documents"] if "revisions" in found and d["number"] and not d["released"]
                      and _norm(d["number"]) == _norm(name)]
        if not hits and unreleased:
            revs = ", ".join(f"{d['number']}@{r['label']}" for d in unreleased for r in d["revisions"])
            raise LabelError(f"{name} has no released revision in the package; name the one to print: {revs}")
        if not hits:
            what = " or ".join(k[:-1] for k in order)
            raise LabelError(f"{name}: no {what} in the package answers to that (another kind? --parts, --documents, "
                             f"--revisions, --projects)")
        out.extend(h for h in hits if h not in out)
    return out, notices


# ------------------------------------------------------------------------------------------------------- text
# Advance widths (1/1000 em) of Helvetica and Helvetica-Bold for the WinAnsiEncoding bytes 32 to 255, from Adobe's font
# metrics (the AFM files, which may be used, copied and distributed for any purpose).
_WIDTHS = {
    "F1": (278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, 556, 556, 556, 556, 556, 556,
           556, 556, 556, 556, 278, 278, 584, 584, 584, 556, 1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667,
           556, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556, 333, 556,
           556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, 556, 556, 333, 500, 278, 556, 500, 722,
           500, 500, 500, 334, 260, 334, 584, 350, 556, 350, 222, 556, 333, 1000, 556, 556, 333, 1000, 667, 333, 1000,
           350, 611, 350, 350, 222, 222, 333, 333, 350, 556, 1000, 333, 1000, 500, 333, 944, 350, 500, 667, 278, 333,
           556, 556, 556, 556, 260, 556, 333, 737, 370, 556, 584, 333, 737, 333, 400, 584, 333, 333, 333, 556, 537, 278,
           333, 333, 365, 556, 834, 834, 834, 611, 667, 667, 667, 667, 667, 667, 1000, 722, 667, 667, 667, 667, 278,
           278, 278, 278, 722, 722, 778, 778, 778, 778, 778, 584, 778, 722, 722, 722, 722, 667, 667, 611, 556, 556, 556,
           556, 556, 556, 889, 500, 556, 556, 556, 556, 278, 278, 278, 278, 556, 556, 556, 556, 556, 556, 556, 584, 611,
           556, 556, 556, 556, 500, 556, 500),
    "F2": (278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278, 556, 556, 556, 556, 556, 556,
           556, 556, 556, 556, 333, 333, 584, 584, 584, 611, 975, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722,
           611, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556, 333, 556,
           611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611, 611, 611, 389, 556, 333, 611, 556, 778,
           556, 556, 500, 389, 280, 389, 584, 350, 556, 350, 278, 556, 500, 1000, 556, 556, 333, 1000, 667, 333, 1000,
           350, 611, 350, 350, 278, 278, 500, 500, 350, 556, 1000, 333, 1000, 556, 333, 944, 350, 500, 667, 278, 333,
           556, 556, 556, 556, 280, 556, 333, 737, 370, 556, 584, 333, 737, 333, 400, 584, 333, 333, 333, 611, 556, 278,
           333, 333, 365, 556, 834, 834, 834, 611, 722, 722, 722, 722, 722, 722, 1000, 722, 667, 667, 667, 667, 278,
           278, 278, 278, 722, 722, 778, 778, 778, 778, 778, 584, 778, 722, 722, 722, 722, 667, 667, 611, 556, 556, 556,
           556, 556, 556, 889, 556, 556, 556, 556, 556, 278, 278, 278, 278, 611, 611, 611, 611, 611, 611, 611, 584, 611,
           611, 611, 611, 611, 556, 611, 556),
    "F3": (600,) * 224,
}
FONTS = {"F1": "Helvetica", "F2": "Helvetica-Bold", "F3": "Courier"}   # Courier for codes: 0, O, 1 and l differ
ELLIPSIS = "…"
_BREAK_AFTER = "-/_.@:"


def printable(text: str) -> bytes:
    """``text`` as the built-in fonts' bytes (Windows-1252): control characters become spaces, characters the fonts
    don't have become "?"."""
    clean = "".join(" " if ord(ch) < 32 or 127 <= ord(ch) < 160 else ch for ch in text)
    return clean.encode("cp1252", errors="replace")


def width(text: str, font: str, size: float) -> float:
    """How wide ``text`` prints, in points."""
    table = _WIDTHS[font]
    return sum(table[b - 32] for b in printable(text)) * size / 1000


def _wrap(text: str, font: str, size: float, room: float) -> list[str]:
    """``text`` in lines no wider than ``room`` points: at spaces where it can, inside a word where it must."""
    lines: list[str] = []
    line = ""
    for word in text.split():
        trial = f"{line} {word}" if line else word
        if width(trial, font, size) <= room:
            line = trial
            continue
        if line:
            lines.append(line)
        while len(word) > 1 and width(word, font, size) > room:
            cut = _cut(word, font, size, room)
            lines.append(word[:cut])
            word = word[cut:]
        line = word
    if line:
        lines.append(line)
    return lines


def _cut(word: str, font: str, size: float, room: float) -> int:
    """Where a word too long for a line breaks: after the last hyphen, slash, underscore, full stop, colon or @ that
    fits, unless that leaves a stub, else after the last character that fits (at least one)."""
    n = 1
    while n < len(word) and width(word[:n + 1], font, size) <= room:
        n += 1
    for i in range(n, n // 2, -1):
        if word[i - 1] in _BREAK_AFTER:
            return i
    return n


def fit_code(code: str, sizes: tuple[float, ...], room: float) -> tuple[float, list[str]]:
    """A code in Courier: on one line at the largest size that holds it, else halved onto two lines, else ``fit``."""
    for size in sizes:
        if width(code, "F3", size) <= room:
            return size, [code]
    half = (len(code) + 1) // 2
    for size in sizes:
        if max(width(code[:half], "F3", size), width(code[half:], "F3", size)) <= room:
            return size, [code[:half], code[half:]]
    return fit(code, "F3", sizes, room, 2)


def fit(text: str, font: str, sizes: tuple[float, ...], room: float, lines: int) -> tuple[float, list[str]]:
    """The largest of ``sizes`` (largest first) at which ``text`` fits on one line ``room`` points wide, else the
    smallest size on up to ``lines`` lines, the last ending in an ellipsis if the text still runs over."""
    for size in sizes:
        if width(text, font, size) <= room:
            return size, [text] if text.strip() else []
    size = sizes[-1]
    out = _wrap(text, font, size, room)
    if len(out) > lines:
        out = out[:lines]
        last = out[-1]
        while last and width(last + ELLIPSIS, font, size) > room:
            last = last[:-1]
        out[-1] = last.rstrip() + ELLIPSIS
    return size, out


# ------------------------------------------------------------------------------------------------------- drawing
def _n(v: float) -> str:
    s = f"{v:.3f}".rstrip("0").rstrip(".")
    return "0" if s in ("", "-0") else s


def _pdf_string(raw: bytes) -> str:
    out = []
    for b in raw:
        if b in (0x28, 0x29, 0x5C):
            out.append("\\" + chr(b))
        elif 32 <= b < 127:
            out.append(chr(b))
        else:
            out.append(f"\\{b:03o}")
    return "(" + "".join(out) + ")"


@dataclass(frozen=True)
class _Type:
    heading: float
    title: tuple[float, ...]
    detail: tuple[float, ...]
    detail_lines: int
    code: tuple[float, ...]


_LARGE = _Type(6.5, (11, 10, 9, 8), (7.5, 7, 6.5), 3, (6, 5.5, 5))
_SMALL = _Type(5.5, (9, 8.5, 8, 7.5, 7), (6.5, 6), 2, (5.5, 5, 4.5))


def _draw_label(lab: Label, x: float, top: float, w: float, h: float, page_h: float) -> list[str]:
    """PDF operators for one label whose top-left corner is ``x``, ``top`` mm from the page's top-left corner."""
    ops: list[str] = []
    m = encode(lab.text, LEVEL)
    side = min(h - 2 * EDGE, w * 0.55)              # the QR code with its quiet zone of 4 modules
    unit = side * MM / (len(m) + 8)
    qx = (x + EDGE) * MM + 4 * unit
    qtop = page_h - (top + (h - side) / 2) * MM - 4 * unit

    def edge_y(r: int) -> float:                     # rows share edges exactly, so no seams show between them
        return round(qtop - r * unit, 3)

    for r, row in enumerate(m):
        c = 0
        while c < len(row):
            if not row[c]:
                c += 1
                continue
            start = c
            while c < len(row) and row[c]:
                c += 1
            x0, x1 = round(qx + start * unit, 3), round(qx + c * unit, 3)
            y0, y1 = edge_y(r + 1), edge_y(r)
            ops.append(f"{_n(x0)} {_n(y0)} {_n(x1 - x0)} {_n(y1 - y0)} re")
    ops.append("f")

    t = _LARGE if h >= 30 else _SMALL
    tx = (x + EDGE + side) * MM
    room = (x + w - PAD) * MM - tx
    ceiling = page_h - (top + PAD) * MM
    floor = page_h - (top + h - PAD) * MM

    def text(font: str, size: float, line: str, baseline: float) -> None:
        ops.append(f"BT /{font} {_n(size)} Tf 1 0 0 1 {_n(tx)} {_n(baseline)} Tm {_pdf_string(printable(line))} Tj ET")

    y = ceiling
    y -= t.heading * 0.75
    text("F1", t.heading, lab.heading.upper(), y)
    title = lab.title or lab.code
    title_size, title_lines = fit(title, "F2", t.title, room, 2)
    for line in title_lines:
        y -= title_size * 1.15
        text("F2", title_size, line, y)
    code_lines: list[str] = []
    code_size = t.code[-1]
    if _norm(lab.code) != _norm(title):             # the code written out, for typing when a camera can't read it
        code_size, code_lines = fit_code(lab.code, t.code, room)
    code_top = floor + code_size * 0.2 + code_size * 1.15 * len(code_lines)
    for i, line in enumerate(code_lines):
        text("F3", code_size, line, floor + code_size * 0.2 + code_size * 1.15 * (len(code_lines) - 1 - i))
    if lab.detail:
        y -= 1.5
        for size in t.detail:
            fits = int((y - code_top - size * 0.3) // (size * 1.18))
            if fits < 1:
                continue
            size, lines = fit(lab.detail, "F1", (size,), room, min(fits, t.detail_lines))
            for line in lines:
                y -= size * 1.18
                text("F1", size, line, y)
            break
    return ops


def sheet(labels: list[Label], layout: Layout, *, skip: int = 0, title: str = "FieldWorx labels",
          producer: str = "fieldworx-bridge") -> tuple[bytes, int]:
    """The PDF of ``labels`` laid out on ``layout``'s sheets, left to right and top to bottom, after ``skip`` positions
    already used on the first sheet. Returns the PDF and its number of pages. The same labels give the same bytes."""
    if not labels:
        raise LabelError("no labels to print")
    if not 0 <= skip < layout.per_page:
        raise LabelError(f"the {layout.name} layout has {layout.per_page} position(s) a page: skip 0 to "
                         f"{layout.per_page - 1}")
    page_w, page_h = layout.page[0] * MM, layout.page[1] * MM
    pages: list[list[str]] = []
    for i, lab in enumerate(labels, start=skip):
        p, k = divmod(i, layout.per_page)
        while len(pages) <= p:
            pages.append(["0 g"])
        row, col = divmod(k, layout.columns)
        x = layout.first[0] + col * layout.pitch[0]
        top = layout.first[1] + row * layout.pitch[1]
        pages[p].extend(_draw_label(lab, x, top, layout.label[0], layout.label[1], page_h))
    return _pdf([("\n".join(ops) + "\n").encode("ascii") for ops in pages], (page_w, page_h), title, producer), len(pages)


def _pdf(contents: list[bytes], size: tuple[float, float], title: str, producer: str) -> bytes:
    """A PDF 1.4 file: catalog, page tree, the three fonts, document information, then a page and its content per
    page."""
    objects: list[bytes] = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"",                                                                    # the page tree, filled in below
        *(f"<< /Type /Font /Subtype /Type1 /BaseFont /{FONTS[f]} /Encoding /WinAnsiEncoding >>".encode("ascii")
          for f in ("F1", "F2", "F3")),
        f"<< /Title {_pdf_string(printable(title))} /Producer {_pdf_string(printable(producer))} >>".encode("ascii"),
    ]
    kids = []
    for content in contents:
        page_no = len(objects) + 1
        kids.append(f"{page_no} 0 R")
        objects.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {_n(size[0])} {_n(size[1])}] /Resources << /Font "
                       f"<< /F1 3 0 R /F2 4 0 R /F3 5 0 R >> >> /Contents {page_no + 1} 0 R >>".encode("ascii"))
        data = zlib.compress(content, 9)
        objects.append(f"<< /Length {len(data)} /Filter /FlateDecode >>\nstream\n".encode("ascii") + data
                       + b"\nendstream")
    objects[1] = f"<< /Type /Pages /Kids [{' '.join(kids)}] /Count {len(kids)} >>".encode("ascii")
    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for i, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n".encode("ascii") + body + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode("ascii")
    out += b"".join(f"{o:010d} 00000 n \n".encode("ascii") for o in offsets)
    out += (f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R /Info 6 0 R >>\nstartxref\n{xref}\n%%EOF\n"
            .encode("ascii"))
    return bytes(out)
