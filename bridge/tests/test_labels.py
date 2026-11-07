# SPDX-License-Identifier: GPL-3.0-or-later
"""Label sheets (fieldworx_bridge/labels.py, ``fieldworx-bridge labels``): which labels a package gives, and that every
label on every layout prints where the layout says, with text that fits, and reads back. The pages are rendered by
pdfium (pypdfium2) and read by zxing-cpp, the decoder the phone app uses; both are test-only (``bridge[dev]``)."""
from __future__ import annotations

import copy
import random
import re
from pathlib import Path

import numpy as np
import pypdfium2 as pdfium
import pytest
import zxingcpp

from fieldworx_bridge import archive, catalog as cat_mod, labels
from fieldworx_bridge.cli import main
from fieldworx_bridge.labels import Label, LabelError

VECTORS = Path(__file__).resolve().parents[2] / "spec" / "vectors"
UNITS = VECTORS / "units.fieldworx"
DPI = 300


@pytest.fixture(scope="module")
def units() -> dict:
    with archive.read(UNITS) as arc:
        return cat_mod.check_catalog(arc.catalog)


def texts(labs: list[Label]) -> list[str]:
    return [lab.text for lab in labs]


# ---------------------------------------------------------------------------------------------- which labels
def test_a_package_gives_a_label_for_each_unit_asset_part_document_revision_and_project(units):
    assert texts(labels.choose(units)[0]) == [
        "FWX:A:unt_" + "0c" * 16, "FWX:A:unt_" + "0d" * 16, "FWX:A:HPU-0002"], \
        "units carry their permanent id; an asset register row its tag"
    every, notices = labels.choose(units, labels.KINDS)
    assert texts(every) == [
        "FWX:A:unt_" + "0c" * 16, "FWX:A:unt_" + "0d" * 16, "FWX:A:HPU-0002",
        "FWX:P:HPU-75", "FWX:P:FRM-200",
        "FWX:D:FRM-200", "FWX:D:HPU-75-GA", "FWX:D:MAN-HPU-75",
        "FWX:R:FRM-200@B", "FWX:R:HPU-75-GA@A", "FWX:R:MAN-HPU-75@A",     # released revisions only: FRM-200 A is superseded
        "FWX:J:J-2001"]
    assert notices == []
    unit = every[0]
    assert (unit.heading, unit.title, unit.detail) == ("Unit", "NH-26-0001", "Hydraulic power unit · HPU-75")
    rev = every[8]
    assert (rev.heading, rev.title, rev.detail) == ("Revision", "FRM-200 rev B", "Skid frame")
    assert all("Northline" not in f"{lab.title} {lab.detail}" for lab in every), "labels never carry the customer"


def test_only_picks_by_any_name_in_the_order_given(units):
    picked, _ = labels.choose(units, ["assets"], [" gp-4471 ", "unt_" + "0c" * 16, "HPU-0002", "GP-4471"])
    assert texts(picked) == ["FWX:A:unt_" + "0d" * 16, "FWX:A:unt_" + "0c" * 16, "FWX:A:HPU-0002"], \
        "a serial, an id and a tag each find their unit; asking twice prints it once (use --copies for more)"
    picked, _ = labels.choose(units, ["revisions"], ["FRM-200@A", "frm-200", "HPU-75-GA"])
    assert texts(picked) == ["FWX:R:FRM-200@A", "FWX:R:FRM-200@B", "FWX:R:HPU-75-GA@A"], \
        "a named revision prints whatever its state (the phone says it is superseded); a document number means its " \
        "released revision"
    with pytest.raises(LabelError, match="PMP-10: no asset in the package"):
        labels.choose(units, ["assets"], ["PMP-10"])
    with pytest.raises(LabelError, match="FRM-200@C"):
        labels.choose(units, ["revisions"], ["FRM-200@C"])
    with pytest.raises(LabelError):
        labels.choose(units, ["tools"])


def test_what_cannot_be_labelled_is_said(units):
    c = copy.deepcopy(units)
    frm = next(d for d in c["documents"] if d["number"] == "FRM-200")
    frm["released"] = ""
    c["parts"][0]["number"] = ""
    picked, notices = labels.choose(c, ["parts", "revisions"])
    assert texts(picked) == ["FWX:P:FRM-200", "FWX:R:HPU-75-GA@A", "FWX:R:MAN-HPU-75@A"]
    assert notices == ["1 without a number left out: a label needs one",
                       "1 document(s) with no released revision in the package left out (name one as "
                       "DOCUMENT@REVISION to print it)"]
    assert texts(labels.choose(c, ["revisions"], ["FRM-200@B"])[0]) == ["FWX:R:FRM-200@B"]
    with pytest.raises(LabelError, match="FRM-200 has no released revision in the package; name the one to print: "
                                         "FRM-200@A, FRM-200@B"):
        labels.choose(c, ["revisions"], ["FRM-200"])


# --------------------------------------------------------------------------------------------- on the page
def render(data: bytes) -> list[np.ndarray]:
    pdf = pdfium.PdfDocument(data)
    return [pdf[i].render(scale=DPI / 72, grayscale=True).to_numpy() for i in range(len(pdf))]


def slot_box(layout: labels.Layout, k: int) -> tuple[float, float, float, float]:
    """Label position ``k`` on a page, in pixels: left, top, right, bottom."""
    row, col = divmod(k, layout.columns)
    px = DPI / 25.4
    x = (layout.first[0] + col * layout.pitch[0]) * px
    y = (layout.first[1] + row * layout.pitch[1]) * px
    return x, y, x + layout.label[0] * px, y + layout.label[1] * px


LONG = [Label("P", "PMP-10-SS-316L-FLANGED-DN50-PN40", "Part", "PMP-10-SS-316L-FLANGED-DN50-PN40",
              "Centrifugal pump, stainless steel 316L, flanged DN50 PN40, with mechanical seal and a 7.5 kW 400 V motor"),
        Label("D", "Füllstand-Ü/ø 3", "Document", "Füllstand-Ü/ø 3", "Füllstandsmessung — Ölbehälter „neu“ 配管"),
        Label("A", "unt_" + "ab12" * 8, "Unit", "", "")]


@pytest.mark.parametrize("name", sorted(labels.LAYOUTS))
def test_every_label_prints_in_its_place_and_reads_back(units, name):
    layout = labels.LAYOUTS[name]
    labs = labels.choose(units, labels.KINDS)[0] + LONG
    skip = 2 if layout.per_page > 1 else 0
    data, pages = labels.sheet(labs, layout, skip=skip)
    images = render(data)
    assert len(images) == pages == -(-(len(labs) + skip) // layout.per_page)
    px = DPI / 25.4
    for img in images:                                  # the page is the layout's paper (pdfium rounds up a pixel)
        assert abs(img.shape[0] - layout.page[1] * px) <= 1 and abs(img.shape[1] - layout.page[0] * px) <= 1
    for i, lab in enumerate(labs, start=skip):
        page, k = divmod(i, layout.per_page)
        left, top, right, bottom = slot_box(layout, k)
        crop = images[page][int(top):int(bottom), int(left):int(right)]
        found = zxingcpp.read_barcodes(crop, formats=zxingcpp.BarcodeFormat.QRCode)
        assert [f.bytes for f in found] == [lab.text.encode()], (name, i, lab.text)
        assert found[0].ec_level == layout.level
        p = found[0].position
        corners = [(c.x, c.y) for c in (p.top_left, p.top_right, p.bottom_left, p.bottom_right)]
        assert all(1.0 * px <= x and 1.0 * px <= y and y <= crop.shape[0] - px for x, y in corners), \
            "the code sits inside its label, clear of the edge"
    whole = zxingcpp.read_barcodes(images[0], formats=zxingcpp.BarcodeFormat.QRCode)
    assert len(whole) == min(len(labs), layout.per_page - skip), "nothing else on the page reads as a code"


def test_the_words_on_a_label(units):
    layout = labels.LAYOUTS["a4-24"]
    labs = labels.choose(units, ["assets", "revisions"])[0] + LONG
    pdf = pdfium.PdfDocument(labels.sheet(labs, layout)[0])
    page = pdf[0]
    text = page.get_textpage()
    h = layout.page[1] * labels.MM

    def words(k: int) -> str:
        row, col = divmod(k, layout.columns)
        x = (layout.first[0] + col * layout.pitch[0]) * labels.MM
        y = (layout.first[1] + row * layout.pitch[1]) * labels.MM
        found = text.get_text_bounded(x, h - y - layout.label[1] * labels.MM, x + layout.label[0] * labels.MM, h - y)
        return " ".join(found.split())

    assert words(0) == "UNIT NH-26-0001 unt_0c0c0c0c0c0c0c 0c0c0c0c0c0c0c0c0c Hydraulic power unit · HPU-75"
    assert words(2) == "ASSET HPU-0002 Unit 2 · HPU-75", "a tag is its own code: not printed twice"
    assert words(3) == "REVISION FRM-200 rev B FRM-200@B Skid frame", "nothing about whether it is still released"
    assert words(7) == "DOCUMENT Füllstand-Ü/ø 3 Füllstandsmessung — Ölbehälter „neu“ ??", \
        "letters the built-in font lacks print as ?, while the QR code holds them"
    assert "…" in words(6), "a description too long for the label ends in an ellipsis"


def test_text_fits_its_room():
    rng = random.Random(3)
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-/_ .ÄÖÜäöüßé"
    for _ in range(300):
        text = "".join(rng.choice(alphabet) for _ in range(rng.randint(1, 120)))
        room = rng.uniform(40, 120)
        for font in ("F1", "F2"):
            size, lines = labels.fit(text, font, (9, 8, 7), room, 2)
            assert size in (9, 8, 7) and 1 <= len(lines) <= 2
            assert all(labels.width(line, font, size) <= room for line in lines), (text, room, lines)
            if len(lines) == 1 and not lines[0].endswith(labels.ELLIPSIS):
                assert lines[0] == text
        size, lines = labels.fit_code(text.replace(" ", ""), (6, 5.5, 5), room)
        assert all(labels.width(line, "F3", size) <= room for line in lines)
    assert labels.fit("PMP-10-SS-316L-FLANGED-DN50-PN40", "F2", (8,), 110, 2)[1] == \
        ["PMP-10-SS-316L-FLANGED-", "DN50-PN40"], "a long number breaks after a hyphen"
    assert labels.fit_code("unt_" + "0d" * 16, (5,), 60)[1] == ["unt_0d0d0d0d0d0d0d", "0d0d0d0d0d0d0d0d0d"]


def test_the_pdf_is_well_formed_and_the_same_labels_give_the_same_bytes(units):
    labs = labels.choose(units, labels.KINDS)[0]
    data, pages = labels.sheet(labs, labels.LAYOUTS["roll-50x25"], title="FieldWorx labels: (HPU) \\ ü")
    assert data == labels.sheet(labs, labels.LAYOUTS["roll-50x25"], title="FieldWorx labels: (HPU) \\ ü")[0]
    assert data.startswith(b"%PDF-1.4\n") and data.endswith(b"%%EOF\n")
    start = int(re.search(rb"startxref\n(\d+)\n%%EOF\n$", data).group(1))
    table = data[start:].split(b"\n")
    assert table[0] == b"xref" and table[1].startswith(b"0 ")
    count = int(table[1].split()[1])
    assert table[2] == b"0000000000 65535 f "
    for n in range(1, count):
        entry = table[2 + n]
        assert len(entry) == 19 and entry.endswith(b" 00000 n "), "xref entries are 20 bytes with their end of line"
        assert data[int(entry[:10]):].startswith(f"{n} 0 obj\n".encode()), n
    assert count == 7 + 2 * pages
    for m in re.finditer(rb"<< /Length (\d+) /Filter /FlateDecode >>\nstream\n", data):
        end = m.end() + int(m.group(1))
        assert data[end:end + 10] == b"\nendstream"
    assert b"/Title (FieldWorx labels: \\(HPU\\) \\\\ \\374)" in data


def test_a_sheet_asks_for_sensible_positions(units):
    labs = labels.choose(units)[0]
    with pytest.raises(LabelError, match="skip 0 to 23"):
        labels.sheet(labs, labels.LAYOUTS["a4-24"], skip=24)
    with pytest.raises(LabelError, match="skip 0 to 0"):
        labels.sheet(labs, labels.LAYOUTS["roll-50x25"], skip=1)
    with pytest.raises(LabelError):
        labels.sheet([], labels.LAYOUTS["a4-24"])
    assert labels.sheet(labs * 9, labels.LAYOUTS["a4-24"], skip=23)[1] == 3, "27 labels after 23 used positions"


# ----------------------------------------------------------------------------------------------- the command
def test_the_labels_command(tmp_path, capsys):
    out = tmp_path / "labels.pdf"
    assert main(["labels", str(UNITS), "-o", str(out), "--parts", "--projects", "--copies", "2"]) == 0
    said = capsys.readouterr().out
    assert "6 label(s) on 1 sheet" in said and "actual size (100%)" in said
    found = zxingcpp.read_barcodes(render(out.read_bytes())[0], formats=zxingcpp.BarcodeFormat.QRCode)
    assert sorted(f.text for f in found) == sorted(["FWX:P:HPU-75", "FWX:P:FRM-200", "FWX:J:J-2001"] * 2)

    assert main(["labels", str(UNITS), "-o", str(out)]) == 2, "an existing file is never replaced unasked"
    assert "already exists" in capsys.readouterr().err
    assert main(["labels", str(UNITS), "-o", str(out), "--overwrite", "--layout", "roll-50x25"]) == 0
    assert "3 label(s) on 3 pages" in capsys.readouterr().out

    refused = tmp_path / "refused.pdf"
    for args in (["--only", "NO-SUCH-TAG"], ["--copies", "0"], ["--skip", "30"]):
        assert main(["labels", str(UNITS), "-o", str(refused), *args]) == 2, args
    assert main(["labels", str(VECTORS / "sample.fieldlog"), "-o", str(refused)]) == 2
    assert "is a field log" in capsys.readouterr().err
    damaged = tmp_path / "damaged.fieldworx"
    raw = bytearray(UNITS.read_bytes())
    raw[len(raw) // 2] ^= 0xFF
    damaged.write_bytes(bytes(raw))
    assert main(["labels", str(damaged), "-o", str(refused)]) == 2, "a damaged package is refused whole"
    assert not refused.exists(), "nothing is written when a request is refused"


def test_the_small_label_has_the_code_its_kind_and_its_number(units):
    layout = labels.LAYOUTS["roll-25x12"]
    labs = labels.choose(units, ["assets", "parts"])[0]
    pdf = pdfium.PdfDocument(labels.sheet(labs, layout)[0])
    assert len(pdf) == len(labs)
    assert " ".join(pdf[0].get_textpage().get_text_range().split()) == "UNIT NH-26-0001", \
        "no description and no code written out: the QR code holds it"
    assert " ".join(pdf[3].get_textpage().get_text_range().split()) == "PART HPU-75"
    assert layout.level == "M" and labels.LAYOUTS["roll-50x25"].level == labels.LEVEL == "Q"
    image = render(labels.sheet(labs[:1], layout)[0])[0]
    found = zxingcpp.read_barcodes(image, formats=zxingcpp.BarcodeFormat.QRCode)
    p = found[0].position
    side_mm = abs(p.top_right.x - p.top_left.x) / (DPI / 25.4)
    assert side_mm / 29 > 0.28, "a unit's code is 29 modules at level M, each big enough for a phone"
