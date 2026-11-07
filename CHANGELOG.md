# Changelog

All notable changes to FieldWorx. Versions and release dates are set by the Director when a release is made.

## Unreleased (proposed 1.0.0)

The first field release: QR scanning, engineering document access, part lookup and basic inspections.

### Added

- **App** (Flutter, Android and iOS): Scan, Find, Inspect and Library tabs.
  - Scanning of FieldWorx labels (`FWX:A:`, `FWX:P:`, `FWX:J:`), serial plates, part numbers, makers' part
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
- **Units from RevisionWorx's unit register** (catalog version 2; version 1 still opens):
  - The bridge packs a workspace's units through `revisionworx link units` when RevisionWorx has a unit register:
    the chosen projects' units, every unit fitted in them, and every revision they name. A unit's earlier `ast_`
    id (from an asset register row) comes along as an alias, so records already made against it stay attached; an asset register row for
    a unit the register holds is left out.
  - Unit pages show every identifier with its issuer (and former ones), customer, site, status and dates, the build
    standard, the revisions that apply with where each came from and how well it is known, what is fitted and
    where the unit is fitted, and its history with voided entries marked.
  - Engineering changes that reach a unit (RevisionWorx's `unit-changes` feature): each retrofit, modification or drawing
    correction, the drawings it moves, and where it stands on the unit; outstanding required changes are counted at the top.
  - Labels: `FWX:A:unt_…` opens a unit by its permanent id (an earlier `ast_` id too, and never a tag that looks the
    same); a unit's *Show label* gives its permanent label. Former codes still find a unit, marked *former*.
  - Shared vectors for catalogs (`catalogs.json`) and a sample package of units (`units.fieldworx`).
- **PDFs engineering attached to native drawings** (RevisionWorx's `pdf-derivatives` feature): an Inventor, SolidWorks or
  other CAD revision opens on the phone through the PDF attached to exactly that revision (`revisionworx doc pdf`); a revision
  without one never shows another revision's.
- **Labels:**
  - `fieldworx-bridge labels` prints labels for a package's units and assets, parts or projects, as a PDF for A4 or US Letter label sheets or a label printer (50 x 25 mm, or 25 x 12 mm for components
    and bins, which carries just the code, its kind and its number). Each label has a QR code (level Q), what
    it is, its number, a description and the code to type. `--only`, `--skip` and `--copies` pick what and where.
  - Drawings have no label. Which revision applies depends on the machine, so its label finds the revisions it is
    built to. Document and revision labels (`FWX:D:`, `FWX:R:`) were tried and withdrawn before release: scanned,
    they match nothing and say to scan the machine or search for the drawing.
  - `fwx_label.py`, the standard-library QR encoder a program copies to print FieldWorx labels, checked bit for bit
    against python-qrcode and read back with zxing-cpp.
  - A label of a kind the phone doesn't read (`FWX:L:…`) now matches nothing and says so, as the protocol says. It
    used to be matched by its code alone.
- **Demo**: Northline Hydraulics' HPU-75, built from scratch through RevisionWorx, with two units and their
  acceptance tests.
- **Documentation**: architecture and decisions, protocol, roadmap, user guide, known limitations, development
  guide, and a review of the family from the shop floor.
- **CI**: the bridge against real RevisionWorx and OpenMeridian, the Dart core, both end to end, widget tests,
  Android and iOS builds.
