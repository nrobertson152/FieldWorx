#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The checks a release build has to pass (.github/workflows/release.yml), kept here so they're tested without a key.

    release_checks.py version REF [--tag]
        The app, the core and the bridge carry one version, and a version tag (v1.0.0) names that version. Prints it.
        With --tag, REF must be a version tag: what the release is drafted for.
    release_checks.py permissions DUMP
        DUMP is the output of `aapt dump permissions APK`: the APK asks for the camera and nothing else.
    release_checks.py signer CERTS --release-cert SHA256
        CERTS is the output of `apksigner verify --verbose --print-certs APK`: the APK verifies, no signer is the debug
        key, and every signer is the release certificate.

Each exits 0 when everything passes, and 1, saying why on standard error, when anything doesn't. Output it can't read
is a failure too: a check that can't tell never passes. Standard library only, Python 3.10 or later.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

#: Where the version is written. app/test/app_test.dart checks the app's two agree; this checks all four.
VERSION_FILES = {
    "app/pubspec.yaml": re.compile(r"^version: (\d+\.\d+\.\d+)\+\d+$", re.M),
    "app/lib/version.dart": re.compile(r"^const String appVersion = '(\d+\.\d+\.\d+)';$", re.M),
    "core/pubspec.yaml": re.compile(r"^version: (\d+\.\d+\.\d+)$", re.M),
    "bridge/fieldworx_bridge/__init__.py": re.compile(r'^__version__ = "(\d+\.\d+\.\d+)"$', re.M),
}
TAG = re.compile(r"(?:refs/tags/)?v(\d+\.\d+\.\d+)")

#: What FieldWorx asks for: the camera, to scan. AndroidX adds a permission of the app's own, granted to no other app,
#: that keeps its receivers private; it is allowed under the app's own package name only.
ALLOWED = frozenset({"android.permission.CAMERA"})
OWN_PERMISSION = "{package}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"
PACKAGE = re.compile(r"package: (?:name=')?([A-Za-z]\w*(?:\.[A-Za-z]\w*)+)'?(?:\s.*)?")
ASKS = re.compile(r"uses-(?:implied-)?permission(?:-sdk-23|-sdk-m)?: (?:name=')?([^'\s]+)'?(?:\s.*)?")

#: The subject of Android's debug keystore, always C=US, O=Android, CN=Android Debug.
DEBUG_CN = "cn=android debug"
#: A signer's lines, as apksigner names them: "V2 Signer: certificate DN: …" (one signer per scheme verified, as the
#: build tools CI uses print it; "V3.1 Signer (minSdkVersion=33, …): …" with key rotation), or "Signer #1 certificate
#: DN: …" (older build tools). A source stamp's signer ("Source Stamp Signer …") isn't the app's and is left out.
_SIGNER = r"((?:V\d+(?:\.\d+)? )?Signer\b[^:]*?):?"
SIGNER_DN = re.compile(_SIGNER + r" certificate DN: (.+)")
SIGNER_SHA256 = re.compile(_SIGNER + r" certificate SHA-256 digest: ([0-9A-Fa-f: ]+)")


def versions(root: Path = ROOT) -> tuple[dict[str, str], list[str]]:
    """The version each file gives, and what couldn't be read."""
    found: dict[str, str] = {}
    problems: list[str] = []
    for name, pattern in VERSION_FILES.items():
        try:
            text = (root / name).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as e:
            problems.append(f"{name} can't be read ({getattr(e, 'strerror', None) or e})")
            continue
        hits = pattern.findall(text)
        if len(hits) != 1:
            problems.append(f"{name} doesn't give exactly one version")
        else:
            found[name] = hits[0]
    return found, problems


def version_problems(ref: str, root: Path = ROOT, *, tag_only: bool = False) -> tuple[str | None, list[str]]:
    """The one version the files carry, and what is wrong: files that disagree, a tag naming another version, or (with
    tag_only) a ref that isn't a version tag."""
    if tag_only and not TAG.fullmatch(ref.strip()):
        return None, [f"{ref.strip() or 'an empty ref'} isn't a version tag (v1.0.0): a release is drafted for a tag only"]
    found, problems = versions(root)
    distinct = sorted(set(found.values()))
    if len(distinct) > 1:
        problems.append("the versions differ: " + ", ".join(f"{name} has {v}" for name, v in found.items()))
    tag = TAG.fullmatch(ref.strip())
    if tag and distinct and distinct != [tag[1]]:
        problems.append(f"{ref.strip()} names version {tag[1]}, but the files carry {', '.join(distinct)}")
    if problems or not distinct:
        return None, problems or ["no version found"]
    return distinct[0], []


def permission_problems(dump: str) -> list[str]:
    """Everything the APK asks for beyond the camera, from `aapt dump permissions`."""
    package = None
    asked: list[str] = []
    problems: list[str] = []
    for raw in dump.splitlines():
        line = raw.strip()
        if m := PACKAGE.fullmatch(line):
            if package and package != m[1]:
                problems.append(f"the dump names two packages, {package} and {m[1]}")
            package = m[1]
        elif line.startswith(("uses-permission", "uses-implied-permission")):
            if m := ASKS.fullmatch(line):
                asked.append(m[1])
            else:
                problems.append(f"this line can't be read: {line}")
    if package is None:
        return ["the dump names no package: give it the output of `aapt dump permissions APK`"]
    allowed = ALLOWED | {OWN_PERMISSION.format(package=package)}
    problems += [f"the APK asks for {name}" for name in asked if name not in allowed]
    return problems


def digest(text: str) -> str | None:
    """A SHA-256 digest as 64 lower-case hex digits, however it was written (colons, spaces, capitals), or None."""
    d = re.sub(r"[\s:]", "", text or "").lower()
    return d if re.fullmatch(r"[0-9a-f]{64}", d) else None


def signer_problem(output: str, release_cert: str) -> str | None:
    """Why the APK isn't signed for release, from `apksigner verify --verbose --print-certs`, or None if it is."""
    lines = [line.strip() for line in output.splitlines()]
    if "DOES NOT VERIFY" in lines:
        return "apksigner says the APK doesn't verify"
    if "Verifies" not in lines:
        return "apksigner doesn't say the APK verifies (run `apksigner verify --verbose --print-certs APK`)"
    signers: dict[str, dict[str, str | None]] = {}
    for line in lines:
        if m := SIGNER_DN.fullmatch(line):
            signers.setdefault(m[1], {})["dn"] = m[2]
        elif m := SIGNER_SHA256.fullmatch(line):
            signers.setdefault(m[1], {})["sha256"] = digest(m[2])
    if not signers:
        return "apksigner names no signer"
    for label, s in signers.items():
        if not s.get("dn") or not s.get("sha256"):
            return f"{label}'s certificate can't be read"
        if DEBUG_CN in str(s["dn"]).lower():
            return f"the APK is signed with the debug key ({label}: {s['dn']})"
    want = digest(release_cert)
    if want is None:
        return ("there's no release certificate to check it against: set the repository variable ANDROID_CERT_SHA256 "
                "to its SHA-256 digest (docs/DEVELOPMENT.md)")
    for label, s in signers.items():
        if s["sha256"] != want:
            return f"{label} is the certificate {s['sha256']}, not the release certificate {want}"
    return None


def _read(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError as e:
        _say([f"{path} can't be read ({e.strerror or e})"])
        return None


def _say(problems: list[str]) -> int:
    for p in problems:
        print(f"release_checks.py: {p}", file=sys.stderr)
    return 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="release_checks.py", description=__doc__.split("\n\n")[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="check", required=True)
    version = sub.add_parser("version", help="the one version, and the one the tag names")
    version.add_argument("ref")
    version.add_argument("--tag", action="store_true", help="the ref must be a version tag")
    sub.add_parser("permissions", help="the camera and nothing else").add_argument("dump", type=Path)
    signer = sub.add_parser("signer", help="signed with the release certificate, never the debug key")
    signer.add_argument("certs", type=Path)
    signer.add_argument("--release-cert", default="", help="the release certificate's SHA-256 digest")
    args = parser.parse_args(argv)

    if args.check == "version":
        version, problems = version_problems(args.ref, tag_only=args.tag)
        if problems:
            return _say(problems)
        print(version)
        return 0
    text = _read(args.dump if args.check == "permissions" else args.certs)
    if text is None:
        return 1
    if args.check == "permissions":
        problems = permission_problems(text)
        return _say(problems) if problems else 0
    problem = signer_problem(text, args.release_cert)
    return _say([problem]) if problem else 0


if __name__ == "__main__":
    sys.exit(main())
