# Known limitations

What FieldWorx doesn't do yet, or hasn't been shown to do. Planned work is in [ROADMAP.md](ROADMAP.md).

## What the phone knows

- **It is only as current as its last package.** A drawing released after the package was made isn't on the
  phone. Every page shows the package's age, and a package more than 30 days old is flagged.
- **Stock is a snapshot.** On-hand figures come from the OpenMeridian company file when the package was made and
  are labelled *not live*.
- **Photos taken on other phones don't travel in packages.** Their records do, so a unit's history shows the
  inspection and *photo not on this phone*; the hub and the bridge's HTML reports have every photo.
- **Some formats have no phone view of their own.** OpenSchematix projects, DWG, Inventor, SolidWorks and STEP files
  open on the phone only through the PDF engineering attaches to that exact revision in RevisionWorx (`revisionworx doc
  pdf`); a revision without one is listed but can't be opened, and never shows another revision's PDF. DraftWorx and DXF
  drawings are turned into PDFs only when DraftWorx is installed on the computer that makes the package.
- **Times are shown in UTC**, as recorded.

## Units

- **The phone shows a unit as it was when the package was made.** A part fitted or a document changed since then
  appears in the next package. What a unit was *on a given date* is answered in RevisionWorx
  (`revisionworx unit show --on DATE`), not on the phone.
- **Engineering changes show where they stood when the package was made**, and can't be updated from the phone. A change
  carried out in the field is a finding, which the office accepts into RevisionWorx (`fieldworx-bridge accept`).
- **Deviations too.** Whether one is in effect is as the package says; *past its end date* uses the phone's own date, so a
  phone with the wrong date shows it wrongly. A temporary part replaced by the right one is a finding; engineering clears
  the deviation in RevisionWorx.
- **A phone doesn't see that a finding was accepted.** The unit's page shows the new configuration from the next package,
  but not which finding it came from; packages would need to carry the evidence (a new asset version).
- **A finding's photos stay in the hub.** RevisionWorx records the field record as evidence, not the photo; the bridge's
  hub has it.

## What the phone records

- **Inspections only.** Nonconformances, redlines, work orders and inventory transactions are planned (0.2, 0.3).
- **Names are as typed.** A record carries the name entered on the phone and the phone's device id; there are no
  accounts on the phone and, so far, no signatures. Hash chains make records tamper-evident, not proof of who held the
  phone. Signed records and phones enrolled to RevisionWorx accounts are decided for 1.0.0 and being built
  (ARCHITECTURE.md ADR-015).
- **On iOS the store is in backups.** Android keeps the device's folder out of backups and device transfers; on an
  iPhone it is in `Application Support`, which iCloud and computer backups include, so a backup restored onto a second
  iPhone would record under the first one's device id (refused as a fork at the hub). Excluding it is part of ADR-015,
  since the folder will hold the phone's key.
- **Clocks are the phones' own.** Times are for people; ordering never depends on them.
- **An inspection keeps the template revision it started with**, even if a newer one arrives mid-inspection.
- **Unsent records live only on the phone.** A lost or broken phone loses what wasn't sent. The Inspect tab counts
  unsent records; send field logs often.
- **The store is never backed up or transferred** to a new phone (on purpose: ARCHITECTURE.md ADR-004). A new
  phone starts empty; everything already sent comes back in the next package.

## Moving files

- **Files, not a network, so far.** Packages and field logs travel through the share sheet, USB, e-mail or a shared
  drive. LAN sync is planned (0.2).
- **A field log always carries every record the phone holds**, so it grows over time. That is what makes resending
  harmless; it is small (a few kilobytes per inspection) until there are many thousands of records.
- **Opening a `.fieldworx` file from e-mail or a file manager** doesn't launch FieldWorx yet: save it, then
  Library → Add.

## Scanning

- **Hardware scanners** (rugged phones' scan keys) work when they type into the code field on the Scan tab, which
  has to have focus. Intent-based scanners (Zebra DataWedge) aren't supported yet.
- **Labels come in four layouts**, the ones the family supports: A4 70 x 37 mm, US Letter 2-5/8 x 1 in, and 50 x 25 mm and
  25 x 12 mm label printers. Other stock needs a new layout in `labels.py`.
- **The 25 x 12 mm label** has room only for the code, its kind and its number. Its code is at level M, not Q, so that
  each module stays big enough for a phone (about 0.3 mm). It reads with less of it dirty or torn than a larger label.
- **Label text uses the fonts every PDF reader has**, which cover Western European letters. Other letters print as "?"
  beside the code; the QR code always holds the exact text.
- **Codes print up to QR version 10** (151 bytes at level Q). A longer number is refused with a message, not shrunk.
- **Sheets that run to the edge of the paper** (the A4 layout does) need a printer that prints close to the edge. Print
  a test sheet on plain paper first.
- **Labels have been checked by rendering and decoding**, with the decoder the app uses, not by printing on real label
  stock and scanning with phones.

## What has and hasn't been verified

- **Automated:** the protocol (shared vectors in Python and Dart), the bridge against real RevisionWorx and
  OpenMeridian, every workflow as widget tests against the real store and demo package (with a fake camera,
  PDF engine, file picker and share sheet), the bridge and the Dart core end to end through real files, and Android
  and iOS builds.
- **Not automated:** the camera scanner, the PDF engine, the file picker, photo capture and the share sheet on real
  devices. Each is a maintained open-source plugin, but they need a manual check on a phone before a release (see
  the acceptance list in [DEVELOPMENT.md](DEVELOPMENT.md)).
- **iOS** builds in CI but hasn't been run on an iPhone, and installing on one needs an Apple developer account.
- **A hub on a network share** relies on exclusive create and no-replace rename, tested on local disks. As with
  RevisionWorx and OpenMeridian, SMB and NFS shares are untested: import on one computer at a time there until
  that is verified.
- **Scale** has been exercised with the demo (9 documents, 17 parts, 35 records). Packages with thousands of
  drawings and phones with tens of thousands of records haven't been measured.
