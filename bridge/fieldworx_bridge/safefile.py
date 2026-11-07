# SPDX-License-Identifier: GPL-3.0-or-later
"""Files that are written once: a complete, flushed temporary file is published under its final name only if that
name does not exist yet (``link`` on POSIX, ``rename`` on Windows, both of which refuse an existing name).

The hub store relies on exactly two properties of the file system, the same two RevisionWorx documents for team
workspaces (its ADR-024, A1 and A2): two writers racing for one name, exactly one wins; and a file published complete
is read complete. Nothing here ever replaces or edits a published file.
"""
from __future__ import annotations

import os
import uuid
from pathlib import Path


class AlreadyExists(FileExistsError):
    """The final name was already taken. The caller decides whether the existing file is the same."""


def _fsync_dir(folder: Path) -> None:
    if os.name != "posix":
        return
    try:
        fd = os.open(folder, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def temp_name(final: Path) -> Path:
    return final.with_name(f".{final.name}.{uuid.uuid4().hex}.tmp")


def publish_new(final: Path, data: bytes) -> None:
    """Write ``data`` to ``final``; raise AlreadyExists if the name is taken. Never overwrites."""
    final.parent.mkdir(parents=True, exist_ok=True)
    tmp = temp_name(final)
    with open(tmp, "xb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    publish_file(tmp, final)


def publish_file(tmp: Path, final: Path) -> None:
    """Give a complete, flushed file ``tmp`` the name ``final`` unless that name exists. ``tmp`` is gone afterwards."""
    try:
        if os.name == "posix":
            try:
                os.link(tmp, final)
            except FileExistsError:
                raise AlreadyExists(str(final)) from None
            os.unlink(tmp)
        else:
            try:
                os.rename(tmp, final)  # Windows: refuses an existing destination
            except FileExistsError:
                raise AlreadyExists(str(final)) from None
    finally:
        if tmp.exists():
            try:
                tmp.unlink()
            except OSError:
                pass
    _fsync_dir(final.parent)


def write_output(final: Path, writer, overwrite: bool = False) -> None:
    """Write a user-chosen output file all-or-nothing. ``writer(fileobj)`` fills it.

    Without ``overwrite`` an existing file is never replaced (AlreadyExists). With it, the replacement is atomic.
    """
    final.parent.mkdir(parents=True, exist_ok=True)
    tmp = temp_name(final)
    try:
        with open(tmp, "xb") as f:
            writer(f)
            f.flush()
            os.fsync(f.fileno())
        if overwrite:
            os.replace(tmp, final)
            _fsync_dir(final.parent)
        else:
            publish_file(tmp, final)
    finally:
        if tmp.exists():
            try:
                tmp.unlink()
            except OSError:
                pass
