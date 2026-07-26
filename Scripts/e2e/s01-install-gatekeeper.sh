#!/bin/bash
# s01-install-gatekeeper.sh — "the download opens" scenario.
#
# A true new user's very first hurdle is Gatekeeper: an unsigned or
# un-notarized Supervisor.app dies at double-click with "can't be opened".
# This scenario verifies the DISTRIBUTED artifact (an app bundle, usually
# extracted from the release dmg) passes the checks Gatekeeper applies,
# WITHOUT launching anything.
#
# Usage:
#   SUPERVISOR_E2E_APP_BUNDLE=/path/to/Supervisor.app ./s01-install-gatekeeper.sh
#   SUPERVISOR_E2E_REQUIRE_NOTARIZED=1  — also require spctl acceptance
#     (dev/adhoc builds legitimately fail spctl; release candidates must not).
#
# Pass criteria:
#   - codesign structural verification succeeds (--verify --deep --strict)
#   - the bundle declares the expected main executable (Supervisor)
#   - with REQUIRE_NOTARIZED=1: `spctl --assess --type exec` accepts it

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

APP_BUNDLE="${SUPERVISOR_E2E_APP_BUNDLE:-}"
[ -n "$APP_BUNDLE" ] || fail "set SUPERVISOR_E2E_APP_BUNDLE=/path/to/Supervisor.app (build one with Scripts/build-app.sh + Scripts/notarize.sh)"
[ -d "$APP_BUNDLE" ] || fail "no app bundle at $APP_BUNDLE"

info "verifying code signature on $APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE" \
    || fail "codesign verification failed — a new user's Gatekeeper will reject this bundle"

[ -x "$APP_BUNDLE/Contents/MacOS/Supervisor" ] \
    || fail "bundle has no Contents/MacOS/Supervisor executable"

if [ "${SUPERVISOR_E2E_REQUIRE_NOTARIZED:-0}" = "1" ]; then
    info "asserting Gatekeeper acceptance (spctl)"
    spctl --assess --type exec "$APP_BUNDLE" \
        || fail "spctl rejected the bundle — not notarized/stapled; a new user cannot open this"
else
    # Informational only: dev builds are expected to fail here.
    if spctl --assess --type exec "$APP_BUNDLE" 2>/dev/null; then
        info "spctl: accepted (notarized)"
    else
        info "spctl: rejected (expected for dev/adhoc builds; set SUPERVISOR_E2E_REQUIRE_NOTARIZED=1 for release gating)"
    fi
fi

pass "s01 install/gatekeeper — $APP_BUNDLE is openable by a new user"
