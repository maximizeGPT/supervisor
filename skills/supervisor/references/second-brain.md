# Second brain: curation rubric

You are the curating agent. scripts/second_brain.py did the deterministic
half: it discovered this project's transcripts, pulled user-authored messages,
redacted them, and emitted candidate entries. The judgment half is yours:
decide what deserves a permanent slot in the project's memory. The motivation
is Nadella's Reverse Information Paradox (July 2026): users pay for AI twice,
in money and in the proprietary knowledge they reveal in prompts and
corrections. Curation is where that second payment stops evaporating.

## The acceptance bar

An entry earns a slot when a fresh session, reading it at minute zero, would
act differently. Apply all four tests; a candidate that fails any of them is
noise:

1. Durable: still true in a month. Not "the build is broken right now".
2. Project-scoped: about this repo, its tools, its owner's ways of working.
   Not about one task ("rename that variable") or one conversation.
3. Costly to relearn: the user had to say it because the agent got it wrong
   or could not have known it. Things any agent infers from the repo in ten
   seconds do not need a slot.
4. Standalone: stated so a stranger could apply it, with the target named.
   Rewrite vague candidates into concrete ones; you may edit text freely,
   the merge keys on the normalized text you submit.

Fewer, better entries win. Ten sharp facts beat fifty mushy ones: every
entry is future context, and stale or vague entries teach future sessions
to ignore the memory. When in doubt, drop it; if it matters, the user will
say it again and the heuristics will re-surface it (that is what the
confirm/confidence loop is for).

## Kinds

- decision: a choice this project made among alternatives.
  "Use ruff for linting and formatting, not flake8 plus black."
  "Schema migrations go through alembic, never hand-edited SQL."
- correction: the user overrode something an agent did or assumed.
  "Don't touch the generated fixtures under tests/golden; regenerate them
  with make fixtures instead."
  "The API client retries internally; do not wrap calls in retry loops."
- environment_fact: something true about this machine, CI, or infra that
  cannot be read out of the repo.
  "CI runners have no network access during the test phase."
  "Local postgres runs on port 5433, not 5432."
- gotcha: a trap that cost time once and will again.
  "pytest -n auto deadlocks on the integration suite; run it serially."
  "The iOS build silently uses the cached provisioning profile; clean
  DerivedData after certificate changes."
- preference: how the user likes things, when it shapes future work.
  "Prefer small PRs, one concern each."
  "Never add comments that restate the code."

The extract heuristics only propose corrections, decisions, and preferences;
they have no reliable surface cue for environment_fact and gotcha. Add those
yourself from what you learned in your own session; give them provenance
(your session id) so the trail stays honest.

## Never store secrets, even redacted-adjacent

The scripts redact known credential shapes, and merge re-redacts on ingest,
but redaction is a backstop, not permission. If a candidate's value came from
sitting next to a credential ("the staging password is <redacted:env-secret>"),
drop the whole entry: the placeholder proves a secret existed, and the
surrounding shape (which service, which env var, which host) is itself
sensitive. Never reconstruct or paraphrase redacted material. Facts ABOUT
secret handling that contain no secret material are fine: "secrets load from
1Password CLI; nothing goes in .env" is a good environment_fact.

## Confidence

Leave new entries at "low" (the extract default). The loop earns confidence
mechanically: each iteration that re-observes an entry bumps it one step
(low, medium, high). Set "medium" at curation only when the user stated the
fact emphatically or more than once in this same batch. Never hand out
"high"; high is proof of survival, not enthusiasm.

## Running the loop

1. Extract candidates (from the skill's scripts directory):
   `python3 second_brain.py extract --project "$(pwd)" --since-hours 24`
2. Curate: keep, rewrite, re-kind, add your own entries. Build a JSON list
   of entries (kind, text, optional confidence and provenance).
3. Merge: `python3 second_brain.py merge --brain-dir "$(pwd)/.supervisor/second-brain"`
   with the curated JSON on stdin. Exact re-observations confirm (bumping
   confidence), near-duplicates merge, entries unconfirmed for 5 iterations
   retire, and memory.md is regenerated from brain.json. An empty list []
   is a valid iteration: it adds nothing but ages stale entries toward
   retirement, so run the loop even on quiet days.
4. Read the printed delta (added / confirmed / merged / retired /
   active_total) and report it to the user; that line is the measurement
   that the memory is improving, not just growing.

Edits belong in the loop, not in memory.md: the file is regenerated on every
merge and says so in its header. brain.json is the ledger of record.

## Promoting entries into CLAUDE.md

Some entries graduate from memory into standing instructions. Propose
promotion, never apply it: show the user the exact line to paste into
CLAUDE.md (or AGENTS.md or equivalent) and let them do it. Propose only when
all hold:

- confidence is high (the entry survived repeated confirmation),
- it has been active for at least 3 iterations without rewording,
- it changes agent behavior on most sessions, not just some task family,
- it is short enough to earn permanent context (one line, two at most).

After the user promotes an entry, keep it in the brain; the brain is the
provenance trail for where the instruction came from.

## Contract constants and twin divergences

The Mac app carries a Swift twin of this loop (the Second Brain built on its
Context Wiki subsystem; DESIGN.md §13). The two implementations share one
entry vocabulary (`decision`, `correction`, `environment_fact`, `gotcha`,
`preference` — these exact strings, in ids and JSON) and one set of contract
constants. This list is the authoritative home for the numbers; both
implementations cite it:

- text cap: 400 chars (redacted, whitespace-collapsed)
- retire after: 5 iterations without confirmation
- containment merge minimum: 12 normalized chars in the shorter text
- transcript tail window: 256 KB per file
- session cap: the 20 most recently modified transcripts
- confidence: low → medium → high, at most one step per entry per iteration

Three loop behaviors diverge between the twins, on purpose:

1. **Retirement evidence.** The skill retires on 5 unconfirmed iterations
   alone. The app additionally requires the source session's transcript to
   be gone — its confirmations are automated re-reads of old transcripts,
   so absence of confirmation is weaker evidence there.
2. **Revival.** The skill revives a retired entry when the curator
   re-submits it (a human/agent judgment). The app never resurrects retired
   entries — its re-distillation of the same transcripts that taught a
   retired belief must not undo a correction.
3. **Contradiction.** The app auto-retires an active belief that a new
   correction contradicts (containment match). The skill leaves
   contradiction handling to you, the curator: retire by omission and say
   so in the delta report.

If you change a constant or a divergence rationale, change it here first,
then in both implementations.
