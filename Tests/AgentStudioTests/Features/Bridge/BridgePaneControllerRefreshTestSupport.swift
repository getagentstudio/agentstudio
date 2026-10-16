import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@MainActor
struct RefreshRevisionFixture {
    let baseEndpoint: BridgeSourceEndpoint
    let headEndpoint: BridgeSourceEndpoint
    let refreshedFile: BridgeEndpointChangedFile
    let secondRefreshedFile: BridgeEndpointChangedFile
    let provider: BridgeReviewSourceProviderFake
    let controller: BridgePaneController
    let commandId: UUID
}

@MainActor
func makeRefreshRevisionFixture() -> RefreshRevisionFixture {
    let baseEndpoint = makeBridgeEndpoint(endpointId: "baseline-headMinusOne", kind: .gitRef)
    let headEndpoint = makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree)
    let initialFile = makeBridgeEndpointChangedFile(
        fileId: "old",
        path: "Sources/App/Old.swift",
        sizeBytes: 100
    )
    let refreshedFile = makeBridgeEndpointChangedFile(
        fileId: "new",
        path: "Sources/App/New.swift",
        sizeBytes: 100
    )
    let secondRefreshedFile = makeBridgeEndpointChangedFile(
        fileId: "newer",
        path: "Sources/App/Newer.swift",
        sizeBytes: 100
    )
    let provider = BridgeReviewSourceProviderFake(
        comparison: BridgeEndpointComparison(
            baseEndpoint: baseEndpoint,
            headEndpoint: headEndpoint,
            changedFiles: [initialFile]
        ),
        contentByHandleId: [:]
    )
    let paneId = UUIDv7.generate()
    let controller = BridgePaneController(
        paneId: paneId,
        state: BridgePaneState(
            panelKind: .diffViewer,
            source: .workspace(
                rootPath: "/tmp/worktree",
                baseline: .staged)
        ),
        appRootURL: testBridgeAppRootURL(),
        metadata: PaneMetadata(
            contentType: .diff,
            title: "Refresh revision",
            facets: PaneContextFacets(
                repoId: headEndpoint.repoId,
                worktreeId: headEndpoint.worktreeId,
                cwd: URL(fileURLWithPath: "/tmp/worktree")
            )
        ),
        reviewSourceProvider: provider,
        initialPaneActivity: .foreground
    )
    return RefreshRevisionFixture(
        baseEndpoint: baseEndpoint,
        headEndpoint: headEndpoint,
        refreshedFile: refreshedFile,
        secondRefreshedFile: secondRefreshedFile,
        provider: provider,
        controller: controller,
        commandId: UUID()
    )
}

@MainActor
func setRefreshComparison(
    _ fixture: RefreshRevisionFixture,
    changedFile: BridgeEndpointChangedFile
) async {
    await fixture.provider.setComparison(
        BridgeEndpointComparison(
            baseEndpoint: fixture.baseEndpoint,
            headEndpoint: fixture.headEndpoint,
            changedFiles: [changedFile]
        )
    )
}

@MainActor
func postRefreshEvent(
    _ fixture: RefreshRevisionFixture,
    path: String,
    batchSeq: UInt64
) async {
    await fixture.controller.handlePaneFilesystemContextEvent(
        .cwdSubtreeChanged(
            context: PaneFilesystemContext(
                paneId: PaneId(existingUUID: fixture.controller.paneId),
                repoId: fixture.headEndpoint.repoId,
                cwd: URL(fileURLWithPath: "/tmp/worktree"),
                worktreeId: fixture.headEndpoint.worktreeId
            ),
            paths: [path],
            batchSeq: batchSeq
        )
    )
}

@MainActor
func expectRefreshPackageState(
    _ fixture: RefreshRevisionFixture,
    itemId: String,
    revision: Int,
    addedItemIds: [String],
    removedItemIds: [String]
) {
    #expect(fixture.controller.paneState.diff.packageMetadata?.orderedItemIds == [itemId])
    #expect(fixture.controller.paneState.diff.packageMetadata?.revision == revision)
    #expect(fixture.controller.paneState.diff.packageDelta?.revision == revision)
    #expect(fixture.controller.paneState.diff.packageDelta?.operations.addItems.map(\.itemId) == addedItemIds)
    #expect(fixture.controller.paneState.diff.packageDelta?.operations.removeItems == removedItemIds)
}

@MainActor
struct RefreshAdmissionIntegrationFixture {
    let baseEndpoint: BridgeSourceEndpoint
    let headEndpoint: BridgeSourceEndpoint
    let refreshedComparison: BridgeEndpointComparison
    let reviewProvider: BridgeReviewSourceProviderFake
    let fileMetadataSource: RefreshAdmissionTrackingFileMetadataSource
    let metadataProducerLease: BridgeProductProducerLease
    let productInstallation: BridgeProductSessionInstallation
    let productAdmission: BridgeProductAdmissionContext
    let productProvider: BridgePaneProductSchemeProvider
    /// Optional direct-dispatch decorator; the controller installation keeps the real base provider.
    let productControlProvider: any BridgeProductSchemeProvider
    let controller: BridgePaneController

    func loadInitialReviewPackage() async throws {
        // fire-and-forget: the test asserts admission state; the presentation transition handle is not its claim
        _ = controller.applyBridgePaneActivity(.foreground)
        await waitForActiveReviewRefreshTaskToFinish(controller)
        #expect(controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-initial"])
    }

    func makeChangeset(paths: [String], batchSequence: UInt64) -> FileChangeset {
        FileChangeset(
            worktreeId: headEndpoint.worktreeId,
            repoId: headEndpoint.repoId,
            rootPath: URL(fileURLWithPath: "/tmp/bridge-refresh-admission"),
            paths: paths,
            timestamp: .now,
            batchSeq: batchSequence
        )
    }

    func currentCommittedReviewPublication() throws -> BridgeReviewCommittedPublication {
        try #require(
            controller.reviewPublicationCoordinator.committedPublicationForReplay(
                productAdmission: productAdmission
            )
        )
    }

    func consumeNextMetadataFrame() async throws -> BridgeProductMetadataFrame {
        guard
            let queuedFrame = await consumeNextBridgeProductProducerFrame(
                for: metadataProducerLease,
                from: productInstallation.session,
                productAdmission: productAdmission
            )
        else {
            throw RefreshAdmissionIntegrationError.expectedMetadataFrame
        }
        let decoder = try BridgeProductMetadataFrameDecoder()
        return try #require(try decoder.append(queuedFrame.data).first)
    }

    func openFileMetadataSubscription() async throws {
        let request = try refreshAdmissionFileSubscriptionOpenRequest(
            installation: productInstallation
        )
        let dispatcher = BridgeProductSchemeControlDispatcher(
            session: productInstallation.session,
            provider: productProvider,
            productAdmission: productAdmission
        )
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(
            productInstallation.capabilityBytes
        )
        guard
            case .response(let responseBytes) = try await dispatcher.dispatch(
                exactRequestBytes: try JSONEncoder().encode(request),
                presentedCapability: capabilityHeader
            ),
            case .subscriptionOpenAccepted = try BridgeProductStrictJSON.decode(
                BridgeProductControlResponse.self,
                from: responseBytes
            )
        else {
            throw RefreshAdmissionIntegrationError.fileSubscriptionDidNotOpen
        }
        guard case .subscriptionAccepted = try await consumeNextMetadataFrame() else {
            throw RefreshAdmissionIntegrationError.expectedSubscriptionAcceptedFrame
        }
    }

    func openReviewMetadataSubscription() async throws {
        let request = try refreshAdmissionReviewSubscriptionOpenRequest(
            installation: productInstallation
        )
        let dispatcher = BridgeProductSchemeControlDispatcher(
            session: productInstallation.session,
            provider: productProvider,
            productAdmission: productAdmission
        )
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(
            productInstallation.capabilityBytes
        )
        guard
            case .response(let responseBytes) = try await dispatcher.dispatch(
                exactRequestBytes: try JSONEncoder().encode(request),
                presentedCapability: capabilityHeader
            ),
            case .subscriptionOpenAccepted = try BridgeProductStrictJSON.decode(
                BridgeProductControlResponse.self,
                from: responseBytes
            )
        else {
            throw RefreshAdmissionIntegrationError.reviewSubscriptionDidNotOpen
        }
        guard case .subscriptionAccepted = try await consumeNextMetadataFrame() else {
            throw RefreshAdmissionIntegrationError.expectedSubscriptionAcceptedFrame
        }
    }

    func finish() async {
        _ = await controller.beginTeardown().value
    }
}

@MainActor
func makeRefreshAdmissionIntegrationFixture(
    comparisonGate: BridgeComparisonGate? = nil,
    failsChangesetPublication: Bool = false,
    failsReviewReservation: Bool = false,
    failsReviewDelivery: Bool = false,
    fileMetadataProducerGate: RefreshAdmissionCancellationIgnoringProducerGate? = nil,
    reviewMetadataReservationGate: RefreshAdmissionReviewReservationGate? = nil,
    reviewMetadataHeldPackageItemId: String? = nil,
    reviewMetadataReservationStep: HeldStep<Void>? = nil,
    reviewConstructionProgress: BridgeReviewConstructionProgressWaitOwner = .init(),
    reviewBuildAdmissionFactSink: BridgePaneReviewBuildAdmissionFactSink? = nil,
    telemetryRecorder: (any BridgePerformanceTraceRecording)? = nil,
    publicationLifecycleRecorder: (any BridgeProductMetadataLifecycleTraceRecording)? = nil,
    sessionDeadlineClock: (any Clock<Duration> & Sendable)? = nil,
    productSchemeProviderDecorator:
        (@MainActor (BridgePaneProductSchemeProvider, BridgeProductAdmissionGate) -> any BridgeProductSchemeProvider)? =
        nil,
    contributionTargetCommit:
        (@MainActor @Sendable (WorkspaceReviewContributionTarget) -> BridgePaneStateMutationResult)? = nil
) async throws -> RefreshAdmissionIntegrationFixture {
    let baseEndpoint = makeBridgeEndpoint(endpointId: "baseline-headMinusOne", kind: .gitRef)
    let headEndpoint = makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree)
    let refreshedFile = makeBridgeEndpointChangedFile(
        fileId: "refreshed",
        path: "Sources/App/Refreshed.swift",
        sizeBytes: 100
    )
    let reviewProvider = makeRefreshAdmissionInitialReviewProvider(
        baseEndpoint: baseEndpoint,
        headEndpoint: headEndpoint,
        comparisonGate: comparisonGate
    )
    let fileMetadataSource = RefreshAdmissionTrackingFileMetadataSource(
        failsChangesetPublication: failsChangesetPublication,
        metadataProducerGate: fileMetadataProducerGate
    )
    let reviewMetadataSource = RefreshAdmissionGatedReviewMetadataSource(
        failsReservation: failsReviewReservation,
        failsDelivery: failsReviewDelivery,
        reservationGate: reviewMetadataReservationGate,
        heldPackageItemId: reviewMetadataHeldPackageItemId,
        reservationStep: reviewMetadataReservationStep
    )
    let refreshWorkAdmission = BridgePaneRefreshWorkAdmissionTestContext.foregroundOnMainActor()
    let productProvider = makeRefreshAdmissionProductProvider(
        fileMetadataSource: fileMetadataSource,
        reviewMetadataSource: reviewMetadataSource,
        refreshWorkAdmissionSource: refreshWorkAdmission.source,
        lifecycleTraceRecorder: publicationLifecycleRecorder
    )
    let paneId = UUIDv7.generate()
    let productAdmissionGate = BridgeProductAdmissionGate()
    let productControlProvider =
        productSchemeProviderDecorator?(productProvider, productAdmissionGate)
        ?? productProvider
    let installation = try BridgeProductSessionInstallation.make(
        paneSessionId: paneId.uuidString,
        provider: productProvider,
        productAdmissionGate: productAdmissionGate,
        deadlineClock: sessionDeadlineClock
    )
    let controller = BridgePaneController(
        paneId: paneId,
        state: BridgePaneState(
            panelKind: .diffViewer,
            source: .workspace(
                rootPath: "/tmp/bridge-refresh-admission",
                baseline: .staged)
        ),
        appRootURL: testBridgeAppRootURL(),
        metadata: PaneMetadata(
            contentType: .diff,
            title: "Refresh admission",
            facets: PaneContextFacets(
                repoId: headEndpoint.repoId,
                worktreeId: headEndpoint.worktreeId,
                cwd: URL(fileURLWithPath: "/tmp/bridge-refresh-admission")
            )
        ),
        reviewSourceProvider: reviewProvider,
        telemetryRecorder: telemetryRecorder,
        initialPaneActivity: .dormant,
        productSessionDependencies: BridgePaneProductSessionDependencies(
            installation: installation,
            owner: BridgePaneController.makeProductSessionOwner(
                paneSessionId: paneId.uuidString,
                provider: productProvider,
                productAdmissionGate: productAdmissionGate,
                activeInstallation: installation
            ),
            productProvider: productProvider
        ),
        reviewConstructionProgress: reviewConstructionProgress,
        contributionTargetCommit: contributionTargetCommit,
        reviewBuildAdmissionFactSink: reviewBuildAdmissionFactSink ?? { _, _ in }
    )
    let productAdmission = try #require(installation.productAdapter.acquireAdmission())
    let metadataProducerLease = try await installRefreshAdmissionMetadataProducer(
        installation: installation,
        productProvider: productProvider,
        productAdmission: productAdmission
    )
    return RefreshAdmissionIntegrationFixture(
        baseEndpoint: baseEndpoint,
        headEndpoint: headEndpoint,
        refreshedComparison: BridgeEndpointComparison(
            baseEndpoint: baseEndpoint,
            headEndpoint: headEndpoint,
            changedFiles: [refreshedFile]
        ),
        reviewProvider: reviewProvider,
        fileMetadataSource: fileMetadataSource,
        metadataProducerLease: metadataProducerLease,
        productInstallation: installation,
        productAdmission: productAdmission,
        productProvider: productProvider,
        productControlProvider: productControlProvider,
        controller: controller
    )
}

@MainActor
private func makeRefreshAdmissionProductProvider(
    fileMetadataSource: RefreshAdmissionTrackingFileMetadataSource,
    reviewMetadataSource: RefreshAdmissionGatedReviewMetadataSource,
    refreshWorkAdmissionSource: BridgePaneRefreshWorkAdmissionSource,
    lifecycleTraceRecorder: (any BridgeProductMetadataLifecycleTraceRecording)?
) -> BridgePaneProductSchemeProvider {
    BridgePaneProductSchemeProvider(
        fileMetadataSource: fileMetadataSource,
        reviewMetadataSource: reviewMetadataSource,
        reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
        markReviewItemViewed: { _, _ in },
        refreshWorkAdmissionSource: refreshWorkAdmissionSource,
        lifecycleTraceRecorder: lifecycleTraceRecorder
    )
}

private func makeRefreshAdmissionInitialReviewProvider(
    baseEndpoint: BridgeSourceEndpoint,
    headEndpoint: BridgeSourceEndpoint,
    comparisonGate: BridgeComparisonGate?
) -> BridgeReviewSourceProviderFake {
    let initialFile = makeBridgeEndpointChangedFile(
        fileId: "initial", path: "Sources/App/Initial.swift", sizeBytes: 100)
    return BridgeReviewSourceProviderFake(
        comparison: BridgeEndpointComparison(
            baseEndpoint: baseEndpoint,
            headEndpoint: headEndpoint,
            changedFiles: [initialFile]
        ),
        contentByHandleId: [:],
        comparisonGate: comparisonGate
    )
}

actor RefreshAdmissionTrackingFileMetadataSource: BridgePaneProductFileMetadataProducing {
    func captureKeyedSnapshot(
        subscriptionId _: String,
        demand _: BridgePaneProductFileViewDemand,
        productAdmission _: BridgeProductAdmissionContext
    ) async -> BridgeWorktreeFileKeyedSnapshot? { nil }

    private let failsChangesetPublication: Bool
    private let metadataProducerGate: RefreshAdmissionCancellationIgnoringProducerGate?
    private var changesets: [FileChangeset] = []
    private var statuses: [GitWorkingTreeStatus] = []
    private var changesetPublishAttempts = 0
    private var changesetWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var statusWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    var changesetPublishCount: Int { changesets.count }
    var statusPublishCount: Int { statuses.count }
    var changesetPublishAttemptCount: Int { changesetPublishAttempts }

    init(
        failsChangesetPublication: Bool = false,
        metadataProducerGate: RefreshAdmissionCancellationIgnoringProducerGate? = nil
    ) {
        self.failsChangesetPublication = failsChangesetPublication
        self.metadataProducerGate = metadataProducerGate
    }

    func currentSource() -> BridgeProductFileSourceCurrentResult {
        .unavailable(.noFileSourceAuthority)
    }

    func open(
        subscription _: BridgeProductSubscriptionSnapshot,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission,
        emit _: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {
        await metadataProducerGate?.holdIgnoringCancellation()
    }

    func applyViewDemand(
        subscriptionId _: String,
        demand _: BridgePaneProductFileViewDemand,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission,
        forceRecapture _: Bool,
        emit _: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {}

    func cancel(subscriptionId _: String) {}

    func publish(
        status: GitWorkingTreeStatus,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) -> [BridgePaneProductFileMetadataEmission] {
        _ = foregroundWorkAdmission.withValidAdmission {
            statuses.append(status)
            resumeSatisfiedStatusWaiters()
        }
        return []
    }

    func publish(
        changeset: FileChangeset,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async throws -> [BridgePaneProductFileMetadataEmission] {
        changesetPublishAttempts += 1
        if failsChangesetPublication {
            throw RefreshAdmissionInjectedFileMetadataFailure.changesetPublication
        }
        _ = foregroundWorkAdmission.withValidAdmission {
            changesets.append(changeset)
            resumeSatisfiedChangesetWaiters()
        }
        return []
    }

    func authoritativePath(
        for _: BridgeProductFileContentRequest,
        productAdmission _: BridgeProductAdmissionContext
    ) -> String? { nil }

    func contentReadPlan(
        for _: BridgeProductFileContentRequest,
        productAdmission _: BridgeProductAdmissionContext
    ) -> BridgePaneProductFileContentReadPlan? { nil }

    func publishedChangesets() -> [FileChangeset] { changesets }
    func publishedStatuses() -> [GitWorkingTreeStatus] { statuses }

    func waitForChangesetPublishCount(_ expectedCount: Int) async {
        guard changesets.count < expectedCount else { return }
        await withCheckedContinuation { continuation in
            changesetWaiters.append((expectedCount, continuation))
        }
    }

    func waitForStatusPublishCount(_ expectedCount: Int) async {
        guard statuses.count < expectedCount else { return }
        await withCheckedContinuation { continuation in
            statusWaiters.append((expectedCount, continuation))
        }
    }

    private func resumeSatisfiedChangesetWaiters() {
        var pendingWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        for (expectedCount, continuation) in changesetWaiters {
            if changesets.count >= expectedCount {
                continuation.resume()
            } else {
                pendingWaiters.append((expectedCount, continuation))
            }
        }
        changesetWaiters = pendingWaiters
    }

    private func resumeSatisfiedStatusWaiters() {
        var pendingWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        for (expectedCount, continuation) in statusWaiters {
            if statuses.count >= expectedCount {
                continuation.resume()
            } else {
                pendingWaiters.append((expectedCount, continuation))
            }
        }
        statusWaiters = pendingWaiters
    }
}

final class RefreshAdmissionCancellationIgnoringProducerGate: @unchecked Sendable {
    private struct State {
        var cancellationRequested = false
        var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
        var isReleased = false
        var releaseContinuations: [CheckedContinuation<Void, Never>] = []
        var started = false
        var startWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let lock = NSLock()
    private var state = State()

    func holdIgnoringCancellation() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let outcome = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
                    state.started = true
                    let startWaiters = state.startWaiters
                    state.startWaiters.removeAll()
                    if state.isReleased {
                        return (true, startWaiters)
                    }
                    state.releaseContinuations.append(continuation)
                    return (false, startWaiters)
                }
                for waiter in outcome.1 { waiter.resume() }
                if outcome.0 { continuation.resume() }
            }
        } onCancel: {
            self.recordCancellationRequest()
        }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard !state.started else { return true }
                state.startWaiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func waitUntilCancellationRequested() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard !state.cancellationRequested else { return true }
                state.cancellationWaiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func releaseAll() {
        let continuations = lock.withLock {
            state.isReleased = true
            let continuations = state.releaseContinuations
            state.releaseContinuations.removeAll()
            return continuations
        }
        for continuation in continuations { continuation.resume() }
    }

    private func recordCancellationRequest() {
        let waiters = lock.withLock {
            state.cancellationRequested = true
            let waiters = state.cancellationWaiters
            state.cancellationWaiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

actor RefreshAdmissionReviewReservationGate {
    private struct StartedWaiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var heldReservationCount = 0
    private var isEnabled = false
    private var isReleased = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var startedWaiters: [StartedWaiter] = []

    func enable() {
        isEnabled = true
    }

    func holdIfEnabled() async {
        guard isEnabled else { return }
        heldReservationCount += 1
        resumeSatisfiedStartedWaiters()
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func waitForHeldReservationCount(_ expectedCount: Int) async {
        guard heldReservationCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(
                StartedWaiter(expectedCount: expectedCount, continuation: continuation)
            )
        }
    }

    func releaseAll() {
        isReleased = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    private func resumeSatisfiedStartedWaiters() {
        var pendingWaiters: [StartedWaiter] = []
        for waiter in startedWaiters {
            if heldReservationCount >= waiter.expectedCount {
                waiter.continuation.resume()
            } else {
                pendingWaiters.append(waiter)
            }
        }
        startedWaiters = pendingWaiters
    }
}

private actor RefreshAdmissionGatedReviewMetadataSource: BridgePaneProductReviewMetadataProducing {
    private let failsReservation: Bool
    private let failsDelivery: Bool
    private let reservationGate: RefreshAdmissionReviewReservationGate?
    private let heldPackageItemId: String?
    private let reservationStep: HeldStep<Void>?
    private let source = BridgePaneProductReviewMetadataSource()

    init(
        failsReservation: Bool,
        failsDelivery: Bool,
        reservationGate: RefreshAdmissionReviewReservationGate?,
        heldPackageItemId: String?,
        reservationStep: HeldStep<Void>?
    ) {
        self.failsReservation = failsReservation
        self.failsDelivery = failsDelivery
        self.reservationGate = reservationGate
        self.heldPackageItemId = heldPackageItemId
        self.reservationStep = reservationStep
    }

    func open(
        subscription: BridgeProductSubscriptionSnapshot,
        productAdmission: BridgeProductAdmissionContext
    ) async throws {
        try await source.open(
            subscription: subscription,
            productAdmission: productAdmission
        )
    }

    func applyViewDemand(_ request: BridgePaneProductReviewViewDemandRequest) async throws
        -> BridgePaneProductReviewViewCapture?
    {
        try await source.applyViewDemand(request)
    }

    func reserve(
        package: BridgeReviewPackage,
        publicationId: UUID,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> BridgeReviewMetadataPublicationReservation {
        await reservationGate?.holdIfEnabled()
        if heldPackageItemId == nil || package.itemsById[heldPackageItemId ?? ""] != nil {
            try await reservationStep?.arrive(())
        }
        if failsReservation {
            throw BridgePaneProductReviewMetadataSourceError.metadataEventExceedsByteLimit
        }
        return try await source.reserve(
            package: package,
            publicationId: publicationId,
            productAdmission: productAdmission
        )
    }

    func deliver(
        publication: BridgeReviewCommittedPublication,
        reservation: BridgeReviewMetadataPublicationReservation,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> BridgePaneProductReviewMetadataPublicationOutcome {
        if failsDelivery {
            throw RefreshAdmissionInjectedReviewMetadataFailure.delivery
        }
        return try await source.deliver(
            publication: publication,
            reservation: reservation,
            productAdmission: productAdmission
        )
    }

    func cancel(subscriptionId: String) async {
        await source.cancel(subscriptionId: subscriptionId)
    }
}

private enum RefreshAdmissionInjectedFileMetadataFailure: Error {
    case changesetPublication
}

private enum RefreshAdmissionInjectedReviewMetadataFailure: Error {
    case delivery
}

private enum RefreshAdmissionIntegrationError: Error {
    case expectedMetadataProducerRegistration
    case expectedMetadataFrame
    case expectedMetadataStreamAcceptance
    case expectedSubscriptionAcceptedFrame
    case expectedWorkerSessionExecution
    case fileSubscriptionDidNotOpen
    case reviewSubscriptionDidNotOpen
}

private func installRefreshAdmissionMetadataProducer(
    installation: BridgeProductSessionInstallation,
    productProvider: BridgePaneProductSchemeProvider,
    productAdmission: BridgeProductAdmissionContext
) async throws -> BridgeProductProducerLease {
    let workerOpenRequest = try refreshAdmissionControlRequest([
        "kind": "workerSession.open",
        "paneSessionId": installation.bootstrap.paneSessionId,
        "request": NSNull(),
        "requestId": "request-open-refresh-admission",
        "requestSequence": 1,
        "wireVersion": BridgeProductWireContract.version,
        "workerInstanceId": installation.bootstrap.workerInstanceId,
    ])
    let workerOpenAdmission = await installation.session.beginControl(
        exactRequestBytes: try JSONEncoder().encode(workerOpenRequest),
        presentedCapability: try BridgeProductCapabilityHeaderEncoding.encode(
            installation.capabilityBytes
        ),
        productAdmission: productAdmission
    )
    guard case .execute(let workerOpenToken, _) = workerOpenAdmission else {
        throw RefreshAdmissionIntegrationError.expectedWorkerSessionExecution
    }
    _ = try await installation.session.completeAdmittedControl(
        token: workerOpenToken,
        exactResponseBytes: try JSONEncoder().encode(
            BridgeProductControlResponse.workerSessionAccepted(correlating: workerOpenRequest)
        )
    )

    let metadataRequest = try refreshAdmissionMetadataRequest(installation: installation)
    let registration = await installation.session.registerMetadataProducer(
        request: metadataRequest,
        productAdmission: productAdmission
    ) { lease in
        await productProvider.runMetadataProducer(
            request: metadataRequest,
            lease: lease,
            productAdmission: productAdmission,
            session: installation.session
        )
    }
    guard case .accepted(let lease) = registration else {
        throw RefreshAdmissionIntegrationError.expectedMetadataProducerRegistration
    }
    guard
        let acceptedStreamFrame = await consumeNextBridgeProductProducerFrame(
            for: lease,
            from: installation.session,
            productAdmission: productAdmission
        )
    else {
        throw RefreshAdmissionIntegrationError.expectedMetadataFrame
    }
    let frameDecoder = try BridgeProductMetadataFrameDecoder()
    guard
        let initialFrame = try frameDecoder.append(acceptedStreamFrame.data).first,
        case .metadataStreamAccepted = initialFrame
    else {
        throw RefreshAdmissionIntegrationError.expectedMetadataStreamAcceptance
    }
    return lease
}

private func refreshAdmissionControlRequest(
    _ object: [String: Any]
) throws -> BridgeProductControlRequest {
    try BridgeProductStrictJSON.decode(
        BridgeProductControlRequest.self,
        from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
}

private func refreshAdmissionMetadataRequest(
    installation: BridgeProductSessionInstallation
) throws -> BridgeProductMetadataStreamRequest {
    try BridgeProductStrictJSON.decode(
        BridgeProductMetadataStreamRequest.self,
        from: JSONSerialization.data(
            withJSONObject: [
                "kind": "metadataStream.open",
                "metadataStreamId": "metadata-refresh-admission",
                "paneSessionId": installation.bootstrap.paneSessionId,
                "resumeFromStreamSequence": NSNull(),
                "wireVersion": BridgeProductWireContract.version,
                "workerInstanceId": installation.bootstrap.workerInstanceId,
            ],
            options: [.sortedKeys]
        )
    )
}

private func refreshAdmissionFileSubscriptionOpenRequest(
    installation: BridgeProductSessionInstallation
) throws -> BridgeProductControlRequest {
    try refreshAdmissionControlRequest([
        "kind": "subscription.open",
        "paneSessionId": installation.bootstrap.paneSessionId,
        "requestId": "request-file-open-refresh-admission",
        "requestSequence": 2,
        "subscription": [
            "source": [
                "cwdScope": NSNull(),
                "freshness": "live",
                "includeStatuses": true,
                "repoId": "00000000-0000-4000-8000-000000000001",
                "rootPathToken": "root-token-refresh-admission",
                "worktreeId": "00000000-0000-4000-8000-000000000002",
            ],
            "subscriptionKind": "file.metadata",
        ],
        "subscriptionId": "file-subscription-refresh-admission",
        "wireVersion": BridgeProductWireContract.version,
        "workerDerivationEpoch": 1,
        "workerInstanceId": installation.bootstrap.workerInstanceId,
    ])
}

private func refreshAdmissionReviewSubscriptionOpenRequest(
    installation: BridgeProductSessionInstallation
) throws -> BridgeProductControlRequest {
    try refreshAdmissionControlRequest([
        "kind": "subscription.open",
        "paneSessionId": installation.bootstrap.paneSessionId,
        "requestId": "request-review-open-refresh-admission",
        "requestSequence": 3,
        "subscription": ["subscriptionKind": "review.metadata"],
        "subscriptionId": "review-subscription-refresh-admission",
        "wireVersion": BridgeProductWireContract.version,
        "workerDerivationEpoch": 1,
        "workerInstanceId": installation.bootstrap.workerInstanceId,
    ])
}

func refreshAdmissionFileSourceAcceptedEvent() throws -> BridgePaneProductFileSourceFact {
    .sourceAccepted(
        try .init(
            repoId: "00000000-0000-4000-8000-000000000001",
            rootRevisionToken: "root-token-refresh-admission",
            sourceCursor: "source-cursor-refresh-admission",
            sourceId: "file-source-refresh-admission",
            subscriptionGeneration: 1,
            worktreeId: "00000000-0000-4000-8000-000000000002"
        ))
}

func waitForRefreshAdmissionQueuedMetadataFrame(
    _ fixture: RefreshAdmissionIntegrationFixture,
    maxTurns: Int = 200
) async -> Bool {
    for _ in 0..<maxTurns {
        if await fixture.productInstallation.session.producerSnapshot().queuedFrameCount > 0 {
            return true
        }
        await Task.yield()
    }
    return false
}

@MainActor
func waitForRefreshAdmissionIdle(
    _ controller: BridgePaneController,
    maxTurns: Int = 2000
) async {
    for _ in 0..<maxTurns {
        let snapshot = controller.refreshAdmissionCoordinator.diagnosticSnapshot
        if snapshot.activeRefreshPass == nil, snapshot.dirtyFact == nil {
            return
        }
        await Task.yield()
    }
    Issue.record("Expected foreground Bridge refresh admission to become idle")
}

@MainActor
func waitForActiveReviewRefreshTaskToFinish(
    _ controller: BridgePaneController,
    maxTurns: Int = 2000
) async {
    for _ in 0..<maxTurns {
        if controller.activeReviewRefreshTask == nil {
            return
        }
        await Task.yield()
    }
    Issue.record("Expected active Bridge Review refresh task to finish")
}

@MainActor
func waitForRefreshAdmissionSettledWhileHidden(
    _ controller: BridgePaneController,
    maxTurns: Int = 2000
) async {
    for _ in 0..<maxTurns {
        let snapshot = controller.refreshAdmissionCoordinator.diagnosticSnapshot
        if snapshot.activity == .loadedHidden,
            snapshot.activeRefreshPass == nil,
            snapshot.dirtyFact != nil,
            controller.activeReviewRefreshTask == nil
        {
            return
        }
        await Task.yield()
    }
    Issue.record("Expected loaded-hidden Bridge refresh admission to retain one dirty fact")
}

func makeRefreshAdmissionStatus(
    branch: String,
    changed: Int
) -> GitWorkingTreeStatus {
    GitWorkingTreeStatus(
        summary: GitWorkingTreeSummary(
            changed: changed,
            staged: 0,
            untracked: 0
        ),
        branch: branch,
        origin: nil
    )
}
