#!/bin/bash
# s07-first-flag.sh — "the new user's first flag" scenario.
#
# Replays the destructive-rm fixture (an rm -rf tool_use aimed at a fake
# path that never exists — nothing is ever executed, it's transcript text)
# and asserts the triage pipeline produces a flag: a row in the flags table
# and the FLAG trace line.
#
# REQUIRES a real, working provider key in E2E_API_KEY (default provider
# deepseek; override with E2E_PROVIDER). `rm -rf` deliberately rides the
# MODEL path, not the deterministic catch (see DeterministicCatch.swift), so
# no key means no flag — the scenario refuses to run rather than fail
# confusingly.
#
# Pass criteria:
#   - abort-gate (inherited)
#   - sqlite: >=1 row in flags for our session id
#   - trace: "FLAG session=<id>" line

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_binaries "$APP_BIN" "$FAKE_CLI_BIN"

[ -n "${E2E_API_KEY:-}" ] || fail "s07 needs a REAL provider key: E2E_API_KEY=sk-... [E2E_PROVIDER=deepseek] $0"
PROVIDER="${E2E_PROVIDER:-deepseek}"

SESSION_ID="e2e-s07-$(uuidgen | tr 'A-Z' 'a-z')"

setup_fakehome
seed_provider_key "$PROVIDER" "$E2E_API_KEY"
seed_active_provider "$PROVIDER"

launch_app
await_running_ready 40

run_fake_session "$FIXTURES_DIR/destructive-rm.jsonl" "$SESSION_ID" 500

# Triage batches + calls the provider; give it a generous window.
await_sqlite_count "SELECT count(*) FROM flags WHERE session_id='$SESSION_ID';" 1 120
info "flags row present for $SESSION_ID"
await_trace "FLAG session=$SESSION_ID" 10

CATEGORY="$(sqlite_query "SELECT category FROM flags WHERE session_id='$SESSION_ID' LIMIT 1;" 2>/dev/null || true)"
info "flag category: ${CATEGORY:-<unknown>}"

pass "s07 first-flag — destructive rm -rf fixture produced a flag via $PROVIDER"
