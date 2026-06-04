#!/bin/bash
# calibration-key.sh — resolve ANTHROPIC_API_KEY for live calibration sweeps.
#
# The calibration tests (RubricCalibrationTests.resolveKey) read the key ONLY
# from an environment variable. This script bridges the other places a key may
# live (macOS Keychain, a .env file, 1Password) into that env var, so a sweep
# can run without the owner pasting a secret into the shell each time.
#
# Usage:
#   source Scripts/calibration-key.sh   # exports ANTHROPIC_API_KEY if found
#   Scripts/calibration-key.sh          # just checks + reports availability
#
# Resolution order (first hit wins): env -> Keychain -> .env -> 1Password.
# The key VALUE is never printed. Returns/exits 0 if resolved, 1 if not.
#
# The 95% calibration gate (PRINCIPLES section 6c) is measured against
# Anthropic Haiku, so this resolves ANTHROPIC_API_KEY specifically. A
# DeepSeek/Moonshot key is a different model and does NOT verify that gate.

# Configurable sources (override via env before sourcing).
KEYCHAIN_SERVICE="${SUPERVISOR_ANTHROPIC_KEYCHAIN_SERVICE:-live.supervisor.api.anthropic}"
ENV_FILE="${SUPERVISOR_ENV_FILE:-.env}"
OP_REF="${SUPERVISOR_OP_ANTHROPIC_REF:-op://Private/Anthropic API/credential}"

# Detect whether we are being sourced (so we can `return` vs `exit`).
# Avoid `set -e`: it would alter or kill the caller's shell when sourced.
_calib_sourced=0
(return 0 2>/dev/null) && _calib_sourced=1

_calib_source=""

# 1. Environment — already provided.
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    _calib_source="environment"
fi

# 2. macOS Keychain. (Absent items fail fast without a prompt; only an
#    access-denied on an EXISTING item would prompt, which is the owner's
#    one-time allow.)
if [ -z "$_calib_source" ] && command -v security >/dev/null 2>&1; then
    _k="$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null)"
    if [ -n "$_k" ]; then
        export ANTHROPIC_API_KEY="$_k"
        _calib_source="macOS Keychain ($KEYCHAIN_SERVICE)"
    fi
    unset _k
fi

# 3. .env file (gitignored). Read only the ANTHROPIC_API_KEY line; strip an
#    optional surrounding quote. Never echo the value.
if [ -z "$_calib_source" ] && [ -f "$ENV_FILE" ]; then
    _v="$(grep -E '^[[:space:]]*(export[[:space:]]+)?ANTHROPIC_API_KEY=' "$ENV_FILE" 2>/dev/null \
          | tail -1 | sed -E 's/^[^=]*=//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//')"
    if [ -n "$_v" ]; then
        export ANTHROPIC_API_KEY="$_v"
        _calib_source=".env ($ENV_FILE)"
    fi
    unset _v
fi

# 4. 1Password CLI — only if installed AND already signed in (no interactive
#    prompt is forced here).
if [ -z "$_calib_source" ] && command -v op >/dev/null 2>&1 && op whoami >/dev/null 2>&1; then
    _v="$(op read "$OP_REF" 2>/dev/null)"
    if [ -n "$_v" ]; then
        export ANTHROPIC_API_KEY="$_v"
        _calib_source="1Password ($OP_REF)"
    fi
    unset _v
fi

# 5. Interactive fallback — ONLY on a real terminal. A non-TTY stdin
#    (autonomous loop, CI, piped) must NEVER hang waiting for input, so the
#    -t guards skip straight to the printed instructions below. The owner
#    enters their own key here; this script never supplies one itself.
if [ -z "$_calib_source" ] && [ -t 0 ] && [ -t 1 ]; then
    printf '[calib-key] paste ANTHROPIC_API_KEY (hidden), or press Enter to skip: ' >&2
    read -rs _v
    printf '\n' >&2
    if [ -n "$_v" ]; then
        export ANTHROPIC_API_KEY="$_v"
        _calib_source="manual entry (this shell only)"
    fi
    unset _v
fi

if [ -n "$_calib_source" ]; then
    echo "[calib-key] ANTHROPIC_API_KEY resolved from: $_calib_source"
    _calib_rc=0
else
    {
        echo "[calib-key] ANTHROPIC_API_KEY not found in any source"
        echo "            (env, Keychain '$KEYCHAIN_SERVICE', '$ENV_FILE', 1Password)."
        echo ""
        echo "Provide it by ANY one of these, then re-run the sweep:"
        echo "  1. Environment:"
        echo "       export ANTHROPIC_API_KEY=sk-ant-..."
        echo "  2. macOS Keychain (persists across shells):"
        echo "       security add-generic-password -s $KEYCHAIN_SERVICE -a \"\$USER\" -w"
        echo "  3. .env at repo root (gitignored):"
        echo "       echo 'ANTHROPIC_API_KEY=sk-ant-...' >> $ENV_FILE"
        echo "  4. 1Password CLI:"
        echo "       install 'op', sign in, and set"
        echo "       SUPERVISOR_OP_ANTHROPIC_REF=op://Vault/Item/field"
        echo ""
        echo "Note: a DeepSeek/Moonshot key is NOT a substitute. The section 6c"
        echo "gate is measured against Anthropic Haiku."
    } >&2
    _calib_rc=1
fi

unset _calib_source KEYCHAIN_SERVICE ENV_FILE OP_REF
if [ "$_calib_sourced" -eq 1 ]; then
    unset _calib_sourced
    return $_calib_rc
else
    exit $_calib_rc
fi
