#!/bin/bash
# s05-running-state.sh — "a fully-onboarded user reaches the running state
# against the fake home" scenario.
#
# Seeds the fake home + prefixed keychain so onboarding is skipped, launches,
# and asserts the app reaches the running state with every artifact (db,
# pidfile, heartbeat, trace) under FAKEHOME.
#
# Requirement: the app binary must already be AX-trusted on this machine
# (TCC is per-binary; grant it once for the dev build). Without it the app
# stays in onboarding at the AX step and this scenario reports that clearly.
#
# Pass criteria:
#   - trace "onboarding skipped; entering running state"
#   - abort-gate: "running state ready" line carries home=$FAKEHOME and
#     keychainPrefix=$SUPERVISOR_KEYCHAIN_PREFIX
#   - supervisor.sqlite exists under the fake home and has the sessions table
#   - the single-instance pidfile under the fake home records the app pid

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_binaries "$APP_BIN"

setup_fakehome
seed_provider_key "deepseek" "${E2E_API_KEY:-sk-e2e-fake-deepseek-key}"
seed_active_provider "deepseek"

launch_app
await_isolated_boot

if grep -q "onboarding needed" "$TRACE_LOG"; then
    fail "app entered onboarding despite seeded key — likely the app binary lacks AX trust (grant Accessibility to $APP_BIN) or the keychain item is unreadable"
fi
await_trace "onboarding skipped; entering running state" 20
await_running_ready 30

[ -f "$APP_DB" ] || fail "no sqlite db at $APP_DB"
sqlite_query "SELECT count(*) FROM sessions;" >/dev/null \
    || fail "sessions table missing/unreadable in $APP_DB"
info "db ok: $APP_DB"

PIDFILE="$APP_SUPPORT_DIR/supervisor.pid"
[ -f "$PIDFILE" ] || fail "no single-instance pidfile at $PIDFILE"
RECORDED="$(cat "$PIDFILE" | tr -cd '0-9')"
[ "$RECORDED" = "$(app_pid)" ] || fail "pidfile records $RECORDED, launched pid is $(app_pid)"
info "pidfile ok: $PIDFILE -> $RECORDED"

pass "s05 running-state — app running fully inside $FAKEHOME"
