# SPDX-License-Identifier: GPL-3.0-or-later
"""The release build's checks (release_checks.py), and that the workflows run them.

The apksigner samples are its real output (CI_CERTS, from CI) and the same shapes with other certificates, in both
ways apksigner names signers. CI's Android job also runs the signer check against the real apksigner on every build, on
the APK signed with the debug key, and fails unless it is refused for that key (.github/workflows/ci.yml).
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

# `apksigner verify --verbose --print-certs` on the APK CI built from 63f3845 (job 128908094735), signed with that
# runner's debug key, as printed. This build-tools version names a signer by the scheme it verified ("V2 Signer:").
CI_CERTS = """\
Verifies
Verified using v1 scheme (JAR signing): false
Verified using v2 scheme (APK Signature Scheme v2): true
Verified using v3 scheme (APK Signature Scheme v3): false
Verified using v3.1 scheme (APK Signature Scheme v3.1): false
Verified using v3.2 scheme (APK Signature Scheme v3.2): false
Verified using v4 scheme (APK Signature Scheme v4): false
Verified for SourceStamp: false
Number of signers: 1
V2 Signer: certificate DN: C=US, O=Android, CN=Android Debug
V2 Signer: certificate SHA-256 digest: df6b9ffefba89c7f40b0ee04b7c5b738af47611b50a51ce6b05bc8786c58ad51
V2 Signer: certificate SHA-1 digest: 7bdf4e03687a29f7bdaea26ace4d14b1350792af
V2 Signer: certificate MD5 digest: 1450ca266869d7783d2e4f28d381c963
V2 Signer: key algorithm: RSA
V2 Signer: key size (bits): 2048
V2 Signer: public key SHA-256 digest: ee2d975e6baf204d8877bf6258e7e8b377dc17c007c1ec71580cee165f092005
V2 Signer: public key SHA-1 digest: 0d250d00e9701ec0fd9490bf7c05780a159c53bb
V2 Signer: public key MD5 digest: cbcd0a8b35d63a24519e278ccbdd8dca
"""
CI_DEBUG_CERT = "df6b9ffefba89c7f40b0ee04b7c5b738af47611b50a51ce6b05bc8786c58ad51"

RELEASE = "3f" * 32
OTHER = "a1" * 32
#: How apksigner names the nth signer: by scheme (current build tools), with key rotation, and by number (older).
STYLES = {
    "scheme": lambda n: ("V2 Signer:", "V3 Signer:", "V3.1 Signer (minSdkVersion=33, maxSdkVersion=2147483647):")[n - 1],
    "numbered": lambda n: f"Signer #{n}",
}


def certs(*signers: tuple[str, str], verifies: str = "Verifies", style: str = "scheme") -> str:
    lines = [verifies, "Verified using v1 scheme (JAR signing): false",
             "Verified using v2 scheme (APK Signature Scheme v2): true",
             "Verified using v3 scheme (APK Signature Scheme v3): true",
             "Verified using v3.1 scheme (APK Signature Scheme v3.1): false",
             "Verified using v4 scheme (APK Signature Scheme v4): false",
             "Verified for SourceStamp: false", f"Number of signers: {len(signers)}"]
    for n, (dn, sha256) in enumerate(signers, 1):
        who = STYLES[style](n)
        lines += [f"{who} certificate DN: {dn}",
                  f"{who} certificate SHA-256 digest: {sha256}",
                  f"{who} certificate SHA-1 digest: {'0b' * 20}",
                  f"{who} certificate MD5 digest: {'0c' * 16}",
                  f"{who} key algorithm: RSA",
                  f"{who} key size (bits): 2048",
                  f"{who} public key SHA-256 digest: {'0d' * 32}"]
    return "\n".join(lines) + "\n"


def label(n: int, style: str = "scheme") -> str:
    """The signer's name in check messages: what apksigner calls it, without the colon."""
    return STYLES[style](n).rstrip(":")


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

def test_the_apk_ci_builds_is_refused_for_the_debug_key_even_expecting_its_own_certificate():
    assert rc.signer_problem(CI_CERTS, CI_DEBUG_CERT) == (
        "the APK is signed with the debug key (V2 Signer: C=US, O=Android, CN=Android Debug)")


def test_the_real_output_signed_with_the_release_key_passes_only_against_its_certificate():
    released = CI_CERTS.replace("C=US, O=Android, CN=Android Debug", RELEASE_DN)
    assert rc.signer_problem(released, CI_DEBUG_CERT) is None
    assert rc.signer_problem(released, RELEASE) == (
        f"V2 Signer is the certificate {CI_DEBUG_CERT}, not the release certificate {RELEASE}")


@pytest.mark.parametrize("style", sorted(STYLES))
def test_signed_with_the_release_certificate(style):
    assert rc.signer_problem(certs((RELEASE_DN, RELEASE), style=style), RELEASE) is None


def test_a_source_stamp_isnt_the_apks_signer():
    stamped = CI_CERTS.replace("C=US, O=Android, CN=Android Debug", RELEASE_DN) + (
        f"Source Stamp Signer certificate DN: {DEBUG_DN}\nSource Stamp Signer certificate SHA-256 digest: {OTHER}\n")
    assert rc.signer_problem(stamped, CI_DEBUG_CERT) is None
    only_stamp = "Verifies\n" + f"Source Stamp Signer certificate DN: {RELEASE_DN}\n" + (
        f"Source Stamp Signer certificate SHA-256 digest: {RELEASE}\n")
    assert rc.signer_problem(only_stamp, RELEASE) == "apksigner names no signer"


def test_the_digest_may_be_written_with_colons_and_capitals():
    pretty = ":".join(RELEASE[i:i + 2] for i in range(0, 64, 2)).upper()
    assert rc.signer_problem(certs((RELEASE_DN, RELEASE)), pretty) is None
    assert rc.signer_problem(certs((RELEASE_DN, pretty)), f"  {RELEASE}\n") is None


@pytest.mark.parametrize("style", sorted(STYLES))
def test_the_debug_key_is_refused_even_when_it_is_the_certificate_expected(style):
    """Setting ANDROID_CERT_SHA256 to the debug certificate (copied from a CI log, say) doesn't let it through."""
    problem = rc.signer_problem(certs((DEBUG_DN, OTHER), style=style), OTHER)
    assert problem == f"the APK is signed with the debug key ({label(1, style)}: {DEBUG_DN})"


@pytest.mark.parametrize("style", sorted(STYLES))
def test_another_certificate_is_refused(style):
    assert rc.signer_problem(certs((RELEASE_DN, OTHER), style=style), RELEASE) == (
        f"{label(1, style)} is the certificate {OTHER}, not the release certificate {RELEASE}")


@pytest.mark.parametrize("style", sorted(STYLES))
def test_every_signer_must_be_the_release_certificate(style):
    second, third = label(2, style), label(3, style)
    mixed = certs((RELEASE_DN, RELEASE), (RELEASE_DN, OTHER), style=style)
    assert rc.signer_problem(mixed, RELEASE).startswith(f"{second} is the certificate {OTHER}")
    debug = certs((RELEASE_DN, RELEASE), (RELEASE_DN, RELEASE), (DEBUG_DN, RELEASE), style=style)
    assert rc.signer_problem(debug, RELEASE) == f"the APK is signed with the debug key ({third}: {DEBUG_DN})"


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


@pytest.mark.parametrize("style", sorted(STYLES))
def test_output_naming_no_signer_or_half_a_signer_never_passes(style):
    who, name = STYLES[style](1), label(1, style)
    assert rc.signer_problem("Verifies\nNumber of signers: 1\n", RELEASE) == "apksigner names no signer"
    half = f"Verifies\n{who} certificate DN: {RELEASE_DN}\n"
    assert rc.signer_problem(half, RELEASE) == f"{name}'s certificate can't be read"
    bad = half + f"{who} certificate SHA-256 digest: 1234\n"
    assert rc.signer_problem(bad, RELEASE) == f"{name}'s certificate can't be read"


@pytest.mark.parametrize("style", sorted(STYLES))
def test_the_public_key_digest_isnt_taken_for_the_certificate(style):
    who = STYLES[style](1)
    output = f"Verifies\n{who} certificate DN: {RELEASE_DN}\n{who} public key SHA-256 digest: {RELEASE}\n"
    assert rc.signer_problem(output, RELEASE) == f"{label(1, style)}'s certificate can't be read"


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

def test_a_release_is_drafted_for_a_version_tag_only(tmp_path):
    root = tree(tmp_path)
    assert rc.version_problems("v1.0.0", root, tag_only=True) == ("1.0.0", [])
    assert rc.version_problems("refs/tags/v1.0.0", root, tag_only=True) == ("1.0.0", [])
    for ref in ("main", "0123abc", "v1.0", "release/1.0.0", ""):
        version, problems = rc.version_problems(ref, root, tag_only=True)
        assert version is None and problems[0].endswith("isn't a version tag (v1.0.0): a release is drafted for a tag only")
    assert rc.version_problems("v1.0.1", root, tag_only=True)[1] == [
        "v1.0.1 names version 1.0.1, but the files carry 1.0.0"]


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
    assert rc.main(["version", "main", "--tag"]) == 1 and "isn't a version tag" in capsys.readouterr().err
    assert rc.main(["version", f"v{version}", "--tag"]) == 0 and capsys.readouterr().out == f"{version}\n"


# --- the workflows run them -------------------------------------------------------------------------------------------

def workflow(name: str) -> str:
    return (ROOT / ".github/workflows" / name).read_text(encoding="utf-8")


def jobs(text: str) -> dict[str, str]:
    """Each job's text, by its id (the two-space-indented keys under `jobs:`)."""
    parts = re.split(r"^  ([A-Za-z0-9_-]+):\n", text.split("\njobs:\n", 1)[1], flags=re.M)
    return dict(zip(parts[1::2], parts[2::2]))


def test_the_release_build_runs_every_check_and_only_drafts():
    text = workflow("release.yml")
    trigger = text.split("\non:", 1)[1].split("\npermissions:", 1)[0]
    assert "workflow_dispatch:" in trigger and not re.search(r"^\s+(push|pull_request|release|schedule):", trigger, re.M)
    assert re.search(r"^permissions:\n  contents: read\n\n", text, re.M), "the workflow's token can only read"
    found = jobs(text)
    assert set(found) == {"android", "bridge", "draft-release"}
    for check in ("release_checks.py version", "release_checks.py permissions",
                  'release_checks.py signer certs.txt --release-cert "$RELEASE_CERT"'):
        assert check in found["android"], check
    assert "apksigner\" verify --verbose --print-certs" in found["android"]
    assert text.count("shell: bash") >= 3, "pipefail: a failing aapt, apksigner or sha256sum fails the step"
    assert "key.properties" in text and 'rm -f android/key.properties "$RUNNER_TEMP/fieldworx-release.jks"' in text
    # Only the draft job can write, only for a version tag, after both builds, and it checks before it drafts.
    assert [name for name, body in found.items() if "contents: write" in body] == ["draft-release"]
    draft = found["draft-release"]
    assert "    if: startsWith(inputs.ref, 'v') || startsWith(inputs.ref, 'refs/tags/v')\n" in draft
    assert "    needs: [android, bridge]\n" in draft
    order = [draft.index(step) for step in ('release_checks.py version "$REF" --tag', 'sha256sum -c "fieldworx-$VERSION.apk.sha256"',
                                            'sha256sum -c "fieldworx-bridge-$VERSION.sha256"', "gh release create")]
    assert order == sorted(order), "every check comes before the draft"
    create = draft[draft.index("gh release create"):]
    assert "--draft" in create and "--verify-tag" in create
    for never in ("--draft=false", "gh release edit", "gh release upload", "git tag", "git push", "gh api", "softprops/",
                  "upload-release-asset"):
        assert never not in text, never
    # What the draft attaches is what the builds named and summed.
    assert 'cp build/app/outputs/flutter-apk/app-release.apk "../release/fieldworx-$VERSION.apk"' in found["android"]
    assert 'tee "fieldworx-$VERSION.apk.sha256"' in found["android"]
    assert 'tee "fieldworx-bridge-$VERSION.sha256"' in found["bridge"]


def test_ci_refuses_its_own_apk_for_the_debug_key():
    text = workflow("ci.yml")
    assert "release_checks.py permissions perms.txt" in text
    assert "release_checks.py signer certs.txt --release-cert" in text and "grep -q \"signed with the debug key\"" in text
    # The certificate it is told to expect is the APK's own, read from apksigner's output in either style.
    pattern = re.search(r"sed -n -E 's/(.+?)//p' certs.txt", text)[1]  # an ERE that Python reads the same
    for output in (CI_CERTS, certs((DEBUG_DN, OTHER), style="numbered")):
        found = [re.sub(pattern, "", line) for line in output.splitlines() if re.match(pattern, line)]
        assert found and found[0] in (CI_DEBUG_CERT, OTHER)
