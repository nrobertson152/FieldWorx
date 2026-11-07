# FieldWorx architecture

FieldWorx puts RevisionWorx's released engineering in the hands of the people who build, inspect and service the
machine, and brings back what they record, without a server, an account or a network connection. This document is
the design: what each part does, why, and the decisions behind it (ADRs at the end). The byte-level formats are in
[PROTOCOL.md](PROTOCOL.md); what is planned but not built is in [ROADMAP.md](ROADMAP.md).

## 1. The problem

The family's desktop programs (RevisionWorx for documents and revisions, OpenSchematix for schematics, DraftWorx
for drawings, OpenMeridian for stock, FluidWorx for hydraulics) all run on Windows and Linux desktops and keep
their data in files on a local disk or a shared folder. None of them listens on a network. A phone can't open a
`.revisionworx` workspace, can't render a `.schematix` project or a `.draftworx` drawing, and is often somewhere with
no Wi-Fi at all: in a pit, on a ship, in a customer's plant.

So FieldWorx has to answer four questions:

1. **How does released engineering reach a phone** that may never see the office network, and how does the phone
   know what it has is genuine and current?
2. **How does a phone show it** when it can't read the native formats?
3. **How does what people record in the field get back**, from many phones, possibly recorded offline on two phones
   about the same thing at the same time, without ever overwriting anything?
4. **How does all of that stay attributable and traceable** with no accounts and no central server?

## 2. The shape of the answer

```
                 OFFICE (desktop, Windows or Linux)                                 FIELD (phones, tablets)

  RevisionWorx workspace ──revisionworx link (JSON)──┐
  OpenMeridian company file ──read-only SQLite───────┤
  DraftWorx ──draftworx pdf (JSON)───────────────────┤
                                                     ▼
                                          fieldworx-bridge pack ──── package (.fieldworx) ────►  FieldWorx app
                                                     ▲                read-only snapshot          scan · view · find
                                                     │                + field records             inspect
                                            WORKSPACE/.fieldworx  ◄── field log (.fieldlog) ────  records, photos
                                                 (the hub)            every record, append-only
                                                     │
                              fieldworx-bridge report: inspection register (CSV), one HTML record each
```

Two kinds of data move, in opposite directions, under opposite rules:

| | Engineering (authoritative) | Field records |
|---|---|---|
| Owner | RevisionWorx (and OpenMeridian for stock) | whoever recorded them, on whichever device |
| On the phone | a **read-only snapshot**: the package | an **append-only set** of signed-by-hash events |
| Changes by | engineering publishing a new revision, then a new package | adding records, never editing or deleting them |
| Moves | office → phones, in packages | everywhere, in field logs and packages |
| Integrity | every file named and checked by SHA-256, the same hash RevisionWorx recorded | every record named by the hash of its bytes, chained per device |
| Conflicts | impossible: phones never write engineering data | kept, shown and settled by a person; never resolved silently |

Everything else follows from keeping these two apart.

## 3. Components

### 3.1 The app (`app/`, Flutter)

Four tabs: **Scan** (the camera, or a typed or hardware-scanner code), **Find** (search and browse), **Inspect**
(inspections on this phone) and **Library** (packages, field logs, settings). The screens hold no rules of their
own: everything they show comes from the core.

Everything that touches the phone's hardware or another app (camera scanner, PDF engine, file picker, share sheet,
photo capture) is behind one interface, `FieldServices` (`lib/platform/services.dart`). The real implementation is
`lib/platform/plugins.dart`; the widget tests use `test/fakes.dart`, so every screen is tested against the real core
and the real demo package without a device.

The look follows the family: OpenSchematix's six themes (Modern Light and Dark, Graphite, Neutral Gray, Blueprint,
High Contrast) and its stroke-icon language, with every text colour held to WCAG AA (4.5:1) against its background,
tested. Targets are large (52 dp answer buttons) for gloved hands; High Contrast is for sunlight.

### 3.2 The core (`core/`, pure Dart, no dependencies)

The protocol and the data: canonical JSON, SHA-256, ZIP reading and writing (streamed, ZIP64), archives, field
events, inspection templates and their reduction, the catalog with its search, label resolution, and the
on-device store. It has no Flutter and no plugins, so it runs in the app, in `dart test` and on the command line
(`bin/fxtool.dart`, used by the end-to-end test to act as a phone).

### 3.3 The bridge (`bridge/`, Python, standard library only)

`fieldworx-bridge`, the office side:

- `pack` builds a package from a RevisionWorx workspace (through `revisionworx link` only), with stock from an
  OpenMeridian company file (opened read-only) and PDFs of DraftWorx drawings (through `draftworx pdf`).
- `import` brings field logs into the hub; `status` and `report` show what the hub holds.
- `verify` checks any package or field log without changing anything.
- `labels` prints FieldWorx labels for what a package holds, as a PDF for sheets of labels or a label printer (ADR-013).

It is the reference implementation of the protocol: `spec/make_vectors.py` writes the shared test vectors from it,
and the Dart core must reproduce them byte for byte.

### 3.4 The hub (`WORKSPACE/.fieldworx`)

The office's copy of every field record: a folder of write-once files beside `.revisionworx` (ADR-005). Because
nothing in it is ever edited, several computers can import into one hub on a shared folder without locks.

## 4. Sync without a server

The directive asks for many phones and desktops working together without central cloud infrastructure. FieldWorx
does it by making the field data a **grow-only set of immutable, content-addressed events** and every view of it a
**deterministic function of the set**:

- **Merge is set union.** Importing a field log (or a package carrying records) adds the events the receiver
  doesn't have. Union is commutative, associative and idempotent, so it doesn't matter who syncs with whom, in what
  order, or how many times: sending a field log twice is harmless.
- **State is a pure reduction.** An inspection's state is computed from its events sorted by id, never by arrival
  order (ADR-006). Two nodes holding the same events show the same state, byte for byte; the vectors in
  `spec/vectors/inspections.json` prove the Python and Dart reductions agree.
- **Causality is explicit.** Each event lists the events of the same entity its author had seen (`deps`). An answer
  "replaces" an earlier one only if it has seen it. Two answers that haven't seen each other are a conflict, and
  both are kept and shown until someone records a value that has seen both.
- **Integrity is structural.** An event's id is the SHA-256 of its canonical bytes; each device's events form a hash
  chain (`seq`, `prev`). A receiver can tell a missing history from a forked one (a phone restored from a backup
  that kept recording) and refuses a batch that doesn't fit, all or nothing.

Any topology then works, and the same files carry it:

| Path | How (1.0) |
|---|---|
| phone → office | the phone writes a field log; the share sheet sends it (USB, e-mail, a shared-drive app); `fieldworx-bridge import` |
| office → phones | `fieldworx-bridge pack` includes the hub's records in the next package |
| phone → phone | Library → *Import a field log from another phone* |
| office → office | several computers import into one hub folder on a shared drive (no locks needed), or each keeps its own and they exchange field logs |

1.0 moves files on purpose (ADR-007). Live LAN sync is the next step (section 7) and uses the same events and the
same merge, only a different transport.

### 4.1 What can go wrong, and what happens

| Failure | Detection | Result |
|---|---|---|
| A package or field log damaged in transit | every member checked against the manifest (size, SHA-256) before anything is used | refused whole; nothing changes |
| A drawing in RevisionWorx whose content no longer matches its recorded hash | `pack` hashes what `revisionworx link fetch` returns | the build stops (fail closed) |
| Two phones answer the same item without seeing each other | neither answer is in the other's `deps` | both kept, item shows *Conflict*, completion blocked until settled |
| An inspection is completed on one phone while another records more | the extra answers are outside the completion's history | the completion is shown as *changed after completion* |
| A phone restored from a backup keeps recording | two different events at one `seq` for one device | the import is refused with a fork error; the device id is never backed up (ADR-004) to prevent it |
| A field log arrives before the one it continues | `prev`/`deps` not known | refused as missing history; import the earlier one first |
| An older package is added after a newer one of the same series | `series` and `created` | refused: the phone never goes back to older engineering by accident |
| A record type this version doesn't know (from a newer phone) | `type` | kept and passed on, listed as a problem, ignored in the state |
| Two offices import the same event into one shared hub at once | write-once files, exclusive create | one wins; the other finds identical bytes and counts it as known |

## 5. Engineering on the phone

### 5.1 Packages (ADR-003)

A package is a read-only snapshot: a catalog (projects, documents and all their revisions' metadata, parts, BOM
lines, units, inspection templates) plus the files the phone can show. It is made for a chosen set of projects and
says so (`source`, `series`, `created`). A newer package of the same series replaces the older one on the phone;
field records are never removed with it.

What the phone shows is exactly what RevisionWorx released: the package carries every revision's metadata but
only the content of the released revision (and, with `--unreleased`, the latest one, marked as not released), plus
every revision a unit was built to. A document whose released revision is newer than what a unit was built to says
so on the unit's page (*current is rev B*); a superseded drawing opens with a red banner.

Units come from RevisionWorx's unit register when it has one (RevisionWorx ADR-025, `revisionworx link units`), as
catalog version 2 assets (PROTOCOL.md section 6.4): a permanent `unt_` id, every identifier with its issuer (former
ones kept), the revisions that apply with where each came from (build standard, the unit itself) and how well it is
known, fitted components, milestones, the unit's history, and the engineering changes that reach it with where each stands
(RevisionWorx's `unit-changes` feature). RevisionWorx stays the record: the package is a
snapshot of it, and nothing on the phone changes it. A unit that an earlier package knew from an asset register row keeps
that row's `ast_` id as an alias, so field records already made against it stay attached. Asset registers still work
for units the unit register doesn't hold; a row for one it does hold is skipped. Version 1 catalogs still open.

### 5.2 Drawings (ADR-009)

The phone shows PDFs (PDFium, through pdfrx): pinch to zoom, find text, page by page. Native formats are turned
into PDFs on the desktop, where the programs that understand them live: DraftWorx drawings through
`draftworx pdf`; PDFs already published in RevisionWorx are used as they are. A revision with no PDF is listed with
what it is (*an OpenSchematix project*) and a note asking engineering to publish a PDF of it.

### 5.3 Labels and scanning (ADR-008)

FieldWorx labels say what they point at and never contain a web address: `FWX:A:unt_…` (a unit's permanent id;
its earlier `ast_` id works too, and an id never falls back to a tag that looks the same), `FWX:A:HPU-0001` (asset),
`FWX:P:FRM-200` (part), `FWX:D:SCH-12` (document), `FWX:J:J-2001` (project), `FWX:R:SCH-12@B` (one revision, for its
prints: the phone says whether it is the released one). Any other code (a maker's barcode,
a serial plate, a supplier's SKU, a reference designator typed as *K1*) is matched exactly against the catalog.
Several matches are all shown; none says none. Nothing is guessed. The scanner is zxing-cpp (Apache-2.0) through
flutter_zxing, so scanning needs no Google Play services and works offline.

## 6. Records in the field

### 6.1 Field events (ADR-006)

Every tap that records something is one event: `{v, device, seq, prev, time, actor, type, entity, deps, body}`.
`actor` is the name entered on the phone (ADR-010), `time` the phone's clock; neither is trusted for ordering,
which comes from `deps` and the per-device chain only.

### 6.2 Inspections

A template (an inspection and test plan) is a controlled document: a `.fwtemplate.csv` (one row per item) or
`.fwtemplate.json` published and released in RevisionWorx. Items are checks (pass/fail/N/A), measurements
(decimal against inclusive limits, evaluated exactly, no floating point), text or a choice, each optionally needing
a photo. The whole template travels inside the inspection's start record, so the record stays readable when the
template is revised or the package removed.

An inspection's state (per item: open, pass, fail, N/A, done, photo needed, conflict; overall: pass, fail,
incomplete, conflict; status: open, completed, voided, conflict) is reduced from its events. Completing records the
result the phone computed; reopening and voiding need a reason, kept with the record.

### 6.3 Photos

Photos are stored by content (SHA-256) and referenced from `inspection.attach` records. A field log carries the
photos not sent before (or all of them, on request); the hub keeps every one; packages carry the records but not
the photos, so a phone shows *photo not on this phone* for photos taken elsewhere (KNOWN_LIMITATIONS.md).

## 7. Next: LAN sync (designed, not built)

Live sync over the shop's network replaces carrying files, with the same events and merge:

- **Opt-in listener.** `fieldworx-bridge serve` listens on the LAN only while it runs. The desktop apps stay as
  they are: no listener is added to RevisionWorx.
- **Pairing by QR code.** The bridge shows a QR code holding its address, the SHA-256 fingerprint of a self-signed
  TLS certificate made for the hub, and a one-time pairing secret. The phone pins the fingerprint; there is no
  certificate authority, account or cloud relay.
- **Exchange.** Each side sends its *frontier* (for each device, the highest `seq` it holds); each then sends the
  events the other lacks, in chain order, and the objects those events name. The receiver applies the batch with
  the same all-or-nothing import as a field log. Packages are offered the same way.
- **Discovery.** Optional mDNS; the paired address is remembered, so none is needed.
- **Failure.** An interrupted exchange leaves both sides valid (imports are all-or-nothing per batch); it simply
  resumes from the frontiers next time.

## 8. Architecture decisions

### ADR-001: A Flutter app over a pure-Dart core, and a Python bridge

**Decision.** One Flutter app for Android and iOS; all protocol and data logic in a dependency-free Dart package
(`core/`); the office side in Python with the standard library only.
**Why.** One codebase for both phone platforms; a core that tests in milliseconds without a device and can be
reused by any later Dart tool; a bridge that runs wherever RevisionWorx runs, with no new runtime on the office
computers, and follows the family's rule of reaching other programs through their documented command lines.
**Cost.** Two implementations of the protocol. Mitigated by shared vectors generated from the Python reference and
an end-to-end test (`tools/interop.sh`) in which the Dart core plays the phone.

### ADR-002: Canonical JSON and content addressing

**Decision.** Everything hashed or exchanged is canonical JSON (FXJ: no floats, sorted keys, no whitespace,
minimal escaping, strict parsing); files are named by the SHA-256 of their bytes; derived hashes carry a domain
(`fieldworx/<domain>\0`).
**Why.** The same value has exactly one byte form in Python and Dart, so ids are stable and comparisons are exact.
A file's name is its integrity check, and it equals the `sha256` RevisionWorx records for the revision, which ties
what the phone shows to what engineering released.
**Cost.** Decimals travel as strings and are compared exactly (a decimal type in each implementation).

### ADR-003: Packages are read-only snapshots of released engineering

**Decision.** The phone never edits engineering data. It receives verified snapshots, replaced by series, and every
omission is stated in the package's notices.
**Why.** RevisionWorx is the authority; a phone that could change a released drawing, or silently show an
unreleased one, would undermine it. Snapshots also make offline use complete: everything needed is on the phone.
**Cost.** The phone is only as current as its last package; the package's age is shown everywhere it matters, and
warns after 30 days.

### ADR-004: The on-device store is write-once files

**Decision.** The store is a folder of files written under their final names only when complete (`device.json`,
`settings.json`, `objects/`, `packages/`, `events/`, `exported.json`). A random device id is made on first run and
the folder is excluded from backups and device transfers.
**Why.** No database to corrupt, nothing half-written after a crash or a flat battery, trivially inspectable. A
device id restored onto a second phone would let two phones write different events under one chain, which every
receiver would then refuse as a fork; so it is never backed up (Android: `allowBackup="false"` and
`data_extraction_rules.xml`).
**Cost.** A phone that is lost loses its unsent records; send field logs often (the Inspect tab counts unsent records).

### ADR-005: The hub is a write-once folder, safe on a shared drive without locks

**Decision.** The office copy of field records is `WORKSPACE/.fieldworx`: one file per event
(`events/<device>/<seq>.json`), per object (`objects/sha256/<aa>/<sha>`) and per imported field log
(`receipts/`), each created exclusively and never replaced.
**Why.** Network filesystems don't reliably honour locks (RevisionWorx and OpenMeridian both say so). With
write-once, content-named files, concurrent writers can only race to write identical bytes; a different file
already at a name is a fork and stops the import.
**Cost.** Many small files. Fine at the scale of a company's inspections; a hub can be compacted into a field log
if it ever matters.

### ADR-006: Field records are immutable events with explicit causality

**Decision.** Events are never edited or deleted. Concurrent writes to one value (an item's answer, an
inspection's status) are kept as a multi-value register and shown as a conflict. A completion covers exactly the
records in its own history.
**Why.** "Never silently overwrite authoritative records": last-writer-wins by timestamp would trust phone clocks
and lose data. With causality explicit, every node computes the same answer and nothing recorded is ever lost.
**Cost.** People occasionally settle a conflict. The app makes it one tap (*Use this*), recorded like any answer.

### ADR-007: Files first; LAN sync next; never the cloud

**Decision.** The first release moves packages and field logs as files through whatever the shop already uses: USB, e-mail,
shared drives, the share sheet.
**Why.** It works today on every phone and network (including none), adds no listener to any computer, and is easy
to audit. The protocol is transport-independent, so LAN sync (section 7) adds a transport, not a new model.
**Cost.** Someone has to send and import the files. The app keeps it to one tap and says how many records are unsent.

### ADR-008: zxing-cpp for scanning; labels without URLs; exact matching

**Decision.** flutter_zxing (zxing-cpp) for QR and barcodes, and for drawing label QR codes. Labels are
`FWX:<kind>:<code>`. Matching is exact and never guesses.
**Why.** ML Kit is proprietary and needs Google Play services; zxing-cpp is Apache-2.0, offline and on every
Android and iOS device. A URL on a label goes stale and invites a network lookup; a plain code means the same thing
offline and in twenty years, and any phone with FieldWorx resolves it.

### ADR-009: Drawings are PDFs prepared on the desktop

**Decision.** Phones render PDFs only; the bridge turns native drawings into PDFs with the programs that own the
formats (`draftworx pdf`), or uses PDFs published in RevisionWorx.
**Why.** Re-implementing DraftWorx, OpenSchematix and CAD renderers on a phone would be enormous and always behind.
A PDF made by the owning program is exactly what it prints.
**Cost.** Engineering publishes a PDF for formats nothing can convert (OpenSchematix projects, Inventor, SolidWorks).

### ADR-010: People are names; devices are ids; signatures come later

**Decision.** The first release records the name typed on the phone (`actor`) and the device id. There are no accounts.
**Why.** The directive rules out accounts and servers, and shop phones are often shared. Device ids and hash chains
already make every record attributable to a device and tamper-evident.
**Next.** Device keys (Ed25519) signing each event, with the public key registered at the hub when a phone is
first imported, so a record can be proved to come from a given phone (ROADMAP.md).

### ADR-011: Material as a package, the family's themes, and readable colours

**Decision.** The UI uses `material_ui` (Flutter 3.47 moved Material out of the framework) with the six family
themes, and computes text colours to reach 4.5:1 against their backgrounds where a palette pair falls short (for
example Modern Dark's blue under white text in filled buttons).
**Why.** Consistency with OpenSchematix and RevisionWorx, and legibility outdoors.

### ADR-012: Release builds ask for the camera and nothing else

**Decision.** The Android manifest removes every permission the libraries declare that FieldWorx doesn't use:
network (INTERNET, ACCESS_NETWORK_STATE), microphone (RECORD_AUDIO, from the camera plugin's video support) and
shared storage (photos go into the app's own folder; files come through the system picker). CI fails if a release
APK asks for anything but the camera.
**Why.** "No telemetry" is then a property of the build, not a promise: a release FieldWorx cannot send anything
anywhere, and a new library can't quietly widen what the app may do. (Debug builds keep INTERNET for Flutter's
development tools.) LAN sync will add the network back, used only for the paired hub.

### ADR-013: The bridge prints labels; one standard-library file draws the QR codes

**Decision.** `fieldworx-bridge labels` lays out labels for what a package holds and writes a PDF itself, with the
Helvetica and Courier every PDF reader has. The QR codes come from `fwx_label.py`, one standard-library file (Python 3.9
or newer) for other programs to copy unchanged, as integrations copy RevisionWorx's `rwx_client.py`. DraftWorx and
OpenSchematix use it for the revision codes on their prints, and their tests check their copy is this file. Labels print at error correction level Q. The layouts are four common stocks, the ones the Director chose on 2026-11-07:
A4 70 x 37 mm, US Letter 2-5/8 x 1 in, and 50 x 25 mm and 25 x 12 mm label printers. The 25 x 12 mm label carries only
the code, its kind and its number, at level M, so its modules stay readable. With labels in use, a unit's code
`FWX:A:unt_<32 hex digits>` is fixed for the life of the machine.
**Why.** Printing from the package means a label always names something the phones that carry that package can find,
and it needs no label software, account or network. A library would be a runtime dependency in a bridge that has none.
One file copied keeps every program's codes identical without one program importing another. At level Q a code still
reads with up to a quarter of it dirty or scratched, and a unit's permanent label (42 characters) still fits a 33-module
code.
**Consequences.** An encoder written here has to be right, so the tests hold it to two programs it shares no code with:
python-qrcode draws the same symbol bit for bit at every version (1 to 10), level and mask, and zxing-cpp, the decoder
the app uses, reads every code back, from the matrix and from each label of a rendered page (test-only dependencies,
`bridge[dev]`). Text the built-in fonts lack prints as "?"; the code holds it exactly. Codes longer than version 10
holds are refused with a message, not shrunk.
