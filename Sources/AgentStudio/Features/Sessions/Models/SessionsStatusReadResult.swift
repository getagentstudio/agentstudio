import AgentStudioCore

/// Health and summary share the ingestion actor's one current-generation read.
package enum SessionsStatusReadResult: Sendable, Equatable {
    case unbound
    case live(SessionSummary)
    case ended(SessionSummary)
}
