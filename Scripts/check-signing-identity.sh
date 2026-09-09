#!/bin/bash
# check-signing-identity.sh — will installing THIS build over the installed
# one keep its macOS permissions, or silently drop them?
#
# Why this exists (the 0.3.1 / 0.3.2 / 0.4.0 regression):
#
# TCC stores an Accessibility / Screen Recording grant against the bundle id
# AND the app's DESIGNATED REQUIREMENT — the codesign expression naming the
# certificate that signed it. Same bundle id, different certificate = a
# different program as far as macOS is concerned, and the grant does not
# carry. The user gets dropped back into onboarding with no explanation.
#
# Supervisor had two signing paths writing to the same /Applications bundle:
#
#   Scripts/build-app.sh  -> Scripts/sign-adhoc.sh -> "Supervisor Self-Signed"
#       designated => identifier "live.supervisor.app" and
#                     certificate leaf = H"33eff905...."
#
#   Scripts/make-dmg.sh / Scripts/notarize.sh    -> Developer ID
#       designated => identifier "live.supervisor.app" and anchor apple
#                     generic and ... certificate leaf[subject.OU] = Q7HKTCTZXQ
#
# make-dmg.sh RE-SIGNS build/Supervisor.app in place, so a deploy that follows
# a release ships Developer ID and the next ordinary dev deploy ships the
# self-signed build again. Every flip drops Accessibility. sign-adhoc.sh now
# prefers the Developer ID identity so both paths agree, and this script is
# the guard that keeps them agreeing.
#
# Usage:
#   Scripts/check-signing-identity.sh [new-bundle] [installed-bundle]
# Defaults: build/Supervisor.app and /Applications/Supervisor.app
#
# Exit codes:
#   0  identities match, or nothing is installed yet (no grant to lose)
#   3  identities DIFFER, or an ad-hoc build would replace an install
#   2  usage / unreadable bundle

set -uo pipefail
cd "$(dirname "$0")/.."

NEW="${1:-build/Supervisor.app}"
INSTALLED="${2:-/Applications/Supervisor.app}"

dr_of() {
    # `codesign -dr -` prints the designated requirement to stderr, prefixed
    # by an "Executable=" line. Keep only the requirement expression.
    codesign -dr - "$1" 2>&1 | sed -n 's/^designated => //p'
}

if [[ ! -d "$NEW" ]]; then
    echo "[check-signing] ERROR: $NEW not found. Run Scripts/build-app.sh first." >&2
    exit 2
fi

# An ad-hoc signature has no cert-based requirement at all: its DR is a bare
# cdhash, which codesign prints as a comment line, so `dr_of` comes back empty.
# That is the worst case for grant survival, because the cdhash changes on
# EVERY build. It is still only a problem when there is a grant to lose, so the
# verdict waits until after the first-install check below.
ADHOC=0
NEW_DR="$(dr_of "$NEW")"
if [[ -z "$NEW_DR" ]]; then
    ADHOC=1
    NEW_DR_SHOWN="$(codesign -dr - "$NEW" 2>&1 | sed -n 's/^# designated => //p')"
else
    NEW_DR_SHOWN="$NEW_DR"
fi

adhoc_explainer() {
    echo "                An ad-hoc designated requirement is a cdhash that" >&2
    echo "                changes on every build, so macOS treats each build as" >&2
    echo "                a different app and drops Accessibility every time." >&2
    echo "                Fix: Scripts/setup-signing-identity.sh (or install the" >&2
    echo "                Developer ID cert), then rebuild." >&2
}

echo "[check-signing] new build:       $NEW"
echo "[check-signing]   DR: ${NEW_DR_SHOWN:-<none>}"

if [[ ! -d "$INSTALLED" ]]; then
    echo "[check-signing] installed:       $INSTALLED (not present, first install)"
    if [[ "$ADHOC" -eq 1 ]]; then
        # Nothing is installed, so nothing can be dropped. Refusing here would
        # block a contributor's very first install over a grant that does not
        # exist yet. Say what the next build will cost them and pass.
        echo "[check-signing] OK: nothing to compare against. Note: this build is" >&2
        echo "                AD-HOC signed, so the FIRST install keeps nothing" >&2
        echo "                and every install after it drops the grants." >&2
        adhoc_explainer
        exit 0
    fi
    echo "[check-signing] OK: nothing to compare against."
    exit 0
fi

if [[ "$ADHOC" -eq 1 ]]; then
    echo "[check-signing] installed:       $INSTALLED"
    echo "[check-signing] FAIL: this build is AD-HOC signed and would replace an" >&2
    echo "                existing install, which drops its grants." >&2
    adhoc_explainer
    exit 3
fi

OLD_DR="$(dr_of "$INSTALLED")"
echo "[check-signing] installed:       $INSTALLED"
echo "[check-signing]   DR: ${OLD_DR:-<ad-hoc / none>}"

# Nested companion binaries get their own TCC identity when they run as their
# own processes, so report them too. Informational: they are not what the main
# app's Accessibility grant hangs off.
for f in "$NEW/Contents/MacOS/"*; do
    [[ -f "$f" ]] || continue
    id="$(codesign -d --verbose=2 "$f" 2>&1 | sed -n 's/^Identifier=//p')"
    echo "[check-signing]   nested $(basename "$f") -> Identifier=$id"
done

if [[ "$NEW_DR" == "$OLD_DR" ]]; then
    echo "[check-signing] OK: identical designated requirement. Accessibility and"
    echo "                Screen Recording grants carry across this install."
    exit 0
fi

echo "" >&2
echo "[check-signing] IDENTITY CHANGE DETECTED" >&2
echo "  installed: ${OLD_DR:-<ad-hoc / none>}" >&2
echo "  new build: $NEW_DR" >&2
echo "" >&2
echo "  macOS keys Accessibility and Screen Recording to the designated" >&2
echo "  requirement. These differ, so installing this build DROPS both grants" >&2
echo "  and sends the user back through onboarding." >&2
echo "" >&2
echo "  Usually this means the build was signed by the other path:" >&2
echo "    - Scripts/make-dmg.sh re-signs build/Supervisor.app with Developer ID." >&2
echo "      Rebuild (Scripts/build-app.sh) before deploying again." >&2
echo "    - Or the Developer ID cert is missing from this keychain, so" >&2
echo "      sign-adhoc.sh fell back to the self-signed identity." >&2
echo "      Check: security find-identity -v -p codesigning" >&2
echo "" >&2
echo "  To proceed anyway (and accept the re-grant):" >&2
echo "    SUPERVISOR_ALLOW_IDENTITY_CHANGE=1 Scripts/deploy.sh" >&2
exit 3
