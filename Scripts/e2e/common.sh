#!/bin/bash
# common.sh — shared environment + helpers for the "true new user" E2E harness.
#
# Sourced (not executed) by every sNN-*.sh scenario script. Establishes a
# fully isolated Supervisor universe under /tmp so scenarios can run on a
# machine where a REAL Supervisor is live:
#
#   - SUPERVISOR_HOME          → a fresh FAKEHOME under /tmp/supervisor-e2e/<RUN_ID>
#                                (the ConfigPaths.resolvedHome seam; stubbing
#                                $HOME does NOT work — Foundation resolves the
#                                passwd entry)
#   - SUPERVISOR_KEYCHAIN_PREFIX → test.supervisor.e2e, so every keychain item
#                                the app touches (including the legacy-item
#                                DELETE in migrateLegacyKeyIfPresent) is
#                                disjoint from live.supervisor.api.*
#   - SUPERVISOR_LOG_DIR       → the fake home's log dir (TraceLog seam)
#
# Safety contract (LIVE Supervisor on this machine — do not weaken):
#   - never pkill/killall; teardown kills ONLY the pid recorded at launch,
#     and only after verifying that pid still runs OUR build's binary
#   - keychain cleanup deletes ONLY $SUPERVISOR_KEYCHAIN_PREFIX* services
#   - nothing under the real ~/Library is ever touched
#
# Abort-gate: no scenario may drive the app before await_running_ready (or,
# for onboarding scenarios, await_isolated_boot) has PROVEN the instance is
# running against FAKEHOME. The app echoes `home=<path>` (and
# `keychainPrefix=<prefix>` when set) on its "running state ready" trace line
# for exactly this purpose.

set -euo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$E2E_DIR/../.." && pwd)"
FIXTURES_DIR="$E2E_DIR/fixtures"

# Binaries: default to the SPM debug build; override for release/bundle runs.
BUILD_DIR="${SUPERVISOR_E2E_BUILD_DIR:-$REPO_ROOT/.build/debug}"
APP_BIN="${SUPERVISOR_E2E_APP_BIN:-$BUILD_DIR/Supervisor}"
DRIVER_BIN="${SUPERVISOR_E2E_DRIVER_BIN:-$BUILD_DIR/SupervisorE2EDriver}"
FAKE_CLI_BIN="${SUPERVISOR_E2E_FAKE_CLI_BIN:-$BUILD_DIR/FakeClaudeCLI}"

# Per-run isolation root. RUN_ID is overridable so a debugging session can
# pin a stable path.
RUN_ID="${SUPERVISOR_E2E_RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"

# RUN_ID feeds a path that teardown rm -rf's: sanitize BEFORE first use. Only
# [A-Za-z0-9._-]+, which structurally excludes empty, slashes, spaces, and
# any ../ traversal — a caller-supplied SUPERVISOR_E2E_RUN_ID like "../.."
# would otherwise aim the teardown at /tmp itself (or worse).
case "$RUN_ID" in
    *[!A-Za-z0-9._-]*|"")
        echo "FAIL: invalid SUPERVISOR_E2E_RUN_ID '$RUN_ID' (allowed: A-Za-z0-9._-)" >&2
        exit 1
        ;;
    ..|.)
        echo "FAIL: invalid SUPERVISOR_E2E_RUN_ID '$RUN_ID' (path traversal)" >&2
        exit 1
        ;;
esac

RUN_ROOT="/tmp/supervisor-e2e/$RUN_ID"
FAKEHOME="$RUN_ROOT/home"

export SUPERVISOR_HOME="$FAKEHOME"
export SUPERVISOR_KEYCHAIN_PREFIX="${SUPERVISOR_E2E_KEYCHAIN_PREFIX:-test.supervisor.e2e}"
export SUPERVISOR_LOG_DIR="$FAKEHOME/Library/Logs/Supervisor"

APP_SUPPORT_DIR="$FAKEHOME/Library/Application Support/Supervisor"
TRACE_LOG="$SUPERVISOR_LOG_DIR/supervisor.log"
APP_DB="$APP_SUPPORT_DIR/supervisor.sqlite"
APP_PID_FILE="$RUN_ROOT/app.pid"
FAKE_CLI_PID_FILE="$RUN_ROOT/fake-claude.pid"

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

fail() {
    echo "FAIL: $*" >&2
    E2E_FAILED=1
    teardown || true
    exit 1
}

pass() {
    echo "PASS: $*"
}

info() {
    echo "  ... $*"
}

# ---------------------------------------------------------------------------
# Setup / launch
# ---------------------------------------------------------------------------

require_binaries() {
    for bin in "$@"; do
        [ -x "$bin" ] || fail "missing binary $bin — run: swift build (or set SUPERVISOR_E2E_BUILD_DIR)"
    done
}

setup_fakehome() {
    mkdir -p \
        "$FAKEHOME/.claude/projects" \
        "$SUPERVISOR_LOG_DIR" \
        "$APP_SUPPORT_DIR" \
        "$FAKEHOME/Downloads"
    # Defense-in-depth: pre-arm the RuntimeToggles kill-switches INSIDE the
    # fake home so no scenario can escalate from "watch a scripted session"
    # to typing on the real screen. dispatch-disabled kills the worker_idle
    # auto-dispatch/inject loop; watchdog-disabled kills stall-nudge injects.
    # Safety triage (what s07 asserts) is a different path and stays live.
    # These are THIS instance's markers (RuntimeToggles reads resolvedHome) —
    # the live app's markers are untouched.
    touch "$APP_SUPPORT_DIR/dispatch-disabled.marker" \
          "$APP_SUPPORT_DIR/watchdog-disabled.marker"
    info "FAKEHOME=$FAKEHOME (RUN_ID=$RUN_ID; dispatch+watchdog pre-disabled)"
}

# PRE-LAUNCH gate: interrogate the binary BEFORE it boots. A stale APP_BIN
# built before the isolation seams would resolve the REAL home and the LIVE
# keychain base — and once booted, its DuplicateLaunchPolicy takeover could
# SIGTERM the live Supervisor before any trace-grep gate gets a look. The
# app answers `--print-paths` (home= / keychainBase=) and exits before
# NSApplication or any side effect; refuse to launch unless both lines show
# exactly our isolated values, and the base is not the live one (an empty
# prefix resolves to live.supervisor.api — see LLMProvider.keychainServiceBase).
verify_print_paths_gate() {
    local out_file="$RUN_ROOT/print-paths.out" gate_pid waited=0
    local out home_line base_line

    # Static check FIRST — zero execution: a binary that predates the seam
    # has no "--print-paths" literal in its Mach-O, and running such a binary
    # at all (even to probe the flag) would boot the full app against the
    # real home. grep -q on a binary matches the embedded string constant.
    grep -q -- "--print-paths" "$APP_BIN" \
        || fail "PRE-LAUNCH GATE: $APP_BIN has no --print-paths support (stale binary predating the isolation seams) — refusing to execute it"

    # Now run it, but never trust it to exit: poll and kill OUR gate pid if
    # the flag somehow fell through to a full boot.
    mkdir -p "$RUN_ROOT"
    "$APP_BIN" --print-paths >"$out_file" 2>/dev/null &
    gate_pid=$!
    while kill -0 "$gate_pid" 2>/dev/null; do
        if [ "$waited" -ge 10 ]; then
            kill -9 "$gate_pid" 2>/dev/null || true
            fail "PRE-LAUNCH GATE: --print-paths did not exit within 10s (binary booted the full app?)"
        fi
        sleep 1; waited=$((waited + 1))
    done
    wait "$gate_pid" 2>/dev/null \
        || fail "PRE-LAUNCH GATE: --print-paths exited nonzero"
    out="$(cat "$out_file")"
    home_line="$(echo "$out" | grep '^home=' || true)"
    base_line="$(echo "$out" | grep '^keychainBase=' || true)"
    [ "$home_line" = "home=$FAKEHOME" ] \
        || fail "PRE-LAUNCH GATE: binary resolves '$home_line', expected home=$FAKEHOME"
    [ "$base_line" = "keychainBase=$SUPERVISOR_KEYCHAIN_PREFIX" ] \
        || fail "PRE-LAUNCH GATE: binary resolves '$base_line', expected keychainBase=$SUPERVISOR_KEYCHAIN_PREFIX"
    [ "$base_line" != "keychainBase=live.supervisor.api" ] \
        || fail "PRE-LAUNCH GATE: keychain base resolved to the LIVE base"
    info "pre-launch gate ok: $home_line, $base_line"
}

# Launch the app binary directly (not `open`, which would strip our env) and
# record its pid. Never launches an installed bundle — only the binary the
# caller pointed APP_BIN at, and only after the pre-launch gate proved it
# honors the isolation seams.
launch_app() {
    require_binaries "$APP_BIN"
    setup_fakehome
    verify_print_paths_gate
    "$APP_BIN" >"$RUN_ROOT/app.stdout.log" 2>&1 &
    echo $! > "$APP_PID_FILE"
    info "launched $APP_BIN pid=$(cat "$APP_PID_FILE")"
}

app_pid() {
    cat "$APP_PID_FILE" 2>/dev/null || true
}

app_is_alive() {
    local pid
    pid="$(app_pid)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Abort-gates: prove isolation BEFORE driving anything
# ---------------------------------------------------------------------------

# Wait for the app's "running state ready" trace line and hard-verify it
# reports OUR fake home + the RESOLVED keychain base. This is the primary
# post-launch abort-gate: an app that reached running state against the real
# home must never be driven (or we'd be poking the live instance's world).
# The line echoes LLMProvider.keychainServiceBase — the resolved value, not
# the raw env — so an empty prefix (which resolves to live.supervisor.api)
# fails LOUDLY here instead of vacuously passing a raw-env comparison.
await_running_ready() {
    local timeout="${1:-30}" waited=0 line=""
    while [ "$waited" -lt "$timeout" ]; do
        line="$(grep "running state ready" "$TRACE_LOG" 2>/dev/null | tail -1 || true)"
        [ -n "$line" ] && break
        app_is_alive || fail "app exited before reaching running state (see $RUN_ROOT/app.stdout.log and $TRACE_LOG)"
        sleep 1; waited=$((waited + 1))
    done
    [ -n "$line" ] || fail "timed out (${timeout}s) waiting for 'running state ready' in $TRACE_LOG"
    echo "$line" | grep -qF "home=$FAKEHOME" \
        || fail "ABORT-GATE: running-state trace does not show the fake home. line: $line"
    echo "$line" | grep -qF "keychainBase=$SUPERVISOR_KEYCHAIN_PREFIX" \
        || fail "ABORT-GATE: resolved keychain base is not $SUPERVISOR_KEYCHAIN_PREFIX. line: $line"
    if echo "$line" | grep -qF "keychainBase=live.supervisor.api"; then
        fail "ABORT-GATE: app resolved the LIVE keychain base. line: $line"
    fi
    info "abort-gate ok: $line"
}

# Weaker gate for scenarios that stay IN onboarding (never reach running
# state, so the ready line never fires): the trace log materializing under
# the fake home's log dir proves SUPERVISOR_LOG_DIR took, and the isolated
# Application Support dir being written proves SUPERVISOR_HOME took.
await_isolated_boot() {
    local timeout="${1:-20}" waited=0
    while [ "$waited" -lt "$timeout" ]; do
        if [ -s "$TRACE_LOG" ] && grep -q "applicationDidFinishLaunching" "$TRACE_LOG" 2>/dev/null; then
            info "abort-gate ok: trace live under fake home ($TRACE_LOG)"
            return 0
        fi
        app_is_alive || fail "app exited during boot (see $RUN_ROOT/app.stdout.log)"
        sleep 1; waited=$((waited + 1))
    done
    fail "ABORT-GATE: no trace under $SUPERVISOR_LOG_DIR after ${timeout}s — SUPERVISOR_HOME/LOG_DIR seam did not take"
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

assert_trace() {
    grep -q "$1" "$TRACE_LOG" || fail "trace missing expected line: $1"
}

# Poll for a trace line to appear (engine paths are async).
await_trace() {
    local pattern="$1" timeout="${2:-30}" waited=0
    while [ "$waited" -lt "$timeout" ]; do
        grep -q "$pattern" "$TRACE_LOG" 2>/dev/null && return 0
        sleep 1; waited=$((waited + 1))
    done
    fail "timed out (${timeout}s) waiting for trace line: $pattern"
}

sqlite_query() {
    /usr/bin/sqlite3 "$APP_DB" "$1"
}

# Poll a sqlite scalar query until it returns a value >= expected.
await_sqlite_count() {
    local query="$1" expected="${2:-1}" timeout="${3:-60}" waited=0 n=0
    while [ "$waited" -lt "$timeout" ]; do
        n="$(sqlite_query "$query" 2>/dev/null || echo 0)"
        [ "${n:-0}" -ge "$expected" ] 2>/dev/null && return 0
        sleep 2; waited=$((waited + 2))
    done
    fail "timed out (${timeout}s): sqlite '$query' = ${n:-0}, wanted >= $expected"
}

# ---------------------------------------------------------------------------
# Keychain seeding / cleanup (prefixed services ONLY)
# ---------------------------------------------------------------------------

# Providers must match LLMProvider's suffixes.
E2E_PROVIDERS="anthropic deepseek moonshot minimax qwenhf openrouter"

# Seed an API key for a provider under the TEST prefix. `-A` (allow all
# apps) is required — a CLI-added item is otherwise unreadable by the app
# binary (KeychainAccess gets errSecAuthFailed and onboarding re-triggers).
seed_provider_key() {
    local provider="$1" key="$2"
    security add-generic-password \
        -s "$SUPERVISOR_KEYCHAIN_PREFIX.$provider" -a "api-key" -w "$key" -A -U \
        >/dev/null
    info "seeded keychain item $SUPERVISOR_KEYCHAIN_PREFIX.$provider"
}

seed_active_provider() {
    local provider="$1"
    mkdir -p "$APP_SUPPORT_DIR"
    printf '{"activeProvider":"%s"}' "$provider" > "$APP_SUPPORT_DIR/active-provider.json"
    info "seeded active provider: $provider"
}

delete_test_keychain_items() {
    local p
    for p in $E2E_PROVIDERS; do
        security delete-generic-password -s "$SUPERVISOR_KEYCHAIN_PREFIX.$p" >/dev/null 2>&1 || true
    done
    # The legacy (bare-base) slot the migration path may have written/read.
    security delete-generic-password -s "$SUPERVISOR_KEYCHAIN_PREFIX" >/dev/null 2>&1 || true
}

assert_no_live_keychain_pollution() {
    # The harness must never CREATE live-named items. We can't diff the live
    # items themselves (they legitimately exist for the real app), but we can
    # verify our prefix is disjoint from the live base.
    case "$SUPERVISOR_KEYCHAIN_PREFIX" in
        live.supervisor.api*) fail "refusing to run: SUPERVISOR_KEYCHAIN_PREFIX collides with the live base" ;;
    esac
}

# ---------------------------------------------------------------------------
# Fake session helper
# ---------------------------------------------------------------------------

# Start FakeClaudeCLI replaying a fixture into the fake home's projects tree.
#   run_fake_session <fixture.jsonl> <session-id> [interval-ms]
run_fake_session() {
    local fixture="$1" session_id="$2" interval_ms="${3:-500}"
    require_binaries "$FAKE_CLI_BIN"
    [ -f "$fixture" ] || fail "fixture not found: $fixture"
    # The project dir name mirrors Claude Code's dash-encoding of the cwd;
    # discovery only needs A directory containing <session-id>.jsonl.
    local cwd="$RUN_ROOT/project"
    mkdir -p "$cwd"
    local proj_dir="$FAKEHOME/.claude/projects/$(echo "$cwd" | tr '/' '-')"
    mkdir -p "$proj_dir"
    "$FAKE_CLI_BIN" \
        --jsonl "$proj_dir/$session_id.jsonl" \
        --cwd "$cwd" \
        --session-id "$session_id" \
        --pid-file "$FAKE_CLI_PID_FILE" \
        --interval-ms "$interval_ms" \
        --script "$fixture" \
        >"$RUN_ROOT/fake-claude.log" 2>&1 &
    info "fake session $session_id replaying $(basename "$fixture") -> $proj_dir"
}

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

# Kill ONLY the recorded pid — and only if it is still OUR binary (pids get
# reused; the live Supervisor must never be a casualty of a stale pidfile).
# Companions (Heartbeat/StatusBar) are spawned as children of our app from
# the same BUILD_DIR, so we sweep direct children matching that path too;
# a live installed Supervisor's companions run from /Applications and never
# match.
kill_recorded_pid() {
    local pid_file="$1" expected_path="$2" pid cmd child
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    [ -n "$pid" ] || return 0
    cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [ -n "$cmd" ] && echo "$cmd" | grep -qF "$expected_path"; then
        for child in $(pgrep -P "$pid" 2>/dev/null || true); do
            local child_cmd
            child_cmd="$(ps -p "$child" -o command= 2>/dev/null || true)"
            if echo "$child_cmd" | grep -qF "$BUILD_DIR"; then
                kill "$child" 2>/dev/null || true
            fi
        done
        kill "$pid" 2>/dev/null || true
        # Escalate only if it ignores TERM (it's OUR test instance).
        local waited=0
        while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 5 ]; do sleep 1; waited=$((waited + 1)); done
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
}

teardown() {
    kill_recorded_pid "$APP_PID_FILE" "$APP_BIN"
    kill_recorded_pid "$FAKE_CLI_PID_FILE" "$FAKE_CLI_BIN"
    kill_recorded_pid "$FAKE_CLI_PID_FILE.child" "$FAKE_CLI_BIN"
    delete_test_keychain_items
    # A failed scenario preserves its evidence (trace log, app stdout, DB)
    # instead of deleting it — a FAIL with no artifacts is undebuggable.
    # fail() sets E2E_FAILED before invoking us via the EXIT trap.
    if [ "${E2E_FAILED:-0}" = "1" ] && [ -d "$RUN_ROOT" ]; then
        mkdir -p /tmp/supervisor-e2e/failures
        mv "$RUN_ROOT" "/tmp/supervisor-e2e/failures/$RUN_ID" 2>/dev/null \
            && echo "  ... evidence preserved at /tmp/supervisor-e2e/failures/$RUN_ID" >&2
        return
    fi
    # Belt-and-suspenders on top of the RUN_ID sanitization above: never
    # rm -rf a path that doesn't PHYSICALLY resolve under the e2e root
    # (symlink games, future refactors of RUN_ROOT). /private/tmp is /tmp's
    # real path on macOS.
    if [ -d "$RUN_ROOT" ]; then
        local resolved
        resolved="$(cd "$RUN_ROOT" 2>/dev/null && pwd -P || true)"
        case "$resolved" in
            /tmp/supervisor-e2e/*|/private/tmp/supervisor-e2e/*)
                rm -rf "$RUN_ROOT"
                ;;
            *)
                echo "FAIL: refusing rm -rf: '$RUN_ROOT' resolves to '$resolved', outside the e2e root" >&2
                ;;
        esac
    fi
}

# Every scenario cleans up on ANY exit path; fail() also calls teardown so a
# failed assertion never leaves a test instance running.
trap teardown EXIT

assert_no_live_keychain_pollution
