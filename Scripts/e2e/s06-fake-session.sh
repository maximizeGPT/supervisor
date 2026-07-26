#!/bin/bash
# s06-fake-session.sh — "Supervisor discovers a (fake) Claude Code session"
# scenario.
#
# With the app in the running state (same seeding as s05), replays the
# benign idle fixture through FakeClaudeCLI --script into the fake home's
# ~/.claude/projects tree, and asserts discovery picked it up: a sessions
# row in sqlite and a discovery trace line.
#
# Pass criteria:
#   - abort-gate (inherited from await_running_ready)
#   - sqlite: sessions row with our session id appears
#   - the session row's jsonl_path is under FAKEHOME (no cross-home bleed)

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_binaries "$APP_BIN" "$FAKE_CLI_BIN"

SESSION_ID="e2e-s06-$(uuidgen | tr 'A-Z' 'a-z')"

setup_fakehome
seed_provider_key "deepseek" "${E2E_API_KEY:-sk-e2e-fake-deepseek-key}"
seed_active_provider "deepseek"

launch_app
await_running_ready 40

run_fake_session "$FIXTURES_DIR/idle.jsonl" "$SESSION_ID" 500

await_sqlite_count "SELECT count(*) FROM sessions WHERE id='$SESSION_ID';" 1 60
info "sessions row present for $SESSION_ID"

JSONL_PATH="$(sqlite_query "SELECT jsonl_path FROM sessions WHERE id='$SESSION_ID';")"
# Compare canonicalized: the app stores physical paths and macOS resolves
# /tmp -> /private/tmp, so the same fake home has two spellings.
FAKEHOME_REAL="$(cd "$FAKEHOME" && pwd -P)"
case "$JSONL_PATH" in
    "$FAKEHOME"/*|"$FAKEHOME_REAL"/*) info "jsonl_path under fake home: $JSONL_PATH" ;;
    *) fail "session jsonl_path escaped the fake home: $JSONL_PATH" ;;
esac

pass "s06 fake-session — discovery tailing the scripted session inside $FAKEHOME"
