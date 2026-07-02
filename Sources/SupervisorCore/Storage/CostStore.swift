// CostStore.swift
//
// Read-write surface for `daily_cost`. v0.1.0 enforcement is view-only —
// we increment per API call but don't cap. v0.1.2 adds a daily-cap check
// that degrades Supervisor to triage-only once spend approaches the cap.

import Foundation
import GRDB

public struct CostStore: Sendable {

    private let db: SupervisorDatabase

    public init(database: SupervisorDatabase) {
        self.db = database
    }

    /// Record a Haiku triage call's token usage against today.
    public func recordHaiku(inputTokens: Int, outputTokens: Int, costUSD: Double, on date: Date = Date()) throws {
        try add(date: date) { row in
            row.haikuInputTokens += inputTokens
            row.haikuOutputTokens += outputTokens
            row.estimatedCostUsd += costUSD
        }
    }

    /// Record a Sonnet escalation call's token usage. (v0.1.1+ uses this.)
    public func recordSonnet(inputTokens: Int, outputTokens: Int, costUSD: Double, on date: Date = Date()) throws {
        try add(date: date) { row in
            row.sonnetInputTokens += inputTokens
            row.sonnetOutputTokens += outputTokens
            row.estimatedCostUsd += costUSD
        }
    }

    /// Today's running total.
    public func today(on date: Date = Date()) throws -> StoredDailyCost {
        let key = Self.dateString(date)
        return try db.queue.read { conn in
            try StoredDailyCost.fetchOne(conn, key: key)
                ?? StoredDailyCost(date: key)
        }
    }

    /// Today's total estimated spend in USD. Cheap single-row read used
    /// by the daily-cap gate before every model call (v0.3.0).
    public func todayTotalUSD(on date: Date = Date()) throws -> Double {
        try today(on: date).estimatedCostUsd
    }

    /// 7-day rolling sum of estimated_cost_usd. Used by the Settings view.
    public func rollingSevenDayCostUSD(asOf date: Date = Date()) throws -> Double {
        let cal = Calendar(identifier: .iso8601)
        var sum = 0.0
        for offset in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: -offset, to: date) else { continue }
            let row = try today(on: day)
            sum += row.estimatedCostUsd
        }
        return sum
    }

    private func add(date: Date, mutate: (inout StoredDailyCost) -> Void) throws {
        let key = Self.dateString(date)
        try db.queue.write { conn in
            var row = try StoredDailyCost.fetchOne(conn, key: key) ?? StoredDailyCost(date: key)
            mutate(&row)
            try row.save(conn)
        }
    }

    static func dateString(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
