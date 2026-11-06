#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# End to end, without the phone's screen: the bridge packs the demo workspace from RevisionWorx, the Dart core
# (acting as a phone) installs it, inspects an asset and exports a field log, and the bridge imports that and writes
# the inspection records. Run from the repository root; needs python (with RevisionWorx installed) and dart.
set -euo pipefail
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export XDG_CACHE_HOME="$work/xdg/cache" XDG_STATE_HOME="$work/xdg/state" XDG_CONFIG_HOME="$work/xdg/config"
export PYTHONPATH="$PWD/bridge${PYTHONPATH:+:$PYTHONPATH}"

python examples/demo/build_demo.py "$work/demo" --package "$work/demo.fieldworx"
python -m fieldworx_bridge verify "$work/demo.fieldworx"
(cd core && dart run bin/fxtool.dart verify "$work/demo.fieldworx")
(cd core && dart run bin/fxtool.dart simulate "$work/demo.fieldworx" "$work/out") | tee "$work/sim.json"
log="$(python -c "import json,sys; print(json.load(open(sys.argv[1]))['fieldlog'])" "$work/sim.json")"
python -m fieldworx_bridge verify "$log"
python -m fieldworx_bridge import -w "$work/demo/workspace" "$log"
python -m fieldworx_bridge status -w "$work/demo/workspace"
python -m fieldworx_bridge report -w "$work/demo/workspace" -o "$work/reports"
grep -q ",completed,pass," "$work/reports/inspections.csv"
# The records travel back out to the phones in the next package.
python -m fieldworx_bridge pack -w "$work/demo/workspace" -o "$work/next.fieldworx"
(cd core && dart run bin/fxtool.dart verify "$work/next.fieldworx") | grep -q '"events":'
echo "interop OK"
