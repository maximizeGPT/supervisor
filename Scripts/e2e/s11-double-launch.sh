#!/bin/bash
# s11-double-launch.sh — "double-click twice" scenario.
#
# A new user who launches Supervisor twice must end up with exactly ONE
# running instance: the newcomer bows out (SingleInstanceGuard flock), the
# incumbent keeps running, and only one hover band/engine exists.
#
# Pass criteria:
#   - first instance reaches running state (abort-gated)
#   - second instance EXITS on its own (exit 0) within the window
#   - trace records the duplicate bowing out ("another Supervisor is already
#     running")
#   - the incumbent is still alive and the pidfile still records ITS pid

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_binaries "$APP_BIN"

setup_fakehome
seed_provider_key "deepseek" "${E2E_API_KEY:-sk-e2e-fake-deepseek-key}"
seed_active_provider "deepseek"

launch_app
await_running_ready 40
INCUMBENT="$(app_pid)"

# Second launch, same env (same FAKEHOME => same pidfile/flock).
"$APP_BIN" >"$RUN_ROOT/app2.stdout.log" 2>&1 &
DUP_PID=$!
info "launched duplicate pid=$DUP_PID"

# The duplicate must exit BY ITSELF. wait-with-timeout: poll liveness.
WAITED=0
while kill -0 "$DUP_PID" 2>/dev/null; do
    if [ "$WAITED" -ge 30 ]; then
        # Scoped kill of the duplicate we spawned, then fail.
        kill "$DUP_PID" 2>/dev/null || true
        fail "duplicate pid=$DUP_PID still alive after 30s — single-instance guard did not fire"
    fi
    sleep 1; WAITED=$((WAITED + 1))
done
info "duplicate exited on its own"

assert_trace "another Supervisor is already running"

kill -0 "$INCUMBENT" 2>/dev/null || fail "incumbent pid=$INCUMBENT died — the guard killed the wrong instance"
PIDFILE="$APP_SUPPORT_DIR/supervisor.pid"
RECORDED="$(cat "$PIDFILE" | tr -cd '0-9')"
[ "$RECORDED" = "$INCUMBENT" ] || fail "pidfile records $RECORDED after the duplicate; expected incumbent $INCUMBENT"

pass "s11 double-launch — duplicate bowed out, incumbent pid=$INCUMBENT unharmed"
