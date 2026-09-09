#!/bin/bash
# selftest-teardown.sh — proves the E2E harness kills every process it started,
# on every exit path.
#
# The bug this exists for: the owner sent a screenshot of three stacked
# "Watching. All clear" hover pills. The extra pills were harness instances.
# Each scenario launches a real Supervisor with an isolated SUPERVISOR_HOME, and
# an isolated instance is invisible to the single-instance flock BY DESIGN (the
# flock is namespaced by the same home seam), so it runs alongside the owner's
# real app and, until this round of fixes, drew its own band on his screen. A
# scenario that dies without killing what it launched leaves that band there.
#
# THIS SCRIPT LAUNCHES NO SUPERVISOR. Every "instance" is a stand-in shell
# script sitting in a fake BUILD_DIR, so the teardown contract can be exercised
# — including the interrupt and the frozen-instance paths — without a single
# window appearing on anyone's screen. That is the whole point: the harness is
# what puts windows up, so its safety net must be testable without doing so.
#
# Cases:
#   clean     a normally-exiting scenario kills what it launched
#   fail      an early fail() kills what it launched
#   sigterm   a scenario killed with SIGTERM kills what it launched
#   sigint    a scenario interrupted with SIGINT (Ctrl-C) kills what it launched
#   frozen    the s13 shape: a SIGSTOPped instance whose pid was displaced in
#             APP_PID_FILE by a relaunch is STILL torn down
#   stranger  a ledger pid that is not our binary is never signalled
#
# Run directly, or via SupervisorCoreTests.E2ETeardownSelfTests.

set -euo pipefail

SELFTEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/supervisor-e2e-selftest.XXXXXX")"
BIN_DIR="$ROOT/bin"
PID_DIR="$ROOT/pids"
CASE_DIR="$ROOT/cases"
mkdir -p "$BIN_DIR" "$PID_DIR" "$CASE_DIR"

FAILURES=0

cleanup_root() {
    # Belt and suspenders: anything the cases somehow left behind dies here, so
    # the self-test itself can never be the thing that leaks a process.
    local f pid status=$?
    # `set -e` is still armed inside an EXIT trap, and a `kill` on an
    # already-dead pid returns nonzero. Without this the sweep would abandon
    # itself halfway and hand back the wrong exit status for the whole run.
    set +e
    for f in "$PID_DIR"/*; do
        [ -f "$f" ] || continue
        while read -r pid; do
            [ -n "${pid:-}" ] && kill -CONT "$pid" 2>/dev/null
            [ -n "${pid:-}" ] && kill -9 "$pid" 2>/dev/null
        done < "$f"
    done
    rm -rf "$ROOT"
    # The `fail` cases preserve their evidence, by design — but a deliberate
    # self-test failure is not evidence anyone wants accumulating on disk, and
    # a case cut short can leave its run directory. Both are named `selftest-*`
    # precisely so this sweep can be exact.
    rm -rf /tmp/supervisor-e2e/selftest-* /tmp/supervisor-e2e/failures/selftest-*
    return "$status"
}
trap cleanup_root EXIT

ok()   { echo "  ok   $*"; }
bad()  { echo "  BAD  $*" >&2; FAILURES=$((FAILURES + 1)); }

pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# Wait for a pid to die, up to `timeout` seconds. Teardown escalates TERM to
# KILL over ~5s, so give it room.
await_death() {
    local pid="$1" timeout="${2:-12}" waited=0
    while pid_alive "$pid"; do
        [ "$waited" -ge "$timeout" ] && return 1
        sleep 1; waited=$((waited + 1))
    done
    return 0
}

# ---------------------------------------------------------------------------
# The stand-in "app binary"
# ---------------------------------------------------------------------------
#
# Named `Supervisor` inside a fake BUILD_DIR because that is what the harness's
# identity check greps for: `ps -p <pid> -o command=` must contain APP_BIN's
# path before the harness will signal anything. A shell script (rather than
# `exec sleep`) keeps the path in the process's command line — an exec'd sleep
# reports as plain "sleep 300" and the identity check would correctly refuse to
# kill it, testing nothing.
cat > "$BIN_DIR/Supervisor" <<'STANDIN'
#!/bin/sh
# Stand-in for the Supervisor binary in teardown self-tests. Blocks without
# burning CPU, keeps its own path in `ps -o command=`, and dies on SIGTERM the
# way the real app does (which never runs applicationWillTerminate either).
sleep 300 &
CHILD=$!
trap 'kill "$CHILD" 2>/dev/null; exit 143' TERM INT
wait "$CHILD"
STANDIN
chmod +x "$BIN_DIR/Supervisor"

# Shared preamble for every case script. A case is a real scenario: it sources
# the real common.sh, with the fake BUILD_DIR and a keychain prefix that cannot
# collide with anything (not the live base, not even the normal e2e items).
case_preamble() {
    local name="$1"
    cat <<PREAMBLE
#!/bin/bash
export SUPERVISOR_E2E_BUILD_DIR="$BIN_DIR"
export SUPERVISOR_E2E_KEYCHAIN_PREFIX="test.supervisor.e2e.selftest"
# A run id that names itself, so anything this self-test leaves under
# /tmp/supervisor-e2e is identifiable and sweepable. The harness sanitizes
# RUN_ID to [A-Za-z0-9._-]+, which this satisfies.
export SUPERVISOR_E2E_RUN_ID="selftest-$name-\$\$"
source "$SELFTEST_DIR/common.sh"
mkdir -p "\$RUN_ROOT"
PREAMBLE
}

write_case() {
    local name="$1"
    local file="$CASE_DIR/$name.sh"
    case_preamble "$name" > "$file"
    cat >> "$file"
    chmod +x "$file"
    echo "$file"
}

# Run a case script in the background, return its pid. Output is captured so a
# deliberate FAIL does not look like a self-test failure.
#
# `set -m` matters, and is not a workaround. POSIX has a non-interactive shell
# start background jobs with SIGINT set to IGNORE, and a signal ignored on entry
# cannot be trapped — so without job control the case would silently have no
# INT handler and the SIGINT case would pass or fail for reasons that have
# nothing to do with the harness. Job control gives the case its own process
# group and the default disposition, which is what a developer's Ctrl-C in a
# terminal actually delivers.
run_case_bg() {
    local file="$1" pid
    set -m
    "$file" >"$ROOT/$(basename "$file").out" 2>&1 &
    pid=$!
    set +m
    echo "$pid"
}

# Read the single pid a case recorded, once the file appears.
await_pid_file() {
    local file="$1" waited=0
    while [ ! -s "$file" ]; do
        [ "$waited" -ge 15 ] && return 1
        sleep 1; waited=$((waited + 1))
    done
    return 0
}

# ---------------------------------------------------------------------------
# clean: a scenario that exits normally kills what it launched
# ---------------------------------------------------------------------------
echo "case: clean exit"
CASE="$(write_case clean <<CASE
spawn_extra_app "\$RUN_ROOT/a.log"
echo "\$E2E_LAST_PID" > "$PID_DIR/clean"
exit 0
CASE
)"
"$CASE" >"$ROOT/clean.out" 2>&1 || true
CLEAN_PID="$(cat "$PID_DIR/clean" 2>/dev/null || true)"
[ -n "$CLEAN_PID" ] || bad "clean: case never recorded a pid"
if [ -n "$CLEAN_PID" ]; then
    if await_death "$CLEAN_PID"; then ok "clean: launched pid $CLEAN_PID was torn down"
    else bad "clean: pid $CLEAN_PID survived a normal exit"; fi
fi

# ---------------------------------------------------------------------------
# fail: an early fail() kills what it launched
# ---------------------------------------------------------------------------
echo "case: early fail()"
CASE="$(write_case failpath <<CASE
spawn_extra_app "\$RUN_ROOT/a.log"
echo "\$E2E_LAST_PID" > "$PID_DIR/failpath"
fail "deliberate self-test failure"
CASE
)"
"$CASE" >"$ROOT/failpath.out" 2>&1 || true
FAIL_PID="$(cat "$PID_DIR/failpath" 2>/dev/null || true)"
[ -n "$FAIL_PID" ] || bad "fail: case never recorded a pid"
if [ -n "$FAIL_PID" ]; then
    if await_death "$FAIL_PID"; then ok "fail: launched pid $FAIL_PID was torn down"
    else bad "fail: pid $FAIL_PID survived fail()"; fi
fi
# ---------------------------------------------------------------------------
# sigterm / sigint: a signalled scenario kills what it launched
# ---------------------------------------------------------------------------
for SIG in TERM INT; do
    echo "case: SIG$SIG"
    lower="$(echo "$SIG" | tr 'A-Z' 'a-z')"
    # The idle shape is a one-second poll loop, matching every real scenario
    # (await_trace, await_running_ready, the duplicate-liveness loops). This is
    # deliberate, not incidental: bash defers a trap until the foreground
    # command it is waiting on returns, so the harness's teardown latency after
    # a Ctrl-C is exactly the length of its longest foreground sleep. Every
    # scenario's is 1-2s. Park a `sleep 60` in one and an interrupted run keeps
    # a Supervisor on screen for a minute.
    CASE="$(write_case "sig$lower" <<CASE
spawn_extra_app "\$RUN_ROOT/a.log"
echo "\$E2E_LAST_PID" > "$PID_DIR/sig$lower"
for _ in \$(seq 1 60); do sleep 1; done
CASE
)"
    CASE_PID="$(run_case_bg "$CASE")"
    if ! await_pid_file "$PID_DIR/sig$lower"; then
        bad "sig$lower: case never recorded a pid"
        kill -9 "$CASE_PID" 2>/dev/null || true
        continue
    fi
    SIG_PID="$(cat "$PID_DIR/sig$lower")"
    kill -"$SIG" "$CASE_PID" 2>/dev/null || true
    if await_death "$SIG_PID"; then ok "sig$lower: launched pid $SIG_PID was torn down"
    else bad "sig$lower: pid $SIG_PID survived SIG$SIG to the scenario"; fi
    # Let the case finish its own teardown. The kill above is the whole point
    # of the case; SIGKILLing it the moment the stand-in dies would cut its
    # cleanup short and leave a run directory behind, which is the self-test
    # littering rather than the harness leaking.
    await_death "$CASE_PID" 10 || kill -9 "$CASE_PID" 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# frozen: the s13 shape. An instance is SIGSTOPped, then a relaunch displaces
# its pid in APP_PID_FILE, then the scenario fails. Before the launch ledger,
# teardown only knew the relaunched pid, so the frozen one stayed alive with
# its hover band painted on the owner's screen — unkillable, and un-noticed
# because a stopped process does not show up as busy.
# ---------------------------------------------------------------------------
echo "case: frozen instance displaced in APP_PID_FILE (s13 shape)"
CASE="$(write_case frozen <<CASE
spawn_extra_app "\$RUN_ROOT/first.log" primary
FIRST="\$E2E_LAST_PID"
kill -STOP "\$FIRST"
spawn_extra_app "\$RUN_ROOT/second.log" primary
SECOND="\$E2E_LAST_PID"
printf '%s\n%s\n' "\$FIRST" "\$SECOND" > "$PID_DIR/frozen"
fail "deliberate self-test failure after the takeover"
CASE
)"
"$CASE" >"$ROOT/frozen.out" 2>&1 || true
FROZEN_FIRST="$(sed -n 1p "$PID_DIR/frozen" 2>/dev/null || true)"
FROZEN_SECOND="$(sed -n 2p "$PID_DIR/frozen" 2>/dev/null || true)"
if [ -z "$FROZEN_FIRST" ] || [ -z "$FROZEN_SECOND" ]; then
    bad "frozen: case never recorded both pids"
else
    if await_death "$FROZEN_FIRST"; then
        ok "frozen: the SIGSTOPped pid $FROZEN_FIRST was torn down despite losing APP_PID_FILE"
    else
        bad "frozen: SIGSTOPped pid $FROZEN_FIRST leaked (this is the stacked-pill bug)"
    fi
    if await_death "$FROZEN_SECOND"; then ok "frozen: relaunched pid $FROZEN_SECOND was torn down"
    else bad "frozen: relaunched pid $FROZEN_SECOND leaked"; fi
fi
# ---------------------------------------------------------------------------
# stranger: a ledger pid that is not our binary is never signalled. This is the
# protection that keeps the owner's live Supervisor safe from a reused pid, and
# it has to survive every change to the kill path above.
# ---------------------------------------------------------------------------
echo "case: stranger pid in the ledger is not signalled"
CASE="$(write_case stranger <<CASE
/bin/sleep 45 &
STRANGER=\$!
record_launched_pid "\$STRANGER" "\$APP_BIN"
echo "\$STRANGER" > "$PID_DIR/stranger"
exit 0
CASE
)"
"$CASE" >"$ROOT/stranger.out" 2>&1 || true
STRANGER_PID="$(cat "$PID_DIR/stranger" 2>/dev/null || true)"
if [ -z "$STRANGER_PID" ]; then
    bad "stranger: case never recorded a pid"
elif pid_alive "$STRANGER_PID"; then
    ok "stranger: pid $STRANGER_PID (not our binary) was left alone"
    kill -9 "$STRANGER_PID" 2>/dev/null || true
else
    bad "stranger: pid $STRANGER_PID was killed; the identity check would also kill the owner's live Supervisor on a reused pid"
fi

# ---------------------------------------------------------------------------
echo
if [ "$FAILURES" -eq 0 ]; then
    echo "PASS: e2e teardown self-test: every launched process was reclaimed on every exit path"
    exit 0
fi
echo "FAIL: e2e teardown self-test: $FAILURES case(s) failed" >&2
exit 1
