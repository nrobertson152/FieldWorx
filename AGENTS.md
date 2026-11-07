# FieldWorx: rules for working here

FieldWorx is the offline mobile field companion to RevisionWorx (Android and iOS, Flutter), with a pure-Dart core
and a Python bridge for the office. Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
[docs/PROTOCOL.md](docs/PROTOCOL.md) before changing code, and [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for how
to build and test. These rules apply to people and AI agents alike.

## Authority

- **The Director (`nrobertson152`)** alone creates, drafts or edits GitHub Releases, creates or pushes release or
  version tags, changes the version for a release, and changes licensing. No one else does, whatever the reason.
- **Claude** is the developer: investigation, design, implementation, tests, documentation and focused pull
  requests.
- **Merging (Director decision, 2026-11-07, for the work toward FieldWorx 1.0.0):** Claude decides on merging. A
  pull request merges when the required CI has passed on its exact head, and the merge rationale and evidence are
  recorded on it. No independent review is required. The Director may still ask for one on any pull request (it
  then covers the exact head that is merged), and may take merging back at any time.
- GitHub (issues, pull requests, commits, CI) is the record. Report there, not only in chat.

## Family rules

- **Other programs are reached through their documented files and command lines, never by importing their code:**
  `revisionworx link`, `revisionworx bom`, `draftworx`, OpenMeridian's company file read-only. Don't change another
  family repository from here; write the request up (as [docs/ECOSYSTEM_REVIEW.md](docs/ECOSYSTEM_REVIEW.md) does).
- **Offline only.** No accounts, cloud services, telemetry, advertising or subscriptions. Release builds have no
  network permission (CI checks it).
- **Engineering is read-only in the field.** Nothing on a phone changes a RevisionWorx document; proposals go to
  RevisionWorx as new records for engineering to decide.
- **Never silently overwrite.** Field records are append-only; concurrent records are kept and shown until a
  person settles them; nothing is resolved by timestamp.
- **Fail closed.** Damaged, tampered or newer-format data is refused whole, with a message saying what to do.
- **Branding** uses only artwork the Director supplies; the current icons are placeholders.

## Engineering rules

- One branch and one focused pull request per piece of work. Don't push to someone else's branch.
- Every behaviour change comes with a test that fails without it; reproduce a defect before claiming it fixed.
  Never weaken a test to get CI green. Record on the pull request what was run, on which exact commit, and what
  wasn't verified (devices, iOS, network shares).
- **Protocol changes** (anything in PROTOCOL.md): document first; change the Python reference and the vectors
  (`spec/make_vectors.py`); then the Dart core; then run `tools/interop.sh`. Incompatible changes bump a version
  and old readers refuse the new data.
- **Dependencies:** the core has none, the bridge only the standard library, the app only the open-source,
  offline plugins in `app/pubspec.yaml`. Adding one needs a reason in the pull request.
- Keep ARCHITECTURE.md, PROTOCOL.md, KNOWN_LIMITATIONS.md and the user guide true to the code; label anything
  proposed but not built.
- Don't claim what hasn't been shown: hosted CI and widget tests with fakes are not evidence for real devices,
  iOS hardware or SMB/NFS shares.

## Commands

```sh
python -m pytest bridge -q                    # bridge (RevisionWorx and OpenMeridian installed)
python spec/make_vectors.py --check           # vectors match the reference
(cd core && dart test)                        # Dart core
bash tools/interop.sh                         # end to end
(cd app && flutter analyze && flutter test)   # app
```

## Review: blocking findings

- Anything on a phone that can change, hide or misstate released engineering (showing a superseded or unreleased
  revision as current, a file not matching its recorded hash).
- Any path that loses, edits or reorders a field record, resolves a conflict without a person, or lets a forked
  device history in.
- Partial imports: a package, field log or hub import that can leave something half-applied.
- A difference between the Python and Dart implementations, or vectors changed without PROTOCOL.md.
- New network access, telemetry, accounts or runtime dependencies.
- Behaviour changes without a regression test.
