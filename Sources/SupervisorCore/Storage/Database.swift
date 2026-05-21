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

public final class SupervisorDatabase {

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

        return m
    }
}
