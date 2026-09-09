#!/bin/bash
# make-dmg.sh - Developer ID sign + package + notarize + staple a distributable
# .dmg (the public artifact format).
#
# Run AFTER `Scripts/build-app.sh release`. Produces a notarized, stapled
# dist/Supervisor.dmg that mounts and opens with NO Gatekeeper warning - a plain
# double-click, then drag Supervisor.app onto the bundled Applications symlink to
# install. This is the public distribution path for Supervisor - the Mac App
# Store is not an option (Supervisor needs to watch/inject/signal OTHER
# processes, which the App Sandbox forbids; default-entitlements.plist sets
# app-sandbox=false).
#
# For a fully clean Gatekeeper pass, BOTH the .app AND the .dmg must be Developer
# ID-signed + notarized + stapled. This script signs the app inside-out (same
# conventions as Scripts/notarize.sh), builds the .dmg, signs the .dmg, then
# notarizes + staples the .dmg. Re-signing the app here is idempotent, so this
# script is self-contained whether or not notarize.sh ran first.
#
# Re-run this for every release: notarization covers a specific build, so a new
# .app/.dmg needs a new notarization.
#
# DRY MODE - validate mechanics without uploading to Apple:
#   bash Scripts/make-dmg.sh --no-notarize
#   SUPERVISOR_SKIP_NOTARIZE=1 bash Scripts/make-dmg.sh
# Either form runs steps 1-5 + 7 (sign app + stage + build + sign dmg + local
# Gatekeeper check) but SKIPS step 6 (notarytool submit + staple). The default
# (no flag) runs the full notarized flow.
#
# One-time prerequisites on the build machine (same as notarize.sh):
#   1. The "Developer ID Application: Mohammed Wasif (Q7HKTCTZXQ)" cert in the
#      login keychain (signing).
#   2. A notarytool credential profile named below, holding the Apple ID +
#      app-specific password + team id (the password lives in the Keychain, not
#      here):
#        xcrun notarytool store-credentials supervisor-notary \
#          --apple-id <your-apple-id> --team-id Q7HKTCTZXQ \
#          --password <app-specific-password>
#      (app-specific password: appleid.apple.com -> Sign-In and Security.)
#
#      Check the profile actually resolves, any time:
#        xcrun notarytool history --keychain-profile supervisor-notary
#      This script runs that check before it signs anything and stops if it
#      fails. A missing profile used to be survivable: during the 0.4.0
#      release notarytool exited with "No Keychain password item found for
#      profile: supervisor-notary", the script carried on, and it reported
#      success over an UNSTAPLED dmg.
#
#   3. Fallback when the stored profile is unavailable - pass the same
#      credentials inline instead of naming a profile. This is what unblocked
#      the 0.4.0 release:
#        SUPERVISOR_NOTARY_ARGS="--apple-id <your-apple-id> --team-id Q7HKTCTZXQ --password <app-specific-password>" \
#          bash Scripts/make-dmg.sh
#      The value replaces `--keychain-profile <profile>` on every notarytool
#      call. It is an app-specific password, never the Apple ID password, and
#      it lands in the shell history of whoever runs it, so prefer the stored
#      profile and re-create it with store-credentials when you can.

set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SUPERVISOR_SIGN_IDENTITY:-Developer ID Application: Mohammed Wasif (Q7HKTCTZXQ)}"
PROFILE="${SUPERVISOR_NOTARY_PROFILE:-supervisor-notary}"
ENT="Scripts/default-entitlements.plist"
APP="build/Supervisor.app"
DMG="dist/Supervisor.dmg"
VOLNAME="Supervisor"

# Parse args / env for the dry (no-notarize) mode.
SKIP_NOTARIZE="${SUPERVISOR_SKIP_NOTARIZE:-0}"
for arg in "$@"; do
  case "$arg" in
    --no-notarize) SKIP_NOTARIZE=1 ;;
    *) echo "[make-dmg] unknown argument: $arg" >&2; exit 2 ;;
  esac
done

[[ -d "$APP" ]] || { echo "[make-dmg] $APP missing - run Scripts/build-app.sh release first" >&2; exit 1; }

# How notarytool is told who we are: the stored keychain profile by default,
# or inline credentials when SUPERVISOR_NOTARY_ARGS is set. Kept in an array
# so a password with spaces survives, and never echoed - only the human-safe
# description below is printed.
NOTARY_ARGS=()
if [[ -n "${SUPERVISOR_NOTARY_ARGS:-}" ]]; then
  # Deliberately unquoted: the variable carries several arguments.
  # shellcheck disable=SC2206
  NOTARY_ARGS=($SUPERVISOR_NOTARY_ARGS)
  NOTARY_CRED_DESC="inline credentials from \$SUPERVISOR_NOTARY_ARGS"
else
  NOTARY_ARGS=(--keychain-profile "$PROFILE")
  NOTARY_CRED_DESC="keychain profile '$PROFILE'"
fi

# --- 0. Preflight: do the notary credentials actually resolve? ---------------
# Before signing, staging, and building a dmg, prove the credential works.
# `notarytool history` is the cheapest call that authenticates. Doing this up
# front turns the 0.4.0 failure into a five-second stop with the fix printed,
# instead of a ten-minute build that ends in a green line over a dmg no user
# can open.
if [[ "$SKIP_NOTARIZE" != "1" ]]; then
  echo "[make-dmg] preflight: checking notary credentials ($NOTARY_CRED_DESC)"
  if ! HISTORY_ERR="$(xcrun notarytool history "${NOTARY_ARGS[@]}" 2>&1 >/dev/null)"; then
    echo "[make-dmg] NOTARY CREDENTIALS UNUSABLE. notarytool said:" >&2
    echo "$HISTORY_ERR" | sed 's/^/    /' >&2
    echo >&2
    echo "    Re-create the stored profile:" >&2
    echo "      xcrun notarytool store-credentials $PROFILE \\" >&2
    echo "        --apple-id <your-apple-id> --team-id Q7HKTCTZXQ \\" >&2
    echo "        --password <app-specific-password>" >&2
    echo >&2
    echo "    Or pass the credentials inline for this run:" >&2
    echo "      SUPERVISOR_NOTARY_ARGS=\"--apple-id <your-apple-id> --team-id Q7HKTCTZXQ --password <app-specific-password>\" \\" >&2
    echo "        bash Scripts/make-dmg.sh" >&2
    echo >&2
    echo "    Or build a signed-but-unnotarized dmg for local testing:" >&2
    echo "      bash Scripts/make-dmg.sh --no-notarize" >&2
    exit 1
  fi
  echo "[make-dmg] preflight ok - the notary credentials authenticate"
fi

# --- 1+2. Sign the app inside-out (idempotent if notarize.sh already ran) ----
# The embedded companion binaries first, then the bundle. BOTH nested Mach-Os
# must be Developer-ID signed — build-app.sh embeds SupervisorHeartbeat AND
# SupervisorStatusBar (re-externalized this RC) in Contents/MacOS, and an
# ad-hoc-signed nested binary fails notarization. Hardened runtime
# (--options runtime) + a secure timestamp are both required for notarization.
echo "[make-dmg] signing nested SupervisorHeartbeat"
codesign --force --options runtime --timestamp --entitlements "$ENT" \
  --sign "$IDENTITY" "$APP/Contents/MacOS/SupervisorHeartbeat"
echo "[make-dmg] signing nested SupervisorStatusBar"
codesign --force --options runtime --timestamp --entitlements "$ENT" \
  --sign "$IDENTITY" "$APP/Contents/MacOS/SupervisorStatusBar"
echo "[make-dmg] signing Supervisor.app"
codesign --force --options runtime --timestamp --entitlements "$ENT" \
  --sign "$IDENTITY" "$APP"

echo "[make-dmg] verifying app signature"
codesign --verify --deep --strict --verbose=2 "$APP"

# --- 3. Stage a dmg source dir: the app + a drag-to-install Applications link -
echo "[make-dmg] staging dmg source"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# --- 4. Create the compressed dmg --------------------------------------------
echo "[make-dmg] creating $DMG"
mkdir -p dist
rm -f "$DMG"
hdiutil create -fs HFS+ -format UDZO -volname "$VOLNAME" \
  -srcfolder "$STAGE" -ov "$DMG"

# Staging dir is no longer needed once the dmg image exists.
rm -rf "$STAGE"

# --- 5. Sign the dmg itself --------------------------------------------------
echo "[make-dmg] signing $DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

# --- 6. Notarize + staple the dmg (skipped in dry mode) ----------------------
if [[ "$SKIP_NOTARIZE" == "1" ]]; then
  echo "[make-dmg] SUPERVISOR_SKIP_NOTARIZE / --no-notarize set - skipping notarytool submit + staple"
else
  echo "[make-dmg] submitting $DMG to Apple notary (this takes a few minutes)"
  SUBMIT_LOG="$(mktemp)"
  set +e
  xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait 2>&1 | tee "$SUBMIT_LOG"
  SUBMIT_RC=${PIPESTATUS[0]}
  set -e

  # Two independent things have to be true, and the old script checked
  # neither: notarytool has to have exited cleanly, AND the verdict it
  # printed has to be "Accepted". A submission can come back Invalid or
  # Rejected, which is a completed run with a refused artifact.
  # `^ *status:` matches the final "Processing complete" block and not the
  # "Current status: In Progress...." progress lines. No match at all leaves
  # the variable empty, which fails here - the check is fail-closed.
  SUBMIT_ID="$(sed -n 's/^ *id: *//p' "$SUBMIT_LOG" | head -1)"
  FINAL_STATUS="$(sed -n 's/^ *status: *//p' "$SUBMIT_LOG" | tail -1 | tr -d '\r' | sed 's/[[:space:]]*$//')"
  rm -f "$SUBMIT_LOG"
  if [[ "$SUBMIT_RC" != "0" || "$FINAL_STATUS" != "Accepted" ]]; then
    echo >&2
    echo "[make-dmg] NOTARIZATION FAILED (notarytool exit=$SUBMIT_RC, status='${FINAL_STATUS:-none reported}')." >&2
    echo "    $DMG is signed but NOT notarized. Do not ship it." >&2
    if [[ -n "$SUBMIT_ID" ]]; then
      echo "    Read Apple's reasons:" >&2
      echo "      xcrun notarytool log $SUBMIT_ID --keychain-profile \"$PROFILE\"" >&2
    fi
    exit 1
  fi
  echo "[make-dmg] notary verdict: $FINAL_STATUS (submission $SUBMIT_ID)"

  echo "[make-dmg] stapling the ticket to $DMG"
  xcrun stapler staple "$DMG"
fi

# --- 7. Verify the artifact really is notarized + stapled --------------------
# Two checks, because they answer different questions and 0.4.0 shipped with
# neither enforced. `stapler validate` asks whether a notarization ticket is
# actually attached to this file, which is what makes it work on a machine
# with no network. `spctl` asks whether Gatekeeper would let a user open it.
# A dmg can pass one and fail the other, so a real release requires both.
# Both exit non-zero in dry mode, where the dmg is signed and nothing else,
# so there they are reported and tolerated.
GATE_FAILED=0

echo "[make-dmg] stapler validate:"
STAPLE_OUT="$(xcrun stapler validate "$DMG" 2>&1)" && STAPLE_RC=0 || STAPLE_RC=$?
echo "$STAPLE_OUT" | sed 's/^/    /'
[[ "$STAPLE_RC" == "0" ]] || GATE_FAILED=1

echo "[make-dmg] Gatekeeper verdict (dmg):"
SPCTL_OUT="$(spctl -a -t open --context context:primary-signature -vvv "$DMG" 2>&1)" && SPCTL_RC=0 || SPCTL_RC=$?
echo "$SPCTL_OUT" | sed 's/^/    /'
[[ "$SPCTL_RC" == "0" ]] || GATE_FAILED=1

if [[ "$SKIP_NOTARIZE" == "1" ]]; then
  if [[ "$GATE_FAILED" == "1" ]]; then
    echo "    (stapler exit $STAPLE_RC, spctl exit $SPCTL_RC - expected in dry mode;"
    echo "     the dmg is signed but not notarized or stapled)"
  fi
elif [[ "$GATE_FAILED" == "1" ]]; then
  echo >&2
  echo "[make-dmg] VERIFICATION FAILED (stapler exit=$STAPLE_RC, spctl exit=$SPCTL_RC)." >&2
  echo "    Apple accepted the submission, but $DMG does not verify as notarized" >&2
  echo "    and stapled on this machine. Do not ship it." >&2
  exit 1
fi

# --- Done --------------------------------------------------------------------
DMG_SIZE="$(du -h "$DMG" | cut -f1)"
echo
if [[ "$SKIP_NOTARIZE" == "1" ]]; then
  echo "[make-dmg] ✓ dry build done - $DMG ($DMG_SIZE) is signed but NOT notarized."
  echo "    Re-run without --no-notarize (with the Developer ID + notary profile)"
  echo "    to produce the public, warning-free artifact."
else
  echo "[make-dmg] ✓ done - $DMG ($DMG_SIZE) is notarized + stapled (opens with no warning)."
fi
echo "    Install: open $DMG, then drag Supervisor.app onto Applications."
