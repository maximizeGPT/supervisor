#!/bin/bash
# run-calibration-sweep.sh — resolve the Anthropic key, then run a targeted
# live calibration sweep. The Swift test writes its report under
# Tests/Calibration/runs/<ISO>/ (PRINCIPLES section 6b).
#
# Usage:
#   Scripts/run-calibration-sweep.sh [test-filter]
#
#   test-filter  XCTest filter for the sweep to run.
#                Default: testIssue4TargetedSweep (the existing targeted test).
#                Use testCalibrateFullCorpus for the full 300-fixture gate
#                (~$1.9 — exceeds the section 9e autonomous tier; owner-run).
#
# Stops with clear instructions and a non-zero exit if no Anthropic key is
# available. It NEVER fabricates key access.

set -uo pipefail
cd "$(dirname "$0")/.."

FILTER="${1:-testIssue4TargetedSweep}"

# Resolve the key into the environment (or stop with instructions).
# shellcheck source=Scripts/calibration-key.sh
source Scripts/calibration-key.sh
if [ "${ANTHROPIC_API_KEY:-}" = "" ]; then
    echo "[sweep] aborted: no ANTHROPIC_API_KEY (see instructions above)." >&2
    exit 1
fi

echo "[sweep] running filter: $FILTER"
export SUPERVISOR_LIVE_API=1
swift test --filter "$FILTER"
rc=$?

if [ $rc -eq 0 ]; then
    LATEST="$(ls -1dt Tests/Calibration/runs/*/ 2>/dev/null | head -1)"
    echo "[sweep] done. Newest run dir: ${LATEST:-<none written>}"
else
    echo "[sweep] swift test exited $rc (see output above)." >&2
fi
exit $rc
