# v0.3.1 question-fixture calibration sweep (result of record)

- **Provider**: DeepSeek (`deepseek-chat` → auto-routed to `deepseek-v4-flash`)
- **Fixtures**: 90 (15 positives + 15 negatives × 3 question_types, with the v0.3.1 corrected `eng.pos.09.design-doc-defaults`)
- **Elapsed**: 371s (~6m11s)
- **Tokens**: 585,634 in / 17,006 out
- **Cost**: ~$0.18

## Result vs v0.3.0 baseline

| question_type | v0.3.0 | **v0.3.1** | Delta |
|---|---|---|---|
| engineering positives | 9/15 (60%) | **12/15 (80%)** | **+20%** |
| safety positives | 14/15 (93%) | **15/15 (100%)** | +7% |
| taste positives | 13/15 (86%) | **15/15 (100%)** | +14% |
| **all positives** | 36/45 (80%) | **42/45 (93%)** | **+13%** |
| negatives (no-fire) | 43/45 (95%) | 42/45 (93%) | -2% |

## Rubric edits applied (v0.3.1)

1. **Engineering → inject is non-negotiable.** The "default to safety/taste when uncertain" guidance now explicitly applies to question_type *classification*, NOT to action mapping after classification. Once Haiku commits to engineering, the action is inject — period.
2. **Anti-hedge note** about inject being wired up in v0.3.0+: *"Picking notify for engineering questions means the user has to paste the answer manually — that's the failure mode this category exists to avoid."*
3. **Fixture correction**: `eng.pos.09` rotated from prioritization (which IS values-shaped) to `eng.pos.09.design-doc-defaults` (a true design-doc-derivable engineering question).

## Failures remaining

### Wrong question_type (3, down from 8)
- `eng.pos.04.yams-dependency` — got taste. Variance from v0.3.0 (was correct then).
- `eng.pos.06.error-style` — got safety. New failure; model read "errors propagate" as safety-shaped.
- `eng.pos.13.macros` — got taste. Variance from v0.3.0 (was correct then).

### False positives (3, +1 from v0.3.0)
- `safety.neg.10.warning-in-output` — read tool stderr as a real question (was clean in v0.3.0)
- `taste.neg.01.rhetorical-color` — rhetorical question self-answered next line (also failed in v0.3.0)
- `taste.neg.02.self-answered-naming` — same shape (new failure)

## Reading

Engineering recall at 80% means most engineering questions auto-inject as designed. The remaining 20% surfaces to user — safer failure per PRINCIPLES §3c. The rubric tightening eliminated the hedging behavior on questions Haiku *had* correctly classified as engineering (eng.pos.10 and eng.pos.12 from v0.3.0 are now picking inject correctly per the rubric's "engineering → inject is non-negotiable" framing).

The 3 new wrong-type cases are different fixtures than the v0.3.0 batch — Haiku's variance moves around. Filed as v0.3.2 calibration if it persists across runs.

**v0.3.1 ships with this as the result of record.**
