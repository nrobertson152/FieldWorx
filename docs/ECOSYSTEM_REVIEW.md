# The family, seen from the shop floor

The directive asked for a study of RevisionWorx, OpenSchematix, DraftWorx and OpenMeridian: their weaknesses for
field use, improvements to recommend, and features worth adding. This is that study, made while building FieldWorx
0.1 against their documented interfaces (November 2026: RevisionWorx 1.0.0 with integration API 1, OpenMeridian
company file format 1, DraftWorx command interface, OpenSchematix project format 1). FluidWorx was not studied;
FieldWorx reaches it only through PDFs published in RevisionWorx.

Each recommendation names the program that would own it. FieldWorx changes none of them: by the family rule,
programs reach each other only through documented files and command lines.

## What the family already gets right

- **One integration shape.** `revisionworx link` and `draftworx` both answer every command with exactly one JSON
  object, `ok` true or false, and a refusal changes nothing. The bridge needed no imports and no screen-scraping.
- **Hashes as identity.** RevisionWorx records each revision's SHA-256. FieldWorx names files by the same hash, so
  "the drawing on this phone is exactly the released revision" is checkable end to end, and the bridge refuses to
  pack content whose hash doesn't match.
- **Append-only where it matters.** OpenMeridian's `stock_moves` and audit tables reject updates and deletes;
  RevisionWorx revisions are immutable. FieldWorx's field records follow the same principle.
- **Offline, local, no accounts by default.** Everything works on a laptop in a container on site.
- **Fail closed.** Every program refuses damaged or newer-format data with a message instead of guessing.

## Weaknesses for field use, and what to do

### W1. Nothing listens on a network (all programs)

The desktop programs work on files; none can be asked anything over a network. That is deliberate and right for
their integrity, but it means a phone can only receive what someone exports.
**FieldWorx's answer:** a separate, opt-in bridge (v0.1 files; v0.2 a paired LAN listener, ARCHITECTURE.md
section 7). **Recommendation:** keep it that way. No listener should be added to RevisionWorx itself; the bridge
reads through `link` and can be stopped at any time.

### W2. Native formats can't be shown on a phone (OpenSchematix, DraftWorx, CAD)

**FieldWorx's answer:** PDF renditions made on the desktop (ADR-009). DraftWorx already has `draftworx pdf`, which
the bridge uses. **Recommendations:**

- **OpenSchematix:** a JSON command line in the same shape as `draftworx`: `openschematix pdf PROJECT OUT.pdf`
  (every sheet, as Export PDF prints it) and `openschematix components PROJECT` (reference designators, symbol,
  sheet, part number, terminals, wire numbers). Today PDF export is only in the window, and the scripting API would
  have to be imported, which the family rule forbids. With these two commands, packages would carry schematics
  automatically and the phone could answer "where is K1?" with the sheet and zone, not just the part.
- **RevisionWorx:** a documented *rendition* relation: "this PDF is the printable form of that revision of that
  native document". Today engineering publishes the PDF as a separate document (the demo's `SCH-HPU-75` and
  `SCH-HPU-75-PDF`), and nothing ties the two revisions together, so a stale PDF can sit next to a new schematic.

### W3. Inventory can be read but not written from the field (OpenMeridian)

FieldWorx reads stock on hand (read-only SQLite, as COMPANY_FILE.md documents) and labels it *not live*. It cannot
record a count, a receipt, a transfer or consumption: OpenMeridian has no command line or import file for
transactions, and writing its database directly would bypass its rules.
**Recommendation (OpenMeridian):** a documented *movement import*: a file of proposed movements (item, quantity as
thousandths, bin, reason, who, when, and an idempotency key, for which FieldWorx would use the field record id),
checked all-or-nothing, shown for approval, and applied as ordinary `stock_moves`. Re-importing the same file would
change nothing. Offline counts would then reconcile as *count variances to approve*, never as overwritten stock.

### W4. No lots or serial numbers (OpenMeridian)

The directive's "serial/lot tracking" has nowhere to live: items have quantities and bins, not identities.
**Recommendation (OpenMeridian):** lot and serial records on receipts and issues (format version 2, with a
migration). Until then FieldWorx records serials in inspections (as the demo's nameplate item does) and in asset
registers.

### W5. There is no register of units built (RevisionWorx, OpenMeridian)

Field work is about *this* machine: serial NH-26-0001, built in March to frame revision A. Neither program records
which revisions a delivered unit was built to. **FieldWorx's answer for now:** asset registers, controlled CSV
documents in RevisionWorx (`*.fwassets.csv`, PROTOCOL.md section 6.4). **Recommendation (RevisionWorx):** an as-built
configuration per serial number (document revisions and part revisions installed), reachable through `link`, so
service history, retrofits and "which units does this ECO affect?" have one authority.
**Status:** built in RevisionWorx as its unit register (ADR-025, docs/UNITS.md: `revisionworx unit`,
`link units`/`link unit`), and packed by FieldWorx as catalog version 2. Asset registers remain for units the unit
register doesn't hold.

### W6. Field findings can't become engineering changes yet (RevisionWorx)

RevisionWorx has full change control (ECR → ECO, audited sign-offs) and `revisionworx change new-request` /
`import-csv` create draft ECRs, but not through `link`'s JSON contract, and they take no attachments.
**Recommendation (RevisionWorx):** `link change-request` with JSON in and out, attachments (photos, a marked-up
PDF), and an idempotency key so one field record can never create two ECRs. FieldWorx v0.2 would then turn a
nonconformance or a redline into a draft ECR that engineering reviews; the phone never edits a released document.

### W7. "What changed since my last package?" can't be asked (RevisionWorx)

`link documents` returns everything, so every package is rebuilt in full and the phone can't be told "three
drawings changed". **Recommendation (RevisionWorx):** `link changes --since TIME` (or a change counter), for
incremental packages and a "what's new" list on the phone.

### W8. People are names, and every program has its own (all)

RevisionWorx team workspaces have logins (ADR-024); OpenMeridian records a user name; FieldWorx records the name
typed on the phone. Nothing links them or proves who did what. **Recommendation (family):** a people register in
the workspace (name, role, and each person's or device's public key). FieldWorx's planned device keys (ADR-010)
would register there, so a hub could show "recorded on Jo Lee's tablet, signature valid".

### W9. Phones on iOS need Apple's accounts

The directive avoids accounts and subscriptions, but installing on an iPhone needs an Apple developer account
(free for personal side-loading, paid for distribution). Android needs none: a debug- or self-signed APK installs
directly. **Recommendation:** treat Android as the primary field platform; build iOS in CI so it stays working, and
leave its distribution to the Director.

## Features worth adding

Ordered by value to the shop floor for the effort.

1. **"Is this print current?"** DraftWorx and OpenSchematix title blocks carry a QR code `FWX:R:FRM-200@A`
   (document and revision). Scanning a paper print on the bench says at once whether it's still the released
   revision, and opens the current one if not. Stale prints are one of the commonest causes of rework; this needs a
   new label kind in FieldWorx and a title-block field in each drawing program.
2. **Nonconformance → draft ECR**, with photos and the exact revision in hand (needs W6).
3. **Label sheets from the bridge:** `fieldworx-bridge labels` writing a PDF of QR labels (units, parts, bins,
   documents) for any label printer, so adopting FieldWorx doesn't need special printing software.
4. **Instrument traceability:** a measurement records which gauge took it and its calibration due date (a gauge
   register document), as ISO 9001 7.1.5 asks.
5. **Witness and customer sign-off** on the same phone (hand it over, they type their name), recorded as its own
   event on the inspection.
6. **As-built capture during assembly:** scan the serial of each installed component into the unit's record,
   building the as-built BOM per unit (feeds W5).
7. **Planned maintenance:** intervals per unit type in a controlled document; the phone lists what's due, offline.
8. **Photo markup:** arrows and circles on an inspection photo or a drawing snapshot (a redline that never
   touches the drawing).
9. **Work packs:** a package for one job: the documents, templates and units of one work order, small enough to
   e-mail.
10. **Hardware scanners:** keyboard-wedge and intent output from rugged phones (Zebra, Honeywell) without tapping
    the code field first.

How these are sequenced is in [ROADMAP.md](ROADMAP.md).
