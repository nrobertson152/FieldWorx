# SPDX-License-Identifier: GPL-3.0-or-later
"""The release build's checks (release_checks.py), and that the workflows run them.

The apksigner samples follow the output of `apksigner verify --verbose --print-certs`. CI's Android job runs the signer
check against the real apksigner on every build, on the APK signed with the debug key, and fails unless it is refused
for that key (.github/workflows/ci.yml).
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

import release_checks as rc

ROOT = Path(__file__).resolve().parent.parent

# `aapt dump permissions` on the APK CI built from main at f657546 (job 128825034030), as printed.
CI_DUMP = """\
package: io.github.nrobertson152.fieldworx
uses-permission: name='android.permission.CAMERA'
permission: io.github.nrobertson152.fieldworx.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION
uses-permission: name='io.github.nrobertson152.fieldworx.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION'
"""

RELEASE = "3f" * 32
OTHER = "a1" * 32


def certs(*signers: tuple[str, str], verifies: str = "Verifies") -> str:
    lines = [verifies, "Verified using v1 scheme (JAR signing): false",
             "Verified using v2 scheme (APK Signature Scheme v2): true",
             "Verified using v3 scheme (APK Signature Scheme v3): true",
             "Verified using v3.1 scheme (APK Signature Scheme v3.1): false",
             "Verified using v4 scheme (APK Signature Scheme v4): false",
             "Verified for SourceStamp: false", f"Number of signers: {len(signers)}"]
    for n, (dn, sha256) in enumerate(signers, 1):
        lines += [f"Signer #{n} certificate DN: {dn}",
                  f"Signer #{n} certificate SHA-256 digest: {sha256}",
                  f"Signer #{n} certificate SHA-1 digest: {'0b' * 20}",
                  f"Signer #{n} certificate MD5 digest: {'0c' * 16}",
                  f"Signer #{n} key algorithm: RSA",
                  f"Signer #{n} key size (bits): 2048",
                  f"Signer #{n} public key SHA-256 digest: {'0d' * 32}"]
    return "\n".join(lines) + "\n"


DEBUG_DN = "C=US, O=Android, CN=Android Debug"
RELEASE_DN = "CN=FieldWorx, O=Northline Hydraulics, C=GB"


# --- permissions ------------------------------------------------------------------------------------------------------

def test_the_apk_ci_builds_asks_only_for_the_camera():
    assert rc.permission_problems(CI_DUMP) == []


@pytest.mark.parametrize("line, refused", [
    ("uses-permission: name='android.permission.INTERNET'", "android.permission.INTERNET"),
    ("uses-permission: name='android.permission.WRITE_EXTERNAL_STORAGE' maxSdkVersion='28'",
     "android.permission.WRITE_EXTERNAL_STORAGE"),
    ("uses-permission-sdk-23: name='android.permission.RECORD_AUDIO'", "android.permission.RECORD_AUDIO"),
    ("uses-implied-permission: name='android.permission.READ_EXTERNAL_STORAGE' reason='x'",
     "android.permission.READ_EXTERNAL_STORAGE"),
    ("uses-permission: android.permission.ACCESS_NETWORK_STATE", "android.permission.ACCESS_NETWORK_STATE"),
    # Another app's private permission isn't this app's own.
    ("uses-permission: name='com.example.other.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION'",
     "com.example.other.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"),
])
def test_anything_beyond_the_camera_is_refused(line, refused):
    assert rc.permission_problems(CI_DUMP + line + "\n") == [f"the APK asks for {refused}"]


def test_the_camera_in_another_spelling_is_still_the_camera():
    dump = "package: io.github.nrobertson152.fieldworx\nuses-permission-sdk-23: name='android.permission.CAMERA'\n"
    assert rc.permission_problems(dump) == []
    assert rc.permission_problems("package: io.github.nrobertson152.fieldworx\n"
                                  "uses-permission: android.permission.CAMERA\n") == []


@pytest.mark.parametrize("dump", ["", "\n", "ERROR: dump failed because no AndroidManifest.xml found\n",
                                  "uses-permission: name='android.permission.CAMERA'\n"])
def test_output_that_isnt_a_dump_never_passes(dump):
    """Without pipefail an aapt that failed left an empty file, and the old grep passed it."""
    assert rc.permission_problems(dump) == [
        "the dump names no package: give it the output of `aapt dump permissions APK`"]


def test_a_line_it_cant_read_is_refused():
    problems = rc.permission_problems(CI_DUMP + "uses-permission: name=''\n")
    assert problems == ["this line can't be read: uses-permission: name=''"]


# --- signer -----------------------------------------------------------------------------------------------------------

def test_signed_with_the_release_certificate():
    assert rc.signer_problem(certs((RELEASE_DN, RELEASE)), RELEASE) is None


def test_the_digest_may_be_written_with_colons_and_capitals():
    pretty = ":".join(RELEASE[i:i + 2] for i in range(0, 64, 2)).upper()
    assert rc.signer_problem(certs((RELEASE_DN, RELEASE)), pretty) is None
    assert rc.signer_problem(certs((RELEASE_DN, pretty)), f"  {RELEASE}\n") is None


def test_the_debug_key_is_refused_even_when_it_is_the_certificate_expected():
    """Setting ANDROID_CERT_SHA256 to the debug certificate (copied from a CI log, say) doesn't let it through."""
    problem = rc.signer_problem(certs((DEBUG_DN, OTHER)), OTHER)
    assert problem == f"the APK is signed with the debug key (Signer #1: {DEBUG_DN})"


def test_another_certificate_is_refused():
    assert rc.signer_problem(certs((RELEASE_DN, OTHER)), RELEASE) == (
        f"Signer #1 is the certificate {OTHER}, not the release certificate {RELEASE}")


def test_every_signer_must_be_the_release_certificate():
    assert "Signer #2 is the certificate" in rc.signer_problem(certs((RELEASE_DN, RELEASE), (RELEASE_DN, OTHER)), RELEASE)
    assert "debug key (Signer #2" in rc.signer_problem(certs((RELEASE_DN, RELEASE), (DEBUG_DN, RELEASE)), RELEASE)


@pytest.mark.parametrize("expected", ["", "   ", "not-a-digest", RELEASE[:-2], RELEASE + "00"])
def test_without_a_release_certificate_to_compare_nothing_passes(expected):
    assert "ANDROID_CERT_SHA256" in rc.signer_problem(certs((RELEASE_DN, RELEASE)), expected)


def test_an_apk_that_doesnt_verify_is_refused():
    assert rc.signer_problem("DOES NOT VERIFY\nERROR: JAR signer CERT.RSA: JAR signature META-INF/CERT.RSA "
                             "indicates the APK is signed using APK Signature Scheme v2 but no such signature "
                             "was found. Signature stripped?\n", RELEASE) == "apksigner says the APK doesn't verify"
    assert rc.signer_problem(certs((RELEASE_DN, RELEASE), verifies="DOES NOT VERIFY"), RELEASE) == (
        "apksigner says the APK doesn't verify")


@pytest.mark.parametrize("output", ["", "Signer #1 certificate DN: CN=x\n",
                                    certs((RELEASE_DN, RELEASE), verifies="Verified")])
def test_output_without_its_verdict_never_passes(output):
    assert rc.signer_problem(output, RELEASE).startswith("apksigner doesn't say the APK verifies")


def test_output_naming_no_signer_or_half_a_signer_never_passes():
    assert rc.signer_problem("Verifies\nNumber of signers: 1\n", RELEASE) == "apksigner names no signer"
    half = "Verifies\nSigner #1 certificate DN: " + RELEASE_DN + "\n"
    assert rc.signer_problem(half, RELEASE) == "Signer #1's certificate can't be read"
    bad = half + "Signer #1 certificate SHA-256 digest: 1234\n"
    assert rc.signer_problem(bad, RELEASE) == "Signer #1's certificate can't be read"


def test_the_public_key_digest_isnt_taken_for_the_certificate():
    output = "Verifies\n" + f"Signer #1 certificate DN: {RELEASE_DN}\nSigner #1 public key SHA-256 digest: {RELEASE}\n"
    assert rc.signer_problem(output, RELEASE) == "Signer #1's certificate can't be read"


# --- version ----------------------------------------------------------------------------------------------------------

def tree(tmp_path: Path, app="1.0.0", dart=None, core="1.0.0", bridge="1.0.0") -> Path:
    (tmp_path / "app/lib").mkdir(parents=True)
    (tmp_path / "core").mkdir()
    (tmp_path / "bridge/fieldworx_bridge").mkdir(parents=True)
    (tmp_path / "app/pubspec.yaml").write_text(f"name: fieldworx\nversion: {app}+1\n")
    (tmp_path / "app/lib/version.dart").write_text(f"/// The app's version.\nconst String appVersion = '{dart or app}';\n")
    (tmp_path / "core/pubspec.yaml").write_text(f"name: fieldworx_core\nversion: {core}\n")
    (tmp_path / "bridge/fieldworx_bridge/__init__.py").write_text(f'"""Bridge."""\n__version__ = "{bridge}"\n')
    return tmp_path


def test_the_repository_carries_one_version():
    version, problems = rc.version_problems("main")
    assert problems == [] and re.fullmatch(r"\d+\.\d+\.\d+", version)
    assert rc.version_problems(f"v{version}") == (version, [])
    assert rc.version_problems(f"refs/tags/v{version}") == (version, [])


def test_a_tag_must_name_the_version_the_files_carry(tmp_path):
    root = tree(tmp_path)
    assert rc.version_problems("v1.0.0", root) == ("1.0.0", [])
    assert rc.version_problems("v1.0.1", root) == (None, ["v1.0.1 names version 1.0.1, but the files carry 1.0.0"])
    assert rc.version_problems("0123abc", root) == ("1.0.0", []), "a commit names no version"


@pytest.mark.parametrize("field", ["app", "dart", "core", "bridge"])
def test_files_that_disagree_are_refused(tmp_path, field):
    root = tree(tmp_path, **{field: "1.0.1"})
    version, problems = rc.version_problems("main", root)
    assert version is None and problems[0].startswith("the versions differ: ") and "has 1.0.1" in problems[0]


def test_a_file_without_its_version_is_refused(tmp_path):
    root = tree(tmp_path)
    (root / "core/pubspec.yaml").write_text("name: fieldworx_core\n")
    (root / "bridge/fieldworx_bridge/__init__.py").unlink()
    _, problems = rc.version_problems("v1.0.0", root)
    assert problems[0] == "core/pubspec.yaml doesn't give exactly one version"
    assert problems[1].startswith("bridge/fieldworx_bridge/__init__.py can't be read")


# --- the command line -------------------------------------------------------------------------------------------------

def test_the_command_line(tmp_path, capsys):
    (tmp_path / "perms.txt").write_text(CI_DUMP)
    (tmp_path / "debug.txt").write_text(certs((DEBUG_DN, OTHER)))
    (tmp_path / "release.txt").write_text(certs((RELEASE_DN, RELEASE)))
    assert rc.main(["permissions", str(tmp_path / "perms.txt")]) == 0
    assert rc.main(["signer", str(tmp_path / "release.txt"), "--release-cert", RELEASE]) == 0
    assert rc.main(["signer", str(tmp_path / "release.txt")]) == 1
    assert rc.main(["signer", str(tmp_path / "debug.txt"), "--release-cert", OTHER]) == 1
    assert rc.main(["permissions", str(tmp_path / "missing.txt")]) == 1
    err = capsys.readouterr().err
    assert "release_checks.py: the APK is signed with the debug key" in err
    assert "ANDROID_CERT_SHA256" in err and "missing.txt can't be read" in err
    version, _ = rc.version_problems("main")
    assert rc.main(["version", f"v{version}"]) == 0 and capsys.readouterr().out == f"{version}\n"
    assert rc.main(["version", "v0.0.1"]) == 1 and "names version 0.0.1" in capsys.readouterr().err


# --- the workflows run them -------------------------------------------------------------------------------------------

def workflow(name: str) -> str:
    return (ROOT / ".github/workflows" / name).read_text(encoding="utf-8")


def test_the_release_build_runs_every_check_and_cant_publish():
    text = workflow("release.yml")
    trigger = text.split("\non:", 1)[1].split("\npermissions:", 1)[0]
    assert "workflow_dispatch:" in trigger and not re.search(r"^\s+(push|pull_request|release|schedule):", trigger, re.M)
    assert re.search(r"^permissions:\n  contents: read\n\n", text, re.M), "the token can only read"
    for check in ("release_checks.py version", "release_checks.py permissions",
                  'release_checks.py signer certs.txt --release-cert "$RELEASE_CERT"'):
        assert check in text, check
    assert "apksigner\" verify --verbose --print-certs" in text
    assert text.count("shell: bash") >= 2, "pipefail: a failing aapt or apksigner fails the step"
    for publishing in ("gh release", "git tag", "git push", "contents: write", "softprops/", "upload-release-asset"):
        assert publishing not in text, publishing
    assert "key.properties" in text and 'rm -f android/key.properties "$RUNNER_TEMP/fieldworx-release.jks"' in text


def test_ci_refuses_its_own_apk_for_the_debug_key():
    text = workflow("ci.yml")
    assert "release_checks.py permissions perms.txt" in text
    assert "release_checks.py signer certs.txt --release-cert" in text and "grep -q \"signed with the debug key\"" in text
