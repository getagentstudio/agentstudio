import AgentStudioCLIStore
import Foundation

enum ClosedAppReadFailure: Equatable, Sendable {
    case store(CLIStoreFailure)
    case localDatabase
    case membership
    case cancelled
}

enum ClosedAppReadOutcome: Equatable, Sendable {
    case complete(throughId: Int64)
    case verifiedEmpty
    case historyLost(thenComplete: Int64?)
    case unreadable(ClosedAppReadFailure)
    case incomplete(heldAtId: Int64?)
}
