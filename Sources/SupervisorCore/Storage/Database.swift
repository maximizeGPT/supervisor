// Database.swift
//
// GRDB DatabaseQueue + migration registry. v0.1.0 ships migration v1 with
// three tables: sessions, flags, daily_cost. Later versions add false_
// positives, triage_runs, interventions via additional migrations.
//
// The connection is a serial DatabaseQueue (vs. a Pool). Supervisor's
// write volume is low (one flag every few minutes at most) and the
// simplicity gain over connection pooling is worth it.

import Foundation
import GRDB

public final class SupervisorDatabase: @unchecked Sendable {
    // GRDB's DatabaseQueue serializes all access internally — safe to share
    // across threads. @unchecked because GRDB hasn't yet annotated for
    // Sendable; revisit if/when they do.

    public let queue: DatabaseQueue

    /// Open or create the DB at `path`. The parent directory must exist —
    /// callers should use `ConfigPaths.ensureDirectoriesExist()` first.
    public init(path: URL) throws {
        var config = Configuration()
        config.label = "supervisor.sqlite"
        config.foreignKeysEnabled = true
        self.queue = try DatabaseQueue(path: path.path, configuration: config)
        try Self.migrator.migrate(self.queue)
    }

    /// In-memory DB for tests.
    public static func inMemory() throws -> SupervisorDatabase {
        let db = try SupervisorDatabase(memoryConfig: ())
        return db
    }

    private init(memoryConfig: Void) throws {
        var config = Configuration()
        config.label = "supervisor.sqlite.memory"
        config.foreignKeysEnabled = true
        self.queue = try DatabaseQueue(configuration: config)
        try Self.migrator.migrate(self.queue)
    }

    // MARK: - Migrations

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1_initial") { db in
            try db.create(table: "sessions") { t in
                t.column("id", .text).primaryKey()
                t.column("project_hash", .text).notNull()
                t.column("cwd", .text).notNull()
                t.column("started_at", .datetime).notNull()
                t.column("last_seen_at", .datetime).notNull()
                t.column("pid", .integer)
                t.column("jsonl_path", .text).notNull()
                t.column("jsonl_offset", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "flags") { t in
                t.column("id", .text).primaryKey()
                t.column("session_id", .text).notNull()
                    .references("sessions", onDelete: .cascade)
                t.column("ts", .datetime).notNull()
                t.column("category", .text).notNull()
                t.column("severity", .text).notNull()
                t.column("action", .text).notNull()
                t.column("reasoning", .text).notNull()
                t.column("evidence_uuids", .text).notNull().defaults(to: "[]")
                t.column("user_response", .text)
                t.column("haiku_input_tokens", .integer)
                t.column("haiku_output_tokens", .integer)
                t.column("sonnet_input_tokens", .integer)
                t.column("sonnet_output_tokens", .integer)
            }
            try db.create(
                index: "flags_by_session_ts",
                on: "flags",
                columns: ["session_id", "ts"]
            )

            try db.create(table: "daily_cost") { t in
                t.column("date", .text).primaryKey()                              // YYYY-MM-DD
                t.column("haiku_input_tokens", .integer).notNull().defaults(to: 0)
                t.column("haiku_output_tokens", .integer).notNull().defaults(to: 0)
                t.column("sonnet_input_tokens", .integer).notNull().defaults(to: 0)
                t.column("sonnet_output_tokens", .integer).notNull().defaults(to: 0)
                t.column("estimated_cost_usd", .double).notNull().defaults(to: 0)
            }
        }

        // v0.1.2: split the single `reasoning` column into two fields —
        // `reasoning_plain` for the notification banner and
        // `reasoning_technical` for the trace log + engineer debugging.
        // Also adds `asymmetry_note` for the optional cost-asymmetry
        // sentence. Old rows backfill reasoning_plain from the existing
        // reasoning text — dense but at least non-empty.
        //
        // macOS 13+ ships SQLite >= 3.39, so RENAME COLUMN (3.25+) is safe.
        m.registerMigration("v2_haiku_reasoning_split") { db in
            try db.alter(table: "flags") { t in
                t.rename(column: "reasoning", to: "reasoning_technical")
                t.add(column: "reasoning_plain", .text).notNull().defaults(to: "")
                t.add(column: "asymmetry_note", .text)
            }
            try db.execute(sql: """
                UPDATE flags
                SET reasoning_plain = reasoning_technical
                WHERE reasoning_plain = ''
                """)
        }

        // v0.4.0 Part C: continuous loop dispatch ledger. Every time the
        // Dispatcher returns a result (ready / lowConfidence / error),
        // the LoopController writes a row here. Used for: (a) the
        // 3-consecutive-low hard-stop check, (b) the
        // prior_dispatches_considered counter passed to the next
        // Dispatcher call, (c) post-mortem inspection of a loop run
        // ("what did the dispatcher decide and when").
        //
        // `task_proposal_head` stores the first ~200 chars of the
        // proposal so the trace is queryable without bloating the row
        // — the full text is on the corresponding StoredFlag if needed.
        // `response_shape` is one of ready | lowConfidence | error so
        // a SQL count(*) WHERE response_shape='lowConfidence' GROUPed
        // by recent rows answers "are we approaching the 3-consecutive-
        // low hard stop."
        m.registerMigration("v3_loop_dispatches") { db in
            try db.create(table: "loop_dispatches") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("session_id", .text).notNull()
                    .references("sessions", onDelete: .cascade)
                t.column("ts", .datetime).notNull()
                t.column("response_shape", .text).notNull()           // ready | lowConfidence | error
                t.column("confidence", .text)                         // high | medium | low (nil for non-ready)
                t.column("selected_path", .text)                      // continue_branch | transition_to_issue | low_confidence_no_action
                t.column("selected_issue_number", .integer)
                t.column("task_proposal_head", .text).notNull().defaults(to: "")
                t.column("justification", .text).notNull().defaults(to: "")
                t.column("prior_dispatches_considered", .integer).notNull().defaults(to: 0)
                t.column("haiku_input_tokens", .integer)
                t.column("haiku_output_tokens", .integer)
            }
            try db.create(
                index: "loop_dispatches_by_session_ts",
                on: "loop_dispatches",
                columns: ["session_id", "ts"]
            )
        }

        // v0.2.0 M2a: the Planner/Evaluator harness plan state. A `plan`
        // is a session's objective decomposed into an ordered list of
        // steps; the loop drives each step, the Evaluator grades it, and
        // the LoopController advances `current_step_index`. Two tables,
        // normalized with FK + cascade, matching the
        // sessions/flags/loop_dispatches pattern (not a single JSON blob):
        // per-step status/verdict/attempts updates map to row UPDATEs, and
        // a join key keeps the steps queryable.
        //
        // The Evaluator's last grade per step is a small owned value
        // (passed/score/feedback) read and written only as a whole, so it
        // is a JSON column (`last_verdict`) rather than its own table —
        // the same JSON-in-column choice the `flags.evidence_uuids` column
        // already makes for a small owned collection.
        //
        // M2a persists the model only; the Planner (M2b), Evaluator (M2c),
        // and loop lifecycle (M2d) are not wired into the live loop yet.
        m.registerMigration("v4_plans") { db in
            try db.create(table: "plans") { t in
                t.column("id", .text).primaryKey()
                t.column("session_id", .text).notNull()
                    .references("sessions", onDelete: .cascade)
                t.column("objective", .text).notNull()
                t.column("status", .text).notNull()              // draft | awaitingApproval | approved | running | completed | aborted
                t.column("current_step_index", .integer).notNull().defaults(to: 0)
                t.column("approved_at", .datetime)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(
                index: "plans_by_session_created",
                on: "plans",
                columns: ["session_id", "created_at"]
            )

            try db.create(table: "plan_steps") { t in
                t.column("id", .text).primaryKey()
                t.column("plan_id", .text).notNull()
                    .references("plans", onDelete: .cascade)
                t.column("idx", .integer).notNull()              // 0-based position in the plan
                t.column("title", .text).notNull()
                t.column("objective", .text).notNull()
                t.column("done_criteria", .text).notNull()
                t.column("status", .text).notNull()              // pending | active | passed | failed | retrying | skipped
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("last_verdict", .text)                  // JSON-encoded PlanStep.Verdict, nil if never graded
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(
                index: "plan_steps_by_plan_idx",
                on: "plan_steps",
                columns: ["plan_id", "idx"]
            )
        }

        // v0.2.0 observability (Reddit feedback A): the unified audit log -
        // the SKIMMABLE, per-action audit spine. Supervisor already writes a
        // raw, free-form trace (TraceLog) and structured ledgers (flags,
        // loop_dispatches, the InjectionLedger); this table is the
        // human-readable record of WHAT Supervisor did AND why, one row per
        // action, queryable per session. It does NOT replace any of those - it
        // sits alongside them and is written ADDITIVELY from the same hooks.
        //
        // One flexible table (not one per kind): `kind` discriminates the
        // action (autoAnswer / block / nudge / planStep / verdict) and `summary`
        // is the always-present one-line human-readable account. The remaining
        // columns are OPTIONAL structured fields a given kind fills in (an
        // auto-answer carries question + contextUsed + authorizingRule; a block
        // carries command + targetPath + riskReason; etc.). `detail` is a JSON
        // blob for anything a future kind needs without a migration - the same
        // JSON-in-column choice flags.evidence_uuids / plan_steps.last_verdict
        // already make. String-coded `kind` for forward compat (an unknown
        // string degrades, never crashes), matching FlagSeverity / FlagAction.
        m.registerMigration("v5_audit_entries") { db in
            try db.create(table: "audit_entries") { t in
                t.column("id", .text).primaryKey()
                t.column("session_id", .text).notNull()
                    .references("sessions", onDelete: .cascade)
                t.column("created_at", .datetime).notNull()
                t.column("kind", .text).notNull()           // autoAnswer | block | nudge | planStep | verdict
                t.column("summary", .text).notNull()        // one-line human-readable account
                // Optional structured fields (a given kind fills the relevant ones).
                t.column("question", .text)                 // autoAnswer: the question answered
                t.column("context_used", .text)             // autoAnswer: the source/context drawn on
                t.column("authorizing_rule", .text)         // autoAnswer: principle/rule that grounded it
                t.column("command", .text)                  // block: the command
                t.column("target_path", .text)              // block: the path/target it would touch
                t.column("risk_reason", .text)              // block: why it was caught ("receipt")
                t.column("classification", .text)           // nudge: the stall failure-mode (PART B)
                t.column("detail", .text)                   // JSON blob for anything extra
            }
            try db.create(
                index: "audit_entries_by_session_created",
                on: "audit_entries",
                columns: ["session_id", "created_at"]
            )
        }

        // v0.3.x REVIEW dimension: the code-review finding ledger. ReviewEngine
        // reviews the code a worker writes (Edit/Write/MultiEdit) and records a
        // row here per finding. The `fingerprint` column is UNIQUE so the same
        // issue on the same file dedups to one row — the noise guard that stops a
        // finding re-surfacing every turn the worker keeps touching that file.
        // `surfaced` records whether a finding cleared the confidence gate and was
        // shown to the owner (sub-bar findings persist with surfaced=0 so the gate
        // is tunable without data loss). Additive + opt-in: with the review-enabled
        // marker OFF (the default) nothing writes here, so the table stays empty
        // and no shipped behavior changes. Same sessions-FK + cascade shape as
        // flags / loop_dispatches / audit_entries.
        m.registerMigration("v6_review_findings") { db in
            try db.create(table: "review_findings") { t in
                t.column("id", .text).primaryKey()
                t.column("session_id", .text).notNull()
                    .references("sessions", onDelete: .cascade)
                t.column("created_at", .datetime).notNull()
                t.column("fingerprint", .text).notNull()
                t.column("file_path", .text).notNull()
                t.column("tool_name", .text).notNull()          // Edit | Write | MultiEdit
                t.column("turn_uuid", .text).notNull().defaults(to: "")
                t.column("category", .text).notNull()
                t.column("severity", .text).notNull()           // low | medium | high
                t.column("confidence", .text).notNull()         // low | medium | high
                t.column("title", .text).notNull()
                t.column("detail", .text).notNull().defaults(to: "")
                t.column("line_hint", .text)
                t.column("surfaced", .boolean).notNull().defaults(to: false)
            }
            // UNIQUE dedup key: one finding per (session, file, normalized title).
            try db.create(
                index: "review_findings_fingerprint",
                on: "review_findings",
                columns: ["fingerprint"],
                unique: true
            )
            try db.create(
                index: "review_findings_by_session_created",
                on: "review_findings",
                columns: ["session_id", "created_at"]
            )
        }

        // v0.3.x Context Wiki: one row per context-hygiene audit run. Unlike the
        // other tables this is NOT keyed to a `sessions` row — an audit targets a
        // PROJECT ROOT (any directory the user points Supervisor at), not a live
        // Claude Code session, so it has no session_id FK. The summary columns
        // (source_count / reclaimable_lines / top_severity …) make "how bloated is
        // this project, and is it getting better over time" a cheap SQL read; the
        // full report is kept verbatim in `report_json` so a past audit can be
        // re-rendered without re-scanning. Same JSON-in-a-column choice the
        // flags.evidence_uuids / plan_steps.last_verdict columns already make.
        //
        // Registered as v7 (after the review dimension's v6, which landed on the RC
        // first); the TABLE is still `context_audits`, so ContextAuditStore is
        // unchanged. Two features each added a "v6" migration on the same RC — GRDB
        // keys migrations by name in registration order, so both run, in sequence.
        m.registerMigration("v7_context_audits") { db in
            try db.create(table: "context_audits") { t in
                t.column("id", .text).primaryKey()
                t.column("root", .text).notNull()               // audited project root
                t.column("generated_at", .datetime).notNull()
                t.column("source_count", .integer).notNull().defaults(to: 0)
                t.column("text_lines", .integer).notNull().defaults(to: 0)
                t.column("duplicate_blocks", .integer).notNull().defaults(to: 0)
                t.column("reclaimable_lines", .integer).notNull().defaults(to: 0)
                t.column("recommendation_count", .integer).notNull().defaults(to: 0)
                t.column("top_severity", .text).notNull().defaults(to: "info")   // info|minor|notable|major
                t.column("used_llm", .boolean).notNull().defaults(to: false)
                t.column("report_json", .text).notNull().defaults(to: "{}")      // full AuditReport, re-renderable
            }
            try db.create(
                index: "context_audits_by_root_generated",
                on: "context_audits",
                columns: ["root", "generated_at"]
            )
        }

        // Launch-audit fix (2026-07): deterministic-catch dedupe ledger. A
        // SessionTail resumes from the last PERSISTED offset (30s cadence), so
        // an engine restart replays the tail of the transcript. Loop/idle STATE
        // mutations were already stale-gated (stale_event_state_skipped), but
        // the deterministic catch re-fired on the replayed tool_use and posted
        // a SECOND identical destructive-action banner for one command. One row
        // per catch, keyed by the event's tool_use id, written when the catch
        // fires — a replayed uuid is skipped, while a NEVER-seen event still
        // always fires regardless of age (an age gate would silently drop a
        // destructive command Supervisor was simply late to read). No sessions
        // FK on purpose: dedupe state must outlive session-row cascades, same
        // stand-alone choice as context_audits.
        m.registerMigration("v8_deterministic_catches") { db in
            try db.create(table: "deterministic_catches") { t in
                t.column("event_uuid", .text).primaryKey()
                t.column("session_id", .text).notNull()
                t.column("ts", .datetime).notNull()
            }
            try db.create(
                index: "deterministic_catches_by_ts",
                on: "deterministic_catches",
                columns: ["ts"]
            )
        }

        // v0.4.x Second Brain: one row per memory-optimization iteration. Like
        // context_audits this is keyed to a PROJECT ROOT, not a live session —
        // the brain outlives any one session, so there is no sessions FK (and
        // dedupe/retire state must survive session-row cascades). The delta
        // columns (added/confirmed/merged/retired/active) make "is the brain
        // growing or converging" a cheap SQL read; the full `MemoryLedger` is
        // kept verbatim in `ledger_json` — the loop's resume point — the same
        // JSON-in-a-column choice flags.evidence_uuids / plan_steps.last_verdict
        // / context_audits.report_json already make. Every string in the blob
        // was redacted BEFORE distillation, so no transcript secret can reach
        // this table.
        m.registerMigration("v9_second_brain_ledgers") { db in
            try db.create(table: "second_brain_ledgers") { t in
                t.column("id", .text).primaryKey()
                t.column("root", .text).notNull()               // project root the brain belongs to
                t.column("generated_at", .datetime).notNull()
                t.column("iteration", .integer).notNull().defaults(to: 0)
                t.column("added_count", .integer).notNull().defaults(to: 0)
                t.column("confirmed_count", .integer).notNull().defaults(to: 0)
                t.column("merged_count", .integer).notNull().defaults(to: 0)
                t.column("retired_count", .integer).notNull().defaults(to: 0)
                t.column("active_entries", .integer).notNull().defaults(to: 0)
                t.column("ledger_json", .text).notNull().defaults(to: "{}")      // full MemoryLedger, re-renderable
            }
            try db.create(
                index: "second_brain_ledgers_by_root_generated",
                on: "second_brain_ledgers",
                columns: ["root", "generated_at"]
            )
        }

        // issue #60 follow-up: persist the REAL intervention outcome per flag.
        // The executor's result (InterventionOutcome: injectSucceeded vs
        // injectDegraded, pauseSucceeded, continueFired, queued, ...) used to
        // flow Notifier -> HoverViewModel.recordInterventionOutcome into the
        // in-memory recentActions list and the TraceLog ONLY, so the trust
        // scorecard could not count what the interventions actually did. One
        // nullable TEXT column on `flags` (written by
        // FlagStore.markInterventionOutcome from the same result hook that
        // drives the banner + hover label) — not a new table, because the
        // outcome is 1:1 with the flag row the decision already persisted.
        // NULL means "no outcome recorded": every row predating this column,
        // and any flag whose decision never reached the router's result hook.
        m.registerMigration("v10_flag_intervention_outcome") { db in
            try db.alter(table: "flags") { t in
                t.add(column: "intervention_outcome", .text)
            }
        }

        return m
    }
}
