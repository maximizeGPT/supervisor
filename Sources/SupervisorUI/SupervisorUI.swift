// SupervisorUI — SwiftUI/AppKit presentation layer.
//
// All views live under this target. Core never imports SupervisorUI; UI
// depends on Core. Most of the file population lands in Phase B.3 and
// Phase C.
//
// Build-graph guard: this target deliberately does not depend on the
// AnthropicClient module (it's nested inside SupervisorCore, but the
// only callers from the UI side are the view models which receive a
// pre-configured client by injection).

import Foundation
import SupervisorCore

/// Re-export of the trace-log shared instance for UI call sites.
/// Avoids spreading `import SupervisorCore` across every SwiftUI file.
public let UITraceLog = TraceLog.shared
