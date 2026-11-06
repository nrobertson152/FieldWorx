# Changelog

All notable changes to FieldWorx. Versions and release dates are set by the Director when a release is made.

## Unreleased (proposed 0.1.0)

The first field release: QR scanning, engineering document access, part lookup and basic inspections.

### Added

- **App** (Flutter, Android and iOS): Scan, Find, Inspect and Library tabs.
  - Scanning of FieldWorx labels (`FWX:A:`, `FWX:P:`, `FWX:D:`, `FWX:J:`), serial plates, part numbers, makers' part
    numbers, supplier codes and reference designators; typed codes and rugged-phone scanners; several matches
    listed, none guessed.
  - Unit pages with as-built revisions, revisions released since, and inspection history.
  - Document pages with every revision's state; released PDFs with zoom and text search; superseded and unreleased
    revisions flagged.
  - Part pages with stock on hand (OpenMeridian, marked not live), makers and suppliers, BOM made-from and used-in
    with reference designators, units, and printable labels.
  - Inspections from controlled templates: checks, exact measurements against limits, text, choices, photos, notes;
    complete, reopen and void with reasons; conflicts between phones shown and settled by a person; completions
    changed afterwards flagged.
  - Packages added from files or the built-in demo, verified completely first; field logs sent through the share
    sheet and imported from other phones.
  - The family's six themes with text held to 4.5:1 contrast; release builds ask for the camera and nothing else; the store
    excluded from backups.
- **Core** (`fieldworx_core`, pure Dart): canonical JSON, SHA-256, streaming ZIP/ZIP64, archives, field events,
  inspection templates and reduction, catalog and search, label resolution, the on-device store, and `fxtool`.
- **Bridge** (`fieldworx-bridge`, Python standard library): `pack` from RevisionWorx through `revisionworx link`
  with OpenMeridian stock and DraftWorx PDFs; `import`, `status`, `report` and `verify`; the write-once hub.
- **Protocol 1** ([docs/PROTOCOL.md](docs/PROTOCOL.md)) with shared vectors both implementations reproduce.
- **Demo**: Northline Hydraulics' HPU-75, built from scratch through RevisionWorx, with two units and their
  acceptance tests.
- **Documentation**: architecture and decisions, protocol, roadmap, user guide, known limitations, development
  guide, and a review of the family from the shop floor.
- **CI**: the bridge against real RevisionWorx and OpenMeridian, the Dart core, both end to end, widget tests,
  Android and iOS builds.
