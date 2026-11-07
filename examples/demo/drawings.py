# SPDX-License-Identifier: GPL-3.0-or-later
"""Demo engineering drawings as small, deterministic vector PDFs (standard library only).

These are invented drawings for the FieldWorx demo: the hydraulic power unit HPU-75 that OpenMeridian's sample company
(Northline Hydraulics) builds. They look like real A3 drawings (border, zones, title block, revision table, views,
dimensions, a parts list) and their text can be searched, which is what the phone's viewer needs to be tried out.
"""
from __future__ import annotations

import math

MM = 72 / 25.4
A3 = (420, 297)


def _esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


class Page:
    def __init__(self, w_mm: float, h_mm: float):
        self.w, self.h = w_mm, h_mm
        self.ops: list[str] = []

    def p(self, x, y):
        return f"{x * MM:.2f} {y * MM:.2f}"

    def width(self, mm: float):
        self.ops.append(f"{mm * MM:.2f} w")

    def gray(self, g: float):
        self.ops.append(f"{g:.2f} G {g:.2f} g")

    def line(self, x1, y1, x2, y2):
        self.ops.append(f"{self.p(x1, y1)} m {self.p(x2, y2)} l S")

    def poly(self, pts, close=False, fill=False):
        s = f"{self.p(*pts[0])} m " + " ".join(f"{self.p(*q)} l" for q in pts[1:])
        self.ops.append(s + (" h f" if fill else " h S" if close else " S"))

    def rect(self, x, y, w, h, fill=False):
        self.ops.append(f"{x * MM:.2f} {y * MM:.2f} {w * MM:.2f} {h * MM:.2f} re {'f' if fill else 'S'}")

    def circle(self, cx, cy, r):
        k = 0.5523 * r
        pts = [(cx + r, cy), (cx + r, cy + k, cx + k, cy + r, cx, cy + r), (cx - k, cy + r, cx - r, cy + k, cx - r, cy),
               (cx - r, cy - k, cx - k, cy - r, cx, cy - r), (cx + k, cy - r, cx + r, cy - k, cx + r, cy)]
        s = f"{self.p(*pts[0])} m "
        for seg in pts[1:]:
            s += " ".join(self.p(seg[i], seg[i + 1]) for i in range(0, 6, 2)) + " c "
        self.ops.append(s + "S")

    def dashed(self, on: bool):
        self.ops.append("[4 2] 0 d" if on else "[] 0 d")

    def text(self, x, y, s: str, size=3.0, bold=False, align="left"):
        pt = size * MM
        w = len(s) * pt * (0.56 if bold else 0.52)
        dx = {"left": 0, "center": -w / 2, "right": -w}[align]
        font = "F2" if bold else "F1"
        self.ops.append(f"BT /{font} {pt:.2f} Tf {x * MM + dx:.2f} {y * MM:.2f} Td ({_esc(s)}) Tj ET")

    def arrow(self, x, y, ang, size=3.0):
        a1, a2 = ang + math.radians(160), ang - math.radians(160)
        self.poly([(x, y), (x + size * math.cos(a1), y + size * math.sin(a1)),
                   (x + size * math.cos(a2), y + size * math.sin(a2))], fill=True)

    def dim_h(self, x1, x2, y_obj, y_dim, label):
        self.width(0.18)
        self.line(x1, y_obj, x1, y_dim + (1.5 if y_dim > y_obj else -1.5))
        self.line(x2, y_obj, x2, y_dim + (1.5 if y_dim > y_obj else -1.5))
        self.line(x1, y_dim, x2, y_dim)
        self.arrow(x1, y_dim, math.pi)
        self.arrow(x2, y_dim, 0)
        self.text((x1 + x2) / 2, y_dim + 1.2, label, 3.0, align="center")

    def dim_v(self, y1, y2, x_obj, x_dim, label):
        self.width(0.18)
        self.line(x_obj, y1, x_dim + (1.5 if x_dim > x_obj else -1.5), y1)
        self.line(x_obj, y2, x_dim + (1.5 if x_dim > x_obj else -1.5), y2)
        self.line(x_dim, y1, x_dim, y2)
        self.arrow(x_dim, y1, -math.pi / 2)
        self.arrow(x_dim, y2, math.pi / 2)
        self.text(x_dim - 1.2, (y1 + y2) / 2, label, 3.0, align="right")

    def balloon(self, x, y, n: str, tx, ty):
        self.width(0.18)
        self.line(x, y, tx, ty)
        self.ops.append(f"{self.p(tx, ty)} m")
        self.circle(x, y, 3.2)
        self.text(x, y - 1.1, n, 3.0, bold=True, align="center")


def frame_border(pg: Page, title: str, number: str, rev: str, scale: str, revisions: list[tuple[str, str, str, str]],
                 material: str = "", company: str = "Northline Hydraulics"):
    w, h = pg.w, pg.h
    pg.width(0.7)
    pg.rect(10, 10, w - 20, h - 20)
    pg.width(0.25)
    pg.rect(5, 5, w - 10, h - 10)
    # zones
    cols, rows = 8, 6
    for i in range(1, cols):
        x = 10 + (w - 20) * i / cols
        pg.line(x, 5, x, 10), pg.line(x, h - 10, x, h - 5)
    for i in range(cols):
        x = 10 + (w - 20) * (i + 0.5) / cols
        pg.text(x, 6.6, str(cols - i), 2.5, align="center"), pg.text(x, h - 8.4, str(cols - i), 2.5, align="center")
    for j in range(1, rows):
        y = 10 + (h - 20) * j / rows
        pg.line(5, y, 10, y), pg.line(w - 10, y, w - 5, y)
    for j in range(rows):
        y = 10 + (h - 20) * (j + 0.5) / rows
        z = "ABCDEF"[rows - 1 - j]
        pg.text(7.5, y - 1, z, 2.5, align="center"), pg.text(w - 7.5, y - 1, z, 2.5, align="center")
    # title block, bottom right
    tx, ty, tw, th = w - 10 - 180, 10, 180, 50
    pg.width(0.5)
    pg.rect(tx, ty, tw, th)
    pg.width(0.25)
    for y in (ty + 10, ty + 20, ty + 30, ty + 40):
        pg.line(tx, y, tx + tw, y)
    pg.line(tx + 110, ty, tx + 110, ty + 30)
    pg.line(tx + 145, ty, tx + 145, ty + 20)
    pg.text(tx + 3, ty + 43, company, 4.5, bold=True)
    pg.text(tx + 3, ty + 33, title, 4.2, bold=True)
    pg.text(tx + 3, ty + 26.5, "DRAWING NUMBER", 2.0)
    pg.text(tx + 3, ty + 21.5, number, 4.0, bold=True)
    pg.text(tx + 113, ty + 26.5, "MATERIAL", 2.0)
    pg.text(tx + 113, ty + 21.5, material or "-", 2.8)
    pg.text(tx + 3, ty + 16.5, "DRAWN  A. MORGAN   CHECKED  J. LEE   APPROVED  P. GRAY", 2.3)
    pg.text(tx + 3, ty + 6.5, "DIMENSIONS IN MM   TOLERANCES UNLESS STATED +/-0.5   THIRD ANGLE", 2.3)
    pg.text(tx + 113, ty + 16.5, "SCALE", 2.0), pg.text(tx + 113, ty + 11.5, scale, 3.2, bold=True)
    pg.text(tx + 148, ty + 16.5, "REV", 2.0), pg.text(tx + 148, ty + 11, rev, 5.0, bold=True)
    pg.text(tx + 113, ty + 6.5, "SIZE A3", 2.3), pg.text(tx + 148, ty + 6.5, "SHEET 1/1", 2.3)
    # revision table, top right
    rx, ry, rw = w - 10 - 150, h - 10, 150
    pg.width(0.35)
    rows_ = [("REV", "DESCRIPTION", "DATE", "BY")] + revisions
    for i, (a, b, c, d) in enumerate(rows_):
        y = ry - 6 * (i + 1)
        pg.rect(rx, y, rw, 6)
        pg.text(rx + 2, y + 2, a, 2.6, bold=i == 0)
        pg.text(rx + 12, y + 2, b, 2.6, bold=i == 0)
        pg.text(rx + 112, y + 2, c, 2.6, bold=i == 0)
        pg.text(rx + 136, y + 2, d, 2.6, bold=i == 0)
    pg.line(rx + 10, ry - 6 * len(rows_), rx + 10, ry)
    pg.line(rx + 110, ry - 6 * len(rows_), rx + 110, ry)
    pg.line(rx + 134, ry - 6 * len(rows_), rx + 134, ry)


def frame_drawing(rev: str) -> bytes:
    """FRM-200 Skid frame, welded. Rev B moves the pump mount holes and adds lifting lugs."""
    pg = Page(*A3)
    revisions = [("A", "First issue", "2026-02-10", "AM")]
    if rev == "B":
        revisions.append(("B", "Pump mount holes moved 25 mm; lifting lugs added", "2026-06-02", "AM"))
    frame_border(pg, "SKID FRAME, WELDED", "FRM-200", rev, "1:10", revisions, material="S355 RHS 100x50x5")
    # top view: 1200 x 800 at 1:10
    ox, oy, W, H = 40, 150, 120, 80
    pg.text(ox, oy + H + 12, "TOP VIEW", 3.5, bold=True)
    pg.width(0.5)
    pg.rect(ox, oy, W, H)
    pg.rect(ox + 5, oy + 5, W - 10, H - 10)
    for x in (ox + 40, ox + 80):
        pg.line(x - 2.5, oy + 5, x - 2.5, oy + H - 5), pg.line(x + 2.5, oy + 5, x + 2.5, oy + H - 5)
    shift = 2.5 if rev == "B" else 0
    pg.width(0.3)
    for (hx, hy) in ((ox + 25 + shift, oy + 25), (ox + 25 + shift, oy + 55), (ox + 55 + shift, oy + 25),
                     (ox + 55 + shift, oy + 55)):
        pg.circle(hx, hy, 0.9)
    for (hx, hy) in ((ox + 95, oy + 30), (ox + 95, oy + 50), (ox + 110, oy + 30), (ox + 110, oy + 50)):
        pg.circle(hx, hy, 0.9)
    pg.dim_h(ox, ox + W, oy, oy - 12, "1200")
    pg.dim_v(oy, oy + H, ox, ox - 12, "800")
    pg.dim_h(ox, ox + 25 + shift, oy + 25, oy - 5, f"{250 + int(shift * 10)}")
    pg.text(ox + 25 + shift, oy + 63, "4x M10 PUMP MOUNT", 2.5)
    pg.text(ox + 90, oy + 63, "4x M10 MOTOR", 2.5)
    # front view
    fx, fy = 40, 90
    pg.text(fx, fy + 22, "FRONT VIEW", 3.5, bold=True)
    pg.width(0.5)
    pg.rect(fx, fy, W, 10)
    pg.dashed(True), pg.width(0.2)
    pg.line(fx, fy + 5, fx + W, fy + 5)
    pg.dashed(False)
    pg.dim_v(fy, fy + 10, fx + W, fx + W + 10, "100")
    if rev == "B":
        pg.width(0.5)
        for lx in (fx + 8, fx + W - 14):
            pg.poly([(lx, fy + 10), (lx, fy + 16), (lx + 6, fy + 16), (lx + 6, fy + 10)])
            pg.circle(lx + 3, fy + 13.5, 1.0)
        pg.text(fx + W / 2, fy + 18, "2x LIFTING LUG LUG-20 (REV B)", 2.5, align="center")
    # cut list
    cx, cy = 200, 150
    pg.text(cx, cy + 62, "CUT LIST", 3.5, bold=True)
    rows = [("ITEM", "PART NUMBER", "DESCRIPTION", "QTY"), ("1", "RHS-100-50", "RHS 100x50x5, 1200 LG", "2"),
            ("2", "RHS-100-50", "RHS 100x50x5, 700 LG", "4"), ("3", "PLT-10", "PLATE 10 THK, 150x150", "4")]
    if rev == "B":
        rows.append(("4", "LUG-20", "LIFTING LUG 20 THK", "2"))
    for i, r in enumerate(rows):
        y = cy + 52 - 7 * i
        pg.width(0.3)
        pg.rect(cx, y, 150, 7)
        for k, (off, s) in enumerate(zip((2, 16, 52, 138), r)):
            pg.text(cx + off, y + 2.3, s, 2.8, bold=i == 0)
    pg.text(cx, 110, "NOTES", 3.5, bold=True)
    notes = ["1. WELD ALL ROUND, 6 MM FILLET UNLESS STATED.", "2. REMOVE ALL SHARP EDGES AND WELD SPATTER.",
             "3. SHOT BLAST AND PAINT RAL 5010 GENTIAN BLUE.", "4. CHECK DIAGONALS AFTER WELDING: DIFFERENCE 3 MM MAX."]
    for i, n in enumerate(notes):
        pg.text(cx, 103 - 6 * i, n, 2.8)
    return build_pdf([pg], f"FRM-200 rev {rev} Skid frame, welded")


def ga_drawing() -> bytes:
    """HPU-75 general arrangement with its parts list."""
    pg = Page(*A3)
    frame_border(pg, "HYDRAULIC POWER UNIT 7.5 KW - GENERAL ARRANGEMENT", "HPU-75-GA", "A", "1:10",
                 [("A", "First issue", "2026-02-24", "AM")])
    ox, oy = 40, 120
    pg.text(ox, oy + 105, "FRONT VIEW", 3.5, bold=True)
    pg.width(0.5)
    pg.rect(ox, oy, 120, 10)                  # frame
    pg.rect(ox + 5, oy + 10, 60, 55)           # tank
    pg.rect(ox + 75, oy + 10, 40, 22)          # motor
    pg.rect(ox + 66, oy + 14, 9, 14)           # pump
    pg.rect(ox + 15, oy + 65, 40, 12)          # manifold
    pg.width(0.3)
    pg.circle(ox + 95, oy + 21, 7)
    pg.balloon(ox + 30, oy + 95, "1", ox + 35, oy + 72)
    pg.balloon(ox + 140, oy + 70, "2", ox + 110, oy + 25)
    pg.balloon(ox + 75, oy + 60, "3", ox + 70, oy + 22)
    pg.balloon(ox - 8, oy + 40, "4", ox + 5, oy + 40)
    pg.balloon(ox + 60, oy - 15, "5", ox + 60, oy + 5)
    pg.balloon(ox + 100, oy + 85, "6", ox + 55, oy + 72)
    pg.dim_h(ox, ox + 120, oy, oy - 25, "1200")
    pg.dim_v(oy, oy + 77, ox + 120, ox + 135, "770")
    cx, cy = 200, 160
    pg.text(cx, cy + 62, "PARTS LIST", 3.5, bold=True)
    rows = [("ITEM", "PART NUMBER", "DESCRIPTION", "QTY"), ("1", "MAN-02", "VALVE MANIFOLD ASSEMBLY", "1"),
            ("2", "MTR-7K5", "ELECTRIC MOTOR 7.5 KW", "1"), ("3", "PMP-10", "GEAR PUMP 10 CC/REV", "1"),
            ("4", "TNK-100", "RESERVOIR 100 L", "1"), ("5", "FRM-200", "SKID FRAME, WELDED", "1"),
            ("6", "HSE-08", "HOSE KIT -08", "2"), ("7", "PNL-24", "CONTROL PANEL 24 V DC", "1")]
    for i, r in enumerate(rows):
        y = cy + 52 - 7 * i
        pg.width(0.3)
        pg.rect(cx, y, 150, 7)
        for off, s in zip((2, 16, 52, 138), r):
            pg.text(cx + off, y + 2.3, s, 2.8, bold=i == 0)
    pg.text(cx, 95, "NOTES", 3.5, bold=True)
    for i, n in enumerate(["1. FILL RESERVOIR WITH ISO VG 46 HYDRAULIC OIL BEFORE START-UP.",
                           "2. RELIEF VALVE SET TO 160 BAR AT FACTORY. SEE SCH-HPU-75.",
                           "3. CHECK MOTOR ROTATION BEFORE RUNNING THE PUMP UNDER LOAD.",
                           "4. INSPECT TO ITP-HPU-75."]):
        pg.text(cx, 88 - 6 * i, n, 2.8)
    return build_pdf([pg], "HPU-75-GA rev A General arrangement")


def build_pdf(pages: list[Page], title: str) -> bytes:
    objs: list[bytes] = []
    kids = []
    n_fixed = 4
    for i, pg in enumerate(pages):
        kids.append(f"{n_fixed + 1 + 2 * i} 0 R")
    objs.append(b"<< /Type /Catalog /Pages 2 0 R >>")
    objs.append(f"<< /Type /Pages /Kids [{' '.join(kids)}] /Count {len(pages)} >>".encode())
    objs.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    objs.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>")
    for i, pg in enumerate(pages):
        content = ("0 G 0 g 1 J 1 j\n" + "\n".join(pg.ops)).encode("latin-1")
        objs.append((f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {pg.w * MM:.2f} {pg.h * MM:.2f}] "
                     f"/Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents {n_fixed + 2 + 2 * i} 0 R >>").encode())
        objs.append(f"<< /Length {len(content)} >>\nstream\n".encode() + content + b"\nendstream")
    info_n = len(objs) + 1
    objs.append(f"<< /Title ({_esc(title)}) /Producer (FieldWorx demo) >>".encode("latin-1"))
    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for n, body in enumerate(objs, start=1):
        offsets.append(len(out))
        out += f"{n} 0 obj\n".encode() + body + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode()
    for off in offsets:
        out += f"{off:010d} 00000 n \n".encode()
    out += f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R /Info {info_n} 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    return bytes(out)
