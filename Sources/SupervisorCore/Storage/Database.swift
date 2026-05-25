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

        return m
    }
}
