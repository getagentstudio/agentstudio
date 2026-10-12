import AgentStudioCore
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge
@testable import AgentStudioBridgeDevelopmentServer

enum SeededReviewObservationFact: Sendable {
    case committed
    case lifecycle(BridgeOperationLifecycleTraceEvent)

    var description: String {
        switch self {
        case .committed: "Review publication committed"
        case .lifecycle(let event):
            "\(event.stage.rawValue) result=\(event.result.rawValue) correlation=\(event.operationCorrelationID)"
        }
    }
}

struct SeededReviewRefreshWithoutDeletion: Error, CustomStringConvertible {
    let terminal: BridgeOperationLifecycleTraceEvent
    var description: String {
        "Review refresh ended without committed tracked-file deletion: stage=\(terminal.stage.rawValue) "
            + "result=\(terminal.result.rawValue) correlation=\(terminal.operationCorrelationID) "
            + "reason=terminal has no committed deletion publication (production reason unavailable)"
    }
}

/// Consumes the actual host lifecycle calls and commit callback in one ordered history.
/// A success-only no-op cannot stand in for the required deletion publication.
final class SeededReviewLifecycleRecorder: BridgeProductMetadataLifecycleTraceRecording, Sendable {
    private let facts = FactRecorder<String, SeededReviewObservationFact>(
        vocabulary: .init(
            describeScope: { $0 }, describeFact: { $0.description }, isClosing: { _, _ in false }
        ))

    func record(_ event: BridgeOperationLifecycleTraceEvent) async {
        guard event.surface == .review,
            event.stage == .refreshReserved || event.stage == .refreshOperationTerminal
        else { return }
        facts.append(scope: "Review refresh", fact: .lifecycle(event))
    }
    func record(_: BridgeProductMetadataLifecycleTraceEvent) async {}
    func record(_: BridgeProductReviewMetadataPublicationTraceEvent) async {}
    func recordCommit() { facts.append(scope: "Review refresh", fact: .committed) }

    private func nextFact() async throws -> SeededReviewObservationFact {
        try await facts.expectNext(
            in: "Review refresh", where: { _ in true }, "Review commit or correlated refresh terminal")
    }

    private func nextReservation() async throws -> String {
        while true {
            if case .lifecycle(let event) = try await nextFact(), event.stage == .refreshReserved {
                return event.operationCorrelationID
            }
        }
    }

    func nextTerminal() async throws -> BridgeOperationLifecycleTraceEvent {
        let correlation = try await nextReservation()
        while true {
            if case .lifecycle(let event) = try await nextFact(),
                event.operationCorrelationID == correlation, event.stage == .refreshOperationTerminal
            {
                return event
            }
        }
    }

    func requireCommittedDeletion(path: String, host: BridgeDevelopmentProductHost) async throws
        -> BridgeReviewCommittedPublication
    {
        let correlation = try await nextReservation()
        while true {
            let fact = try await nextFact()
            let publication = await host.diagnosticCommittedReviewPublication()
            let hasDeletion =
                publication?.package.itemsById.values.contains {
                    $0.basePath == path && $0.headPath == nil
                } == true
            switch fact {
            case .committed:
                if hasDeletion, let publication { return publication }
            case .lifecycle(let event):
                guard event.operationCorrelationID == correlation, event.stage == .refreshOperationTerminal else {
                    continue
                }
                guard hasDeletion, let publication else { throw SeededReviewRefreshWithoutDeletion(terminal: event) }
                return publication
            }
        }
    }

    func finish() async throws {
        facts.receive(.ended)
        try await facts.finish()
    }
}

func makeReviewCommitObservedHost(
    source: BridgeDevelopmentProductSource,
    statusPhysicalGate: AgentStudioGitStatusPhysicalGate,
    lifecycle: SeededReviewLifecycleRecorder,
    captureFailure: SeededReviewCaptureFailure? = nil
) async throws -> BridgeDevelopmentProductHost {
    try await BridgeDevelopmentProductHost(
        source: source,
        contributionTargetCommit: { _ in .unchanged(source.paneState) },
        statusPhysicalGate: statusPhysicalGate,
        makeReviewProvider: { repositoryPath, gitReadContext in
            let provider = BridgeReviewSourceProviderFactory.gitProvider(
                repositoryPath: repositoryPath, gitReadContext: gitReadContext, statusPhysicalGate: statusPhysicalGate
            )
            guard let captureFailure else { return provider }
            return SeededReviewCaptureFailureProvider(base: provider, failure: captureFailure)
        },
        didCommitReviewPublication: { lifecycle.recordCommit() },
        lifecycleTraceRecorder: lifecycle
    )
}

func seededReviewBootstrapRequest() throws -> BridgeDevelopmentProductBootstrapRequest {
    try JSONDecoder().decode(
        BridgeDevelopmentProductBootstrapRequest.self,
        from: Data(
            #"{"navigationIntent":{"commandId":"live-review","commandKind":"activateContext","surface":"review"},"reason":"initial","tabId":"owner-tab-1"}"#
                .utf8
        ))
}

/// This real Git/Review interaction isolates terminal coverage from OS ingress.
/// A provider contract failure closes through the real host's lifecycle emitter.
func exerciseControllableReviewDeletion(capacityDeferred: Bool) async throws {
    let root = try await FilesystemTestGitRepo.create(named: "seeded-review-terminal")
    defer { FilesystemTestGitRepo.destroy(root) }
    let trackedFile = root.appending(path: "tracked.txt")
    try "initial\n".write(to: trackedFile, atomically: true, encoding: .utf8)
    try await FilesystemTestGitRepo.runGit(at: root, args: ["add", "tracked.txt"])
    try await FilesystemTestGitRepo.runGit(at: root, args: ["commit", "-m", "Initial"])
    try "initial\nupdated\n".write(to: trackedFile, atomically: false, encoding: .utf8)
    let source = BridgeDevelopmentObservationFixture.makeSource(root: root)
    let gate = AgentStudioGitStatusPhysicalGate()
    let lifecycle = SeededReviewLifecycleRecorder()
    let failure = capacityDeferred ? SeededReviewCaptureFailure() : nil
    let host = try await makeReviewCommitObservedHost(
        source: source, statusPhysicalGate: gate, lifecycle: lifecycle, captureFailure: failure
    )
    do {
        _ = try await host.issueBootstrap(for: seededReviewBootstrapRequest())
        await failure?.arm()
        try FileManager.default.removeItem(at: trackedFile)
        let changeset = FileChangeset(
            worktreeId: source.worktreeID, repoId: source.repoID, rootPath: root,
            paths: ["tracked.txt"], timestamp: .now, batchSeq: 1
        )
        await host.handleObservedWorktreeInvalidation(.filesChanged(changeset))
        let publication = try await lifecycle.requireCommittedDeletion(path: "tracked.txt", host: host)
        #expect(publication.package.itemsById.values.contains { $0.basePath == "tracked.txt" && $0.headPath == nil })
        await host.shutdown()
        try await lifecycle.finish()
    } catch {
        await host.shutdown()
        try await lifecycle.finish()
        throw error
    }
}

actor SeededReviewCaptureFailure {
    private var armed = false
    func arm() { armed = true }
    func check() throws {
        if armed { throw BridgeProviderFailure.sourceCapacityDeferred }
    }
}

/// Only the dependency's capture outcome is forced. Every bootstrap/read contract
/// is delegated; refresh admission, terminal emission, and the oracle stay real.
struct SeededReviewCaptureFailureProvider: BridgeReviewSourceProvider {
    let base: any BridgeReviewSourceProvider
    let failure: SeededReviewCaptureFailure

    func resolveReviewDefaultTarget() async throws -> BridgeReviewComparisonDefaultTargetIdentity? {
        try await base.resolveReviewDefaultTarget()
    }
    func captureReviewComparisonTargets(_ request: BridgeReviewComparisonTargetsCaptureRequest) async throws
        -> BridgeReviewComparisonTargetsCapture
    {
        try await base.captureReviewComparisonTargets(request)
    }
    func captureContributionComparison(_ request: BridgeContributionComparisonRequest) async throws
        -> BridgeContributionComparisonCapture
    {
        try await failure.check()
        return try await base.captureContributionComparison(request)
    }
    func resolveEndpoint(_ request: BridgeEndpointResolutionRequest) async throws -> BridgeSourceEndpoint {
        try await base.resolveEndpoint(request)
    }
    func compareEndpoints(_ request: BridgeEndpointComparisonRequest) async throws -> BridgeEndpointComparison {
        try await base.compareEndpoints(request)
    }
    func readTree(_ request: BridgeTreeReadRequest) async throws -> BridgeTreeReadResult {
        try await base.readTree(request)
    }
    func readReviewItemDescriptor(_ request: BridgeReviewItemDescriptorRequest) async throws
        -> BridgeReviewItemDescriptor
    {
        try await base.readReviewItemDescriptor(request)
    }
    func resolveCheckpointEndpoint(_ request: BridgeCheckpointEndpointRequest) async throws -> BridgeSourceEndpoint {
        try await base.resolveCheckpointEndpoint(request)
    }
    func loadContent(_ request: BridgeContentLoadRequest) async throws -> BridgeContentLoadResult {
        try await base.loadContent(request)
    }
    func streamContent(
        _ request: BridgeContentStreamRequest, chunkByteCount: Int, emitChunk: BridgeContentStreamEmitter
    )
        async throws -> BridgeContentStreamResult
    {
        try await base.streamContent(request, chunkByteCount: chunkByteCount, emitChunk: emitChunk)
    }
}
