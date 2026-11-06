# FieldWorx roadmap

What is built, what comes next, and in what order. Versions are proposals: releases, version numbers and tags are
the Director's to decide. Each step keeps the rules of [ARCHITECTURE.md](ARCHITECTURE.md): engineering stays
read-only on phones, field records are append-only, nothing is resolved silently, nothing needs the cloud.

## 0.1: the first field release (this work)

The directive's first scope: **QR scanning, engineering document access, part lookup and basic inspections.**

- Scan FieldWorx labels, maker's barcodes, serial plates, supplier codes and reference designators; type a code
  or use a rugged phone's scanner; several matches shown, never guessed.
- Units (assets) with their as-built revisions, what has been revised since, and their inspection history.
- Documents with every revision's state; released PDFs pinch-zoomable and searchable; superseded and unreleased
  revisions flagged in red and amber.
- Parts: makers' and suppliers' codes, BOM *made from* and *used in* with reference designators, stock on hand
  from OpenMeridian (marked not live), labels.
- Inspections from controlled templates: checks, exact measurements against limits, text, choices, photos,
  notes; complete, reopen, void; conflicts between phones shown and settled.
- Files as the transport: packages in, field logs out, phone to phone; `fieldworx-bridge` packs, imports,
  reports and verifies.
- Six family themes, AA contrast, large targets; no network permission in release builds.
- Tests: protocol vectors shared by Python and Dart, the bridge against real RevisionWorx and OpenMeridian,
  widget tests of every v0.1 workflow, an end-to-end run, Android and iOS builds in CI.

## 0.2: closing the loop

1. **LAN sync** (ARCHITECTURE.md section 7): `fieldworx-bridge serve`, pairing by QR code with a pinned
   certificate, frontier exchange of events and objects, packages offered automatically.
2. **Device keys:** every event signed with the phone's Ed25519 key; keys registered at the hub on first import;
   reports show who recorded what and whether the signature holds.
3. **Nonconformances:** a nonconformance record (what, where, severity, photos, disposition) on a unit, part or
   inspection item; the bridge turns it into a draft ECR through RevisionWorx (needs ECOSYSTEM_REVIEW.md W6), and the
   ECR number comes back to the phone in the next package.
4. **Redlines:** markup on a snapshot of a drawing page or a photo, attached to a nonconformance or proposed
   change. The drawing itself is never touched.
5. **"Is this print current?"** labels: `FWX:R:<document>@<revision>`.
6. **Label sheets:** `fieldworx-bridge labels` writes a PDF of QR labels for units, parts, bins and documents.
7. **Opening files from other apps:** a `.fieldworx` or `.fieldlog` tapped in e-mail or a file manager opens
   in FieldWorx.
8. **Hardware scanners:** keyboard-wedge input without focusing the code field; Zebra DataWedge intents.

## 0.3: work in the field

1. **Work orders:** a job for a unit (from the office or raised on the phone), with its documents, templates
   and parts; status, time and parts used recorded as events.
2. **Inventory transactions:** counts, receipts, transfers and consumption recorded offline and imported into
   OpenMeridian as movements for approval (needs W3; lots and serials need W4).
3. **As-built capture:** component serials scanned into a unit's record during assembly.
4. **Instrument traceability** and **witness sign-off** on inspections.
5. **Planned maintenance** from controlled interval documents.

## Later

- Incremental packages (needs W7) and work packs for one job.
- Schematic navigation: component index from OpenSchematix (needs W2), "find K1" opening the right sheet.
- Photos carried in packages (optional, size-limited), so history photos show on every phone.
- A desktop viewer for the hub (inspection register, unit history) inside the family's look.

## Not planned

- Editing engineering documents on a phone.
- Accounts, cloud services, telemetry, subscriptions or advertising.
- Resolving conflicting records automatically.
