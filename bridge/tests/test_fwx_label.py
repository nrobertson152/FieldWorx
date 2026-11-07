# SPDX-License-Identifier: GPL-3.0-or-later
"""The QR encoder that draws FieldWorx labels (fieldworx_bridge/fwx_label.py), checked against two programs that share
no code with it: python-qrcode must draw the same symbol bit for bit at every version, level and mask, and zxing-cpp,
the decoder inside the phone app (flutter_zxing), must read every code back. Both are test-only (``bridge[dev]``); the
bridge itself uses the standard library only."""
from __future__ import annotations

import random

import numpy as np
import pytest
import qrcode
import zxingcpp
from qrcode.util import MODE_8BIT_BYTE, QRData, lost_point

from fieldworx_bridge import fwx_label
from fieldworx_bridge.fwx_label import LEVELS, QRError, encode, label_code

EC = {"L": qrcode.constants.ERROR_CORRECT_L, "M": qrcode.constants.ERROR_CORRECT_M,
      "Q": qrcode.constants.ERROR_CORRECT_Q, "H": qrcode.constants.ERROR_CORRECT_H}
UNIT = "FWX:A:unt_" + "9f2c" * 8
SAMPLES = [UNIT, "FWX:P:PMP-10", "FWX:D:SCH-12", "FWX:R:SCH-12@B", "FWX:J:J-2001", "HPU-0001", "x",
           "FWX:D:Füllstand-Ü/ø 3", "FWX:R:ДОК-7@Б", "FWX:A:配管-12"]


def reference(text: str, level: str, version: int, mask: int) -> list[list[bool]]:
    q = qrcode.QRCode(version=version, error_correction=EC[level], border=0, mask_pattern=mask)
    q.add_data(QRData(text.encode("utf-8"), mode=MODE_8BIT_BYTE))
    q.make(fit=False)
    return [[bool(x) for x in row] for row in q.modules]


def image(m: list[list[bool]], scale: int = 4, quiet: int = 4) -> np.ndarray:
    n = len(m) + 2 * quiet
    img = np.full((n, n), 255, dtype=np.uint8)
    img[quiet:quiet + len(m), quiet:quiet + len(m)] = np.where(np.array(m), 0, 255)
    return np.kron(img, np.ones((scale, scale), dtype=np.uint8))


def read(m: list[list[bool]]):
    found = zxingcpp.read_barcodes(image(m), formats=zxingcpp.BarcodeFormat.QRCode)
    assert len(found) == 1, f"{len(found)} codes read"
    return found[0]


def text_of(n: int, rng: random.Random) -> str:
    return "".join(rng.choice("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-:_@/. ") for _ in range(n))


def most_bytes(version: int, level: str) -> int:
    return fwx_label._capacity(version, level) - (2 if version <= 9 else 3)


@pytest.mark.parametrize("version", range(1, fwx_label.MAX_VERSION + 1))
def test_every_version_level_and_mask_matches_an_independent_encoder(version):
    rng = random.Random(version)
    for level in LEVELS:
        full = most_bytes(version, level)
        for text in (text_of(full, rng), text_of(max(1, full // 3), rng)):     # full, and mostly padding
            for mask in range(8):
                assert encode(text, level, version=version, mask=mask) == reference(text, level, version, mask), \
                    (version, level, len(text), mask)


def test_the_smallest_version_that_holds_the_text():
    for level in LEVELS:
        for version in range(1, fwx_label.MAX_VERSION + 1):
            assert len(encode("a" * most_bytes(version, level), level)) == 17 + 4 * version
            if version < fwx_label.MAX_VERSION:
                assert len(encode("a" * (most_bytes(version, level) + 1), level)) == 17 + 4 * (version + 1)
        with pytest.raises(QRError, match="don't fit a version 10"):
            encode("a" * (most_bytes(fwx_label.MAX_VERSION, level) + 1), level)
    assert len(encode(UNIT, "Q")) == 33, "a unit's permanent label is version 4 at level Q"
    assert len("ü".encode()) == 2 and len(encode("ü" * 8, "L")) == 21, "UTF-8 bytes are what count"


def test_the_mask_is_the_first_with_the_lowest_penalty():
    # lost_point is python-qrcode's scoring of the standard's four penalty rules, written independently of ours.
    rng = random.Random(5)
    for text in SAMPLES + [text_of(rng.randint(1, 150), rng) for _ in range(25)]:
        for level in LEVELS:
            try:
                chosen = encode(text, level)
            except QRError:
                continue
            version = (len(chosen) - 17) // 4
            scores = [lost_point(encode(text, level, version=version, mask=k)) for k in range(8)]
            assert chosen == encode(text, level, version=version, mask=scores.index(min(scores))), (text, level)


def test_the_phone_decoder_reads_every_code_back():
    rng = random.Random(9)
    texts = SAMPLES + [text_of(n, rng) for n in (1, 2, 17, 33, 60, 99, 140, 200, 270)]
    read_back = 0
    for text in texts:
        for level in LEVELS:
            try:
                m = encode(text, level)
            except QRError:
                continue
            got = read(m)
            assert got.bytes == text.encode("utf-8"), (text, level)
            assert got.ec_level == level
            read_back += 1
    for mask in range(8):                                   # every mask, not just the ones chosen above
        assert read(encode(UNIT, "Q", mask=mask)).text == UNIT
    assert read_back >= 60


def test_a_scuffed_label_still_reads():
    # A label in the field gets dirty: wipe out a patch of modules and level Q's recovery must still give the text back.
    m = encode(UNIT, "Q")
    n = len(m)
    for r in range(n - 12, n - 7):
        for c in range(n - 6, n):
            m[r][c] = not m[r][c]
    assert read(m).text == UNIT


def test_label_codes():
    assert label_code("A", UNIT[6:]) == UNIT
    assert label_code("R", "SCH-12@B") == "FWX:R:SCH-12@B"
    assert label_code("R", "A@B@C") == "FWX:R:A@B@C", "the revision is what follows the last @"
    for kind, code in [("X", "1"), ("a", "1"), ("A", ""), ("A", "  "), ("A", "a\nb"), ("P", "a\x7fb"),
                       ("R", "SCH-12"), ("R", "@B"), ("R", "SCH-12@"), ("R", "SCH-12@ ")]:
        with pytest.raises(QRError):
            label_code(kind, code)


def test_bad_requests_are_refused():
    for kwargs in ({"level": "X"}, {"version": 0}, {"version": 11}, {"mask": 8}, {"mask": -1}):
        with pytest.raises(QRError):
            encode("x", **kwargs)
    with pytest.raises(QRError, match="version 1 "):
        encode("x" * 20, "H", version=1)
