import AgentStudioTestHarness
import Synchronization

@testable import AgentStudioBridge

/// Captures owner closes for bootstrap and the initial scope-driven File attempt.
final class ReconnectFileLifecycleProbe: BridgeProductMetadataLifecycleTraceRecording {
    private let completionOrdinal = Mutex(0)
    private let initialOutcomeOrdinal = Mutex(0)
    let initialFileOutcomes = LocalFactSource<Int, BridgeFileSurfaceOutcomeApplication>(
        vocabulary: .init(
            describeScope: { "initial File outcome \($0)" },
            describeFact: { "generation=\($0.attempt.inputGeneration) nonce=\($0.attempt.nonce)" },
            isClosing: { _, _ in true }
        )
    )

    func recordInitialFileOutcome(_ outcome: BridgeFileSurfaceOutcomeApplication) {
        let ordinal = initialOutcomeOrdinal.withLock { ordinal in
            ordinal += 1
            return ordinal
        }
        // This fixture window ends at the second actual outcome: initial
        // bootstrap, then initial scope. Replacement/resnapshot are later work.
        guard ordinal <= 2 else { return }
        initialFileOutcomes.sink(ordinal, outcome)
    }

    let source = LocalFactSource<Int, BridgeProductMetadataLifecycleTraceEvent>(
        vocabulary: .init(
            describeScope: { "File bootstrap completion \($0)" },
            describeFact: { $0.stage.rawValue },
            isClosing: { _, event in event.stage == .bootstrapFinished }
        )
    )

    func record(_ event: BridgeProductMetadataLifecycleTraceEvent) async {
        guard event.stage == .bootstrapFinished else { return }
        let ordinal = completionOrdinal.withLock { ordinal in
            ordinal += 1
            return ordinal
        }
        source.sink(ordinal, event)
    }

    func record(_: BridgeProductReviewMetadataPublicationTraceEvent) async {}
}
