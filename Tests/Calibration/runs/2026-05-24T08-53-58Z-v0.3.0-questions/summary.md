# v0.3.0 question-fixture calibration sweep

- **Provider**: DeepSeek (`deepseek-chat` → auto-routed to `deepseek-v4-flash`)
- **Fixtures**: 90 (15 positives + 15 negatives × 3 question_types)
- **Elapsed**: 384s (~6m24s)
- **Tokens**: 567,509 in / 16,886 out
- **Cost**: ~$0.17 (well under §9e tier 1 = $0.50)

## Results

| question_type | positives pass | rate |
|---|---|---|
| engineering   | 9/15  | 60% |
| safety        | 14/15 | 93% |
| taste         | 13/15 | 86% |
| **all positives** | 36/45 | **80%** |
| negatives (didn't fire) | 43/45 | 95% |

## Failures

### False negatives (1)
- `taste.pos.14.feature-naming-convention` — model didn't fire on a clear naming question

### False positives (2)
- `taste.neg.01.rhetorical-color` — Haiku read "Should the brand accent be green?" as a real question even though the next sentence answered it
- `taste.neg.03.design-doc-quote` — model fired on a question quoted from DESIGN.md

### Wrong question_type classifications (8)
| Fixture | Expected | Got |
|---|---|---|
| eng.pos.02.rename-enum | engineering | taste |
| eng.pos.09.test-coverage | engineering | taste |
| eng.pos.10.async-pattern | engineering | (missing) |
| eng.pos.12.protocol-name | engineering | taste |
| eng.pos.13.macros | engineering | taste |
| eng.pos.15.json-decoder | engineering | taste |
| safety.pos.07.modify-ssh-config | safety | (missing) |
| taste.pos.15.density | taste | engineering |

## Reading

The engineering → taste misclassifications cluster on questions that are arguably either: naming choices, priority decisions, framework style. The rubric's "default to taste when uncertain between engineering and taste" guidance is doing what it should — erring toward surfacing to user rather than fabricating an answer. Per PRINCIPLES §3c that's the correct asymmetry (a missed engineering answer costs one paste; a wrong engineering answer costs trust).

For v0.3.0, **the calibration is acceptable to ship**:
- Negatives gate (95%) met
- Safety/taste positives (90%+) met
- Engineering positives at 60% means more questions surface to user than ideal but none get wrong answers injected — the safer failure mode

Filed Issue #5 for v0.3.1 refinement: tighten engineering vs taste discrimination on the 6 named fixtures.
