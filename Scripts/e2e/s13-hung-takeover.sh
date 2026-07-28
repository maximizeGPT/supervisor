#!/bin/bash
# s13-hung-takeover.sh — the field report, reproduced and beaten: "sometimes
# opens, sometimes doesn't; I had to restart my laptop."
#
# The failing shape was an incumbent that is ALIVE but wedged (main thread
# parked, e.g. on a hidden SecurityAgent prompt): it holds the kernel flock,
# so before v0.3.1 every relaunch silently exited and only a reboot (killing
# the holder) recovered. s11 covers a healthy incumbent, s12 a dead one;
# this covers the hung one — the case the fix exists for.
#
# Mechanism: SIGSTOP our recorded test pid. Its main run loop freezes, so
# the app-alive marker stops being touched, while the process stays alive
# and keeps holding the flock — exactly the wedged-incumbent state. The
# marker is then backdated past the 30s staleness window (a frozen app
# cannot refresh it; this just skips the half-minute wait). A relaunch must
# decide takeover, terminate the frozen incumbent, and reach running state.
#
# Pass criteria:
#   - first instance reaches running state (abort-gated)
#   - relaunch takes the hung-incumbent path (trace: "taking over from
#     hung incumbent"), the frozen incumbent dies, newcomer reaches
#     running state against the fake home
#   - the pidfile records the NEW pid

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_binaries "$APP_BIN"

setup_fakehome
seed_provider_key "deepseek" "${E2E_API_KEY:-sk-e2e-fake-deepseek-key}"
seed_active_provider "deepseek"

launch_app
await_running_ready 40
FIRST_PID="$(app_pid)"

# Freeze the incumbent (OUR verified test pid, never a live instance). The
# process stays alive holding the flock; its alive-beat Timer stops.
kill -STOP "$FIRST_PID"
info "froze incumbent pid=$FIRST_PID (SIGSTOP)"

# Age the marker past the staleness window instead of sleeping 30+ real
# seconds. The frozen incumbent cannot refresh it (that is the point).
APP_ALIVE="$APP_SUPPORT_DIR/app-alive.txt"
[ -f "$APP_ALIVE" ] || { kill -CONT "$FIRST_PID" 2>/dev/null || true; fail "app-alive marker missing at $APP_ALIVE (beat never started?)"; }
touch -t "$(date -v-60S +%Y%m%d%H%M.%S)" "$APP_ALIVE"
info "backdated app-alive marker 60s"

# Relaunch. The newcomer's 2s grace re-check finds the marker still stale
# (the incumbent is frozen and cannot touch it), so it must SIGTERM the
# incumbent, reclaim the flock, and reach running state. Trace persists
# across instances: gate on lines AFTER this point, s12-style.
LINES_BEFORE="$(wc -l < "$TRACE_LOG" | tr -cd '0-9')"

"$APP_BIN" >"$RUN_ROOT/app-relaunch.stdout.log" 2>&1 &
SECOND_PID=$!
echo "$SECOND_PID" > "$APP_PID_FILE"
info "relaunched pid=$SECOND_PID"

WAITED=0
READY_LINE=""
while [ "$WAITED" -lt 40 ]; do
    READY_LINE="$(tail -n "+$((LINES_BEFORE + 1))" "$TRACE_LOG" 2>/dev/null | grep "running state ready" | tail -1 || true)"
    [ -n "$READY_LINE" ] && break
    if ! kill -0 "$SECOND_PID" 2>/dev/null; then
        kill -CONT "$FIRST_PID" 2>/dev/null || true
        fail "relaunch exited instead of taking over the hung incumbent (see $RUN_ROOT/app-relaunch.stdout.log)"
    fi
    sleep 1; WAITED=$((WAITED + 1))
done
if [ -z "$READY_LINE" ]; then
    kill -CONT "$FIRST_PID" 2>/dev/null || true
    fail "relaunch never reached running state within 40s (takeover failed?)"
fi
echo "$READY_LINE" | grep -qF "home=$FAKEHOME" || fail "ABORT-GATE: relaunch ready line lacks fake home: $READY_LINE"

tail -n "+$((LINES_BEFORE + 1))" "$TRACE_LOG" | grep -q "taking over from hung incumbent" \
    || fail "takeover trace line missing — newcomer did not take the hung-incumbent path"
info "takeover trace confirmed"

# The frozen incumbent must be gone (SIGTERM's default disposition
# terminates even a SIGSTOPped process).
WAITED=0
while kill -0 "$FIRST_PID" 2>/dev/null; do
    if [ "$WAITED" -ge 10 ]; then
        kill -CONT "$FIRST_PID" 2>/dev/null || true  # never leak a frozen proc
        fail "hung incumbent pid=$FIRST_PID still alive after takeover"
    fi
    sleep 1; WAITED=$((WAITED + 1))
done
info "hung incumbent pid=$FIRST_PID terminated"

RECORDED="$(cat "$APP_SUPPORT_DIR/supervisor.pid" 2>/dev/null | tr -cd '0-9')"
[ "$RECORDED" = "$SECOND_PID" ] || fail "pidfile records '$RECORDED', expected new pid $SECOND_PID"

pass "s13 hung-takeover — frozen incumbent (the 'restart my laptop' state) was taken over; new pid=$SECOND_PID runs"
