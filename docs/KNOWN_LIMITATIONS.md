# Known limitations (0.1)

What FieldWorx 0.1 doesn't do, or hasn't been shown to do. Planned work is in [ROADMAP.md](ROADMAP.md).

## What the phone knows

- **It is only as current as its last package.** A drawing released after the package was made isn't on the
  phone. Every page shows the package's age, and a package more than 30 days old is flagged.
- **Stock is a snapshot.** On-hand figures come from the OpenMeridian company file when the package was made and
  are labelled *not live*.
- **Photos taken on other phones don't travel in packages.** Their records do, so a unit's history shows the
  inspection and *photo not on this phone*; the hub and the bridge's HTML reports have every photo.
- **Some formats have no phone view.** OpenSchematix projects, DWG, Inventor, SolidWorks and STEP files are listed
  with their revisions but can't be opened: engineering publishes a PDF of them in RevisionWorx. DraftWorx and DXF
  drawings are turned into PDFs only when DraftWorx is installed on the computer that makes the package.
- **Times are shown in UTC**, as recorded.

## What the phone records

- **Inspections only.** Nonconformances, redlines, work orders and inventory transactions are planned (0.2, 0.3).
- **Names are as typed.** A record carries the name entered on the phone and the phone's device id; there are no
  accounts and, in 0.1, no signatures. Hash chains make records tamper-evident, not proof of who held the phone.
- **Clocks are the phones' own.** Times are for people; ordering never depends on them.
- **An inspection keeps the template revision it started with**, even if a newer one arrives mid-inspection.
- **Unsent records live only on the phone.** A lost or broken phone loses what wasn't sent. The Inspect tab counts
  unsent records; send field logs often.
- **The store is never backed up or transferred** to a new phone (on purpose: ARCHITECTURE.md ADR-004). A new
  phone starts empty; everything already sent comes back in the next package.

## Moving files

- **Files, not a network, in 0.1.** Packages and field logs travel through the share sheet, USB, e-mail or a shared
  drive. LAN sync is planned (0.2).
- **A field log always carries every record the phone holds**, so it grows over time. That is what makes resending
  harmless; it is small (a few kilobytes per inspection) until there are many thousands of records.
- **Opening a `.fieldworx` file from e-mail or a file manager** doesn't launch FieldWorx yet: save it, then
  Library → Add.

## Scanning

- **Hardware scanners** (rugged phones' scan keys) work when they type into the code field on the Scan tab, which
  has to have focus. Intent-based scanners (Zebra DataWedge) aren't supported yet.
- **Labels must be printed** with any QR or barcode software for now; the bridge doesn't make label sheets yet.

## What has and hasn't been verified

- **Automated:** the protocol (shared vectors in Python and Dart), the bridge against real RevisionWorx and
  OpenMeridian, every 0.1 workflow as widget tests against the real store and demo package (with a fake camera,
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
