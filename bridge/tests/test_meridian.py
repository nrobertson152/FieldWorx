# SPDX-License-Identifier: GPL-3.0-or-later
"""OpenMeridian company files, opened read-only (OpenMeridian's docs/COMPANY_FILE.md): formats 1, 2 and 3 are read the
same way and any other format is refused. The files are made here from the documented tables, so these tests run without
OpenMeridian; the demo's tests read one OpenMeridian made itself."""
import sqlite3

import pytest

from fieldworx_bridge import sources

# The tables read here, as OpenMeridian's format 1 has them...
FORMAT_1 = """
CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;
CREATE TABLE items (
    id INTEGER PRIMARY KEY, number TEXT NOT NULL UNIQUE COLLATE NOCASE, description TEXT NOT NULL DEFAULT '',
    kind TEXT NOT NULL CHECK (kind IN ('buy', 'make')), unit TEXT NOT NULL DEFAULT 'EA',
    cost INTEGER NOT NULL DEFAULT 0 CHECK (cost >= 0), price INTEGER NOT NULL DEFAULT 0 CHECK (price >= 0),
    reorder_point INTEGER NOT NULL DEFAULT 0 CHECK (reorder_point >= 0),
    reorder_qty INTEGER NOT NULL DEFAULT 0 CHECK (reorder_qty >= 0),
    supplier_id INTEGER REFERENCES contacts(id), lead_days INTEGER NOT NULL DEFAULT 0 CHECK (lead_days >= 0),
    bin TEXT NOT NULL DEFAULT '', notes TEXT NOT NULL DEFAULT '', active INTEGER NOT NULL DEFAULT 1,
    rw_document TEXT NOT NULL DEFAULT '', rw_number TEXT NOT NULL DEFAULT '',
    bom_rw_document TEXT NOT NULL DEFAULT '', bom_rw_revision TEXT NOT NULL DEFAULT '',
    bom_rw_label TEXT NOT NULL DEFAULT '', bom_rw_sha256 TEXT NOT NULL DEFAULT '') STRICT;
CREATE TABLE stock_moves (
    id INTEGER PRIMARY KEY, time TEXT NOT NULL, item_id INTEGER NOT NULL REFERENCES items(id),
    qty INTEGER NOT NULL CHECK (qty <> 0), unit_cost INTEGER NOT NULL DEFAULT 0,
    kind TEXT NOT NULL CHECK (kind IN ('receipt', 'shipment', 'consume', 'produce', 'adjust')),
    ref TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '', user TEXT NOT NULL DEFAULT '') STRICT;
"""
# ...and what format 2 added: serial numbers for units made.
FORMAT_2 = """
ALTER TABLE items ADD COLUMN tracking TEXT NOT NULL DEFAULT 'none' CHECK (tracking IN ('none', 'serial', 'lot'));
ALTER TABLE stock_moves ADD COLUMN serial TEXT NOT NULL DEFAULT '';
ALTER TABLE stock_moves ADD COLUMN lot TEXT NOT NULL DEFAULT '';
CREATE TABLE wo_units (
    id INTEGER PRIMARY KEY, work_order_id INTEGER NOT NULL, item_id INTEGER NOT NULL REFERENCES items(id),
    serial TEXT NOT NULL UNIQUE COLLATE NOCASE, batch INTEGER NOT NULL, made TEXT NOT NULL, model TEXT NOT NULL,
    name TEXT NOT NULL, rw_unit TEXT NOT NULL DEFAULT '', rw_note TEXT NOT NULL DEFAULT '') STRICT;
"""

# ...and what format 3 added: lots. A move of an item tracked by lot names its lot, and no other move names one.
FORMAT_3 = """
ALTER TABLE stock_moves ADD COLUMN batch INTEGER NOT NULL DEFAULT 0 CHECK (batch >= 0);
CREATE INDEX stock_moves_lot ON stock_moves (item_id, lot);
CREATE INDEX stock_moves_ref ON stock_moves (ref, batch);
CREATE TRIGGER stock_moves_lot_named BEFORE INSERT ON stock_moves
    WHEN (NEW.lot = '') = ((SELECT tracking FROM items WHERE id = NEW.item_id) = 'lot')
    BEGIN SELECT RAISE(ABORT, 'a move of an item tracked by lot names its lot, and no other move names one'); END;
"""

WANT = {
    "hse-08": {"number": "HSE-08", "description": "Hose assembly", "unit": "EA", "bin": "B4", "on_hand": "8"},
    "hpu-75": {"number": "HPU-75", "description": "Hydraulic power unit", "unit": "EA", "bin": "", "on_hand": "1"},
    "oil-46": {"number": "OIL-46", "description": "Hydraulic oil", "unit": "L", "bin": "", "on_hand": "12.5"},
}


def _company(path, version):
    """A company as OpenMeridian keeps it: hoses received and used (in format 3, in two lots), oil in litres, two power
    units made (from format 2, each under its serial) and one shipped, and an item no longer used."""
    con = sqlite3.connect(path)
    con.executescript(FORMAT_1 + (FORMAT_2 if version >= 2 else "") + (FORMAT_3 if version >= 3 else ""))
    con.execute("INSERT INTO settings VALUES ('company_name', 'Northline Hydraulics')")
    items = [(1, "HSE-08", "Hose assembly", "buy", "EA", "B4", 1), (2, "HPU-75", "Hydraulic power unit", "make", "EA", "", 1),
             (3, "OIL-46", "Hydraulic oil", "buy", "L", "", 1), (4, "OLD-1", "No longer used", "buy", "EA", "", 0)]
    con.executemany("INSERT INTO items (id, number, description, kind, unit, bin, active) VALUES (?,?,?,?,?,?,?)", items)
    moves = [(1, 10000, "receipt", ""), (1, -2000, "consume", ""), (3, 12500, "receipt", ""), (4, 3000, "receipt", "")]
    if version >= 3:
        con.execute("UPDATE items SET tracking = 'lot' WHERE id = 1")
        con.executemany("INSERT INTO stock_moves (time, item_id, qty, kind, lot, batch) "
                        "VALUES ('2026-11-07T10:00:00', 1, ?, ?, ?, ?)",
                        [(6000, "receipt", "H-2611", 0), (4000, "receipt", "H-2612", 0),
                         (-2000, "consume", "H-2611", 1)])
        moves = moves[2:]  # the hoses' moves are the ones above, in lots
    if version >= 2:
        con.execute("UPDATE items SET tracking = 'serial' WHERE id = 2")
        moves += [(2, 1000, "produce", "NH-26-0001"), (2, 1000, "produce", "NH-26-0002"), (2, -1000, "shipment", "")]
        con.executemany("INSERT INTO wo_units (work_order_id, item_id, serial, batch, made, model, name) "
                        "VALUES (1, 2, ?, 1, '2026-11-07', 'HPU-75', 'Hydraulic power unit')", [("NH-26-0001",), ("NH-26-0002",)])
        con.executemany("INSERT INTO stock_moves (time, item_id, qty, kind, serial) VALUES ('2026-11-07T10:00:00', ?, ?, ?, ?)",
                        moves)
    else:
        moves += [(2, 2000, "produce", ""), (2, -1000, "shipment", "")]
        con.executemany("INSERT INTO stock_moves (time, item_id, qty, kind) VALUES ('2026-11-07T10:00:00', ?, ?, ?)",
                        [m[:3] for m in moves])
    con.execute(f"PRAGMA application_id = {sources.MERIDIAN_APP_ID}")
    con.execute(f"PRAGMA user_version = {version}")
    con.commit()
    con.close()
    return path


@pytest.mark.parametrize("version", [1, 2, 3])
def test_formats_1_2_and_3_are_read_the_same_way_and_left_as_they_were(tmp_path, version):
    path = _company(tmp_path / f"format{version}.meridian", version)
    before = path.read_bytes()
    items, name = sources.read_meridian(path)
    assert (items, name) == (WANT, "Northline Hydraulics")
    assert path.read_bytes() == before, "opened read-only"


@pytest.mark.parametrize("version", [0, 4])
def test_a_format_it_doesnt_know_is_refused(tmp_path, version):
    path = _company(tmp_path / "other.meridian", 3)
    con = sqlite3.connect(path)
    con.execute(f"PRAGMA user_version = {version}")
    con.commit()
    con.close()
    with pytest.raises(sources.SourceError, match=f"format {version}; this bridge reads formats 1, 2 and 3"):
        sources.read_meridian(path)


def test_a_file_that_isnt_openmeridians_is_refused(tmp_path):
    path = tmp_path / "other.meridian"
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE t (x)")
    con.commit()
    con.close()
    with pytest.raises(sources.SourceError, match="not an OpenMeridian company file"):
        sources.read_meridian(path)
