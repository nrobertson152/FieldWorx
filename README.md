# FieldWorx

**The field companion to RevisionWorx.** Scan a label on a machine and get the drawings it was built to, the
current released revision, its parts and stock, and its inspection history; record an inspection with photos;
send it back to the office. Offline, on Android and iOS, with no accounts, no cloud and no telemetry.

FieldWorx is part of a family of free engineering programs: [RevisionWorx](https://github.com/nrobertson152/revisionworx)
(documents and revisions), [OpenSchematix](https://github.com/nrobertson152/openschematix) (schematics),
[DraftWorx](https://github.com/nrobertson152/draftworx) (drawings), [OpenMeridian](https://github.com/nrobertson152/openmeridian)
(stock) and FluidWorx (hydraulics). Designers, builders, inspectors and field technicians all work from the same
released engineering, and nothing in the field can change it.

> **Status: 0.1 in development.** Scanning, documents and drawings, part lookup and inspections work end to end
> with the built-in demo. Not yet released: releases are made by the project's Director. See
> [docs/ROADMAP.md](docs/ROADMAP.md) for what comes next and [docs/KNOWN_LIMITATIONS.md](docs/KNOWN_LIMITATIONS.md)
> for what 0.1 doesn't do.

## How it works

```
 RevisionWorx workspace ─┐                                   ┌─────────────── phones ───────────────┐
 OpenMeridian stock ─────┼─► fieldworx-bridge pack ─► .fieldworx package ─►  scan · drawings · parts │
 DraftWorx (to PDF) ─────┘        (office PC)                                │  inspections · photos  │
                          fieldworx-bridge import ◄─ .fieldlog field log ◄──┘                        │
                          → inspection register and records                 └────────────────────────┘
```

- **Engineering is read-only on the phone.** A package is a verified snapshot of what RevisionWorx released: every
  file is checked against the SHA-256 RevisionWorx recorded, and superseded or unreleased revisions are flagged.
- **Field records are append-only.** Every answer, photo and sign-off is a permanent record named by its own hash,
  with who and which phone. Nothing is overwritten; two phones that answered the same thing offline show both
  answers until someone chooses.
- **No server.** Packages and field logs are files: USB, e-mail, a shared drive, the share sheet. Any phone or
  office can merge any other's records, in any order, any number of times. A release build asks for the camera
  and nothing else: no network, no storage, no microphone.

The design is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and the formats in [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Try it

Install the app (an APK from the latest CI run's artifacts, or build it: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)),
enter your name and tap **Try the demo (HPU-75)**: a hydraulic power unit with two units built, a revised frame
drawing, a schematic, a BOM, stock and a 16-item inspection plan. Then type `HPU-0001`, `K1` or `FRM-200` on the
Scan tab. The [user guide](docs/USER_GUIDE.md) walks through the rest, for the phone and for the office.

In the office:

```sh
python -m pip install ./bridge
fieldworx-bridge pack -w WORKSPACE --project J-2001 --meridian company.meridian -o J-2001.fieldworx
fieldworx-bridge import -w WORKSPACE FieldWorx-*.fieldlog
fieldworx-bridge report -w WORKSPACE -o reports
```

## Repository

| Folder | What |
|---|---|
| [`app/`](app) | the Flutter app |
| [`core/`](core) | the protocol, catalog and on-device store in pure Dart, no dependencies |
| [`bridge/`](bridge) | `fieldworx-bridge`, the office side, Python standard library only ([README](bridge/README.md)) |
| [`spec/`](spec) | shared protocol vectors both implementations must reproduce |
| [`examples/demo/`](examples/demo) | builds the demo workspace and package from scratch through RevisionWorx |
| [`docs/`](docs) | [architecture](docs/ARCHITECTURE.md), [protocol](docs/PROTOCOL.md), [roadmap](docs/ROADMAP.md), [user guide](docs/USER_GUIDE.md), [limitations](docs/KNOWN_LIMITATIONS.md), [development](docs/DEVELOPMENT.md), [ecosystem review](docs/ECOSYSTEM_REVIEW.md) |

## Testing

Every push runs the bridge against real RevisionWorx and OpenMeridian, the Dart core against the shared vectors,
the two end to end through real files, the app's widget tests on the real store with the demo package, and Android
and iOS builds. See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Licence

GNU General Public License v3.0 or later. See [LICENSE](LICENSE).
