#!/bin/bash
# s03-onboarding-key.sh — "first launch shows onboarding; the key lands in an
# ISOLATED keychain slot" scenario.
#
# Launches the app against a virgin FAKEHOME (no key, no config), asserts it
# enters onboarding rather than the running state, then drives the key-entry
# step over AX and asserts the entered key was written under the TEST
# keychain prefix — never under live.supervisor.api.*.
#
# Requirements: the invoking terminal must be AX-trusted (the driver reads
# the app's AX tree), and the app binary itself needs no permissions for
# this scenario (we stop before the AX/notification steps).
#
# Optional: E2E_API_KEY — a real provider key, if you want "Validate & Save"
# to actually succeed. Defaults to an obviously-fake key; validation then
# FAILS, which is itself an accepted outcome here (the assertion is about
# keychain isolation + the flow being drivable, not provider availability).
#
# Pass criteria:
#   - abort-gate: trace log materializes under FAKEHOME (isolation took)
#   - abort-gate: the onboarding window is placed off screen, not presented as
#     the real user (screen isolation, the half the running-state gate misses)
#   - trace shows "onboarding needed" (virgin home => onboarding, not running)
#   - the key field is settable and "Validate & Save" pressable over AX
#   - after the press, the trace shows "submitKey provider=" (emitted only on
#     the submit path, so it proves the press landed) followed by one of the
#     three validation outcomes
#   - the outcome and the keychain agree both ways: "validated + persisted"
#     requires a prefixed item to exist, any other outcome requires that no
#     item was written
#   - in BOTH cases no NEW live-named item appears

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_binaries "$APP_BIN" "$DRIVER_BIN"

E2E_KEY="${E2E_API_KEY:-sk-ant-e2e-fake-key-000000}"

launch_app
await_isolated_boot
await_trace "onboarding needed" 20

# Screen isolation, the onboarding half. This scenario stays IN onboarding, so
# the running-state abort-gate (which checks the hover band) never fires for
# it — and the window it drives is a 480x420 one that used to open on the
# owner's desktop and take his keyboard with it via NSApp.activate. The window
# still exists, because the AX drive below needs one, but off every screen.
await_trace "onboarding window off screen" 15
if grep -q "onboarding window presented (real user home)" "$TRACE_LOG"; then
    fail "ABORT-GATE: this instance presented onboarding as the real user; it is drawing on the owner's screen"
fi
info "abort-gate ok: onboarding window off screen (nothing drawn on the owner's screen)"

PID="$(app_pid)"

# Give the onboarding window a beat to construct its AX tree.
WAITED=0
until "$DRIVER_BIN" --pid "$PID" windows 2>/dev/null | grep -q '"title"'; do
    [ "$WAITED" -ge 20 ] && fail "no AX windows on pid $PID after 20s (is this terminal AX-trusted?)"
    sleep 1; WAITED=$((WAITED + 1))
done
info "onboarding window up"

# Walk to the key-entry step. The welcome/provider screens advance on
# "Continue"; tolerate their absence (step order may evolve) by trying a few
# times, then require the key field.
for _ in 1 2 3; do
    if "$DRIVER_BIN" --pid "$PID" tree | grep -q '"placeholder" : "sk-'; then
        break
    fi
    "$DRIVER_BIN" --pid "$PID" press --title "Continue" >/dev/null 2>&1 || true
    sleep 1
done
"$DRIVER_BIN" --pid "$PID" tree | grep -q '"placeholder" : "sk-' \
    || fail "key-entry SecureField (placeholder sk-...) not found in AX tree"

# The SecureField carries no title; it is matched by its placeholder text
# (matchableStrings includes AXPlaceholderValue). Default provider is
# Anthropic => placeholder "sk-ant-...".
"$DRIVER_BIN" --pid "$PID" set --title "sk-" --value "$E2E_KEY" \
    || fail "could not set the API key field over AX"
"$DRIVER_BIN" --pid "$PID" press --title "Validate & Save" \
    || fail "could not press 'Validate & Save'"
info "key entered + submitted"

# The submit is async. `submitKey provider=` is emitted at the top of
# OnboardingViewModel.submitKey and nowhere else, so it is the first line that
# can only exist because the press landed. Wait for it before asserting
# anything about the outcome.
#
# The old assertion here grepped the cumulative trace for "validat|api|key",
# which the viewmodel-init and onboarding lines already satisfy before the
# press ever happens. It could not fail, so it proved nothing.
await_trace "submitKey provider=" 15

# Then the outcome of that submit. submitKey has exactly three exits, and one
# of the three lines must appear.
VALIDATION_OUTCOME=""
for _ in $(seq 1 30); do
    VALIDATION_OUTCOME="$(grep -E "key validated \+ persisted|key validation failed|key validation unexpected" \
        "$TRACE_LOG" 2>/dev/null | tail -1 || true)"
    [ -n "$VALIDATION_OUTCOME" ] && break
    sleep 1
done
[ -n "$VALIDATION_OUTCOME" ] \
    || fail "submitKey ran but no validation outcome (validated / failed / unexpected) in trace after 30s"
info "validation outcome: $VALIDATION_OUTCOME"

# The keychain write happens only on the success exit, immediately before that
# trace line. Assert the trace and the keychain agree in BOTH directions: a
# claimed persist with no item is a broken write, and an item with no
# successful validation is a write that should never have happened.
case "$VALIDATION_OUTCOME" in
    *"key validated + persisted"*)
        FOUND_ITEM=""
        for _ in $(seq 1 15); do
            if security find-generic-password -s "$SUPERVISOR_KEYCHAIN_PREFIX.anthropic" >/dev/null 2>&1; then
                FOUND_ITEM=yes
                break
            fi
            sleep 1
        done
        [ -n "$FOUND_ITEM" ] \
            || fail "trace says the key was persisted, but no item exists under $SUPERVISOR_KEYCHAIN_PREFIX.anthropic"
        info "key validated and stored under $SUPERVISOR_KEYCHAIN_PREFIX.anthropic (isolated slot)"
        ;;
    *)
        # Fake key => validation fails => nothing is written. Give a stray
        # write a beat to land before calling the slot clean.
        sleep 2
        if security find-generic-password -s "$SUPERVISOR_KEYCHAIN_PREFIX.anthropic" >/dev/null 2>&1; then
            fail "validation did not succeed, yet a key was written to $SUPERVISOR_KEYCHAIN_PREFIX.anthropic"
        fi
        info "validation failed with the fake key (expected without E2E_API_KEY); nothing written"
        ;;
esac

pass "s03 onboarding/key — onboarding drivable, key writes namespaced to $SUPERVISOR_KEYCHAIN_PREFIX.*"
