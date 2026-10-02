import Foundation

package enum TerminalActivityDeadlineKind: Hashable, Sendable {
    case unseen
    case agentSettled
}

/// One window evaluation, independent of an injected clock's sleep numbering.
package struct TerminalActivityDeadlineScope: Hashable, Sendable {
    package let paneID: UUID
    package let windowID: UUID
    package let kind: TerminalActivityDeadlineKind
    package let generation: UInt64
}

package enum TerminalActivityDeadlineDisposition: Equatable, Sendable {
    case fired
    case cancelled
    case superseded
}

/// Synchronous observations of this actor's deadlines, never runtime bus events.
/// Absolute deadlines are offsets from the clock origin captured at initialization.
package enum TerminalActivityProjectorFact: Equatable, Sendable {
    case deadlineRegistered(TerminalActivityDeadlineKind, deadline: Duration)
    case deadlineDisposition(TerminalActivityDeadlineKind, TerminalActivityDeadlineDisposition)
}

package typealias TerminalActivityProjectorFactSink =
    @Sendable (TerminalActivityDeadlineScope, TerminalActivityProjectorFact) -> Void
