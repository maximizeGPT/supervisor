// EventBus.swift
//
// Combine-backed fan-out for SupervisorEvent. Subscribers (HoverViewModel,
// TriageEngine, future Escalation) receive every event published. v0.1.0
// has two live subscribers; the bus is sized for handfuls, not thousands.
//
// PassthroughSubject vs. CurrentValueSubject: events are time-ordered and
// each one is a moment of state change. A CurrentValueSubject would
// replay the last event to new subscribers, which is wrong for an event
// stream. Subscribers maintain their own buffers if they need history
// (TriageEngine does — its 5-turn window).

import Combine
import Foundation

public final class EventBus: Sendable {

    /// Process-wide default. Most call sites use this. Tests construct
    /// their own instance.
    public static let shared = EventBus()

    private let subject = PassthroughSubject<SupervisorEvent, Never>()
    private let trace: TraceLog

    public init(trace: TraceLog = .shared) {
        self.trace = trace
    }

    /// Subscribe. Caller retains the returned `AnyCancellable` for the
    /// lifetime of their interest in events.
    public func subscribe(_ handler: @escaping @Sendable (SupervisorEvent) -> Void) -> AnyCancellable {
        subject.sink { event in handler(event) }
    }

    /// Publish. Safe to call from any thread; subscribers receive on the
    /// dispatch they specify via `.receive(on:)`.
    public func publish(_ event: SupervisorEvent) {
        trace.emit("eventbus", "publish session=\(event.sessionId) type=\(eventLabel(event))")
        subject.send(event)
    }

    private func eventLabel(_ e: SupervisorEvent) -> String {
        switch e {
        case .sessionStart:   return "sessionStart"
        case .userPrompt:     return "userPrompt"
        case .assistantText:  return "assistantText"
        case .bashToolCall(let v):
            // Log the command head only — full command is in the JSONL.
            let head = v.command.prefix(60).replacingOccurrences(of: "\n", with: " ")
            return "bashToolCall(\(head))"
        case .bashToolResult(let v):
            return "bashToolResult(isError=\(v.isError), bytes=\(v.output.utf8.count))"
        case .fileEdit(let v):
            return "fileEdit(\(v.toolName) \(v.filePath) hunks=\(v.hunks.count))"
        case .systemSignal(let v):
            return "systemSignal(\(v.subtype), preventedContinuation=\(v.preventedContinuation))"
        }
    }
}
