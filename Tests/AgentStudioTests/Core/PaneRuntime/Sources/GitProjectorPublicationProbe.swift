import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization

@testable import AgentStudioCore

// The real output seam records attempts synchronously, before any bus collector hop.
// The projector's joined shutdown closes the lifetime; tests join released drain
// handles before shutdown so cancellation cannot conceal the operation under test.
enum GitProjectorPublicationFact: Sendable {
    case output(GitWorkingDirectoryEvent)
    case shutdownCompleted
}

final class GitProjectorPublicationProbe: RuntimeEnvelopePosting {
    private let bus: EventBus<RuntimeEnvelope>
    private let isObserving = Mutex(false)
    private let publicationFactSource: LocalFactSource<GitProjectorScope, GitProjectorPublicationFact>
    let facts: FactRecorder<GitProjectorScope, GitProjectorPublicationFact>

    init(bus: EventBus<RuntimeEnvelope>) throws {
        let publicationFactSource = LocalFactSource(
            vocabulary: FactVocabulary<GitProjectorScope, GitProjectorPublicationFact>(
                describeScope: { String(describing: $0) },
                describeFact: { String(describing: $0) },
                isClosing: { _, fact in
                    if case .shutdownCompleted = fact { return true }
                    return false
                }
            )
        )
        self.bus = bus
        self.publicationFactSource = publicationFactSource
        facts = try publicationFactSource.attach()
    }

    func beginObservation() async -> OpeningPosition<GitProjectorScope> {
        let opening = await facts.mark(.lifetime(1))
        isObserving.withLock { $0 = true }
        return opening
    }

    var factSink: GitProjectorFactSink {
        { [self] scope, fact in
            guard scope == .lifetime(1), fact == .shutdownCompleted,
                isObserving.withLock({ $0 })
            else { return }
            publicationFactSource.sink(scope, .shutdownCompleted)
        }
    }

    func post(_ envelope: RuntimeEnvelope) async -> EventBus<RuntimeEnvelope>.PostResult {
        if isObserving.withLock({ $0 }),
            case .worktree(let worktree) = envelope,
            case .gitWorkingDirectory(let event) = worktree.event
        {
            publicationFactSource.sink(.lifetime(1), .output(event))
        }
        return await bus.post(envelope)
    }
}
