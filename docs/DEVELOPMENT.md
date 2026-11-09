# Developing FieldWorx

How the repository is laid out, how to build and test each part, and how changes are made. The rules for people
and AI agents working here are in [AGENTS.md](../AGENTS.md).

## Layout

```
app/        the Flutter app (Android, iOS)
  lib/        screens, theme, the model; platform/ is the only code that touches plugins
  test/       widget tests: the real store and demo package, faked camera/viewer/picker/share sheet
  assets/demo/demo.fieldworx   the built-in demo package
  android/, ios/               platform projects (see "Platform folders")
core/       fieldworx_core: the protocol and store in pure Dart (no dependencies); bin/fxtool.dart
bridge/     fieldworx-bridge: the office side in Python (standard library only)
spec/       make_vectors.py and vectors/: the shared protocol test vectors
examples/demo/   build_demo.py: the demo workspace, OpenMeridian sample and package, from scratch
tools/interop.sh the bridge and the Dart core end to end through real files
docs/       architecture, protocol, roadmap, user guide, limitations, ecosystem review
```

## Toolchain

| Part | Needs |
|---|---|
| app | Flutter **3.47.9** (Dart 3.13); Android SDK 36, JDK 17; Xcode 16 for iOS |
| core | Dart ≥ 3.5 |
| bridge | Python ≥ 3.10; RevisionWorx (integration API 1) for `pack`; OpenMeridian optional; DraftWorx optional |

The app pins Flutter in CI (`.github/workflows/ci.yml`). `app/pubspec.lock` records the plugin versions CI
resolved; commit it when it changes (CI uploads it as the `pubspec-lock` artifact).

## Running the tests

```sh
# Bridge (RevisionWorx and OpenMeridian installed, e.g. from their repositories)
python -m pip install -e "bridge[dev]"     # pytest, and the test-only checks for labels (python-qrcode, zxing-cpp, pdfium)
python -m pytest bridge -q

# The release build's checks (standard library; pytest only)
python -m pytest tools -q

# The vectors are what the reference produces
python spec/make_vectors.py --check

# Dart core
cd core && dart pub get && dart test && cd ..

# End to end: bridge packs, the Dart core plays the phone, the bridge imports and reports
bash tools/interop.sh

# App
cd app && flutter pub get && flutter analyze && flutter test
```

Bridge tests marked `revisionworx` build the demo through RevisionWorx's real command line and are skipped when
RevisionWorx isn't installed. Everything runs offline once dependencies are installed.

## Changing the protocol

The protocol has two implementations that must agree byte for byte. A change to anything in
[PROTOCOL.md](PROTOCOL.md):

1. Write it into PROTOCOL.md first, including what an old reader does with the new data.
2. Change the Python reference (`bridge/fieldworx_bridge/`) and add the cases to `spec/make_vectors.py`.
3. Regenerate: `python spec/make_vectors.py` (archives are only rewritten with `--force-archives`).
4. Change the Dart core until `dart test` passes the new vectors.
5. Run `tools/interop.sh`.

A change that an existing reader would misread needs a new version number (`v` of events, `version` of the
archive, catalog or template), and readers refuse versions newer than they know.

## The demo package

`app/assets/demo/demo.fieldworx` is built, not hand-made:

```sh
python examples/demo/build_demo.py /tmp/demo --history --package app/assets/demo/demo.fieldworx
```

It makes a RevisionWorx workspace from scratch through RevisionWorx's command line (author `dwhitfield`), an
OpenMeridian sample company if OpenMeridian is installed (stock figures), records the two units' acceptance tests
in the workspace's hub (`--history`), and packs it all. The widget tests rely on its content (unit tags, the FRM-200
revisions, K1, PMP-10's stock), so rebuild it when the demo changes and run `flutter test`.

## Platform folders

`app/android` and `app/ios` are what `flutter create --platforms=android,ios --org io.github.nrobertson152
--project-name fieldworx` writes with Flutter 3.47.9 (AGP 9.1.0, Kotlin 2.4.0, Gradle 9.3.1, Swift Package Manager
on), then changed as follows:

- **Android** (`app/src/main/AndroidManifest.xml`): label *FieldWorx*; `CAMERA` permission with the camera
  feature optional; network, microphone and shared-storage permissions removed from every library (ADR-012; the
  debug manifest keeps `INTERNET` for Flutter's tools);
  `allowBackup="false"` and `res/xml/data_extraction_rules.xml` so the store is never backed up or transferred
  (ADR-004).
- **Android** (`app/build.gradle.kts`): application id `io.github.nrobertson152.fieldworx`; release signing
  from `android/key.properties` when it exists, otherwise the debug key.
- **iOS** (`Runner/Info.plist`): display name *FieldWorx*; camera and photo-library usage descriptions;
  `ITSAppUsesNonExemptEncryption` false (FieldWorx hashes but doesn't encrypt). Deployment target iOS 15 (pdfrx).
- **Icons:** placeholder marks (the family's blue tile with the scan glyph) until the Director supplies artwork:
  adaptive and legacy Android launcher icons, iOS app icons and launch image.

## Signing and releases

AGENTS.md says who makes a release. CI builds a release-mode APK signed with the debug key, for testing only; it is
never released. Android won't update an app signed with one key to one signed with another, so a phone moves from a test
build to a release by sending its field log, uninstalling the test build (which deletes what wasn't sent) and installing
the release; it then has a new key and is enrolled again.

**The release build** is the *Release build* workflow (`.github/workflows/release.yml`): Actions → *Release build* →
*Run workflow*, given the tag (`v1.0.0`) or a commit. It

1. checks that the app, the core and the bridge carry one version, and that the tag names it;
2. builds the APK signed with the release key from the repository's secrets, and fails if any is missing: it never falls
   back to the debug key;
3. refuses the APK if it is signed with the debug key, or with any other certificate than the release one, or asks for
   more than the camera;
4. builds the bridge's wheel and source, and checks the wheel installs and reports the version;
5. given a version tag, drafts that tag's GitHub Release with the APK, the bridge and their SHA-256 sums, each file
   checked against its sum first. Given a commit, it drafts nothing: that is how to try the signed build before tagging.

Only the drafting job can write, and it never publishes or makes a tag: a person writes the notes on the draft and
publishes it (AGENTS.md says who). The files are also the run's artifacts. The checks are `tools/release_checks.py`,
tested in CI (`python -m pytest tools`), where the Android build also checks that its own debug-signed APK is refused.

The release key is the Director's. Set once, in the repository's *Settings → Secrets and variables → Actions*:

| Name | Kind | What it is |
|---|---|---|
| `ANDROID_KEYSTORE_BASE64` | secret | the release keystore, base64-encoded (`base64 -w0 fieldworx-release.jks`) |
| `ANDROID_KEYSTORE_PASSWORD` | secret | the keystore's password |
| `ANDROID_KEY_ALIAS` | secret | the key's alias in it |
| `ANDROID_KEY_PASSWORD` | secret | the key's password |
| `ANDROID_CERT_SHA256` | variable | the release certificate's SHA-256 digest, as `keytool -list -v -keystore fieldworx-release.jks` prints it; the APK must be signed with exactly this certificate |

**Keep the keystore and its passwords safe, and backed up outside GitHub.** Every later version must be signed with the
same key. Without it, phones can only install a new version by uninstalling FieldWorx first, which deletes every record
they haven't sent.

To sign on a computer instead, create `app/android/key.properties` (never committed; it's in `.gitignore`):

```properties
storeFile=/path/to/fieldworx-release.jks
storePassword=…
keyAlias=fieldworx
keyPassword=…
```

run `flutter build apk --release`, and make the same checks: `python3 tools/release_checks.py signer CERTS
--release-cert SHA256` on the output of `apksigner verify --verbose --print-certs`, and `permissions` on the output of
`aapt dump permissions`.

iOS signing needs the Director's Apple developer team in Xcode. Until there is one, FieldWorx is released for Android
only; CI builds iOS for the simulator so that it keeps building.

## Checking on a real phone

The widget tests fake the camera, PDF engine, file picker, photo capture and share sheet, and CI runs on computers,
not phones. Before a release, check on at least one Android phone (and an iPhone if iOS is released). The office
steps need RevisionWorx 1.0.0 with a workspace set up for a team, and the bridge.

1. First run asks for a name; **Try the demo** installs it.
2. The camera opens on the Scan tab (permission asked once) and decodes a printed `FWX:A:HPU-0001` QR code and a
   Code 128 barcode; it stops when another tab or page is open.
3. A drawing opens, pinch-zooms smoothly, and *find text* highlights `LIFTING` on FRM-200 rev B.
4. An inspection photo can be taken; it shows in the item and full screen.
5. **Send field log** opens the share sheet, and the file saved from it passes `fieldworx-bridge verify` and imports.
6. **Add a package** picks a `.fieldworx` file from Downloads.
7. Turn airplane mode on: everything above still works.
8. High Contrast theme is readable outdoors.
9. **Labels:** `fieldworx-bridge labels` sheets printed on each stock in use (A4 70 x 37 mm, US Letter 2-5/8 x 1 in,
   50 x 25 mm, 25 x 12 mm) scan from the phone at arm's length: a unit, a part and a project from each.
10. **Findings:** on a unit's page, **Report a finding** for a part replaced, with a photo; sent in a field log,
    `fieldworx-bridge findings` lists it and `accept` records it in RevisionWorx.
11. **Signing and enrolment:** **Library → This phone** shows the fingerprint; `fieldworx-bridge enrol` with that
    fingerprint and a field log from the phone enrols it; a finding from it is then accepted as *verified* in the
    account's name. `revisionworx user device revoke` (or the Accounts window) makes its next findings *reported*.
12. **Many records at once** (with a hub that holds a few thousand records): a package made from it says it is
    checking them, and the app stays usable meanwhile.
13. **Kept out of backups:** Android: a device-to-device transfer or `adb backup` doesn't carry FieldWorx's records.
    iPhone: after the app has opened once, an encrypted Finder or iTunes backup doesn't hold FieldWorx's store, and the
    Library doesn't say it couldn't keep it out (KNOWN_LIMITATIONS.md).

## Continuous integration

`.github/workflows/ci.yml` runs on every push to `main` and every pull request:

| Job | Runs |
|---|---|
| Bridge (Python 3.10, 3.13) | the bridge's tests with RevisionWorx and OpenMeridian installed from their repositories; the vector check |
| Dart core | analysis and the vector and store tests |
| Bridge ⇄ core | `tools/interop.sh`, and the shipped demo package verified by both |
| App | `flutter analyze` and the widget tests |
| Android | a release-mode APK (uploaded as an artifact, signed with the debug key) and a check that it asks for no permission but the camera |
| iOS | a simulator build |

RevisionWorx and OpenMeridian are installed from their default branches, so CI also notices when a sibling changes
a contract FieldWorx relies on.

## Working on the repository

- One branch and one pull request per piece of work; `main` only changes through reviewed pull requests.
- Every behaviour change comes with a test that fails without it. Don't weaken a test to make CI pass.
- No new runtime dependency without a reason in the pull request: the core has none, the bridge only the
  standard library, the app only the plugins listed in `app/pubspec.yaml` (each open source and offline).
- Keep [ARCHITECTURE.md](ARCHITECTURE.md), [PROTOCOL.md](PROTOCOL.md) and [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md)
  true to the code; label anything not built yet.
- Every source file starts with `SPDX-License-Identifier: GPL-3.0-or-later`.
