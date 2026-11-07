# fieldworx-bridge

The office side of FieldWorx: it makes the packages the phones read from a RevisionWorx workspace, and collects the
field logs they send back. Python 3.10 or later, standard library only. It reaches RevisionWorx, OpenMeridian and
DraftWorx only through their documented command lines and files; it never imports them.

## Install

```sh
python -m pip install ./bridge            # from a FieldWorx checkout
```

RevisionWorx is installed as its own README describes (a standalone build, or
`python -m pip install git+https://github.com/nrobertson152/revisionworx`).

`pack` needs RevisionWorx's `revisionworx` command (on PATH, or `REVISIONWORX_CLI`, or `--revisionworx`).
OpenMeridian is optional (stock figures, from a company file opened read-only). DraftWorx is optional (`draftworx`
on PATH or `DRAFTWORX_CLI`), to give DraftWorx and DXF drawings a phone view.

## Commands

```
fieldworx-bridge pack    -w WORKSPACE [--project P ...] -o OUT.fieldworx [--meridian FILE] [--unreleased]
                         [--templates DIR] [--assets FILE] [--hub DIR | --no-field-records] [--title T] [--overwrite]
fieldworx-bridge import  [-w WORKSPACE | --hub DIR] FILE.fieldlog ...
fieldworx-bridge status  [-w WORKSPACE | --hub DIR]
fieldworx-bridge report  [-w WORKSPACE | --hub DIR] -o FOLDER
fieldworx-bridge verify  FILE
fieldworx-bridge labels  PACKAGE -o OUT.pdf [--assets] [--parts] [--projects]
                         [--only CODE ...] [--layout a4-24|letter-30|roll-50x25|roll-25x12] [--skip N] [--copies N] [--overwrite]
```

- **pack** builds a package: the chosen projects' documents (every revision's details; the released revision's
  content, and every revision a unit was built to), parts and BOMs, unit registers, inspection templates, stock,
  and the field records already in the hub. It refuses content whose hash doesn't match what RevisionWorx recorded,
  and lists in the package's notes everything it left out.
- **import** adds field logs to the hub (`WORKSPACE/.fieldworx` unless `--hub`): each one all or nothing; the same
  log twice changes nothing; a phone whose history was forked is refused.
- **status** summarises the hub and lists inspections that need attention (exit 1 if any).
- **report** writes `inspections.csv` and one self-contained HTML record per inspection, photos included.
- **verify** checks a package or field log completely, changing nothing.
- **labels** lays out FieldWorx labels (QR code, number, description) for what a package holds, as a PDF for label
  sheets or a label printer. A name given with `--only` that matches nothing stops it with nothing written.

Exit codes: 0 done; 1 `verify` found the file unusable, or `status` found something needing attention; 2 refused
(bad input, a damaged file, a forked history, a missing program), with the reason on standard error and nothing
changed.

`python -m fieldworx_bridge` works the same without installing.

## Files

The formats are in [docs/PROTOCOL.md](../docs/PROTOCOL.md); the design in
[docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md). `fieldworx_bridge/rwx_client.py` is RevisionWorx's reference client
(`contrib/rwx_client.py`), copied unchanged as RevisionWorx's integration guide asks. `fieldworx_bridge/fwx_label.py`
is the reference QR encoder for FieldWorx labels, for other programs to copy unchanged.

## Tests

```sh
python -m pip install -e "bridge[dev]"     # test-only: pytest, python-qrcode, zxing-cpp, numpy, pypdfium2
python -m pytest bridge -q
```

Tests marked `revisionworx` run RevisionWorx's real command line on a demo workspace built from scratch; they skip
when RevisionWorx isn't installed.
