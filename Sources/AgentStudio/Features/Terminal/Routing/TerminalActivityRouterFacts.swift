import Foundation

package enum TerminalActivityRouterLifecycleKind: Equatable, Sendable {
    case start
    case stop
}

/// Correlates an exact runtime envelope or one existing lifecycle operation.
package enum TerminalActivityRouterFactScope: Hashable, Sendable {
    case runtimeEnvelope(paneID: UUID, eventID: UUID)
    case lifecycle(Int)
}

/// Synchronous owner acknowledgements; these are not runtime bus events.
package enum TerminalActivityRouterFact: Equatable, Sendable {
    /// The atom consume, ordered control and trace enqueue have returned.
    /// Trace flushing and derived bus delivery retain their own completion boundaries.
    case runtimeEnvelopeHandled
    /// The operation has been installed behind its predecessor, before it is awaited.
    case lifecycleEnqueued(TerminalActivityRouterLifecycleKind)
    /// The operation returned and current-tail cleanup has completed.
    case lifecycleCompleted
}

package typealias TerminalActivityRouterFactSink =
    @Sendable (TerminalActivityRouterFactScope, TerminalActivityRouterFact) -> Void
