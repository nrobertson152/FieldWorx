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
- **A unit transferred in from another workspace** (RevisionWorx docs/UNITS.md section 16) shows only the PDF of each
  revision it uses: that's all the receiving workspace keeps of another's documents. A revision that came without one has no
  phone view, and no newer revision is ever shown beside it.
- **Factory lots are in the history.** The lots the work that built a unit used appear as one line of its history (the first
  ten, then how many more), not in a list of their own.
- **A finding's photos stay in the hub.** RevisionWorx records the field record as evidence, not the photo; the bridge's
  hub has it.

## What the phone records

- **Inspections only.** Nonconformances, redlines, work orders and inventory transactions are planned (0.2, 0.3).
- **Names are as typed; phones are enrolled.** A record carries the name entered on the phone, the phone's device id
  and its signature with the phone's own key: that proves which phone made it, not who held the phone. A phone enrolled
  to a RevisionWorx account (`fieldworx-bridge enrol`) is taken to be that person's, so its findings are accepted as
  verified in their name; lend it to someone and what they record is still in the owner's name. Only findings become
  verified: inspections are signed too, but aren't accepted into RevisionWorx. Records made before keys are unsigned.
- **The phone doesn't know whether it is enrolled.** Enrolment is recorded in RevisionWorx; packages don't carry it.
- **A package bringing thousands of new records takes a while to check.** Each record's signature is checked once,
  when it first arrives, in a few milliseconds; a phone's first package after a long time away can bring other phones'
  records by the thousand. The app says it is checking, and stays usable meanwhile.
- **The phone's key is in its app storage,** protected by the app sandbox and the phone's storage encryption, not a
  hardware keystore. Someone who copies the app's files from a rooted or forensically copied phone can sign as it until
  an administrator revokes it.
- **Backups made before this version.** The store, which holds the phone's key, is kept out of backups: on Android by
  the manifest, on an iPhone by marking its folder when the app opens it (the Library says so if that fails). An iPhone
  backup made before this version may still hold the store, with the phone's device id (and, from a build with keys,
  its key): restored onto a second iPhone it would record under the first one's id, refused as a fork at the hub, so
  revoke that phone. Not verified on a real iPhone, or for iPhone-to-iPhone transfer (Quick Start).
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
