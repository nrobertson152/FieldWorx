# SPDX-License-Identifier: GPL-3.0-or-later
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "bridge"))
sys.path.insert(0, str(ROOT / "examples" / "demo"))
VECTORS = ROOT / "spec" / "vectors"


def have_revisionworx() -> bool:
    from fieldworx_bridge.rwx_client import RevisionWorx
    return RevisionWorx().available()


@pytest.fixture(scope="session")
def demo(tmp_path_factory):
    """The demo workspace (and OpenMeridian file, if OpenMeridian is installed), built once per session."""
    if not have_revisionworx():
        pytest.skip("RevisionWorx is not installed")
    out = tmp_path_factory.mktemp("demo") / "demo"
    import build_demo
    assert build_demo.main([str(out)]) == 0
    return out


@pytest.fixture(autouse=True)
def _isolate_revisionworx(tmp_path_factory, monkeypatch):
    base = tmp_path_factory.getbasetemp() / "rwx-local"
    for k in ("XDG_CACHE_HOME", "XDG_STATE_HOME", "XDG_CONFIG_HOME", "LOCALAPPDATA"):
        monkeypatch.setenv(k, str(base / k.lower()))
