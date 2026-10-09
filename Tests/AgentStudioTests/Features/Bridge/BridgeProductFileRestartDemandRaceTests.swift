import AgentStudioCore
import AgentStudioTestHarness
import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import AgentStudioBridge

private enum FileRestartOwnerFact: Sendable {
    case sourceAccepted(Int)
    case bootstrapFinished(succeeded: Bool)
}

private enum FileRestartDemandBoundary: Sendable {
    case reachedSource
    case completed
}

extension BridgeProductFileResumedCertificateRestartTests {
    private static var demandBoundaryVocabulary: FactVocabulary<String, FileRestartDemandBoundary> {
        .init(
            describeScope: { $0 }, describeFact: { String(describing: $0) },
            isClosing: { _, fact in
                if case .completed = fact { true } else { false }
            })
    }

    private static var restartOwnerVocabulary: FactVocabulary<String, FileRestartOwnerFact> {
        .init(
            describeScope: { $0 }, describeFact: { String(describing: $0) },
            isClosing: { _, fact in
                if case .bootstrapFinished(succeeded: true) = fact { true } else { false }
            })
    }

    @Test("resnapshot demand without a source cannot consume a deferred File reopen", arguments: [false, true])
    func resnapshotDemandCannotConsumeDeferredRestart(withCompetingResume: Bool) async throws {
        let facts = LocalFactSource<String, ResumedFileRestartFact>(
            vocabulary: .init(describeScope: { $0 }, describeFact: { $0.description }, isClosing: { _, _ in false }))
        let recorder = try facts.attach()
        let factSink = facts.sink
        let boundaries = LocalFactSource(vocabulary: Self.demandBoundaryVocabulary)
        let boundaryRecorder = try boundaries.attach()
        let boundarySink = boundaries.sink
        let demandHold = HeldStep<Void>("resnapshot demand with released File source before restart")
        let demandControl = FileRestartDemandHold()
        let ownerFacts = LocalFactSource(vocabulary: Self.restartOwnerVocabulary)
        let ownerRecorder = try ownerFacts.attach()
        let ownerSink = ownerFacts.sink
        let context = try await FileRestartContextBuilder(
            factSink: factSink, ownerSink: ownerSink, boundarySink: boundarySink,
            demandControl: demandControl, demandHold: demandHold
        ).make()
        defer {
            demandHold.release()
            context.fixture.remove()
        }
        let stream = try await context.openStream(id: "file-demand-restart", barrier: nil)
        try await context.openSubscription()
        _ = try await context.initialSourceHeld.firstArrival()
        try await context.acceptInitialScope()
        context.initialSourceHeld.release()
        let pump = Task { try await context.pump(stream.pump, holding: nil) }
        _ = try await recorder.expectNext(
            in: "lifecycle", where: { $0.isSuccessfulBootstrap }, "Initial source bootstrap closes before restart probe"
        )
        _ = try await recorder.expectNext(
            in: "descriptor", where: { $0.descriptor != nil }, "Initial source descriptor closes before restart probe")
        let bytes = Data("descriptor after interrupted source release\n".utf8)
        try bytes.write(to: context.fixture.demandedFileURL)
        let expectedSHA = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        // This is the real owner's state after interrupted bootstrap cleanup,
        // immediately before resumeForegroundWork attempts its deferred reopen.
        await context.provider.metadataCoordinator.stageReleasedFileSourceForRestartProbe(
            subscriptionId: "file-subscription-1")
        #expect(await context.source.diagnosticSnapshot().subscriptionCount == 0)
        let reconciler = await context.provider.metadataCoordinator.fileSurfaceReconciler
        #expect(await reconciler.activeAttempt == nil)
        #expect(await reconciler.currentFailure == nil)
        demandControl.armed.withLock { $0 = true }
        demandControl.observesReopen.withLock { $0 = true }
        let reopenOpening = await ownerRecorder.mark("reopen")
        let demandTask = Task {
            try await context.applyRetainedDemand()
            boundarySink("demand", .completed)
        }
        let boundary = try await boundaryRecorder.expectNext(
            in: "demand", where: { _ in true }, "Demand either completes without source or reaches the source port")
        if case .reachedSource = boundary {
            #expect(await reconciler.activeAttempt != nil, "The held demand owns the competing builder slot")
        }
        await context.provider.metadataCoordinator.resumeForegroundWork()
        let deferred = await context.provider.metadataCoordinator.deferredOpenSubscriptionIds
        let sourceCount = await context.source.diagnosticSnapshot().subscriptionCount
        // While the competing builder is held, preserving the deferred marker
        // is the logical outcome. An early-return demand is proved by the source
        // acceptance and descriptor facts below, never by sampling task speed.
        let restartWasPreserved: Bool
        if case .reachedSource = boundary {
            restartWasPreserved = deferred.contains("file-subscription-1")
        } else {
            restartWasPreserved = true
        }
        print("GO19 forced restart: boundary=\(boundary),deferred=\(deferred),sourceCount=\(sourceCount)")
        #expect(restartWasPreserved, "Resnapshot demand must not consume the pending source reopen")
        demandHold.release()
        let competingResume =
            withCompetingResume
            ? Task { await context.provider.metadataCoordinator.resumeForegroundWork() } : nil
        try await demandTask.value
        await competingResume?.value
        if case .reachedSource = boundary {
            _ = try await boundaryRecorder.expectNext(in: "demand", where: { _ in true }, "Held demand completes")
        }
        var proofError: (any Error)?
        do {
            if restartWasPreserved {
                try await FileRestartReopenProof(
                    context: context, recorder: recorder, ownerRecorder: ownerRecorder,
                    opening: reopenOpening, expectedSHA: expectedSHA
                ).verify()
            }
        } catch {
            proofError = error
        }
        #expect(await stream.pump.cancel())
        do { try await pump.value } catch { proofError = proofError ?? error }
        await context.provider.closeAndDrain()
        facts.end()
        boundaries.end()
        ownerFacts.end()
        try await recorder.finish()
        try await boundaryRecorder.finish()
        try await ownerRecorder.finish()
        #expect(await context.harness.session.producerSnapshot().hasZeroResidue)
        if let proofError { throw proofError }
    }
}

private struct FileRestartContextBuilder: Sendable {
    let factSink: @Sendable (String, ResumedFileRestartFact) -> Void
    let ownerSink: @Sendable (String, FileRestartOwnerFact) -> Void
    let boundarySink: @Sendable (String, FileRestartDemandBoundary) -> Void
    let demandControl: FileRestartDemandHold
    let demandHold: HeldStep<Void>

    func make() async throws -> ResumedFileRestartContext {
        try await ResumedFileRestartContext.make(
            sink: { _, fact in
                factSink(fact.recordingScope, fact)
                if demandControl.observesReopen.withLock({ $0 }) {
                    if case .sourceAccepted(let identity) = fact {
                        ownerSink("reopen", .sourceAccepted(identity.subscriptionGeneration))
                    } else if case .lifecycle(let event) = fact {
                        ownerSink("reopen", .bootstrapFinished(succeeded: event.result == .success))
                    }
                }
            },
            decorateSource: { source in
                FileRestartDemandSourcePort(
                    source: source, demandControl: demandControl, demandHold: demandHold,
                    boundarySink: { boundarySink("demand", $0) })
            })
    }
}

private struct FileRestartReopenProof {
    let context: ResumedFileRestartContext
    let recorder: FactRecorder<String, ResumedFileRestartFact>
    let ownerRecorder: FactRecorder<String, FileRestartOwnerFact>
    let opening: OpeningPosition<String>
    let expectedSHA: String

    func verify() async throws {
        let reopenedSource = try await context.replaySourceHeld.firstArrival()
        #expect(reopenedSource.subscriptionGeneration == 2)
        // A second resume while this registered bootstrap is still held must
        // neither replace it nor open a second source for the same E3.
        await context.provider.metadataCoordinator.resumeForegroundWork()
        context.replaySourceHeld.release()
        let descriptor = try await recorder.expectNext(
            in: "descriptor", where: { $0.descriptor?.expectedSha256 == expectedSHA },
            "Preserved deferred reopen delivers the descriptor from its new source")
        #expect((descriptor.descriptor?.source.subscriptionGeneration ?? 0) == 2)
        _ = try await recorder.expectNext(
            in: "lifecycle", where: { $0.isSuccessfulBootstrap }, "The one replacement File bootstrap closes")
        let duplicateDescription = "a duplicate or replaced source open"
        try await ownerRecorder.expectNone(
            of: { fact in
                if case .sourceAccepted(let generation) = fact { return generation != 2 }
                if case .bootstrapFinished(succeeded: false) = fact { return true }
                return false
            },
            duplicateDescription,
            from: opening,
            closedBy: { if case .bootstrapFinished(succeeded: true) = $0 { true } else { false } })
        #expect(await context.source.diagnosticSnapshot().subscriptionCount == 1)
        #expect(await context.provider.metadataCoordinator.deferredOpenSubscriptionIds.isEmpty)
    }
}

extension BridgePaneProductMetadataCoordinator {
    func stageReleasedFileSourceForRestartProbe(subscriptionId: String) async {
        await fileMetadataSource.cancel(subscriptionId: subscriptionId)
        openedSourceSubscriptionIds.remove(subscriptionId)
        deferredOpenSubscriptionIds.insert(subscriptionId)
    }
}

private final class FileRestartDemandHold: Sendable {
    let armed = Mutex(false)
    let observesReopen = Mutex(false)
}

private struct FileRestartDemandSourcePort: BridgePaneProductFileMetadataProducing {
    let source: BridgePaneProductFileMetadataSource
    let demandControl: FileRestartDemandHold
    let demandHold: HeldStep<Void>
    let boundarySink: @Sendable (FileRestartDemandBoundary) -> Void

    func currentSource() async throws(BridgeWorktreeFileRootAccessError) -> BridgeProductFileSourceCurrentResult {
        try await source.currentSource()
    }
    func captureKeyedSnapshot(
        subscriptionId: String, demand: BridgePaneProductFileViewDemand, productAdmission: BridgeProductAdmissionContext
    ) async -> BridgeWorktreeFileKeyedSnapshot? {
        await source.captureKeyedSnapshot(
            subscriptionId: subscriptionId, demand: demand, productAdmission: productAdmission)
    }
    func open(
        subscription: BridgeProductSubscriptionSnapshot, productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission, emit: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {
        try await source.open(
            subscription: subscription, productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission, emit: emit)
    }
    func applyViewDemand(
        subscriptionId: String, demand: BridgePaneProductFileViewDemand,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission, forceRecapture: Bool,
        emit: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {
        let shouldHold = demandControl.armed.withLock { armed in
            let shouldHold = armed
            armed = false
            return shouldHold
        }
        if shouldHold {
            boundarySink(.reachedSource)
            try await demandHold.arrive(())
        }
        try await source.applyViewDemand(
            subscriptionId: subscriptionId, demand: demand, productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission, forceRecapture: forceRecapture, emit: emit)
    }
    func cancel(subscriptionId: String) async { await source.cancel(subscriptionId: subscriptionId) }
    func publish(
        status: GitWorkingTreeStatus, productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async -> [BridgePaneProductFileMetadataEmission] {
        await source.publish(
            status: status, productAdmission: productAdmission, foregroundWorkAdmission: foregroundWorkAdmission)
    }
    func publish(
        changeset: FileChangeset, productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async throws -> [BridgePaneProductFileMetadataEmission] {
        try await source.publish(
            changeset: changeset, productAdmission: productAdmission, foregroundWorkAdmission: foregroundWorkAdmission)
    }
    func contentReadPlan(
        for request: BridgeProductFileContentRequest, productAdmission: BridgeProductAdmissionContext
    ) async -> BridgePaneProductFileContentReadPlan? {
        await source.contentReadPlan(for: request, productAdmission: productAdmission)
    }
}
