import AgentStudioTestHarness
import Foundation
import Synchronization

@testable import AgentStudioCore

enum GitProjectorCompletionObservation: Equatable, Sendable {
    case snapshotPosted(UUID)
    case refreshClosed(UUID, UInt64)
}

final class GitProjectorCompletionWitness: Sendable {
    private let storage = Mutex<[GitProjectorCompletionObservation]>([])
    var values: [GitProjectorCompletionObservation] { storage.withLock { $0 } }
    func append(_ observation: GitProjectorCompletionObservation) { storage.withLock { $0.append(observation) } }
}

struct GitProjectorHeldSnapshotPoster: RuntimeEnvelopePosting {
    let bus: EventBus<RuntimeEnvelope>
    let step: HeldStep<RuntimeEnvelope>
    let witness: GitProjectorCompletionWitness

    func post(_ envelope: RuntimeEnvelope) async -> EventBus<RuntimeEnvelope>.PostResult {
        let snapshotWorktreeID: UUID?
        if case .worktree(let worktree) = envelope,
            case .gitWorkingDirectory(.snapshotChanged(let snapshot)) = worktree.event
        {
            snapshotWorktreeID = snapshot.worktreeId
            try? await step.arrive(envelope)
        } else {
            snapshotWorktreeID = nil
        }
        let result = await bus.post(envelope)
        if let snapshotWorktreeID { witness.append(.snapshotPosted(snapshotWorktreeID)) }
        return result
    }
}
