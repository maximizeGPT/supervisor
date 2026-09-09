#!/bin/bash
# export-public.sh - build the public repo's release commit from a private
# release commit.
#
# Supervisor develops in a private repo (remote `origin`,
# maximizeGPT/supervisor-priv) and publishes to a public one (remote
# `public`, maximizeGPT/supervisor). The public branch is an unrelated
# history: one squashed commit per release, each one the private tree minus
# the internal material listed under EXCLUSIONS below.
#
# Through v0.4.0 that was a hand-typed chain of `git checkout <sha> -- .`,
# `rm -rf`, `find -delete` and a grep, retyped every release. Two things went
# wrong with it that this script exists to prevent:
#
#   - the v0.3.2 tag landed one commit SHORT of the export tip, so anyone
#     building from `git checkout v0.3.2` got the commit before the fix the
#     version promised. This script can only ever tag the commit it just
#     made, and it verifies the tag resolved there before it finishes.
#   - the 0.4.0 secret scan ran over `git diff --cached`, i.e. only the lines
#     that changed in that commit. The same regexes over the whole exported
#     tree find seven times as much. This script scans the whole tree.
#
# USAGE
#   Scripts/export-public.sh <release-commit> <version>            # dry run
#   Scripts/export-public.sh <release-commit> <version> --apply    # act
#
#   <release-commit>  the private commit to publish, usually the merge commit
#                     of the release PR (e.g. a248774 for v0.4.0)
#   <version>         the public tag to create (e.g. v0.4.0)
#
#   --apply           actually write to the export worktree, commit, and tag.
#                     Without it the script stages, excludes, scans, and
#                     reports, touching nothing outside a temp dir.
#   --retag           allow moving a public tag that already points somewhere
#                     else. Off by default, because silently moving a
#                     published tag is its own kind of release bug.
#   --message <text>  commit subject for the public commit.
#                     Default: "Supervisor <version>".
#
# WHAT THIS SCRIPT DOES NOT DO
#   It never pushes. The public repo is the thing users see, and a push is
#   not a step to automate away. It prints the exact push commands at the end
#   and stops.
#
# ENVIRONMENT
#   SUPERVISOR_PUBLIC_WORKTREE   export worktree (default below)
#   SUPERVISOR_PUBLIC_REMOTE     public remote name (default: public)

set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

# Defaulted off $HOME rather than a literal path: this file ships in the
# public repo, and a hardcoded /Users/<name>/ leaks the build machine's user.
PUBLIC_WT="${SUPERVISOR_PUBLIC_WORKTREE:-$HOME/supervisor-public-skill-wt}"
PUBLIC_REMOTE="${SUPERVISOR_PUBLIC_REMOTE:-public}"

# ---------------------------------------------------------------------------
# EXCLUSIONS - what never leaves the private repo.
#
# Globs, not the literal filenames the hand-run used: a second
# META-POSTMORTEM-v0.5.0-*.md or STATUS-*.md would otherwise ship silently,
# which is exactly how an internal doc gets published by accident.
# ---------------------------------------------------------------------------
EXCLUDE_DIRS=(
    site                # stale in-repo copy; the deployed site is its own checkout
    spikes              # throwaway feasibility probes
    trials              # autonomous-run scratch
    Tests/Calibration   # triage-calibration sweep output, not test code
)
EXCLUDE_GLOBS=(
    'AUTONOMOUS_SESSION_PROMPT.md'
    'DESIGN.md'                 # excluded pending a leak review; do not link it publicly
    'META-POSTMORTEM-*.md'
    'PRINCIPLES.md'
    'STATUS-*.md'
    'trial-notes.md'
    'SHIFT-LOG.md'
)
# Everything under docs/ goes except this one file, which the README links.
DOCS_KEEP='architecture.svg'

# ---------------------------------------------------------------------------
# SECRET SCAN
#
# Provider-shaped credentials, plus a literal --password on a command line
# (the notarytool app-specific password is the one that has actually been at
# risk here). Calibrated against the v0.4.0 tree: 42 raw hits, all of them
# obvious fixtures, zero survivors.
# ---------------------------------------------------------------------------
SECRET_RE='sk-ant-api03-[A-Za-z0-9_-]{20,}'
SECRET_RE="$SECRET_RE"'|sk-ant-[A-Za-z0-9_-]{24,}'
SECRET_RE="$SECRET_RE"'|sk-proj-[A-Za-z0-9_-]{20,}'
SECRET_RE="$SECRET_RE"'|sk_live_[A-Za-z0-9]{16,}'
SECRET_RE="$SECRET_RE"'|gh[pousr]_[A-Za-z0-9]{36}'
SECRET_RE="$SECRET_RE"'|github_pat_[A-Za-z0-9_]{20,}'
SECRET_RE="$SECRET_RE"'|AKIA[0-9A-Z]{16}'
SECRET_RE="$SECRET_RE"'|vcp_[A-Za-z0-9]{20,}'
SECRET_RE="$SECRET_RE"'|xox[baprs]-[A-Za-z0-9-]{12,}'
SECRET_RE="$SECRET_RE"'|AIza[0-9A-Za-z_-]{35}'
SECRET_RE="$SECRET_RE"'|-----BEGIN [A-Z ]*PRIVATE KEY-----'
SECRET_RE="$SECRET_RE"'|--password[ =]+[A-Za-z0-9][A-Za-z0-9_-]{7,}'

# A hit is tolerated when the matched LINE OR ITS PATH looks like a fixture.
# The path counts deliberately: RedactorTests.swift and CalibrationFixtures/
# exist to hold credential-shaped strings. Every tolerated hit is printed, so
# nothing is silently forgiven. Matched case-insensitively.
FIXTURE_RE='(.)\1{7,}'
FIXTURE_RE="$FIXTURE_RE"'|abcdefghijklmnopqrstuvwxyz0123456789|abcdefghij1234567890'
FIXTURE_RE="$FIXTURE_RE"'|akiaiosfodnn7example|wjalrxutnfemi'   # AWS's own published example pair
FIXTURE_RE="$FIXTURE_RE"'|example|placeholder|fake|dummy|redact|fixture|sample'
FIXTURE_RE="$FIXTURE_RE"'|selftest|self-test|self_test|realish|not-a-real|notreal'
FIXTURE_RE="$FIXTURE_RE"'|<your-|xxxx'

# ---------------------------------------------------------------------------

APPLY=0
RETAG=0
COMMIT=""
VERSION=""
MESSAGE=""

die() { echo "[export-public] $*" >&2; exit 1; }
say() { echo "[export-public] $*"; }

usage() {
    sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-2}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)   APPLY=1; shift ;;
        --retag)   RETAG=1; shift ;;
        --message) MESSAGE="${2:-}"; shift 2 ;;
        -h|--help) usage 0 ;;
        -*)        die "unknown flag: $1" ;;
        *)
            if [[ -z "$COMMIT" ]]; then COMMIT="$1"
            elif [[ -z "$VERSION" ]]; then VERSION="$1"
            else die "unexpected argument: $1"
            fi
            shift ;;
    esac
done

[[ -n "$COMMIT" && -n "$VERSION" ]] || usage 2
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "version must look like v1.2.3, got '$VERSION'"
MESSAGE="${MESSAGE:-Supervisor $VERSION}"

SHA="$(git rev-parse --verify "$COMMIT^{commit}" 2>/dev/null)" \
    || die "'$COMMIT' is not a commit in $REPO_ROOT"
SHORT="$(git rev-parse --short "$SHA")"

echo
say "release commit : $SHORT ($(git log -1 --format=%s "$SHA"))"
say "public version : $VERSION"
say "export worktree: $PUBLIC_WT"
say "public remote  : $PUBLIC_REMOTE"
say "mode           : $([[ "$APPLY" == "1" ]] && echo 'APPLY (will write + commit + tag locally)' || echo 'DRY RUN (writes nothing outside a temp dir)')"
echo

# --- 1. Stage the release tree in a temp dir --------------------------------
# Built from `git archive` rather than by checking out into the export
# worktree, so a dry run is genuinely side-effect free and the exclusions and
# the secret scan run against the exact bytes that would be published.
STAGE="$(mktemp -d)"
REMOVED="$(mktemp)"
cleanup() { rm -rf "$STAGE"; rm -f "$REMOVED"; }
trap cleanup EXIT
git archive "$SHA" | tar -x -C "$STAGE"

TOTAL_BEFORE="$(find "$STAGE" -type f | wc -l | tr -d ' ')"

# --- 2. Apply the exclusions, recording every path removed ------------------
: > "$REMOVED"

for d in "${EXCLUDE_DIRS[@]}"; do
    if [[ -e "$STAGE/$d" ]]; then
        (cd "$STAGE" && find "$d" -type f) >> "$REMOVED"
        rm -rf "${STAGE:?}/$d"
    fi
done

for g in "${EXCLUDE_GLOBS[@]}"; do
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        echo "${f#./}" >> "$REMOVED"
        rm -f "$STAGE/$f"
    done < <(cd "$STAGE" && find . -maxdepth 1 -type f -name "$g" 2>/dev/null)
done

if [[ -d "$STAGE/docs" ]]; then
    (cd "$STAGE" && find docs -type f -not -name "$DOCS_KEEP") >> "$REMOVED"
    find "$STAGE/docs" -type f -not -name "$DOCS_KEEP" -delete
    find "$STAGE/docs" -type d -empty -delete
fi

sort -o "$REMOVED" "$REMOVED"
TOTAL_AFTER="$(find "$STAGE" -type f | wc -l | tr -d ' ')"
REMOVED_N="$(grep -c . "$REMOVED" || true)"

say "excluded $REMOVED_N files ($TOTAL_BEFORE in the release tree, $TOTAL_AFTER exported):"
awk -F/ '{ if (NF>1) print "  " $1 "/"; else print "  " $0 }' "$REMOVED" \
    | sort | uniq -c | sort -rn | sed 's/^/  /'
echo
say "full excluded list (the audit trail for what did not ship):"
sed 's/^/    /' "$REMOVED"
echo

# A release that excludes nothing means the exclusion list stopped matching
# the tree, which is worth stopping for.
[[ "$REMOVED_N" -gt 0 ]] || die "excluded nothing - the exclusion list no longer matches this tree"

# --- 3. Secret scan over the WHOLE exported tree ----------------------------
say "secret scan over the exported tree"
RAW="$(cd "$STAGE" && grep -rInE "$SECRET_RE" . 2>/dev/null || true)"
RAW_N="$(printf '%s\n' "$RAW" | grep -c . || true)"
TOLERATED="$(printf '%s\n' "$RAW" | grep -iE "$FIXTURE_RE" || true)"
SURVIVORS="$(printf '%s\n' "$RAW" | grep -ivE "$FIXTURE_RE" || true)"
TOL_N="$(printf '%s\n' "$TOLERATED" | grep -c . || true)"
SUR_N="$(printf '%s\n' "$SURVIVORS" | grep -c . || true)"

say "  $RAW_N credential-shaped matches, $TOL_N tolerated as fixtures, $SUR_N unexplained"
if [[ "$TOL_N" -gt 0 ]]; then
    # Grouped by file, because a scan nobody reads is the same as no scan.
    # These are forgiven, not ignored: the file list is the thing to eyeball,
    # and any file on it that is not a test or a redaction fixture is a
    # problem regardless of what the heuristic decided.
    echo "  tolerated, by file:"
    printf '%s\n' "$TOLERATED" | grep . | cut -d: -f1 | sort | uniq -c \
        | sort -rn | awk '{printf "    %4d  %s\n", $1, $2}'
fi
if [[ "$SUR_N" -gt 0 ]]; then
    echo >&2
    echo "[export-public] SECRET SCAN FAILED: $SUR_N match(es) that do not look like fixtures:" >&2
    printf '%s\n' "$SURVIVORS" | grep . | cut -c1-160 | sed 's/^/    /' >&2
    echo >&2
    echo "    Remove the credential, or if it really is a fixture, make it look" >&2
    echo "    like one (repeated characters, the word 'example'/'fake', etc.)." >&2
    exit 1
fi

# Home-directory paths leak the build machine's username. They are not
# credentials and some are legitimately hardcoded (the dispatch-loop hook's
# example settings), so this warns instead of failing.
HOMEPATHS="$(cd "$STAGE" && grep -rInE '/Users/[a-z][a-z0-9_-]*/' . 2>/dev/null | grep -viE 'example|placeholder|fixture|/Users/(test|you|username)/' || true)"
HOME_N="$(printf '%s\n' "$HOMEPATHS" | grep -c . || true)"
if [[ "$HOME_N" -gt 0 ]]; then
    say "  WARNING: $HOME_N line(s) carry a real home path (leaks the build machine's"
    say "  username; not a credential, so this does not fail the export). By file:"
    HOME_FILES="$(printf '%s\n' "$HOMEPATHS" | grep . | cut -d: -f1 | sort | uniq -c | sort -rn)"
    printf '%s\n' "$HOME_FILES" | head -10 | awk '{printf "    %4d  %s\n", $1, $2}'
    HOME_FILE_N="$(printf '%s\n' "$HOME_FILES" | grep -c . || true)"
    [[ "$HOME_FILE_N" -gt 10 ]] && echo "    ... and $((HOME_FILE_N - 10)) more files"
fi
echo

# --- 4. Dry run stops here --------------------------------------------------
BRANCH="public/$VERSION-export"
if [[ "$APPLY" != "1" ]]; then
    say "DRY RUN complete. Nothing outside $STAGE was touched."
    say "It would have:"
    echo "    - reset $PUBLIC_WT to $PUBLIC_REMOTE/main on branch $BRANCH"
    echo "    - replaced its contents with the $TOTAL_AFTER files above"
    echo "    - committed them as: $MESSAGE"
    echo "    - tagged $VERSION at that new commit (the export tip), locally"
    echo
    say "Re-run with --apply to do it."
    exit 0
fi

# --- 5. Apply ---------------------------------------------------------------
[[ -d "$PUBLIC_WT/.git" || -f "$PUBLIC_WT/.git" ]] \
    || die "no git worktree at $PUBLIC_WT. Create it with:
    git worktree add $PUBLIC_WT $PUBLIC_REMOTE/main"

git -C "$PUBLIC_WT" remote get-url "$PUBLIC_REMOTE" >/dev/null 2>&1 \
    || die "no remote named '$PUBLIC_REMOTE' in $PUBLIC_WT"
REMOTE_URL="$(git -C "$PUBLIC_WT" remote get-url "$PUBLIC_REMOTE")"
case "$REMOTE_URL" in
    *maximizeGPT/supervisor.git|*maximizeGPT/supervisor) ;;
    *) die "remote '$PUBLIC_REMOTE' points at $REMOTE_URL, which is not the public repo" ;;
esac

# Never destroy work in progress in the export worktree.
if [[ -n "$(git -C "$PUBLIC_WT" status --porcelain)" ]]; then
    git -C "$PUBLIC_WT" status --short >&2
    die "$PUBLIC_WT has uncommitted changes. Deal with them first; this script wipes its contents."
fi

say "fetching $PUBLIC_REMOTE"
git -C "$PUBLIC_WT" fetch "$PUBLIC_REMOTE" --quiet --tags

say "resetting $PUBLIC_WT to $PUBLIC_REMOTE/main on $BRANCH"
git -C "$PUBLIC_WT" checkout -B "$BRANCH" "$PUBLIC_REMOTE/main" --quiet

say "replacing the worktree contents with the staged export"
(cd "$PUBLIC_WT" && find . -mindepth 1 -maxdepth 1 -not -name .git -exec rm -rf {} +)
rsync -a "$STAGE"/ "$PUBLIC_WT"/

git -C "$PUBLIC_WT" add -A
if git -C "$PUBLIC_WT" diff --cached --quiet; then
    die "the export is identical to $PUBLIC_REMOTE/main - nothing to release"
fi
git -C "$PUBLIC_WT" status --short | awk '{print $1}' | sort | uniq -c | sed 's/^/    /'

git -C "$PUBLIC_WT" commit --quiet -m "$MESSAGE"
EXPORT_TIP="$(git -C "$PUBLIC_WT" rev-parse HEAD)"
say "committed export tip $(git -C "$PUBLIC_WT" rev-parse --short HEAD)"

# --- 6. Tag, and only ever at the export tip --------------------------------
# There is deliberately no way to pass a tag target. The only commit this
# script will tag is the one it just created. v0.3.2 shipped with its tag one
# commit behind the export; that cannot happen through this path.
EXISTING="$(git -C "$PUBLIC_WT" rev-parse -q --verify "refs/tags/$VERSION^{commit}" 2>/dev/null || true)"
if [[ -n "$EXISTING" && "$EXISTING" != "$EXPORT_TIP" ]]; then
    if [[ "$RETAG" != "1" ]]; then
        die "tag $VERSION already exists at $(git -C "$PUBLIC_WT" rev-parse --short "$EXISTING"),
    which is not the export tip $(git -C "$PUBLIC_WT" rev-parse --short "$EXPORT_TIP").
    Re-run with --retag to move it, once you are sure that is what you want."
    fi
    say "moving existing tag $VERSION (--retag)"
fi
git -C "$PUBLIC_WT" tag -f "$VERSION" "$EXPORT_TIP" >/dev/null

TAGGED="$(git -C "$PUBLIC_WT" rev-parse "refs/tags/$VERSION^{commit}")"
[[ "$TAGGED" == "$EXPORT_TIP" ]] \
    || die "REFUSING to continue: $VERSION resolved to $TAGGED, not the export tip $EXPORT_TIP"
say "tag $VERSION verified at the export tip"

# --- 7. Hand the push back to a human ---------------------------------------
echo
say "done locally. Nothing has been pushed. To publish:"
echo "    git -C $PUBLIC_WT push $PUBLIC_REMOTE HEAD:main"
echo "    git -C $PUBLIC_WT push --force $PUBLIC_REMOTE $VERSION"
echo
say "then verify the tag landed where you think it did:"
echo "    git -C $PUBLIC_WT ls-remote --tags $PUBLIC_REMOTE $VERSION"
echo "    # must print $EXPORT_TIP"
