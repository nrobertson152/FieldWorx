# SPDX-License-Identifier: GPL-3.0-or-later
"""Reading the family's programs, only through their documented command lines and files.

* RevisionWorx: ``revisionworx link`` (docs/INTEGRATION.md there) through the copied reference client, and
  ``revisionworx bom convert`` for BOM files, so BOMs are read by RevisionWorx's own BOM reader.
* RevisionWorx parts lists: the parts CSV of its BOM data contract (docs/bom/DATA_CONTRACT.md section 3).
* OpenMeridian: the ``.meridian`` company file as docs/COMPANY_FILE.md describes it, opened read-only.
* DraftWorx: ``draftworx pdf`` (docs/COMMAND_LINE.md there) for drawings it can print.

Nothing here writes to any of them.
"""
from __future__ import annotations

import csv
import hashlib
import io
import json
import os
import re
import shutil
import sqlite3
import subprocess
import tempfile
from decimal import Decimal
from pathlib import Path
from typing import Any

from .rwx_client import RevisionWorx, RwxError, find_command


class SourceError(Exception):
    """A source program refused or gave something unusable. The message is meant for the person running the bridge."""


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def _no_window() -> dict:
    return {"creationflags": 0x08000000} if os.name == "nt" else {}


# ---------------------------------------------------------------------------------------------------- RevisionWorx
class RevisionWorxSource:
    """One RevisionWorx workspace, read through ``revisionworx link``."""

    def __init__(self, workspace: str | Path | None = None, executable: str | None = None):
        self.rwx = RevisionWorx(executable=executable, workspace=str(workspace) if workspace else None)
        self.command = find_command(executable)
        self.workspace = str(workspace) if workspace else None
        if not self.rwx.available():
            raise SourceError("RevisionWorx (integration API 1) was not found. Install it, or set REVISIONWORX_CLI to "
                              "its 'revisionworx' program.")
        self.version = self.rwx.version().get("version", "")
        self._info: dict | None = None

    def _call(self, fn, *args, **kwargs):
        try:
            return fn(*args, **kwargs)
        except RwxError as exc:
            raise SourceError(f"RevisionWorx: {exc}") from None

    def projects(self) -> list[dict]:
        data = self._call(self.rwx._run, "projects")
        self._info = data.get("workspace") or {}
        return data["projects"]

    @property
    def info(self) -> dict:
        if self._info is None:
            self.projects()
        return self._info or {}

    def documents(self, project_id: str) -> list[dict]:
        return self._call(self.rwx.documents, project=project_id)

    def document(self, doc_id: str) -> dict:
        return self._call(self.rwx.document, doc_id)

    def fetch(self, doc_id: str, label: str, expect_sha256: str, to_dir: Path) -> Path:
        """Copy one revision's verified content into ``to_dir``; the bytes are checked against ``expect_sha256``."""
        sub = Path(tempfile.mkdtemp(dir=to_dir))
        res = self._call(self.rwx.fetch, doc_id, str(sub), revision=label)
        path = Path(res["path"])
        if sha256_file(path) != expect_sha256:
            raise SourceError(f"RevisionWorx gave content for {doc_id} rev {label} that doesn't match its recorded "
                              "SHA-256; nothing was packed. Run 'revisionworx doctor'.")
        return path

    def bom_convert(self, path: Path, out_dir: Path) -> dict | None:
        """The BOM in ``path`` as RevisionWorx's BOM JSON, or None if RevisionWorx doesn't read it as a BOM."""
        out = out_dir / f"bom-{hashlib.sha256(str(path).encode()).hexdigest()[:12]}.json"
        cmd = list(self.command) + ["bom", "-o", str(out), "--overwrite", "convert", str(path)]
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=300,
                                  stdin=subprocess.DEVNULL, **_no_window())
        except (OSError, subprocess.TimeoutExpired):
            return None
        if proc.returncode != 0 or not out.is_file():
            return None
        try:
            data = json.loads(out.read_text(encoding="utf-8"))
        except ValueError:
            return None
        if data.get("format") != "revisionworx.bom" or data.get("version") != 1 or "structure" not in data:
            return None
        return data["structure"]


# ------------------------------------------------------------------------------------------- RevisionWorx parts CSV
PARTS_REQUIRED = {"number", "description"}
_GROUP = re.compile(r"(manufacturer|mpn|vendor|sku|document_id|revision_id|role)_(\d+)\Z")


def _cell(v: str | None) -> str:
    v = (v or "").strip()
    if len(v) > 1 and v[0] == "'" and v[1] in "=+-@\t\r":
        return v[1:]
    return v


def looks_like_parts_csv(text: str) -> bool:
    first = text.lstrip("﻿").split("\n", 1)[0]
    cols = {c.strip().casefold() for c in first.split(",")}
    return PARTS_REQUIRED <= cols and ("part_id" in cols or "manufacturer_1" in cols or "mpn_1" in cols) \
        and "quantity" not in cols


def parse_parts_csv(text: str) -> list[dict]:
    """Rows of a RevisionWorx parts CSV as plain dicts (number, description, unit, kind, status, revision, part_id,
    manufacturers, vendors, documents, attributes). Raises SourceError naming the row on a malformed file."""
    reader = csv.DictReader(io.StringIO(text.lstrip("﻿"), newline=""))
    fields = reader.fieldnames or []
    out = []
    for n, row in enumerate(reader, start=2):
        if None in row:
            raise SourceError(f"parts list row {n}: more cells than columns")
        cells = {k.strip(): _cell(v) for k, v in row.items() if k is not None}
        low = {k.casefold(): v for k, v in cells.items()}
        if not low.get("number"):
            if any(cells.values()):
                raise SourceError(f"parts list row {n}: no part number")
            continue
        groups: dict[str, dict[str, dict[str, str]]] = {"m": {}, "v": {}, "d": {}}
        attrs = {}
        for k, v in cells.items():
            m = _GROUP.match(k.casefold())
            if m:
                kind = {"manufacturer": "m", "mpn": "m", "vendor": "v", "sku": "v", "document_id": "d",
                        "revision_id": "d", "role": "d"}[m.group(1)]
                groups[kind].setdefault(m.group(2), {})[m.group(1)] = v
            elif k.casefold().startswith("attr:") and v:
                attrs[k[5:]] = v
        out.append({
            "part_id": low.get("part_id", ""), "number": low["number"], "description": low.get("description", ""),
            "unit": low.get("unit", "") or "EA", "kind": low.get("kind", ""), "status": low.get("status", ""),
            "revision": low.get("revision", ""),
            "manufacturers": [{"name": g.get("manufacturer", ""), "mpn": g.get("mpn", "")}
                              for _, g in sorted(groups["m"].items(), key=lambda kv: int(kv[0]))
                              if g.get("manufacturer") or g.get("mpn")],
            "vendors": [{"name": g.get("vendor", ""), "sku": g.get("sku", "")}
                        for _, g in sorted(groups["v"].items(), key=lambda kv: int(kv[0]))
                        if g.get("vendor") or g.get("sku")],
            "documents": [{"document": g.get("document_id", ""), "revision": g.get("revision_id", ""),
                           "role": g.get("role", "")}
                          for _, g in sorted(groups["d"].items(), key=lambda kv: int(kv[0])) if g.get("document_id")],
            "attributes": attrs})
    if not fields:
        raise SourceError("parts list is empty")
    return out


# -------------------------------------------------------------------------------------------------- asset registers
ASSET_COLUMNS = ("tag", "serial", "name", "part", "project", "location", "built", "as_built", "notes")


def parse_assets_csv(text: str) -> list[dict]:
    """An asset register: one row per physical unit (docs/PROTOCOL.md section 6.4)."""
    reader = csv.DictReader(io.StringIO(text.lstrip("﻿"), newline=""))
    header = [(h or "").strip().casefold() for h in (reader.fieldnames or [])]
    unknown = set(header) - set(ASSET_COLUMNS)
    if unknown:
        raise SourceError(f"asset register: unknown columns {', '.join(sorted(unknown))}")
    if "tag" not in header and "serial" not in header:
        raise SourceError("asset register needs a tag or a serial column")
    reader.fieldnames = header
    rows, seen = [], set()
    for n, row in enumerate(reader, start=2):
        if None in row:
            raise SourceError(f"asset register row {n}: more cells than columns")
        cells = {k: _cell(row.get(k)) for k in ASSET_COLUMNS}
        if not any(cells.values()):
            continue
        key = (cells["tag"] or cells["serial"]).casefold()
        if not key:
            raise SourceError(f"asset register row {n}: needs a tag or a serial number")
        if key in seen:
            raise SourceError(f"asset register row {n}: {cells['tag'] or cells['serial']} appears twice")
        seen.add(key)
        cells["as_built"] = [r.strip() for r in cells["as_built"].split(";") if r.strip()]
        rows.append(cells)
    return rows


# ------------------------------------------------------------------------------------------------------ OpenMeridian
MERIDIAN_APP_ID = 0x4F4D4552


def read_meridian(path: Path) -> tuple[dict[str, dict], str]:
    """Items of an OpenMeridian company file, by casefolded number: number, description, unit, bin, on_hand (a
    decimal string: the sum of its stock ledger). Read-only; refuses a file it doesn't recognise. Returns (items,
    company name)."""
    uri = Path(path).resolve().as_uri() + "?mode=ro"
    try:
        conn = sqlite3.connect(uri, uri=True, timeout=10)
    except sqlite3.Error as exc:
        raise SourceError(f"OpenMeridian file {path}: {exc}") from None
    try:
        conn.execute("PRAGMA query_only = ON")
        app_id = conn.execute("PRAGMA application_id").fetchone()[0]
        version = conn.execute("PRAGMA user_version").fetchone()[0]
        if app_id != MERIDIAN_APP_ID:
            raise SourceError(f"{path} is not an OpenMeridian company file")
        if version != 1:
            raise SourceError(f"{path} is OpenMeridian format {version}; this bridge reads format 1")
        name_row = conn.execute("SELECT value FROM settings WHERE key = 'company_name'").fetchone()
        rows = conn.execute(
            "SELECT i.number, i.description, i.unit, i.bin, i.active, COALESCE(SUM(m.qty), 0) "
            "FROM items i LEFT JOIN stock_moves m ON m.item_id = i.id GROUP BY i.id").fetchall()
    except sqlite3.Error as exc:
        raise SourceError(f"OpenMeridian file {path}: {exc}") from None
    finally:
        conn.close()
    items = {}
    for number, desc, unit, bin_, active, qty in rows:
        if not active:
            continue
        on_hand = (Decimal(qty) / 1000).normalize()
        text = format(on_hand, "f")
        if "." in text:
            text = text.rstrip("0").rstrip(".")
        items[number.casefold()] = {"number": number, "description": desc, "unit": unit or "EA", "bin": bin_,
                                    "on_hand": text if text not in ("-0", "") else "0"}
    return items, (name_row[0] if name_row else "")


# --------------------------------------------------------------------------------------------------------- DraftWorx
class DraftWorx:
    """``draftworx pdf`` for .draftworx and .dxf drawings, if DraftWorx is installed."""

    EXTENSIONS = (".draftworx", ".dxf")

    def __init__(self, executable: str | None = None):
        exe = executable or os.environ.get("DRAFTWORX_CLI") or shutil.which("draftworx")
        self.command = [exe] if exe else None
        self.version = ""
        if self.command:
            try:
                proc = subprocess.run(self.command + ["version"], capture_output=True, text=True, timeout=60,
                                      stdin=subprocess.DEVNULL, **_no_window())
                data = json.loads(proc.stdout.strip().splitlines()[-1])
                if data.get("ok") and data.get("api") == 1:
                    self.version = data.get("version", "")
                else:
                    self.command = None
            except (OSError, ValueError, IndexError, subprocess.TimeoutExpired):
                self.command = None

    def available(self) -> bool:
        return self.command is not None

    def pdf(self, drawing: Path, out: Path) -> Path | None:
        if not self.command:
            return None
        try:
            proc = subprocess.run(self.command + ["pdf", str(drawing), str(out), "--overwrite"], capture_output=True,
                                  text=True, timeout=600, stdin=subprocess.DEVNULL, **_no_window())
            data = json.loads(proc.stdout.strip().splitlines()[-1])
        except (OSError, ValueError, IndexError, subprocess.TimeoutExpired):
            return None
        return out if data.get("ok") and out.is_file() else None


def as_text(path: Path) -> str:
    data = path.read_bytes()
    try:
        return data.decode("utf-8-sig")
    except UnicodeDecodeError:
        raise SourceError(f"{path.name} is not UTF-8 text") from None


def first(items: list[Any], pred) -> Any:
    return next((i for i in items if pred(i)), None)
