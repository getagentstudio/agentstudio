import AgentStudioCore
import Foundation

/// One incoming cache operation; lifetimes distinguish stale observations from replacements.
package struct WorkspaceCacheApplicationScope: Hashable, Sendable {
    package enum Kind: Hashable, Sendable {
        case repositoryIdentity
        case worktreeEnrichment
        case repositoryProjection
    }

    package let repositoryID: UUID
    package let worktreeID: UUID?
    package let observationLifetime: RepositoryFactObservationLifetime
    package let envelopeID: UUID
    package let envelopeSequence: UInt64
    package let kind: Kind

    package func hash(into hasher: inout Hasher) {
        hasher.combine(repositoryID)
        hasher.combine(worktreeID)
        hasher.combine(envelopeID)
        hasher.combine(envelopeSequence)
        hasher.combine(kind)
        // Equality includes the lifetime; unequal lifetimes may legally share this hash.
        // Its fields are internal to Core, so the coordinator does not widen that API.
    }
}

/// Observations of this coordinator's cache publication, never runtime bus events.
package enum WorkspaceCacheCoordinatorFact: Equatable, Sendable {
    case applied
    case superseded
    case ignored
}

/// Synchronous at the cache commit; an installed observer may capture that exact cache image.
package typealias WorkspaceCacheCoordinatorFactSink =
    @MainActor @Sendable (WorkspaceCacheApplicationScope, WorkspaceCacheCoordinatorFact) -> Void
