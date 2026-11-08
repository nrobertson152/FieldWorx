# FieldWorx user guide

FieldWorx is the field companion to RevisionWorx. On the phone it shows released drawings, parts and units, and
records inspections; in the office, `fieldworx-bridge` makes the packages the phones read and collects what they
record. It works offline, has no accounts and sends nothing anywhere by itself.

- [On the phone](#on-the-phone)
- [In the office](#in-the-office)
- [Trying it with the demo](#trying-it-with-the-demo)

## On the phone

### First run

Enter your name. It goes into every record you make so the office knows who did what; it isn't an account and
isn't checked. Shared phone? Change it in **Library → your name** when you pick the phone up.

Then add a package: **Add a package** opens the file picker for a `.fieldworx` file (copied over USB, saved from an
e-mail, or from a shared-drive app). FieldWorx checks every file in it before keeping anything; a damaged or
tampered package is refused and nothing changes. **Try the demo** adds the built-in HPU-75 example.

### Scan

Point the camera at a label. FieldWorx understands:

- its own labels: `FWX:A:unt_…` (a unit in RevisionWorx's unit register, by its permanent id), `FWX:A:<tag>`
  (a unit by its tag), `FWX:P:<part>` and `FWX:J:<project>`. Drawings have no label: which revision applies depends on
  the machine, so scan the machine's label and its page lists the revisions it is built to;
- a unit's serial plate, asset tag or an old code it used to carry, a part number, a maker's part number, a
  supplier's code, a document or project number;
- a reference designator from the BOM, typed as on the schematic: `K1`, `V2`.

One match opens straight away. Several are all listed with why each matched: choose. No match says so and offers a
search; nothing is guessed. You can also type a code (or let a rugged phone's scan key type it) in the field under
the camera. The camera only runs while the Scan tab is showing. Recent scans are listed below.

### Units

A unit's page shows what it is, where it is, its serial and build date, and **As built**: the exact revisions it was
built to. If a drawing has been revised since, the row says *current is rev B* and the top says how many drawings
have changed. Tap a revision to open it. **Inspections** lists everything recorded on the unit; **Start an
inspection** begins a new one.

A unit from RevisionWorx's **unit register** (its page says *Unit*) shows more:

- every code it carries, with who issued it (a customer's asset tag, a maker's serial), and the codes it used to
  carry, so an old label still finds it;
- its customer, site and location, its **build standard**, and its dates (built, shipped, installed, commissioned);
- **As built** lists the revisions that apply to this unit: its build standard's, and any recorded for this unit
  alone (*this unit only*). A document that doesn't apply to it says so. A revision known only from a report or old
  records says *reported* or *from old records*;
- **Fitted**: what is fitted in it, by position (a pump, a motor, by serial or lot), and **Fitted in**: the unit it
  is part of. Tap one to open it;
- **Engineering changes**: each change engineering has decided reaches the unit (a retrofit, a modification, a drawing
  correction), with the drawings it moves and where it stands on this unit (*pending*, *scheduled*, *installed*, *verified*...).
  A required change not yet verified counts as outstanding, and the top of the page says how many there are;
- **Deviations and concessions**: approved departures from the drawings for this unit: a substitute part allowed while the
  right one is out of stock (a *deviation*, often temporary, until a date), or a difference accepted after it was built (a
  *concession*). Where one is *in effect*, the unit may differ as it says, and that isn't a fault to put right. A temporary one
  past its end date is flagged, and the top of the page says so;
- **Record**: its history from the unit register, newest first. A correction shows as *voided*, never erased.

The phone shows the unit as it was when the package was made. Changes to a unit are made in RevisionWorx.

**Findings.** When you replace a part, find something fitted that the page doesn't show, carry out an engineering change,
or see something the office should know, tap **Report a finding** on the unit's page:

- **Replaced a part**: the position (P1); what came out (filled in from the page when it knows what's there) and where
  it went (for repair, returned, scrapped, to stock, reused); what went in, by part number, serial or lot;
- **What is fitted**: the position and what is there;
- **Carried out a change**: tap one of the changes due on the unit, or type its number;
- **Something else**: say what you found.

Add the date it was done (today, unless you change it), a comment and photos, and tap **Record finding**. The finding is
a field record like an inspection: it doesn't change the unit's page. It goes to the office in the next field log, and
someone there decides what goes into RevisionWorx; the next package shows the unit as it is recorded there. A finding
recorded by mistake can be voided (it stays on record, marked *voided*).

### Documents and drawings

A document's page lists every revision with its state: *Released* in green, *Superseded* and *Not released* warned
about. **Open drawing** shows the released PDF. Pinch or use the zoom buttons; the search button finds text on the
drawing (part numbers, tags, notes), with up and down to step through matches. A superseded or unreleased revision
opens with a coloured banner saying which revision is current. **Units built to it** shows which units were built
to which revision.

Formats the phone can't draw (an OpenSchematix project, a CAD model) are listed with a note: ask engineering to
publish a PDF of it in RevisionWorx and it will be in the next package.

### Parts

A part's page shows its description and revision, **stock on hand** (from OpenMeridian when the package was made:
*not live*), its drawings, what it's **made from** and **used in** (with item numbers, quantities and reference
designators), the units built from it, and where to **buy it** (makers' part numbers and suppliers' codes). The QR
button shows a label you can print or let someone scan from your screen.

### Find

Search by number, description, maker's part number, serial or reference designator, or browse all units, parts,
documents and projects. Everything searched is on the phone.

### Inspections

Start from a unit (**Start an inspection**) or from the Inspect tab (**New inspection**), and choose the
inspection and test plan. Templates come from engineering as controlled documents; one marked *uncontrolled* didn't.

- **Checks:** Pass, Fail or N/A. Tap the selected answer again to clear it.
- **Measurements:** type the reading (a comma or a point for decimals) and press done. The limits are shown above;
  FieldWorx marks it pass or fail exactly, with no rounding. N/A if it doesn't apply.
- **Text and choices:** type, or pick one.
- **Photos:** items marked *A photo is required* need one before the inspection can be completed; others may
  have one. **Note** adds a remark to an item; the menu adds notes or photos for the whole inspection.

Every answer is a permanent record with your name and the time. Changing an answer records a new one; the old one
stays in the history. The button at the bottom says what's left (*3 required items to go*) and becomes **Complete ·
Pass** (or Fail) when everything required is answered. Completing asks for an optional summary.

**Reopen** (with a reason) to change a completed inspection; **Void** (menu, with a reason) if it shouldn't have
been started. Nothing is ever deleted.

**Two phones, one inspection.** If an item was answered on two phones that hadn't seen each other's records, both
answers are kept and the item shows them side by side with who and when: choose **Use this** on the right one. The
inspection can't be completed until every such conflict is settled. If answers arrive from another phone after the
inspection was completed, it shows *changed after completion*: reopen it, check them, and complete it again.

### Sending records to the office

Records stay on the phone until they're sent. The Inspect tab and the badge on it count unsent records.
**Send field log** (Inspect banner or Library) writes a `.fieldlog` file holding every record on the phone and
the photos not sent before, and opens the share sheet: send it by e-mail, save it to a shared drive or USB, or
share it to another phone. Sending twice is harmless: records are only ever added. **Send again with every photo**
includes photos already sent.

Another phone's records can be brought onto this one with **Library → Import a field log from another phone**.

### Library

- **Packages:** what's on the phone, how old, and what each says about itself (what was left out). A newer package
  of the same projects replaces the older one; an older one is refused. **Remove** takes its drawings and parts off
  the phone; field records stay.
- **Field records:** how many, how many made here, how many unsent.
- **This phone:** your name, and the phone's **fingerprint**: four groups of four letters and digits that the
  office checks when it enrols the phone to your account (below), so that what you record is accepted as verified in
  your name. Tell the office if the phone is lost.
- **Theme:** the family's six themes; High Contrast reads best in sunlight.
- **About:** version, this phone's device id and fingerprint, open-source licences.

## In the office

The office side is `fieldworx-bridge`, a Python program that reads RevisionWorx through its command line. See
[bridge/README.md](../bridge/README.md) for installing it.

### Making a package

```sh
fieldworx-bridge pack -w "D:/Engineering/Workspace" --project J-2001 -o "J-2001.fieldworx"
```

The package holds every document of the chosen projects (all revisions' details; the released revision's file),
the parts, BOMs, units and inspection templates published in them, and the field records already collected (so
every phone sees the history). When RevisionWorx has a unit register (`revisionworx unit`), the units of the chosen
projects come from it, with every unit fitted in them and the revisions each one names, even from other projects.
Useful options:

| Option | Does |
|---|---|
| `--project P` | a project id, number or name; repeat for several (default: every active project) |
| `--meridian FILE.meridian` | add stock on hand from an OpenMeridian company file (opened read-only; formats 1 to 3, and a newer one is refused) |
| `--unreleased` | include the latest revisions that aren't released yet, marked *not released* |
| `--templates DIR` | add inspection templates that aren't in RevisionWorx (marked *uncontrolled*) |
| `--assets FILE.fwassets.csv` | add a unit register that isn't in RevisionWorx (uncontrolled) |
| `--no-field-records` | leave the field records out |
| `--title T` | what the phones call it |

The package's notes say what was left out and why (an unreleased document, a format without a phone view). If a
file in RevisionWorx doesn't match the hash RevisionWorx recorded for it, the build stops.

### What to publish in RevisionWorx for the phones

- **Drawings as PDFs** (or DraftWorx/DXF drawings, printed to PDF automatically when DraftWorx is installed). For an
  Inventor, SolidWorks or other CAD drawing, attach its PDF export to the revision: `revisionworx doc pdf FRM-200@B
  "FRM-200 rev B.pdf"`. The phone shows it for that revision only.
- **BOMs** as RevisionWorx reads them, and **parts lists** in RevisionWorx's parts CSV.
- **Inspection templates** named `*.fwtemplate.csv`: one row per item with the columns `section, id, kind, prompt,
  unit, nominal, min, max, required, photo, choices, help`. `kind` is `check`, `measure`, `text` or `choice`;
  `required` is yes or no; `photo` is none, optional or required; `choices` are separated by `;`. The document
  number becomes the template's id and the revision label its revision. Release it like any document.
- **Units** in RevisionWorx's unit register (`revisionworx unit new`, or `revisionworx unit import` of a CSV, such
  as an existing `*.fwassets.csv`). Records made on phones against a unit before it was in the register stay with
  it: the package carries its earlier FieldWorx id.
- **Unit registers** named `*.fwassets.csv`, for units that aren't in the unit register: columns `tag, serial,
  name, part, project, location, built, as_built, notes`; `as_built` lists the revisions the unit was built to,
  `DOCUMENT@REV;DOCUMENT@REV`. A row for a unit the unit register holds is left out of the package.

### Labels

```sh
fieldworx-bridge labels hpu.fieldworx -o units.pdf                            # a label for each unit and asset
fieldworx-bridge labels hpu.fieldworx --parts --layout letter-30 -o bins.pdf  # parts, on US Letter sheets
fieldworx-bridge labels hpu.fieldworx --only NH-26-0001 --copies 2 --skip 5 -o two.pdf
```

`labels` lays out FieldWorx labels for what a package holds, as a PDF: a QR code, what it is, its number, a description
and the code written out for typing. Units in RevisionWorx's unit register get their permanent label, `FWX:A:unt_…`,
which never has to change: a new tag, a new owner or a rebuild don't affect it. Assets from an asset register get
`FWX:A:<tag>`, parts `FWX:P:<part number>`, projects `FWX:J:<number>`. Drawings get none: the machine's label finds
the revisions it is built to, and a code on a print could only say which revision is released, which is the wrong
answer for a machine built to an earlier one. Nothing that changes is printed: the phone says that when a label is
scanned.

- `--only` picks by any name a thing answers to (a tag, a serial, a unit id, a part or project number), in the order
  given; a name that matches nothing stops the command, so a sheet never leaves a label out quietly.
- `--layout`: `a4-24` (A4, 24 labels of 70 x 37 mm, the default), `letter-30` (US Letter, 30 labels of 2-5/8 x 1 in),
  `roll-50x25` (a label printer, one 50 x 25 mm label per page) or `roll-25x12` (25 x 12 mm, for components and bins:
  just the code, its kind and its number). `--skip N` starts after positions already used on a
  sheet; `--copies N` repeats each label.
- Print at **actual size (100%)**, not *fit to page*. Print a test sheet on plain paper and hold it against a sheet of
  labels to the light before using the labels.

Plain part numbers and serial plates work too. Labels never hold web addresses, so they keep working offline and for
good. Any phone with FieldWorx shows the label for a unit, part or document from its page.

### Collecting field logs

```sh
fieldworx-bridge import -w "D:/Engineering/Workspace" FieldWorx-*.fieldlog
fieldworx-bridge status -w "D:/Engineering/Workspace"
fieldworx-bridge report -w "D:/Engineering/Workspace" -o reports
```

`import` adds the records to the workspace's hub (`.fieldworx`, beside `.revisionworx`): all of a field log or none
of it, and the same log twice changes nothing. `status` counts inspections by state and lists what needs
attention (conflicting answers, completions changed afterwards, unreadable records), exiting with 1 when anything
does, so it can run from a scheduled task. `report` writes `inspections.csv` (the register) and one HTML
record per inspection, with its photos, that prints well.

`fieldworx-bridge verify FILE` checks any package or field log without changing anything.

### Findings: what was found or changed on a unit

A finding is something someone in the field saw or did to a unit: a part replaced, what is actually fitted at a
position, an engineering change carried out, or a note. The phone records it; it never changes the unit's record.
Someone in the office decides what goes into RevisionWorx's unit register:

```sh
fieldworx-bridge findings -w "D:/Engineering/Workspace"
fieldworx-bridge accept fnd_3f9a2c17 -w "D:/Engineering/Workspace" --dry-run
fieldworx-bridge accept fnd_3f9a2c17 -w "D:/Engineering/Workspace"
```

`findings` lists every finding in the hub with what it would record: *to accept* (and what), *needs a decision*,
*already in the register*, *accepted* (with the event number in the unit's history) or *voided*. `accept` records one,
named by its id or the start of it:

- a replacement or a find becomes what is fitted at that position (a replacement takes out what the register has
  there), a change becomes the change carried out, a note a note;
- it is recorded as *reported*, with the field record as its evidence and who reported it when; `--basis verified` if
  you saw it yourself. In a team workspace it is in the name of whoever is logged in to RevisionWorx;
- a finding signed on a phone enrolled to someone's account (below) is recorded as *verified* in that person's name:
  RevisionWorx checks the phone's signature itself, and records nothing if it doesn't hold or the phone has been
  revoked. `--basis reported` records it as reported instead;
- a finding the register contradicts (the phone says PMP-10 serial 111 came out, the register has serial 999 there) is
  not recorded until you decide: `--as fit` records what the phone says is fitted now, `--as note` keeps it as a note and
  leaves the configuration alone;
- accepting the same finding again records nothing, and nothing is recorded if the unit changed in RevisionWorx while
  you were deciding: run it again to look afresh.

RevisionWorx needs its `unit-records` feature (1.0.0). Findings about a unit that is only an asset register row are listed
but can't be accepted until the register is imported (`revisionworx unit import`).

### Enrolling phones

Every phone signs the records it makes with its own key. In a RevisionWorx workspace set up for a team, an
administrator can enrol a phone to the person who carries it; from then on, what they record on it is accepted as
*verified* in their name rather than *reported*:

1. On the phone, **Library → This phone** shows its fingerprint: four groups of four letters and digits.
2. Bring a field log from that phone (any; it carries the phone's key).
3. Logged in to RevisionWorx as an administrator, type the fingerprint **from the phone's screen**:

```sh
fieldworx-bridge enrol FieldWorx-4c4c4c-20261107.fieldlog -w "D:/Engineering/Workspace" --account riley \
  --fingerprint 3F2A-91C0-77B1-04DE --name "Riley's phone"
```

If the fingerprint isn't the one of the phone that wrote the field log, nothing is enrolled: you have another phone's
field log. `findings` then says, for each signed finding, whose phone signed it and whether accepting records it as
verified. A lost or stolen phone is revoked in RevisionWorx (`revisionworx user device revoke riley dev_… --reason
"lost"`): its records are accepted as reported from then on, and what was accepted before stays. Enrol a phone before
handing it to someone: the key is the phone's, so what it signed before belongs to the account too. A phone handed to
someone else is reset (reinstall FieldWorx), and enrolled again as a new phone. Needs RevisionWorx's `field-signatures`
feature.

## Trying it with the demo

The app has a built-in demo: Northline Hydraulics' HPU-75 hydraulic power unit (project J-2001), with two units
built, a revised skid frame, a schematic, a BOM with reference designators, stock from OpenMeridian's sample company
and a 16-item final inspection plan. Things to try:

1. **Try the demo (HPU-75)** on the Scan tab or in Library (offered while no package is on the phone).
2. Type `HPU-0001` on the Scan tab: the first unit, built to frame revision A, which has since been revised (*current
   is rev B*). Open its completed acceptance test.
3. Type `K1`: the contactor in the control panel, found by its reference designator.
4. Find `FRM-200`: two things have that number, a part and its drawing; open the drawing, search it for `LIFTING`,
   then open revision A and see the superseded banner.
5. Open `HPU-0002` and **Start an inspection**; answer a few items, enter 170 for the relief valve setting and watch
   it fail, then correct it.

To build the demo yourself, with a real RevisionWorx workspace:
`python examples/demo/build_demo.py OUT --history --package demo.fieldworx`.
