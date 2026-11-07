# FieldWorx protocol, version 1

The exact formats FieldWorx writes and reads: what a package, a field log, a field record, an inspection template
and a label are, byte for byte. Two implementations follow it, the Python bridge (the reference,
`bridge/fieldworx_bridge/`) and the Dart core (`core/lib/src/`); the vectors in `spec/vectors/` are generated from
the reference by `spec/make_vectors.py` and both must reproduce them exactly. Anything a reader doesn't understand
it refuses with a message, never guesses at.

Section numbers are cited from the code; keep them stable.

## 1. Conventions

- Ids are `<three lowercase letters>_<32 lowercase hex>`, random, as RevisionWorx makes them: `dev_` devices,
  `ins_` inspections, `pkg_` packages, `flg_` field logs, `unt_` units (RevisionWorx's unit register, permanent),
  `ast_` assets of an asset register (derived, section 6.4).
- Hashes are SHA-256, lowercase hex.
- Times are UTC with a `Z`; writers use milliseconds, readers accept 0–6 fractional digits:
  `2026-11-06T21:42:00.123Z`.
- Decimals (measurements, quantities, stock) are strings matching `-?(0|[1-9]\d{0,14})(\.\d{1,9})?`, compared
  exactly. There are no floating-point numbers anywhere.
- Text fields have length limits (stated below or in the code) and refuse control characters except where a field
  is multi-line.

## 2. Canonical JSON (FXJ) and digests

The bytes FieldWorx hashes, stores and exchanges.

- Values: `null`, `true`, `false`, integers within ±(2⁵³−1), strings, arrays, objects with string keys.
  Floats are refused.
- Objects: keys sorted by Unicode code point (not UTF-16 unit), no duplicates.
- No whitespace anywhere.
- Strings: UTF-8; `"` and `\` escaped; `\b \f \n \r \t` as those escapes; other characters below U+0020 as
  `\u00XX` (lowercase hex); everything else literal. Unpaired surrogates are refused.
- Nesting deeper than 64 is refused.
- **Strict parsing** for anything that will be hashed: `parse_canonical` parses and then requires that re-encoding
  gives the identical bytes, so there is exactly one accepted byte form of every value.

**Digests.** A derived hash names its purpose: `digest(domain, v) = SHA-256("fieldworx/" + domain + "\0" +
FXJ(v))`. Domains in use: `event/v1` (event ids), `template/v1` (template digests shown on records).

**Content addresses.** Files (drawings, photos) are named by the plain SHA-256 of their bytes, which for a
RevisionWorx revision is the `sha256` RevisionWorx itself recorded.

Vectors: `fxjson.json` (encodings, refusals), `digests.json`.

## 3. Archives: packages and field logs

Both are ZIP files with one layout, so one reader serves both.

```
mimetype            "application/x-fieldworx-package" or "application/x-fieldworx-fieldlog"; first member, stored
manifest.json       FXJ, lists every member below
catalog.json        packages only: the catalog (section 6), FXJ
events/<id>         one field event (section 4), its exact canonical bytes
objects/<sha256>    one file: a PDF rendition, a photo
```

File names end `.fieldworx` (package) and `.fieldlog` (field log).

**Manifest** (`manifest.json`, FXJ, exactly these keys):

| Key | Value |
|---|---|
| `format`, `version` | `"fieldworx.archive"`, `1` |
| `kind` | `"package"` or `"fieldlog"`, matching `mimetype` |
| `id` | `pkg_…` or `flg_…` |
| `title` | what to call it, ≤ 200 characters |
| `series` | packages: which packages replace each other (section 3.2); field logs: `""` |
| `created` | UTC time it was written |
| `created_by` | object of short strings: `user`, `host`, `tool`, `device` as known |
| `source` | packages: where the engineering came from (`system`, `workspace`, `name`, `version`, `projects`, …) |
| `catalog` | packages: `{"sha256", "size"}` of `catalog.json`; field logs: `null` |
| `events` | `[{"id", "size"}]` in the order they are to be applied (each device's chain in `seq` order) |
| `objects` | `[{"sha256", "size", "media_type"}]` sorted by hash, each listed once |
| `notices` | strings for people: what was left out and why |

The **archive digest** is the SHA-256 of `manifest.json`'s bytes; since the manifest lists every member's hash, it
identifies the whole archive.

**Reading.** Before anything from an archive is used, a reader checks: the `mimetype` member is first, stored and
matches `kind`; the manifest is canonical and valid; every listed member exists with exactly the listed size and
hash; every event's id is the digest of its bytes; the catalog is valid (section 6). Any failure refuses the whole
archive. Members the manifest doesn't list are ignored. Limits: manifest 16 MiB, catalog 256 MiB, one object 2 GiB,
200 000 members; ZIP64 is supported.

**Writing.** Written to a temporary name and renamed into place when complete. JPEG, PNG, WebP, HEIC, PDF and ZIP
objects are stored; everything else deflated.

### 3.1 Field logs

A field log carries **every** event the writing device holds (its own and those it got from others) and the photos
it has not sent before (or all of them, on request). Sending one twice is harmless.

### 3.2 Packages

`series` is `SHA-256(system + "\0" + workspace id + "\0" + sorted project ids joined by ",")`, first 32 hex
characters. A device keeps one package per series: a newer one (later `created`) replaces the older; an older one
is refused. A package may carry field events (the hub's, section 8); they are imported like a field log's.

Vectors: `archives.json`, `sample.fieldworx` (a version 1 catalog with field records), `sample.fieldlog`, `units.fieldworx` (a version 2 catalog of units).

## 4. Field events

One record of something done in the field. The **envelope** is an FXJ object with exactly these keys:

| Key | Value |
|---|---|
| `v` | `1` |
| `device` | `dev_…`, the recording device |
| `seq` | 1, 2, 3 … per device, no gaps |
| `prev` | id of this device's previous event; `""` when `seq` is 1 |
| `time` | the device's clock, UTC (for people; never used for ordering) |
| `actor` | the name entered on the device, ≤ 200 characters |
| `type` | dotted lowercase name, e.g. `inspection.answer`, ≤ 64 characters |
| `entity` | what it is about: `ins_…` for an inspection |
| `deps` | ids of events **of the same entity** its author had seen, sorted, unique, ≤ 64 (normally the entity's heads) |
| `body` | object; its shape depends on `type` (section 5) |

The event's **id** is `digest("event/v1", envelope)`; its stored form is the canonical bytes (≤ 256 KiB).

**A set of events** (a device's store, the hub, a field log) must be closed and consistent:

- each device's events form an unbroken chain: `seq` 1…n, each `prev` the id of `seq − 1`;
- every `deps` entry is an event of the same entity already in the set;
- no device has two different events at the same `seq` (a **fork**: for example a phone restored from a backup
  that kept recording).

**Importing** a batch is all-or-nothing: the batch plus what is held must satisfy the rules above, or nothing from
it is used. The errors are distinct so people can be told what to do: *fork* (a device's history was forked;
investigate), *missing history* (import the earlier field log first), *malformed* (damaged).

**Heads** of an entity are its events no other event of the entity depends on. **Ancestors** of an event are
everything reachable through `deps`.

**Concurrent writes.** For a register (an item's answer, an inspection's status), the current value is the set of
writes that are not an ancestor of another write to the same register. One write: that value. More than one: a
conflict, all kept, until a write that has seen them all (it depends on every one) settles it.

Vectors: `envelopes.json`, `fieldlog.json`.

## 5. Inspections

### 5.1 Templates

FXJ object, exactly:

```json
{"format": "fieldworx.template", "version": 1, "id": "ITP-HPU-75", "revision": "1",
 "title": "HPU-75 final inspection and test plan", "description": "",
 "sections": [{"title": "Mechanical", "items": [ITEM, ...]}, ...]}
```

`id` ≤ 64, `revision` ≤ 16, `title` ≤ 200, `description` ≤ 4000 (multi-line). At least one section; each with at
least one item; at most 1000 items in all.

An **item**: `id` (1–32 of letters, digits, `.`, `_`, `-`; unique in the template, ignoring case), `kind`, `prompt`
(≤ 500), `required` (boolean), `photo` (`none`, `optional`, `required`), `help` (≤ 2000, multi-line), and by kind:

| `kind` | Extra keys | Answer `value` |
|---|---|---|
| `check` | — | `{"result": "pass" \| "fail" \| "na"}` |
| `measure` | `unit` (≤ 16), `nominal`, `min`, `max` (decimals or `""`; `min` ≤ `max`) | `{"measured": DECIMAL}` or `{"result": "na"}` |
| `text` | — | `{"text": ≤ 4000}` |
| `choice` | `choices`: 2–20 distinct strings (≤ 100) | `{"choice": one of choices}` |

`{}` clears an answer.

**From a spreadsheet** (`*.fwtemplate.csv`): columns `section, id, kind, prompt, unit, nominal, min, max,
required, photo, choices, help` (only `id`, `kind` and `prompt` are needed; unknown columns are refused).
Consecutive rows with the same `section` make one section; `required` is yes unless `no`/`false`/`0`; `photo`
defaults to `none`; `choices` are separated by `;`. A leading `'` before `= + - @` (RevisionWorx's spreadsheet
guard) is removed. As a RevisionWorx document, the template's `id` is the document number and its `revision` the
revision label.

Vectors: `templates.json`.

### 5.2 Records

All with `entity` = the inspection's `ins_…` id.

| `type` | `body` (exactly) |
|---|---|
| `inspection.start` | `template` (the whole template, section 5.1), `title` (≤ 200), `subject` `{kind: "" \| asset \| part \| document \| project, id, label}`, `package` (the package id it was started from, or `""`) |
| `inspection.answer` | `item`, `value` (per kind, above), `note` (≤ 2000) |
| `inspection.note` | `text` (1–4000), `item` (`""` for the whole inspection) |
| `inspection.attach` | `object` (SHA-256), `size`, `media_type`, `item` (or `""`), `caption` (≤ 500) |
| `inspection.complete` | `result` (`pass` \| `fail`), `summary` (≤ 4000) |
| `inspection.reopen` | `reason` (≤ 2000) |
| `inspection.void` | `reason` (≤ 2000) |

An inspection has exactly one start. Records with an unknown `type` are kept but reported (`problems`) and ignored;
malformed records likewise.

### 5.3 State

Computed from the entity's events **sorted by id** (never by arrival order or time):

- **Item outcome**: `open` (no answer, or cleared); `pass`/`fail`/`na` for checks; for measurements `na`, or `pass`
  when `min ≤ measured ≤ max` (each limit only if given; exact decimal comparison), else `fail`; `done` for text and
  choice; `conflict` when the answer register has more than one current value. A required photo with none attached
  to the item turns any outcome except `open` and `na` into `photo-missing`.
- **Overall outcome**: `conflict` if any item is; else `fail` if any item fails; else `incomplete` if any required
  item is `open` or `photo-missing`; else `pass`.
- **Status**: the status register over complete/reopen/void: none → `open`; one → `completed`, `open` (reopened) or
  `voided`; several → `conflict`.
- **Completion**: when the status is completed, its result and summary, and `stale` = some answer or photo exists
  outside the completion's ancestors (`uncovered` lists them).
- The **template digest** shown with the state is `digest("template/v1", template)`.

`reduce` (Python) and `reduceInspection` (Dart) return the same FXJ-able object for the same events. Vectors:
`inspections.json`, `decimals.json`.

## 6. The catalog

`catalog.json`: FXJ object with exactly `format` (`"fieldworx.catalog"`), `version` (`2`; `1` is still read),
`projects`, `documents`, `parts`, `bom`, `assets`, `templates`. Every cross-reference must point inside the catalog;
ids are unique. A newer `version` is refused with a request to update.

Versions 1 and 2 differ only in the shape of an asset (section 6.4). Writers write version 2. A version 1 reader (an earlier
build) refuses a version 2 package whole, asking for an update, which is the intended failure. A version 2 reader reads a version 1
asset as the version 2 asset section 6.4 derives from it, so an old package keeps working.

### 6.1 Projects and documents

- **project**: `id, number, name, customer`.
- **document**: `id, number, title, type, project, path, released, latest, revisions` (`released`/`latest` are ids
  among its revisions, or `""`).
- **revision**: `id, label, state, state_name, sha256, size, created, author, description, ext, rendition`, as
  RevisionWorx reports them; `rendition` is `null` or `{object, media_type, via}` naming a phone-viewable object in
  the package (`via` says how it was made: `content`, `pdf attached in RevisionWorx (Inventor 2025 export)` when
  engineering attached the PDF of exactly that revision (RevisionWorx ADR-026), `draftworx pdf 1.2.0`, …). A revision is
  never shown with another revision's PDF.

All revisions' metadata is included; content only for those the package needs (ARCHITECTURE.md 5.1).

### 6.2 Parts and the BOM

- **part**: `id, number, description, unit, kind, revision, status, manufacturers [{name, mpn}], vendors
  [{name, sku}], documents [{document, revision, role}], attributes {name: value}, stock`.
  Parts come from a released RevisionWorx parts list (its CSV contract: `part_id, number, …, manufacturer_N, mpn_N,
  vendor_N, sku_N, document_id_N, revision_id_N, role_N, attr:<name>`); a part without a RevisionWorx id gets
  `pn:<number, case-folded>`.
- **BOM line**: `parent, child` (part ids), `quantity` (positive decimal), `unit, find_number, refdes [..],
  note, provenance, source`, read from released BOM documents through `revisionworx bom convert`.
  `provenance` `inferred` or `unknown` is shown as *needs verification*.

### 6.3 Stock

`stock` on a part is `null` or `{on_hand (decimal), unit, bin, as_of, source}`: on hand from an OpenMeridian
company file (the sum of its append-only `stock_moves`), read when the package was made and shown as *not live*.

### 6.4 Assets: units built, from RevisionWorx's unit register or from an asset register

An asset is one physical unit: a machine, a tracked component, an instrument, a tool. Its record comes from one of two
places, and the phone shows exactly what that record says.

- **RevisionWorx's unit register** (RevisionWorx `docs/UNITS.md`), read through `revisionworx link units --detail` when
  `link version` lists the `units` feature. The unit's id is its permanent `unt_` id; its documents are the revisions its
  history records, never a newer released one.
- **An asset register**: a released RevisionWorx document named `*.fwassets.csv` (or `--assets FILE`, uncontrolled), columns
  `tag, serial, name, part, project, location, built, as_built, notes`; `tag` or `serial` required per row; `as_built` lists
  `DOCUMENT@REVISION` separated by `;`. Its `id` is `"ast_" + SHA-256(workspace id + "\0" + (tag or serial), case-folded)[:32]`.
  A register row that RevisionWorx's register already holds (the unit has that `ast_` id as an identifier) is left out, with a
  notice: the register is the authority.

**asset** (version 2), exactly:

| Key | Value |
|---|---|
| `id` | `unt_…` or `ast_…` |
| `aliases` | `[ast_…]`: earlier ids field records may name; sorted, unique, ≤ 100 |
| `label` | what to call it, ≤ 200: RevisionWorx's label (its first current serial, else tag, else other code); a register row's tag, else serial |
| `class` | `product`, `component`, `instrument` or `tool` |
| `name`, `customer`, `site`, `location` | text ≤ 200 |
| `model` | text ≤ 100: the part number of the design it is an instance of |
| `part` | a catalog part id, or `""` |
| `project` | a catalog project id, or `""` |
| `status` | `""` (not recorded) or `planned`, `in-build`, `built`, `in-service`, `out-of-service`, `retired`, `scrapped` |
| `identifiers` | ≤ 100 `{scheme, issuer, value, active}`; `scheme` `serial`, `tag` or `other`; text ≤ 200 (`value` 1–100); `active` boolean |
| `parent` | `null` or `{asset, position}`: the catalog asset it is fitted in |
| `standard` | `null` or `{number, title}`: the build standard it conforms to |
| `documents` | ≤ 2000 `{document, revision, source, basis}`: a catalog document; one of its revisions, or `""` when the document doesn't apply to this unit; `source` `standard`, `unit` or `register`; `basis` `verified`, `reported`, `declared` or `legacy`. A document appears once |
| `components` | ≤ 1000 `{position, part, number, asset, serial, lot, since, basis}`: `part` a catalog part id or `""`; `asset` the catalog asset fitted there or `""`; `position` 1–64; the rest text ≤ 200; positions unique |
| `milestones` | object: at most `built`, `shipped`, `installed`, `commissioned`, `decommissioned`, each a date text ≤ 32 (`""` = date unknown) |
| `history` | ≤ 1000 `{n, type, summary, effective, time, actor, basis, voided}` oldest first: `n` 1, 2, 3 … increasing; `type` ≤ 64; `summary` ≤ 500; `effective`, `time` ≤ 32; `actor` ≤ 200; `voided` boolean |
| `changes` | ≤ 200 `{change, number, title, kind, required, state, since, documents}`: the engineering changes RevisionWorx records as reaching this unit (its `docs/UNITS.md` section 10). `change` and `number` text ≤ 64, `title` ≤ 200; `kind` `production`, `retrofit-required`, `retrofit-optional`, `unit`, `documentation` or `""`; `required` boolean; `state` `pending`, `offered`, `accepted`, `scheduled`, `deferred`, `declined`, `installed`, `verified`, `not-applicable` or `reversed`; `since` ≤ 32; `documents` ≤ 100 `{number, from, to}`, text ≤ 64: a document and the revisions the change takes it from and to. A change appears once |
| `notes` | ≤ 4000 |
| `source` | ≤ 200: `revisionworx`, or the register it came from (`AST-HPU-75 rev A`, `units.fwassets.csv (uncontrolled)`) |

Ids and aliases are unique across the catalog's assets, and no asset is fitted in itself through `parent`.

A change is **outstanding** on a unit when it is `required` and its state is neither `verified` nor `not-applicable`. The phone
shows outstanding changes first and counts them; it never changes them (they are settled in RevisionWorx).

**A version 1 asset** (`id, tag, serial, name, part, project, location, built, notes, as_built`) is read as: `aliases` `[]`,
`label` its tag, else serial; `class` `product`; `model`, `customer`, `site` and `status` `""`; `identifiers` its tag then its
serial, each when not empty, issuer `""`, active; `parent` and `standard` `null`; `documents` one `{document: the revision's
document, revision, source: "register", basis: "legacy"}` per `as_built` revision, in that order; `components` and `history`
`[]`; `milestones` `{"built": built}` when built isn't empty, else `{}`; `changes` `[]`; `source` `""`. The vectors (`catalogs.json`) hold both
readings.

### 6.5 Templates

**template entry**: `{template (section 5.1), document, revision, state}`; `document`/`revision` are the
RevisionWorx document and revision it came from (`""` and `state: "uncontrolled"` for `--templates` files). A
template id and revision appear once.

## 7. Labels and resolution

A FieldWorx label is a QR code (or any barcode) holding `FWX:<kind>:<code>`:

| Kind | Means | Matched against |
|---|---|---|
| `A` | asset | its id or an alias when the code is one (`FWX:A:unt_…`, the permanent label of a unit); otherwise a current tag, then a current serial, then a current other code, then a former one |
| `P` | part | part number |
| `J` | project | project number |

Labels go on machines, tracked components, stock and projects, never on drawings. Which revision of a drawing applies is the
machine's to say: its unit record lists the revisions it is built to (section 6.4), and the phone shows those. A code on a
print or a binder could only say which revision is released, which is the wrong answer for a machine built to an earlier one.
So `D` (a document) and `R` (one revision of a document, `FWX:R:<number>@<revision>`) were withdrawn before release
(2026-11-07) and are never reused: a reader matches nothing for them and says that drawings are found from the machine or by
searching for their number.

`L` (a storage location) and `W` (a work order) are reserved for later versions. A reader that doesn't know a kind says so
and matches nothing, even when the code alone would match something.

**Printing.** FieldWorx labels are QR Code model 2 (ISO/IEC 18004), the text in UTF-8 in byte mode without an ECI header,
at error correction level Q (M on labels 12 mm high, where Q's extra modules would be too small to read), with a quiet
zone of at least 4 modules. A unit's code, `FWX:A:unt_` and its 32 hex digits, is fixed: printed labels must keep
resolving for the life of the machine. The reference encoder is one standard-library file,
`bridge/fieldworx_bridge/fwx_label.py`; a program that prints FieldWorx labels copies it unchanged. The words printed
beside a code are what it is, its number and a description, and the code itself for typing; never anything that changes
(a revision's state, a unit's status, owner or site).

A unit's permanent label holds its id, so it never changes when its serial, tag, owner or drawings do, and a reprint is
identical. Ids are random, so labels from different companies never collide. Labels never contain a URL, a customer or a site.
A typed label only matches things of its kind.

Any other scanned or typed text is matched **exactly** (case-insensitive, surrounding whitespace ignored) against,
in this order of priority: internal ids and asset aliases, asset tags, serials and other codes (current before former), part
numbers, document numbers, project numbers, manufacturer part numbers, supplier codes, reference designators (a BOM line's
refdes resolves to its child part). All matches are returned, most specific first; none is guessed.

## 8. The hub

`WORKSPACE/.fieldworx/` (or any folder given with `--hub`):

```
hub.json                          {"format": "fieldworx.hub", "version": 1, "id": "hub_…", "created"}, written once
events/<device>/<seq:010d>.json   one event, canonical bytes
objects/sha256/<aa>/<sha256>      one file, by content
receipts/<archive id>.json        what each imported archive brought
```

Every file is written to a temporary name, flushed, and published with an exclusive create (link or rename that
never replaces). An existing file with the same bytes counts as already known; with different bytes it is a fork and
the import stops. Before writing, the whole batch is checked against everything in the hub (section 4).

## 9. The device store

The app's private folder:

```
device.json                       {"device": "dev_…", "created"}: made once; never backed up
settings.json                     {"user", "theme"}: the only file that is replaced (atomically)
objects/<aa>/<sha256>             renditions and photos
packages/<pkg id>/manifest.json   as received
packages/<pkg id>/catalog.json
events/<device>/<seq>.json        every field event this device holds
exported.json                     {"objects": [...], "own_seq"}: what has gone out in field logs
tmp/                              work in progress; cleared on start
```

Removing a package removes its files unless a field record still refers to them; field events are never removed.

## 10. Conformance

An implementation conforms when it reproduces every vector in `spec/vectors/` (encodings, refusals, ids, reduced
inspection states, archive digests) and refuses what the vectors refuse. `python spec/make_vectors.py --check`
regenerates them in memory and fails if the files differ; `dart test` in `core/` runs them against the Dart code;
`tools/interop.sh` runs the bridge and the Dart core against each other through real files.
