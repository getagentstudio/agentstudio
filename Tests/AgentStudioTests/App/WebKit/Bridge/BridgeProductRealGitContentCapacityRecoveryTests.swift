import AgentStudioGit
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioTestSupport

@MainActor
extension WebKitSerializedTests.BridgeProductRealGitFileAndReviewWebKitTests {
    @Test("selected tracked content recovers through the packaged worker after a real capacity refusal")
    func selectedTrackedContentRecoversAfterCapacityRefusal() async throws {
        let repoURL = try await FilesystemTestGitRepo.create(named: "bridge-content-capacity-recovery")
        defer { FilesystemTestGitRepo.destroy(repoURL) }
        try await seedHeavyReviewChanges(at: repoURL, trackedFileCount: 128)
        let facts = FactRecorder<String, String>(
            vocabulary: .init(
                describeScope: { $0 }, describeFact: { $0 }, isClosing: { _, fact in fact == "finished" }
            ))
        let heldRead = HeldStep<Void>("non-selected real Git content read")
        let scheduler = BridgeGitReadScheduler(
            topology: try contentCapacityRecoveryTopology(),
            deadlineScheduler: BridgeGitReadManualDeadlineScheduler(),
            eventSink: { event in
                if event.kind == .queued, event.operationClass == .selectedVisibleContent,
                    event.operationId == 2
                {
                    facts.append(scope: "queue", fact: "full")
                }
            }
        )
        let firstRead = Task {
            defer { facts.append(scope: "running", fact: "finished") }
            return try await scheduler.read(
                request: makeBridgeGitReadRequest(
                    worktree: repoURL.path, operationClass: .selectedVisibleContent, key: "non-selected-running"
                )
            ) {
                facts.append(scope: "running", fact: "started")
                try await heldRead.arrive(())
                return try await LibGit2AgentStudioGitLocalClient().content(
                    GitContentRequest(
                        repositoryPath: repoURL, target: .workingTree, path: "zz-heavy-review-001.txt"
                    ))
            }
        }
        defer {
            heldRead.release()
            firstRead.cancel()
        }
        var queuedRead: Task<GitContentPayload, any Error>?
        do {
            try await facts.expectNext(in: "running", "started")
            let secondRead = Task {
                defer { facts.append(scope: "queue", fact: "finished") }
                return try await scheduler.read(
                    request: makeBridgeGitReadRequest(
                        worktree: repoURL.path, operationClass: .selectedVisibleContent, key: "non-selected-queued"
                    )
                ) {
                    try await LibGit2AgentStudioGitLocalClient().content(
                        GitContentRequest(
                            repositoryPath: repoURL, target: .workingTree, path: "zz-heavy-review-002.txt"
                        ))
                }
            }
            queuedRead = secondRead
            try await facts.expectNext(in: "queue", "full")
            let observations = CapacityRecoveryObservations()
            let controller = try makeCapacityRecoveryController(
                repoURL: repoURL, scheduler: scheduler, observations: observations
            )
            let journey = Task {
                defer { observations.facts.append(scope: "selected", fact: .finished) }
                return try await collectCapacityRecoveryPaint(controller)
            }
            do {
                let refusal = try await observations.facts.expectNext(
                    in: "selected", where: { if case .refused = $0 { true } else { false } },
                    "selected head capacity refusal"
                )
                guard case .refused(let handle, let failure) = refusal else { preconditionFailure() }
                #expect(failure == .sourceCapacityDeferred)
                heldRead.release()
                _ = try await firstRead.value
                _ = try await secondRead.value
                let recovery = try await observations.facts.expectNext(
                    in: "selected", where: { if case .recovered = $0 { true } else { false } },
                    "same selected head recovered"
                )
                guard case .recovered(let recoveredHandle) = recovery else { preconditionFailure() }
                #expect(recoveredHandle == handle)
                #expect(try await journey.value == "tracked.txt")
            } catch {
                journey.cancel()
                if case .failure(let journeyError) = await journey.result {
                    print("TQ8_CAPACITY_RECOVERY journeyFailure=\(journeyError), observationFailure=\(error)")
                }
                throw error
            }
        } catch {
            heldRead.release()
            firstRead.cancel()
            queuedRead?.cancel()
            _ = await firstRead.result
            _ = await queuedRead?.result
            await scheduler.shutdown()
            throw error
        }
        await scheduler.shutdown()
        #expect((await scheduler.snapshot()).activeOperationIds.isEmpty)
    }
    private func makeCapacityRecoveryController(
        repoURL: URL, scheduler: BridgeGitReadScheduler, observations: CapacityRecoveryObservations
    ) throws -> BridgePaneController {
        let controller = makeController(
            repoURL: repoURL, traceRecorder: BridgeProductWebKitCarrierTraceRecorder(),
            reviewSourceProviderTransform: { CapacityRecoveryReviewProvider(base: $0, observations: observations) },
            gitReadContext: BridgeGitReadContext(
                scheduler: scheduler, worktreeKey: BridgeGitReadWorktreeKey(token: repoURL.path)
            )
        )
        try BridgeProductWebKitSelectedReviewFailureCapture.install(on: controller)
        return controller
    }

    private func contentCapacityRecoveryTopology() throws -> BridgeGitReadSchedulerTopology {
        let baseline = BridgeGitReadSchedulerTopology.recoveryBaseline
        return BridgeGitReadSchedulerTopology(
            slotsByOperationClass: [
                .reviewMetadata: try #require(baseline.slotsByOperationClass[.reviewMetadata]),
                .selectedVisibleContent: [BridgeGitReadSlotID(token: "held-content-slot")],
            ],
            maximumQueuedOperationCountByClass: [
                .reviewMetadata: try #require(baseline.maximumQueuedOperationCountByClass[.reviewMetadata]),
                .selectedVisibleContent: 1,
            ],
            maximumLogicalWaiterCountPerOperation: baseline.maximumLogicalWaiterCountPerOperation
        )
    }

    private func collectCapacityRecoveryPaint(_ controller: BridgePaneController) async throws -> String? {
        let run = try await BridgeProductWebKitCarrierTestSupport.withHostedController(controller) { hosted in
            _ = try await loadLiveAppThroughNavigationFinish(hosted)
            _ = try await waitForLiveShell(hosted)
            let packageResult: Result<BridgeReviewPackage, CapacityRecoveryFixtureFailure> =
                try await BridgePaneControllerEventWaits.waitForValue(
                    {
                        guard hosted.canReloadWebView else { return .failure(.retiredPane) }
                        if let package = hosted.paneState.diff.packageMetadata { return .success(package) }
                        switch hosted.paneState.diff.status {
                        case .error: return .failure(.nativePackageFailed)
                        case .ready: return .failure(.readyWithoutPackage)
                        case .idle, .loading: return nil
                        }
                    },
                    milestone: "capacity recovery native package",
                    lastObservation: { "status=\(hosted.paneState.diff.status)" }
                )
            let package = try packageResult.get()
            let selected = try #require(package.itemsById.values.first { $0.headPath == "tracked.txt" })
            let hashes = selected.contentRoles.allHandles.map { "\($0.role.rawValue):\($0.contentHash)" }
                .joined(separator: ",")
            return try await BridgeProductWebKitSelectedReviewContentWait.wait(
                hosted, expectedPath: "tracked.txt", expectedHashes: hashes,
                expectedGeneration: package.reviewGeneration.rawValue, expectedItemId: selected.itemId
            ) as? String
        }
        return run.value
    }

}

private enum CapacityRecoveryFixtureFailure: Error {
    case retiredPane
    case nativePackageFailed
    case readyWithoutPackage
}

private struct CapacityRecoveryObservations: Sendable {
    enum Observation: Sendable {
        case refused(BridgeContentHandle, BridgeProviderFailure?)
        case recovered(BridgeContentHandle)
        case finished
    }
    let facts = FactRecorder<String, Observation>(
        vocabulary: .init(
            describeScope: { $0 }, describeFact: { String(describing: $0) },
            isClosing: { _, fact in if case .finished = fact { true } else { false } }
        ))
}

private actor CapacityRecoveryReviewProvider: BridgeSharedReviewConstructionSourceProvider {
    let base: any BridgeReviewSourceProvider
    let sharedBase: (any BridgeSharedReviewConstructionSourceProvider)?
    let observations: CapacityRecoveryObservations
    var selectedItemId: String?
    var refusedHandle: BridgeContentHandle?
    var recovered = false

    init(base: any BridgeReviewSourceProvider, observations: CapacityRecoveryObservations) {
        self.base = base
        self.sharedBase = base as? any BridgeSharedReviewConstructionSourceProvider
        self.observations = observations
    }

    func resolveReviewDefaultTarget() async throws -> BridgeReviewComparisonDefaultTargetIdentity? {
        try await base.resolveReviewDefaultTarget()
    }
    func captureReviewComparisonTargets(_ request: BridgeReviewComparisonTargetsCaptureRequest) async throws
        -> BridgeReviewComparisonTargetsCapture
    { try await base.captureReviewComparisonTargets(request) }
    func captureContributionComparison(_ request: BridgeContributionComparisonRequest) async throws
        -> BridgeContributionComparisonCapture
    {
        let result = try await base.captureContributionComparison(request)
        rememberSelectedItem(result.comparison)
        return result
    }
    func resolveEndpoint(_ request: BridgeEndpointResolutionRequest) async throws -> BridgeSourceEndpoint {
        try await base.resolveEndpoint(request)
    }
    func compareEndpoints(_ request: BridgeEndpointComparisonRequest) async throws -> BridgeEndpointComparison {
        let result = try await base.compareEndpoints(request)
        rememberSelectedItem(result)
        return result
    }
    private func rememberSelectedItem(_ comparison: BridgeEndpointComparison) {
        selectedItemId = comparison.changedFiles.first { $0.path == "tracked.txt" }.map { "item-\($0.fileId)" }
    }
    func readTree(_ request: BridgeTreeReadRequest) async throws -> BridgeTreeReadResult {
        try await base.readTree(request)
    }
    func readReviewItemDescriptor(_ request: BridgeReviewItemDescriptorRequest) async throws
        -> BridgeReviewItemDescriptor
    {
        let result = try await base.readReviewItemDescriptor(request)
        if result.headPath == "tracked.txt" { selectedItemId = result.itemId }
        return result
    }
    func resolveCheckpointEndpoint(_ request: BridgeCheckpointEndpointRequest) async throws -> BridgeSourceEndpoint {
        try await base.resolveCheckpointEndpoint(request)
    }
    func loadContent(_ request: BridgeContentLoadRequest) async throws -> BridgeContentLoadResult {
        do {
            let result = try await base.loadContent(request)
            if refusedHandle == request.handle, !recovered {
                recovered = true
                observations.facts.append(scope: "selected", fact: .recovered(request.handle))
            }
            return result
        } catch {
            if request.handle.itemId == selectedItemId, request.handle.role == .head, refusedHandle == nil {
                refusedHandle = request.handle
                observations.facts.append(
                    scope: "selected", fact: .refused(request.handle, error as? BridgeProviderFailure))
            }
            throw error
        }
    }

    // Preserve the real provider's shared-construction route while observing body outcomes.
    private func requireSharedBase() throws -> any BridgeSharedReviewConstructionSourceProvider {
        guard let sharedBase else { throw BridgeProviderFailure.providerUnavailable }
        return sharedBase
    }

    func resolveEndpoint(
        _ request: BridgeEndpointResolutionRequest, freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> BridgeSourceEndpoint {
        try await requireSharedBase().resolveEndpoint(request, freshnessKey: freshnessKey)
    }

    func compareEndpoints(
        _ request: BridgeEndpointComparisonRequest, freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> BridgeEndpointComparison {
        let result = try await requireSharedBase().compareEndpoints(request, freshnessKey: freshnessKey)
        rememberSelectedItem(result)
        return result
    }

    func readTree(
        _ request: BridgeTreeReadRequest, freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> BridgeTreeReadResult {
        try await requireSharedBase().readTree(request, freshnessKey: freshnessKey)
    }

    func readReviewItemDescriptor(
        _ request: BridgeReviewItemDescriptorRequest, freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> BridgeReviewItemDescriptor {
        let result = try await requireSharedBase().readReviewItemDescriptor(request, freshnessKey: freshnessKey)
        if result.headPath == "tracked.txt" { selectedItemId = result.itemId }
        return result
    }

    func captureSharedContent(
        handles: [BridgeContentHandle], freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> BridgeSharedReviewContentBacking {
        try await requireSharedBase().captureSharedContent(handles: handles, freshnessKey: freshnessKey)
    }

    func installSharedContent(backing: BridgeSharedReviewContentBacking, handles: [BridgeContentHandle]) async throws {
        try await requireSharedBase().installSharedContent(backing: backing, handles: handles)
    }

}
