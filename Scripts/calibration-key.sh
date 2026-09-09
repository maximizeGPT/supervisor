#!/bin/bash
# calibration-key.sh — resolve a calibration provider key into the environment.
#
# The calibration tests (RubricCalibrationTests.resolveKey) read the key ONLY
# from an environment variable (ANTHROPIC_API_KEY preferred, then
# DEEPSEEK_API_KEY). This script bridges the other places a key may live
# (macOS Keychain, a .env file, 1Password) into that env var, so a sweep can
# run without the owner pasting a secret into the shell each time.
#
# Usage:
#   source Scripts/calibration-key.sh   # exports the resolved key if found
#   Scripts/calibration-key.sh          # just checks + reports availability
#
# PREFERENCE: Anthropic first when a key exists, then DeepSeek. Neither is a
# "proxy" for the other. PRINCIPLES section 6c measures the 95% gate against
# the provider that actually SHIPS to the user, and this owner has no
# Anthropic key, so DeepSeek deepseek-chat is his gate. The resolved provider
# is printed so the run self-documents which model it used, because a recall
# number means nothing without the model beside it. The key VALUE is never
# printed.
# Returns/exits 0 if resolved, 1 if not.

# Configurable sources (override via env before sourcing).
KEYCHAIN_SERVICE="${SUPERVISOR_ANTHROPIC_KEYCHAIN_SERVICE:-live.supervisor.api.anthropic}"
DEEPSEEK_KEYCHAIN_SERVICE="${SUPERVISOR_DEEPSEEK_KEYCHAIN_SERVICE:-live.supervisor.api.deepseek}"
ENV_FILE="${SUPERVISOR_ENV_FILE:-.env}"
OP_REF="${SUPERVISOR_OP_ANTHROPIC_REF:-op://Private/Anthropic API/credential}"

# Detect whether we are being sourced (so we can `return` vs `exit`).
# Avoid `set -e`: it would alter or kill the caller's shell when sourced.
_calib_sourced=0
(return 0 2>/dev/null) && _calib_sourced=1

_calib_source=""
_calib_provider="anthropic"

# ─── Anthropic (preferred when a key exists) ────────────────────────────────

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
#    -t guards skip straight to the DeepSeek fallback / instructions below.
#    The owner enters their own key here; this script never supplies one.
if [ -z "$_calib_source" ] && [ -t 0 ] && [ -t 1 ]; then
    printf '[calib-key] paste ANTHROPIC_API_KEY (hidden), or press Enter to fall back to DeepSeek: ' >&2
    read -rs _v
    printf '\n' >&2
    if [ -n "$_v" ]; then
        export ANTHROPIC_API_KEY="$_v"
        _calib_source="manual entry (this shell only)"
    fi
    unset _v
fi

# ─── DeepSeek (the shipped provider for an owner with no Anthropic key) ─────
# The runner's resolveKey already accepts DEEPSEEK_API_KEY; this makes the
# DeepSeek sweep reproducible (no per-run owner override). env -> Keychain.

if [ -z "$_calib_source" ] && [ -n "${DEEPSEEK_API_KEY:-}" ]; then
    _calib_source="environment"; _calib_provider="deepseek"
fi
if [ -z "$_calib_source" ] && command -v security >/dev/null 2>&1; then
    _k="$(security find-generic-password -s "$DEEPSEEK_KEYCHAIN_SERVICE" -w 2>/dev/null)"
    if [ -n "$_k" ]; then
        export DEEPSEEK_API_KEY="$_k"
        _calib_source="macOS Keychain ($DEEPSEEK_KEYCHAIN_SERVICE)"; _calib_provider="deepseek"
    fi
    unset _k
fi

# ─── Report ────────────────────────────────────────────────────────────────

if [ -n "$_calib_source" ]; then
    echo "[calib-key] provider=$_calib_provider key resolved from: $_calib_source"
    if [ "$_calib_provider" = "deepseek" ]; then
        echo "[calib-key] NOTE: this run measures DeepSeek. Per PRINCIPLES section 6c the"
        echo "            gate is measured against the provider that ships, so name the"
        echo "            provider and model beside any recall number from it."
    fi
    _calib_rc=0
else
    {
        echo "[calib-key] no calibration key found in any source"
        echo "            (Anthropic: env, Keychain '$KEYCHAIN_SERVICE', '$ENV_FILE', 1Password;"
        echo "             DeepSeek: env, Keychain '$DEEPSEEK_KEYCHAIN_SERVICE')."
        echo ""
        echo "Provide one, then re-run the sweep. For the GATE (preferred), Anthropic:"
        echo "  1. export ANTHROPIC_API_KEY=sk-ant-..."
        echo "  2. security add-generic-password -s $KEYCHAIN_SERVICE -a \"\$USER\" -w"
        echo "     (this is a calibration-only item: account \$USER, which the app never reads."
        echo "      To set the key the APP reads, use the app's onboarding, or"
        echo "      SUPERVISOR_PROVIDER_API_KEY=... swift run SupervisorDevTools \\"
        echo "        inject-provider-key-from-env anthropic."
        echo "      A raw 'security add-generic-password -a api-key' writes an item Supervisor"
        echo "      is not allowed to read, and the next launch stalls on a permission prompt.)"
        echo "  3. echo 'ANTHROPIC_API_KEY=sk-ant-...' >> $ENV_FILE   (gitignored)"
        echo "  4. 1Password: install 'op', sign in, set SUPERVISOR_OP_ANTHROPIC_REF=op://Vault/Item/field"
        echo ""
        echo "For a DeepSeek sweep (the shipped provider when no Anthropic key exists):"
        echo "  export DEEPSEEK_API_KEY=sk-...   OR"
        echo "  security add-generic-password -s $DEEPSEEK_KEYCHAIN_SERVICE -a \"\$USER\" -w"
        echo "  (calibration-only item, same caveat as above: to set the key the APP reads use"
        echo "   SupervisorDevTools inject-provider-key-from-env deepseek)"
    } >&2
    _calib_rc=1
fi

unset _calib_source _calib_provider KEYCHAIN_SERVICE DEEPSEEK_KEYCHAIN_SERVICE ENV_FILE OP_REF
if [ "$_calib_sourced" -eq 1 ]; then
    unset _calib_sourced
    return $_calib_rc
else
    exit $_calib_rc
fi
