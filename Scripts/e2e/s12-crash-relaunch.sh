#!/bin/bash
# s12-crash-relaunch.sh — "the app crashed; relaunch must not be blocked"
# scenario.
#
# Simulates a hard crash (SIGKILL to OUR recorded test pid — never a live
# instance) and asserts a relaunch takes over cleanly: the flock died with
# the holder, so the newcomer claims the lock instead of bowing out to a
# ghost, and reaches the running state again.
#
# Pass criteria:
#   - first instance reaches running state (abort-gated)
#   - after SIGKILL, a relaunch reaches running state again (no stale-lock
#     lockout, no "duplicate" false positive against a dead pid)
#   - the pidfile now records the NEW pid

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_binaries "$APP_BIN"

setup_fakehome
seed_provider_key "deepseek" "${E2E_API_KEY:-sk-e2e-fake-deepseek-key}"
seed_active_provider "deepseek"

launch_app
await_running_ready 40
FIRST_PID="$(app_pid)"

# Hard crash. This pid is the one WE launched and abort-gate-verified
# against FAKEHOME; killing it is in-contract. kill -9 specifically: the
# guard must survive the no-cleanup path (flock released by the kernel, but
# the pidfile content and any markers are left behind).
kill -9 "$FIRST_PID"
# Reap + confirm death.
WAITED=0
while kill -0 "$FIRST_PID" 2>/dev/null; do
    [ "$WAITED" -ge 10 ] && fail "pid $FIRST_PID survived SIGKILL?"
    sleep 1; WAITED=$((WAITED + 1))
done
rm -f "$APP_PID_FILE"
info "crashed pid=$FIRST_PID (SIGKILL)"

# Relaunch. The trace file persists across the crash, so gate on a ready
# line NEWER than the crash: truncate our view by line count.
LINES_BEFORE="$(wc -l < "$TRACE_LOG" | tr -cd '0-9')"

"$APP_BIN" >"$RUN_ROOT/app-relaunch.stdout.log" 2>&1 &
echo $! > "$APP_PID_FILE"
SECOND_PID="$(app_pid)"
info "relaunched pid=$SECOND_PID"

WAITED=0
READY_LINE=""
while [ "$WAITED" -lt 40 ]; do
    READY_LINE="$(tail -n "+$((LINES_BEFORE + 1))" "$TRACE_LOG" 2>/dev/null | grep "running state ready" | tail -1 || true)"
    [ -n "$READY_LINE" ] && break
    kill -0 "$SECOND_PID" 2>/dev/null || fail "relaunch exited — stale lock/pidfile blocked recovery (see $RUN_ROOT/app-relaunch.stdout.log)"
    sleep 1; WAITED=$((WAITED + 1))
done
[ -n "$READY_LINE" ] || fail "relaunch never reached running state within 40s"
echo "$READY_LINE" | grep -qF "home=$FAKEHOME" || fail "ABORT-GATE: relaunch ready line lacks fake home: $READY_LINE"
info "relaunch ready: $READY_LINE"

PIDFILE="$APP_SUPPORT_DIR/supervisor.pid"
RECORDED="$(cat "$PIDFILE" | tr -cd '0-9')"
[ "$RECORDED" = "$SECOND_PID" ] || fail "pidfile records $RECORDED; expected relaunched pid $SECOND_PID"

pass "s12 crash-relaunch — SIGKILL'd instance did not block recovery; new pid=$SECOND_PID owns the lock"
