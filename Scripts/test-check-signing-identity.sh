#!/bin/bash
# test-check-signing-identity.sh: exercise Scripts/check-signing-identity.sh
# against scratch bundles, so the guard that stands between a deploy and a lost
# Accessibility grant is itself checked.
#
# It never touches /Applications, never signs anything in build/, and never
# launches Supervisor. Every bundle it looks at lives in a mktemp directory it
# deletes on exit.
#
# Cases, and what each one is protecting:
#
#   1. no new bundle                 -> 2   usage error, not a false all-clear
#   2. ad-hoc build, nothing installed -> 0 a first install has no grant to
#                                          lose, so refusing it would block a
#                                          contributor for no reason
#   3. ad-hoc build over an install  -> 3   the cdhash changes every build, so
#                                          this one really does drop the grants
#   4. same identity both sides      -> 0   the ordinary deploy
#   5. different identity            -> 3   the 0.3.1 / 0.3.2 / 0.4.0 bug
#
# Cases 4 and 5 need a real codesigning identity in the keychain and are
# skipped when there is none. Signing with a real identity reads a private key,
# which can raise a keychain prompt, so an unattended caller (the Swift test in
# Tests/SupervisorCoreTests/DeployScriptOrderingTests.swift) sets
# CHECK_SIGNING_HARNESS_ADHOC_ONLY=1 and gets only the cases that touch nothing.
#
# Usage: Scripts/test-check-signing-identity.sh
# Exit 0 when every case that ran passed.

set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
CHECK="$REPO/Scripts/check-signing-identity.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-signing-harness.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
SKIP=0

make_bundle() {   # make_bundle <path> <bundle-id>
    local app="$1" bid="$2"
    mkdir -p "$app/Contents/MacOS"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Scratch</string>
<key>CFBundleIdentifier</key><string>$bid</string>
<key>CFBundleName</key><string>Scratch</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.0.0</string>
</dict></plist>
PLIST
    printf '#!/bin/bash\nexit 0\n' > "$app/Contents/MacOS/Scratch"
    chmod +x "$app/Contents/MacOS/Scratch"
}

sign() {          # sign <path> <identity>   ("-" is ad-hoc)
    codesign --force --deep --sign "$2" "$1" >/dev/null 2>&1
}

expect() {        # expect <case-name> <expected-exit> <args...>
    local name="$1" want="$2"; shift 2
    local out got
    out="$("$CHECK" "$@" 2>&1)"
    got=$?
    if [[ "$got" -eq "$want" ]]; then
        echo "  PASS  $name (exit $got)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $name: expected exit $want, got $got" >&2
        echo "$out" | sed 's/^/        | /' >&2
        FAIL=$((FAIL + 1))
    fi
}

echo "[harness] scratch dir: $WORK"

# --- 1. missing new bundle -------------------------------------------------
expect "missing new bundle is a usage error" 2 \
    "$WORK/nonexistent.app" "$WORK/also-nonexistent.app"

# --- 2. ad-hoc build, nothing installed ------------------------------------
# The reordering this case pins: the ad-hoc verdict must come AFTER the
# first-install check, or a contributor's first install is refused over a grant
# that does not exist yet.
make_bundle "$WORK/adhoc.app" "live.supervisor.scratch"
sign "$WORK/adhoc.app" "-"
expect "ad-hoc build with nothing installed is allowed" 0 \
    "$WORK/adhoc.app" "$WORK/nothing-here.app"

# --- 3. ad-hoc build over an existing install ------------------------------
make_bundle "$WORK/installed-adhoc.app" "live.supervisor.scratch"
sign "$WORK/installed-adhoc.app" "-"
expect "ad-hoc build over an install is refused" 3 \
    "$WORK/adhoc.app" "$WORK/installed-adhoc.app"

# --- 4 + 5. real identity cases --------------------------------------------
IDENTITY=""
if [[ "${CHECK_SIGNING_HARNESS_ADHOC_ONLY:-0}" != "1" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
    if [[ -z "$IDENTITY" ]]; then
        IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | sed -n 's/.*"\(Supervisor Self-Signed\)".*/\1/p' | head -1)"
    fi
fi

if [[ -z "$IDENTITY" ]]; then
    echo "  SKIP  same-identity and identity-change cases (no identity available, or ad-hoc-only mode)"
    SKIP=$((SKIP + 2))
else
    echo "[harness] using identity: $IDENTITY"
    make_bundle "$WORK/certA.app" "live.supervisor.scratch"
    sign "$WORK/certA.app" "$IDENTITY"
    make_bundle "$WORK/certB.app" "live.supervisor.scratch"
    sign "$WORK/certB.app" "$IDENTITY"

    expect "same identity on both sides carries the grants" 0 \
        "$WORK/certA.app" "$WORK/certB.app"

    expect "an identity change is refused" 3 \
        "$WORK/certA.app" "$WORK/installed-adhoc.app"
fi

echo ""
echo "[harness] $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
