#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# End to end, without the phone's screen: the bridge packs the demo workspace from RevisionWorx (its asset register
# imported into RevisionWorx's unit register), the Dart core (acting as a phone) installs it, inspects a unit, records a
# finding about it and exports a field log, all signed with the phone's own key, and the bridge imports that (checking
# the signatures in Python), writes the inspection records, enrols the phone to an account in the workspace (set up
# for a team) and accepts the finding into RevisionWorx as verified, which RevisionWorx checks again with its own
# Ed25519.
# Run from the repository root; needs python (with RevisionWorx installed) and dart.
set -euo pipefail
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export XDG_CACHE_HOME="$work/xdg/cache" XDG_STATE_HOME="$work/xdg/state" XDG_CONFIG_HOME="$work/xdg/config"
export PYTHONPATH="$PWD/bridge${PYTHONPATH:+:$PYTHONPATH}"

python examples/demo/build_demo.py "$work/demo"
revisionworx -w "$work/demo/workspace" unit import "$work/demo/source/AST-HPU-75 Units built.fwassets.csv"
meridian="$(python -c "import json,sys; print(json.load(open(sys.argv[1]))['meridian'])" "$work/demo/demo.json")"
python -m fieldworx_bridge pack -w "$work/demo/workspace" --project J-2001 -o "$work/demo.fieldworx" \
  ${meridian:+--meridian "$meridian"}
python -m fieldworx_bridge verify "$work/demo.fieldworx"
(cd core && dart run bin/fxtool.dart verify "$work/demo.fieldworx")
(cd core && dart run bin/fxtool.dart simulate "$work/demo.fieldworx" "$work/out") | tee "$work/sim.json"
log="$(python -c "import json,sys; print(json.load(open(sys.argv[1]))['fieldlog'])" "$work/sim.json")"
python -m fieldworx_bridge verify "$log"
python -m fieldworx_bridge import -w "$work/demo/workspace" "$log"
python -m fieldworx_bridge status -w "$work/demo/workspace"
python -m fieldworx_bridge report -w "$work/demo/workspace" -o "$work/reports"
grep -q ",completed,pass," "$work/reports/inspections.csv"
# The phone is enrolled to an account, by its fingerprint, in the workspace now set up for a team; the finding goes into
# the unit's history in RevisionWorx as verified in that account's name, once, and RevisionWorx checks it again.
printf 'correct horse battery\n' |
  revisionworx -w "$work/demo/workspace" team enable --admin office --password-stdin >/dev/null
fingerprint="$(python -c "import json,sys; print(json.load(open(sys.argv[1]))['fingerprint'])" "$work/sim.json")"
python -m fieldworx_bridge enrol "$log" -w "$work/demo/workspace" --account office --fingerprint "$fingerprint" \
  --name "fxtool phone" | grep -q "enrolled fxtool phone"
finding="$(python -c "import json,sys; print(json.load(open(sys.argv[1]))['finding'])" "$work/sim.json")"
python -m fieldworx_bridge findings -w "$work/demo/workspace" | grep -q "to accept: kept as a note"
python -m fieldworx_bridge findings -w "$work/demo/workspace" | grep -q "signed on fxtool phone, enrolled to office"
python -m fieldworx_bridge accept "$finding" -w "$work/demo/workspace" | grep -q "verified: signed on fxtool phone"
python -m fieldworx_bridge accept "$finding" -w "$work/demo/workspace" | grep -q "already accepted"
revisionworx -w "$work/demo/workspace" unit verify
# The records travel back out to the phones in the next package.
python -m fieldworx_bridge pack -w "$work/demo/workspace" -o "$work/next.fieldworx"
(cd core && dart run bin/fxtool.dart verify "$work/next.fieldworx") | grep -q '"events":'
echo "interop OK"
