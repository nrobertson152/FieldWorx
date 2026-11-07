# SPDX-License-Identifier: GPL-3.0-or-later
"""Enrolling a phone to a person's RevisionWorx account (docs/PROTOCOL.md section 12.4, ARCHITECTURE.md ADR-015).

The phone's field log carries its device id and public key; the person enrolling it types the fingerprint the phone
shows, which must be that key's, so the key enrolled is the one on the phone in their hand. RevisionWorx records the
phone in the account (``revisionworx link device-enrol``, feature ``field-signatures``), in the name of the
administrator logged in to RevisionWorx on this computer, and checks the fingerprint again. Nothing else is written,
and nothing is written by this module itself.
"""
from __future__ import annotations

import re
from pathlib import Path

from . import archive, events as E
from .rwx_client import RwxError
from .sources import RevisionWorxSource, SourceError

FEATURE = "field-signatures"
_HEX16 = re.compile(r"[0-9A-F]{16}\Z")


class EnrolError(Exception):
    """Nothing was enrolled. The message says why, and what to do."""


def normal_fingerprint(text: str) -> str:
    """A fingerprint as typed (any case, with or without the dashes and spaces) in its written form."""
    digits = re.sub(r"[\s-]", "", str(text or "")).upper()
    if not _HEX16.match(digits):
        raise EnrolError("a fingerprint is 16 letters and digits, 0-9 and A-F, in four groups as the phone shows them, "
                         "such as 3F2A-91C0-77B1-04DE")
    return "-".join(digits[i:i + 4] for i in range(0, 16, 4))


def phone_of(arc: archive.Archive) -> tuple[str, str]:
    """``(device id, public key)`` of the phone that wrote a field log. Its own signed records must carry that key."""
    if arc.kind != "fieldlog":
        raise EnrolError("this is a package; a phone is enrolled from a field log it wrote")
    made_by = arc.manifest["created_by"]
    device, key = made_by.get("device", ""), made_by.get("key", "")
    if not E.RE_DEVICE.match(device):
        raise EnrolError("this field log doesn't say which phone wrote it")
    if not key:
        raise EnrolError("this field log was written by a FieldWorx from before phones had keys: update the app on the "
                         "phone, open it once, and send a new field log")
    if not E.RE_KEY.match(key):
        raise EnrolError("this field log's key is damaged")
    if any(e.device == device and e.version == 2 and e.key != key for e in arc.events):
        raise EnrolError("this field log names one key for its phone, but the phone's records are signed with another: "
                         "it can't be used to enrol the phone")
    return device, key


def enrol(fieldlog: Path, workspace: str | Path | None, account: str, fingerprint: str, *, name: str = "",
          executable: str | None = None) -> dict:
    """Enrol the phone that wrote ``fieldlog`` to ``account``. Returns RevisionWorx's answer: ``{"result": "enrolled" |
    "already-enrolled", "device": {...}}``. Raises EnrolError when nothing was enrolled."""
    try:
        with archive.read(Path(fieldlog), verify_objects=False) as arc:
            device, key = phone_of(arc)
    except archive.ArchiveError as exc:
        raise EnrolError(f"{fieldlog} can't be used: {exc}") from None
    typed = normal_fingerprint(fingerprint)
    actual = E.fingerprint(key)
    if typed != actual:
        raise EnrolError(f"the fingerprint you typed, {typed}, isn't the one of the phone that wrote this field log "
                         f"({actual}), so nothing was enrolled. Check you have that phone's field log, and read the "
                         "fingerprint from the phone itself (Library, This phone)")
    try:
        src = RevisionWorxSource(workspace, executable)
    except SourceError as exc:
        raise EnrolError(str(exc)) from None
    if not src.has(FEATURE):
        raise EnrolError(f"this RevisionWorx ({src.version}) can't enrol phones: update it (its 'link version' doesn't "
                         f"list '{FEATURE}')")
    try:
        return src.rwx.device_enrol(account, device, key, typed, name=name)
    except RwxError as exc:
        raise EnrolError(f"nothing was enrolled: RevisionWorx: {exc}") from None
