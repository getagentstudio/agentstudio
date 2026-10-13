import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge
@testable import AgentStudioBridgeDevelopmentServer

enum SeededReviewObservationFact: Sendable {
    case committed(BridgeReviewCommittedPublication)
    case opening(UUID)
    case lifecycle(BridgeOperationLifecycleTraceEvent)

    var description: String {
        switch self {
        case .committed(let publication):
            "Review publication committed correlation=\(publication.operationCorrelationID ?? "none")"
        case .opening: "Deletion observation opened"
        case .lifecycle(let event):
            "\(event.stage.rawValue) result=\(event.result.rawValue) correlation=\(event.operationCorrelationID)"
        }
    }
}

/// Consumes the actual host lifecycle calls and commit callback in one ordered history.
/// A success-only no-op cannot stand in for the required deletion publication.
final class SeededReviewLifecycleRecorder: BridgeProductMetadataLifecycleTraceRecording, Sendable {
    private let diagnosticLog: HeldStepEventLog
    private let emitConsoleDiagnostic: @Sendable (String) -> Void

    init(
        diagnosticLog: HeldStepEventLog = .environment,
        emitConsoleDiagnostic: @escaping @Sendable (String) -> Void = { diagnostic in
            FileHandle.standardOutput.write(Data(diagnostic.utf8))
        }
    ) {
        self.diagnosticLog = diagnosticLog
        self.emitConsoleDiagnostic = emitConsoleDiagnostic
    }

    private let facts = FactRecorder<String, SeededReviewObservationFact>(
        vocabulary: .init(
            describeScope: { $0 }, describeFact: { $0.description }, isClosing: { _, _ in false }
        ))

    func record(_ event: BridgeOperationLifecycleTraceEvent) async {
        guard event.surface == .review else { return }
        switch event.stage {
        case .refreshReserved: break
        case .refreshOperationTerminal, .filePrepareTerminal, .reviewPrepareTerminal,
            .refreshCommitTerminal, .metadataEnqueueTerminal, .metadataDeliveryTerminal:
            let diagnostic =
                "TQ56 Review terminal: stage=\(event.stage.rawValue) result=\(event.result.rawValue) correlation=\(event.operationCorrelationID)\n"
            TestEventLogWriter.append(diagnostic, path: diagnosticLog.path)
            emitConsoleDiagnostic(diagnostic)
        case .filePrepareStarted, .reviewPrepareStarted, .refreshCommitStarted,
            .metadataEnqueueStarted, .metadataDeliveryStarted:
            return
        }
        facts.append(scope: "Review refresh", fact: .lifecycle(event))
    }
    func record(_: BridgeProductMetadataLifecycleTraceEvent) async {}
    func record(_: BridgeProductReviewMetadataPublicationTraceEvent) async {}
    func recordCommit(_ publication: BridgeReviewCommittedPublication) {
        facts.append(scope: "Review refresh", fact: .committed(publication))
    }

    func openDeletionObservation() -> UUID {
        let opening = UUIDv7.generate()
        facts.append(scope: "Review refresh", fact: .opening(opening))
        return opening
    }

    func nextCommittedPublication() async throws -> BridgeReviewCommittedPublication {
        while true {
            if case .committed(let publication) = try await nextFact() { return publication }
        }
    }

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

    func requireCommittedDeletion(path: String, after opening: UUID) async throws
        -> BridgeReviewCommittedPublication
    {
        var observationOpened = false
        var operationReservations: Set<String> = []
        while true {
            let fact = try await nextFact()
            if case .opening(let observedOpening) = fact, observedOpening == opening {
                observationOpened = true
                continue
            }
            guard observationOpened else { continue }
            switch fact {
            case .lifecycle(let event):
                if event.stage == .refreshReserved {
                    operationReservations.insert(event.operationCorrelationID)
                }
            case .committed(let publication):
                guard let correlation = publication.operationCorrelationID,
                    operationReservations.contains(correlation),
                    publication.package.itemsById.values.contains(where: {
                        $0.basePath == path && $0.headPath == nil
                    })
                else { continue }
                return publication
            case .opening: continue
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
    lifecycle: SeededReviewLifecycleRecorder
) async throws -> BridgeDevelopmentProductHost {
    try await BridgeDevelopmentProductHost(
        source: source,
        contributionTargetCommit: { _ in .unchanged(source.paneState) },
        statusPhysicalGate: statusPhysicalGate,
        makeReviewProvider: { repositoryPath, gitReadContext in
            BridgeReviewSourceProviderFactory.gitProvider(
                repositoryPath: repositoryPath, gitReadContext: gitReadContext, statusPhysicalGate: statusPhysicalGate
            )
        },
        didCommitReviewPublication: { lifecycle.recordCommit($0) },
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

/// Real Git and the real host prove the publication-bearing commit seam.
func captureControllableReviewPublications() async throws -> SeededReviewPublicationFixture {
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
    let host = try await makeReviewCommitObservedHost(
        source: source, statusPhysicalGate: gate, lifecycle: lifecycle
    )
    do {
        _ = try await host.issueBootstrap(for: seededReviewBootstrapRequest())
        let baseline = try await lifecycle.nextCommittedPublication()
        let opening = lifecycle.openDeletionObservation()
        try FileManager.default.removeItem(at: trackedFile)
        let changeset = FileChangeset(
            worktreeId: source.worktreeID, repoId: source.repoID, rootPath: root,
            paths: ["tracked.txt"], timestamp: .now, batchSeq: 1
        )
        await host.handleObservedWorktreeInvalidation(.filesChanged(changeset))
        let publication = try await lifecycle.requireCommittedDeletion(path: "tracked.txt", after: opening)
        #expect(publication.package.itemsById.values.contains { $0.basePath == "tracked.txt" && $0.headPath == nil })
        await host.shutdown()
        try await lifecycle.finish()
        return SeededReviewPublicationFixture(baseline: baseline, deletion: publication)
    } catch {
        await host.shutdown()
        try await lifecycle.finish()
        throw error
    }
}
