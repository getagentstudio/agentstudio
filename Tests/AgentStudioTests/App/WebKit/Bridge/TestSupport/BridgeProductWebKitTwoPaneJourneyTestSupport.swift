import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import AppKit
import Foundation
import Testing
import WebKit

@testable import AgentStudioBridge

struct BridgeProductWebKitTwoPanePositionSnapshot: Decodable, Equatable, Sendable {
    let activeMode: String?
    let comparisonStatusText: String?
    let fileCodeScrollTop: Double
    let fileRenderedPath: String?
    let fileSelectedPath: String?
    let fileStatusText: String?
    let fileTreePresentationState: String?
    let fileTreeScrollTop: Double
    let hasAppRoot: Bool
    let reviewCodeScrollTop: Double
    let reviewCollapsedDirectoryExpansion: String?
    let reviewSelectedItemId: String?
    let reviewSelectedPath: String?
    let reviewStatusText: String?
    let reviewTreeScrollTop: Double
}

struct BridgeProductWebKitTwoPaneJourneyProof: Sendable {
    let dormantDefaults: BridgeProductWebKitTwoPanePositionSnapshot
    let fileStateAfterReturn: BridgeProductWebKitTwoPanePositionSnapshot
    let hiddenDirtyGeneration: UInt64?
    let hiddenMetadataStormDiagnostic: String
    let hiddenRefreshPassCountAfterStorm: Int
    let hiddenRefreshPassCountBeforeStorm: Int
    let hiddenReviewPublicationCountAfterLateRelease: Int
    let hiddenReviewPublicationCountBeforeLateRelease: Int
    let hiddenStatus: BridgeProductWebKitTwoPanePositionSnapshot
    let hiddenStormProductDeltas: BridgeProductWebKitHiddenStormProductDeltas
    let initialReviewState: BridgeProductWebKitTwoPanePositionSnapshot
    let paneOneFinalRefreshPassCount: Int
    let paneOneForegroundRefreshPassCount: Int
    let paneOneWorkerIdAfterReturn: String?
    let paneOneWorkerIdBeforeHide: String?
    let paneOneWorkerReplacementFacts: String
    let paneTwoActivityAfterJourney: BridgePaneActivity
    let paneTwoStateAfterJourney: BridgeProductWebKitTwoPanePositionSnapshot
    let paneTwoStateBeforeJourney: BridgeProductWebKitTwoPanePositionSnapshot
    let paneTwoWorkerIdAfterJourney: String?
    let paneTwoWorkerIdBeforeJourney: String?
    let paneTwoWorkerReplacementFacts: String
    let reviewStateAfterReturn: BridgeProductWebKitTwoPanePositionSnapshot
    let staleForegroundAdmissionWasRejected: Bool
    let updatingFileStatus: BridgeProductWebKitTwoPanePositionSnapshot
    let updatingReviewStatus: BridgeProductWebKitTwoPanePositionSnapshot
}

private actor BridgeProductWebKitGatedReviewSourceProvider: BridgeReviewSourceProvider {
    private let base: any BridgeReviewSourceProvider
    private var blockedComparisonCount = 0
    private var comparisonCount = 0
    private var isNextComparisonArmed = false
    private var blockedSteps: [HeldStep<Void>] = []
    private var blockedCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(base: any BridgeReviewSourceProvider) {
        self.base = base
    }

    func resolveReviewDefaultTarget() async throws -> BridgeReviewComparisonDefaultTargetIdentity? {
        try await base.resolveReviewDefaultTarget()
    }

    func captureReviewComparisonTargets(
        _ request: BridgeReviewComparisonTargetsCaptureRequest
    ) async throws -> BridgeReviewComparisonTargetsCapture {
        try await base.captureReviewComparisonTargets(request)
    }

    func captureContributionComparison(_ request: BridgeContributionComparisonRequest) async throws
        -> BridgeContributionComparisonCapture
    {
        await recordAndBlockComparisonIfArmed()
        return try await base.captureContributionComparison(request)
    }

    func armNextComparison() {
        isNextComparisonArmed = true
    }

    func releaseBlockedComparisons() {
        let steps = blockedSteps
        blockedSteps.removeAll()
        for step in steps { step.release() }
    }

    func snapshot() -> (comparisonCount: Int, blockedComparisonCount: Int) {
        (comparisonCount, blockedComparisonCount)
    }

    func waitForBlockedComparisonCount(_ count: Int) async -> Int {
        if blockedComparisonCount < count {
            await withCheckedContinuation { continuation in
                blockedCountWaiters.append((count: count, continuation: continuation))
            }
        }
        return blockedComparisonCount
    }

    func resolveEndpoint(_ request: BridgeEndpointResolutionRequest) async throws
        -> BridgeSourceEndpoint
    {
        try await base.resolveEndpoint(request)
    }

    func compareEndpoints(_ request: BridgeEndpointComparisonRequest) async throws
        -> BridgeEndpointComparison
    {
        await recordAndBlockComparisonIfArmed()
        return try await base.compareEndpoints(request)
    }

    private func recordAndBlockComparisonIfArmed() async {
        comparisonCount += 1
        if isNextComparisonArmed {
            isNextComparisonArmed = false
            blockedComparisonCount += 1
            let readyWaiters = blockedCountWaiters.filter { blockedComparisonCount >= $0.count }
            blockedCountWaiters.removeAll { blockedComparisonCount >= $0.count }
            for waiter in readyWaiters { waiter.continuation.resume() }
            let step = HeldStep<Void>("blocked review comparison", cancellation: .holdThroughCancellation)
            blockedSteps.append(step)
            try? await step.arrive(())
        }
    }

    func readTree(_ request: BridgeTreeReadRequest) async throws -> BridgeTreeReadResult {
        try await base.readTree(request)
    }

    func readReviewItemDescriptor(_ request: BridgeReviewItemDescriptorRequest) async throws
        -> BridgeReviewItemDescriptor
    {
        try await base.readReviewItemDescriptor(request)
    }

    func resolveCheckpointEndpoint(_ request: BridgeCheckpointEndpointRequest) async throws
        -> BridgeSourceEndpoint
    {
        try await base.resolveCheckpointEndpoint(request)
    }

    func loadContent(_ request: BridgeContentLoadRequest) async throws -> BridgeContentLoadResult {
        try await base.loadContent(request)
    }

    func streamContent(
        _ request: BridgeContentStreamRequest,
        chunkByteCount: Int,
        emitChunk: BridgeContentStreamEmitter
    ) async throws -> BridgeContentStreamResult {
        try await base.streamContent(request, chunkByteCount: chunkByteCount, emitChunk: emitChunk)
    }
}

@MainActor
enum BridgeProductWebKitTwoPaneJourneyTestSupport {
    private struct ControllerInput {
        let gitReadContext: BridgeGitReadContext
        let initialActivity: BridgePaneActivity
        let gitWorkingTreeStatusProvider: any GitWorkingTreeStatusProvider
        let repoURL: URL
        let reviewProvider: any BridgeReviewSourceProvider
        let title: String
        let traceRecorder: BridgeProductWebKitCarrierTraceRecorder
        let worktreeProductConstructionCoordinator: BridgeWorktreeProductConstructionCoordinator
    }

    private struct JourneyInput {
        let paneOne: BridgePaneController
        let paneOneGitStatusProvider: BridgeProductWebKitGatedGitStatusProvider
        let paneOneRepoURL: URL
        let paneOneReviewProvider: BridgeProductWebKitGatedReviewSourceProvider
        let paneOneTrace: BridgeProductWebKitCarrierTraceRecorder
        let paneTwo: BridgePaneController
        let paneTwoReviewProvider: BridgeProductWebKitGatedReviewSourceProvider
        let paneTwoTrace: BridgeProductWebKitCarrierTraceRecorder
    }

    private struct JourneyPreparation {
        let dormantDefaults: BridgeProductWebKitTwoPanePositionSnapshot
        let initialReviewState: BridgeProductWebKitTwoPanePositionSnapshot
        let paneOneNativeBeforeHide: BridgeProductWebKitCarrierNativeSnapshot
        let paneTwoNativeBeforeJourney: BridgeProductWebKitCarrierNativeSnapshot
        let paneTwoStateBeforeJourney: BridgeProductWebKitTwoPanePositionSnapshot
        let staleForegroundAdmission: BridgePaneRefreshWorkAdmission?
    }

    private struct JourneyUpdatingState {
        let foregroundRefreshPassCount: Int
        let fileStatus: BridgeProductWebKitTwoPanePositionSnapshot
        let reviewStatus: BridgeProductWebKitTwoPanePositionSnapshot
    }

    private static let filePositionPath = "Sources/Group00/large-position.txt"
    private static var retainedPages: [WebPage] = []

    static func run() async throws -> BridgeProductWebKitTwoPaneJourneyProof {
        let paneOneRepoURL = try await FilesystemTestGitRepo.create(named: "bridge-two-pane-one-webkit")
        let paneTwoRepoURL = try await FilesystemTestGitRepo.create(named: "bridge-two-pane-two-webkit")
        defer {
            FilesystemTestGitRepo.destroy(paneOneRepoURL)
            FilesystemTestGitRepo.destroy(paneTwoRepoURL)
        }
        try await seedPositionFixture(at: paneOneRepoURL, prefix: "pane-one")
        try await seedPositionFixture(at: paneTwoRepoURL, prefix: "pane-two")

        let paneOneTrace = BridgeProductWebKitCarrierTraceRecorder()
        let paneTwoTrace = BridgeProductWebKitCarrierTraceRecorder()
        let worktreeProductConstructionCoordinator =
            BridgeWorktreeProductConstructionCoordinator()
        let gitWorkingTreeStatusProvider = AgentStudioGitWorkingTreeStatusProvider(
            physicalGate: AgentStudioGitStatusPhysicalGate()
        )
        let paneOneGitStatusProvider = BridgeProductWebKitGatedGitStatusProvider(
            base: gitWorkingTreeStatusProvider
        )
        let paneOneGitReadContext = makeBridgeGitReadContext(rootURL: paneOneRepoURL)
        let paneTwoGitReadContext = makeBridgeGitReadContext(rootURL: paneTwoRepoURL)
        let paneOneReviewProvider = BridgeProductWebKitGatedReviewSourceProvider(
            base: BridgeReviewSourceProviderFactory.gitProvider(
                repositoryPath: paneOneRepoURL,
                gitReadContext: paneOneGitReadContext
            )
        )
        let paneTwoReviewProvider = BridgeProductWebKitGatedReviewSourceProvider(
            base: BridgeReviewSourceProviderFactory.gitProvider(
                repositoryPath: paneTwoRepoURL,
                gitReadContext: paneTwoGitReadContext
            )
        )
        let paneOne = makeController(
            ControllerInput(
                gitReadContext: paneOneGitReadContext,
                initialActivity: .foreground,
                gitWorkingTreeStatusProvider: paneOneGitStatusProvider,
                repoURL: paneOneRepoURL,
                reviewProvider: paneOneReviewProvider,
                title: "Hosted Pane One",
                traceRecorder: paneOneTrace,
                worktreeProductConstructionCoordinator: worktreeProductConstructionCoordinator
            )
        )
        let paneTwo = makeController(
            ControllerInput(
                gitReadContext: paneTwoGitReadContext,
                initialActivity: .dormant,
                gitWorkingTreeStatusProvider: gitWorkingTreeStatusProvider,
                repoURL: paneTwoRepoURL,
                reviewProvider: paneTwoReviewProvider,
                title: "Hosted Pane Two",
                traceRecorder: paneTwoTrace,
                worktreeProductConstructionCoordinator: worktreeProductConstructionCoordinator
            )
        )

        return try await withHostedControllers([paneOne, paneTwo]) {
            try await exerciseJourney(
                JourneyInput(
                    paneOne: paneOne,
                    paneOneGitStatusProvider: paneOneGitStatusProvider,
                    paneOneRepoURL: paneOneRepoURL,
                    paneOneReviewProvider: paneOneReviewProvider,
                    paneOneTrace: paneOneTrace,
                    paneTwo: paneTwo,
                    paneTwoReviewProvider: paneTwoReviewProvider,
                    paneTwoTrace: paneTwoTrace
                )
            )
        }
    }

    private static func prepareJourney(_ input: JourneyInput) async throws -> JourneyPreparation {
        input.paneOne.loadApp()
        input.paneTwo.loadApp()
        try await requireMountedApp(input.paneOne)
        try await requireMountedApp(input.paneTwo)

        let dormantDefaults = try await requirePositionSnapshot(input.paneTwo.page)
        let dormantNative = await BridgeProductWebKitCarrierTestSupport.nativeSnapshot(input.paneTwo)
        guard dormantNative.lifecycle == "active" else {
            throw JourneyError.conditionFailed("pane two dormant worker did not open")
        }
        guard input.paneTwo.refreshAdmissionCoordinator.diagnosticSnapshot.refreshPassCount == 0
        else {
            throw JourneyError.conditionFailed("fresh dormant pane started a refresh pass")
        }

        let paneTwoForegroundTransition = input.paneTwo.applyBridgePaneActivity(.foreground)
        await paneTwoForegroundTransition?.value
        try await requireReadyReview(
            input.paneOne,
            paneLabel: "pane one",
            reviewProvider: input.paneOneReviewProvider,
            traceRecorder: input.paneOneTrace
        )
        try await requireReadyReview(
            input.paneTwo,
            paneLabel: "pane two",
            reviewProvider: input.paneTwoReviewProvider,
            traceRecorder: input.paneTwoTrace
        )

        let initialReviewState = try await requirePositionSnapshot(input.paneOne.page)
        try await activateReadyFileMode(input.paneOne, failure: "pane one File mode did not activate")
        guard await activateReviewMode(input.paneOne.page) else {
            throw JourneyError.conditionFailed("pane one Review mode did not reactivate")
        }
        try await requireReadyReview(
            input.paneOne,
            paneLabel: "pane one after mode round-trip",
            reviewProvider: input.paneOneReviewProvider,
            traceRecorder: input.paneOneTrace
        )

        return JourneyPreparation(
            dormantDefaults: dormantDefaults,
            initialReviewState: initialReviewState,
            paneOneNativeBeforeHide:
                await BridgeProductWebKitCarrierTestSupport.nativeSnapshot(input.paneOne),
            paneTwoNativeBeforeJourney:
                await BridgeProductWebKitCarrierTestSupport.nativeSnapshot(input.paneTwo),
            paneTwoStateBeforeJourney: try await requirePositionSnapshot(input.paneTwo.page),
            staleForegroundAdmission:
                input.paneOne.refreshAdmissionCoordinator.acquireForegroundWork()
        )
    }

    private static func exerciseJourney(
        _ input: JourneyInput
    ) async throws -> BridgeProductWebKitTwoPaneJourneyProof {
        do {
            let proof = try await exercisePreparedJourney(input)
            try await input.paneOneTrace.finishForegroundCatchUp()
            return proof
        } catch {
            await input.paneOneReviewProvider.releaseBlockedComparisons()
            await input.paneOneGitStatusProvider.releaseBlockedStatusRead()
            try await input.paneOneTrace.finishForegroundCatchUp()
            throw error
        }
    }

    private static func exercisePreparedJourney(
        _ input: JourneyInput
    ) async throws -> BridgeProductWebKitTwoPaneJourneyProof {
        let preparation = try await prepareJourney(input)
        let updatingState = try await beginBlockedRefresh(input)

        let hiddenTransition = input.paneOne.applyBridgePaneActivity(.loadedHidden)
        await hiddenTransition?.value
        try await requireHiddenFileRetirementBoundary(input.paneOne)
        let hiddenStatus = try await requireNoUpdatingStatus(input.paneOne.page)
        let staleForegroundAdmissionWasRejected =
            preparation.staleForegroundAdmission?.withValidAdmission { true } == nil
        let hiddenBeforeStorm = input.paneOne.refreshAdmissionCoordinator.diagnosticSnapshot
        let hiddenNativeBeforeStorm =
            await BridgeProductWebKitCarrierTestSupport.nativeSnapshot(input.paneOne)
        let hiddenTraceBeforeLateRelease = await input.paneOneTrace.scrubbedTrace()
        let hiddenComparisonCountBeforeStorm =
            await input.paneOneReviewProvider.snapshot().comparisonCount

        try await publishHiddenFileStorm(input.paneOne)
        let hiddenAfterStorm = input.paneOne.refreshAdmissionCoordinator.diagnosticSnapshot
        let hiddenNativeAfterStorm =
            await BridgeProductWebKitCarrierTestSupport.nativeSnapshot(input.paneOne)
        let hiddenTraceAfterStorm = await input.paneOneTrace.scrubbedTrace()
        guard
            await input.paneOneReviewProvider.snapshot().comparisonCount
                == hiddenComparisonCountBeforeStorm
        else {
            throw JourneyError.conditionFailed("loaded-hidden invalidation started Review work")
        }

        await input.paneOneReviewProvider.releaseBlockedComparisons()
        try await requireHiddenRefreshSettled(input.paneOne)
        let hiddenTraceAfterLateRelease = await input.paneOneTrace.scrubbedTrace()
        let catchUpTerminal = await input.paneOneTrace.prepareForegroundCatchUp(
            dirtyFact: input.paneOne.refreshAdmissionCoordinator.diagnosticSnapshot.dirtyFact
        )
        let paneOneForegroundTransition = input.paneOne.applyBridgePaneActivity(.foreground)
        await paneOneForegroundTransition?.value
        try await requireRefreshIdle(input.paneOne, terminalExpectation: catchUpTerminal)
        try await requireReadyReview(
            input.paneOne,
            paneLabel: "pane one after foreground return",
            reviewProvider: input.paneOneReviewProvider,
            traceRecorder: input.paneOneTrace
        )
        let reviewStateAfterReturn = try await requirePositionSnapshot(input.paneOne.page)
        try await activateReadyFileMode(
            input.paneOne,
            failure: "File mode did not reactivate after foreground return"
        )
        let fileStateAfterReturn = try await requirePositionSnapshot(input.paneOne.page)
        let paneOneNativeAfterReturn =
            await BridgeProductWebKitCarrierTestSupport.nativeSnapshot(input.paneOne)
        let paneTwoNativeAfterJourney =
            await BridgeProductWebKitCarrierTestSupport.nativeSnapshot(input.paneTwo)
        let paneTwoStateAfterJourney = try await requirePositionSnapshot(input.paneTwo.page)
        // One reading of the hidden-pane traces feeds both the assertable product
        // deltas and the printed diagnostic, so the two can never disagree.
        let hiddenStorm = BridgeProductWebKitMetadataStormDiagnostic.summarize(
            nativeBefore: hiddenNativeBeforeStorm,
            nativeAfter: hiddenNativeAfterStorm,
            traceBefore: hiddenTraceBeforeLateRelease,
            traceAfter: hiddenTraceAfterStorm
        )

        return BridgeProductWebKitTwoPaneJourneyProof(
            dormantDefaults: preparation.dormantDefaults,
            fileStateAfterReturn: fileStateAfterReturn,
            hiddenDirtyGeneration: hiddenAfterStorm.dirtyFact?.generation,
            hiddenMetadataStormDiagnostic: hiddenStorm.message,
            hiddenRefreshPassCountAfterStorm: hiddenAfterStorm.refreshPassCount,
            hiddenRefreshPassCountBeforeStorm: hiddenBeforeStorm.refreshPassCount,
            hiddenReviewPublicationCountAfterLateRelease:
                hiddenTraceAfterLateRelease.completedReviewPublicationCount,
            hiddenReviewPublicationCountBeforeLateRelease:
                hiddenTraceBeforeLateRelease.completedReviewPublicationCount,
            hiddenStatus: hiddenStatus,
            hiddenStormProductDeltas: hiddenStorm.productDeltas,
            initialReviewState: preparation.initialReviewState,
            paneOneFinalRefreshPassCount:
                input.paneOne.refreshAdmissionCoordinator.diagnosticSnapshot.refreshPassCount,
            paneOneForegroundRefreshPassCount: updatingState.foregroundRefreshPassCount,
            paneOneWorkerIdAfterReturn: paneOneNativeAfterReturn.workerInstanceId,
            paneOneWorkerIdBeforeHide: preparation.paneOneNativeBeforeHide.workerInstanceId,
            paneOneWorkerReplacementFacts:
                await BridgeProductWebKitReplacementFactTestSupport.read(input.paneOne.page),
            paneTwoActivityAfterJourney:
                input.paneTwo.refreshAdmissionCoordinator.diagnosticSnapshot.activity,
            paneTwoStateAfterJourney: paneTwoStateAfterJourney,
            paneTwoStateBeforeJourney: preparation.paneTwoStateBeforeJourney,
            paneTwoWorkerIdAfterJourney: paneTwoNativeAfterJourney.workerInstanceId,
            paneTwoWorkerIdBeforeJourney: preparation.paneTwoNativeBeforeJourney.workerInstanceId,
            paneTwoWorkerReplacementFacts:
                await BridgeProductWebKitReplacementFactTestSupport.read(input.paneTwo.page),
            reviewStateAfterReturn: reviewStateAfterReturn,
            staleForegroundAdmissionWasRejected: staleForegroundAdmissionWasRejected,
            updatingFileStatus: updatingState.fileStatus,
            updatingReviewStatus: updatingState.reviewStatus
        )
    }

    private static func publishHiddenFileStorm(_ controller: BridgePaneController) async throws {
        for batchSequence in [UInt64(702), 703] {
            await controller.handleWorktreeProductInvalidation(
                .filesChanged(
                    try makeChangeset(
                        for: controller,
                        paths: ["tracked.txt"],
                        batchSequence: batchSequence
                    )
                )
            )
        }
    }

    private static func beginBlockedRefresh(
        _ input: JourneyInput
    ) async throws -> JourneyUpdatingState {
        await input.paneOneReviewProvider.armNextComparison()
        try appendTrackedChange(at: input.paneOneRepoURL)
        await input.paneOne.handleWorktreeProductInvalidation(
            .filesChanged(
                try makeChangeset(
                    for: input.paneOne,
                    paths: ["tracked.txt"],
                    batchSequence: 701
                )
            )
        )
        try await requireBlockedComparison(input.paneOneReviewProvider, expectedCount: 1)
        let paneOneForegroundRefreshPassCount =
            input.paneOne.refreshAdmissionCoordinator.diagnosticSnapshot.refreshPassCount
        let updatingReviewStatus = try await requireNoUpdatingStatus(input.paneOne.page)
        guard updatingReviewStatus.activeMode == "review" else {
            let observedActiveMode = updatingReviewStatus.activeMode ?? "nil"
            throw JourneyError.conditionFailed(
                "ordinary Review refresh changed the active surface "
                    + "(observedActiveMode: \(observedActiveMode))"
            )
        }
        try await activateReadyFileMode(
            input.paneOne,
            failure: "File mode did not activate during refresh"
        )
        await input.paneOneGitStatusProvider.armNextStatusRead()
        try await armFileTreeUpdatingObservation(input.paneOne.page)
        try appendTrackedChange(at: input.paneOneRepoURL)
        let fileChangeset = try makeChangeset(
            for: input.paneOne,
            paths: ["tracked.txt"],
            batchSequence: 704,
            containsGitInternalChanges: true
        )
        _ = input.paneOne.worktreeRefreshDriver.recordInvalidation(
            fileChangeset: fileChangeset,
            requiresReviewRefresh: false
        )
        input.paneOne.worktreeRefreshDriver.scheduleFileCatchUpIfPossible()
        guard try await input.paneOneGitStatusProvider.waitForBlockedStatusReadCount(1) == 1 else {
            throw JourneyError.conditionFailed("File catch-up did not reach its held status read")
        }
        let updatingFileStatus = try await requireArmedStatus(input.paneOne.page)
        await input.paneOneGitStatusProvider.releaseBlockedStatusRead()
        let nativeBeforeReviewActivation =
            await BridgeProductWebKitCarrierTestSupport.nativeSnapshot(input.paneOne)
        guard await activateReviewMode(input.paneOne.page) else {
            throw JourneyError.conditionFailed("Review mode did not reactivate during refresh")
        }
        try await requireNativeControlQuiescence(
            input.paneOne,
            afterRequestSequence: nativeBeforeReviewActivation.nextControlRequestSequence
        )
        return JourneyUpdatingState(
            foregroundRefreshPassCount: paneOneForegroundRefreshPassCount,
            fileStatus: updatingFileStatus,
            reviewStatus: updatingReviewStatus
        )
    }

    private static func withHostedControllers<Value>(
        _ controllers: [BridgePaneController],
        operation: @MainActor () async throws -> Value
    ) async throws -> Value {
        let frame = NSRect(x: 0, y: 0, width: 960, height: 720)
        let hosts = controllers.enumerated().map { index, controller in
            let window = NSWindow(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            let mountView = BridgePaneMountView(paneId: controller.paneId, controller: controller)
            mountView.frame = frame
            window.contentView = mountView
            window.alphaValue = 0.01
            window.ignoresMouseEvents = true
            window.setFrameOrigin(NSPoint(x: index * 12, y: index * 12))
            window.orderBack(nil)
            return window
        }
        do {
            let value = try await operation()
            try await teardown(controllers: controllers, windows: hosts)
            return value
        } catch {
            try? await teardown(controllers: controllers, windows: hosts)
            throw error
        }
    }

    private static func teardown(
        controllers: [BridgePaneController],
        windows: [NSWindow]
    ) async throws {
        for controller in controllers {
            _ = await controller.beginTeardown().value
            controller.page.stopLoading()
        }
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        for _ in 0..<80 {
            await Task.yield()
        }
        for controller in controllers {
            let snapshot = await controller.productSessionOwner.snapshot()
            guard snapshot.hasZeroResidue else {
                throw JourneyError.conditionFailed("two-pane teardown retained residue: \(snapshot)")
            }
        }
        retainedPages = controllers.map(\.page)
    }

    private static func makeController(_ input: ControllerInput) -> BridgePaneController {
        let paneId = UUIDv7.generate()
        return BridgePaneController(
            paneId: paneId,
            state: BridgePaneState(
                panelKind: .diffViewer,
                source: .workspace(
                    rootPath: input.repoURL.path,
                    baseline: .localDefaultBranch(branchName: "main")
                )
            ),
            appRootURL: testBridgeAppRootURL(),
            metadata: PaneMetadata(
                paneId: PaneId(existingUUID: paneId),
                contentType: .diff,
                launchDirectory: input.repoURL,
                title: input.title,
                facets: PaneContextFacets(
                    repoId: UUIDv7.generate(),
                    worktreeId: UUIDv7.generate(),
                    worktreeName: input.title,
                    cwd: input.repoURL
                )
            ),
            reviewSourceProvider: input.reviewProvider,
            gitReadContext: input.gitReadContext,
            worktreeProductConstructionCoordinator: input.worktreeProductConstructionCoordinator,
            gitWorkingTreeStatusProvider: input.gitWorkingTreeStatusProvider,
            telemetryRuntimePolicy: .live,
            telemetryScopeGate: BridgeTelemetryScopeGate(enabledScopes: []),
            telemetryRecorder: input.traceRecorder,
            initialPaneActivity: input.initialActivity
        )
    }

    private static func seedPositionFixture(at repoURL: URL, prefix: String) async throws {
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repoURL)
        for index in 0..<36 {
            let directory = repoURL.appending(path: String(format: "Sources/Group%02d", index / 9))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appending(path: String(format: "item-%03d.txt", index))
            try "\(prefix) review item \(index)\n".write(
                to: fileURL,
                atomically: true,
                encoding: .utf8
            )
        }
        let largeBody = (0..<520).map { "\(prefix) large line \($0)" }.joined(separator: "\n")
        try "\(largeBody)\n".write(
            to: repoURL.appending(path: filePositionPath),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func appendTrackedChange(at repoURL: URL) throws {
        let trackedURL = repoURL.appending(path: "tracked.txt")
        let current = try String(contentsOf: trackedURL, encoding: .utf8)
        try "\(current)hosted hidden refresh\n".write(
            to: trackedURL,
            atomically: true,
            encoding: .utf8
        )
    }

    private static func makeChangeset(
        for controller: BridgePaneController,
        paths: [String],
        batchSequence: UInt64,
        containsGitInternalChanges: Bool = false
    ) throws -> FileChangeset {
        let worktreeId = try #require(controller.runtime.metadata.worktreeId)
        let rootPath = try #require(controller.runtime.metadata.cwd)
        return FileChangeset(
            worktreeId: worktreeId,
            repoId: controller.runtime.metadata.repoId,
            rootPath: rootPath,
            paths: paths,
            containsGitInternalChanges: containsGitInternalChanges,
            timestamp: .now,
            batchSeq: batchSequence
        )
    }

    private static func requireMountedApp(_ controller: BridgePaneController) async throws {
        await WebPageEventWaits.waitForNavigationToFinish(controller.page)
        try await WebPageEventWaits.waitForDocumentSelector(
            controller.page,
            "[data-testid=\"bridge-app-root\"]"
        )
        await WebPageEventWaits.waitForBridgeReady(controller)
        guard let installation = await controller.productSessionOwner.activeInstallation,
            await installation.session.waitUntilActive()
        else {
            throw JourneyError.conditionFailed("bundled app native session did not activate")
        }
        let native = await BridgeProductWebKitCarrierTestSupport.nativeSnapshot(controller)
        guard native.lifecycle == "active" else {
            throw JourneyError.conditionFailed("bundled app native session was not active")
        }
    }

    private static func activateReadyFileMode(
        _ controller: BridgePaneController,
        failure: String
    ) async throws {
        guard await BridgeProductWebKitCarrierTestSupport.activateFileMode(controller.page) else {
            throw JourneyError.conditionFailed(failure)
        }
        _ = try await WebPageEventWaits.waitForDocumentValue(
            controller.page,
            reader: """
                const shell = document.querySelector('[data-testid="bridge-file-viewer-shell"]');
                const count = Number(shell?.getAttribute('data-file-display-item-count') ?? '0');
                return shell?.getAttribute('data-file-display-status') === 'ready'
                  && count > 0 ? count : null;
                """
        )
    }

    private static func requireReadyReview(
        _ controller: BridgePaneController,
        paneLabel: String,
        reviewProvider: BridgeProductWebKitGatedReviewSourceProvider,
        traceRecorder: BridgeProductWebKitCarrierTraceRecorder
    ) async throws {
        _ = try await WebPageEventWaits.waitForDocumentValue(
            controller.page,
            reader: """
                const reviewShell = document.querySelector('[data-testid="review-viewer-shell"]');
                return reviewShell?.getAttribute('data-selected-content-state') === 'ready' ? true : null;
                """
        )
        let trace = await traceRecorder.waitForTrace(.canonicalSubscriptionsAndReviewPublication)
        guard trace?.hasCanonicalEagerSubscriptions == true,
            trace?.hasReviewMetadataPublication == true
        else {
            let dom = await BridgeProductWebKitCarrierTestSupport.domSnapshot(controller.page)
            let native = await BridgeProductWebKitCarrierTestSupport.nativeSnapshot(controller)
            let providerSnapshot = await reviewProvider.snapshot()
            throw JourneyError.conditionFailed(
                "\(paneLabel) real-git Review did not become ready; appRoot=\(dom?.hasAppRoot == true), canonicalSubscriptions=\(trace?.hasCanonicalEagerSubscriptions == true), reviewPublication=\(trace?.hasReviewMetadataPublication == true), reviewState=\(dom?.reviewSelectedContentState ?? "missing"), comparisons=\(providerSnapshot.comparisonCount), blockedComparisons=\(providerSnapshot.blockedComparisonCount), native=\(native)"
            )
        }
    }

    private static func requireBlockedComparison(
        _ provider: BridgeProductWebKitGatedReviewSourceProvider,
        expectedCount: Int
    ) async throws {
        let blockedComparisonCount = await provider.waitForBlockedComparisonCount(expectedCount)
        guard blockedComparisonCount == expectedCount else {
            throw JourneyError.conditionFailed("real-git comparison did not block")
        }
    }

    private static func requireNativeControlQuiescence(
        _ controller: BridgePaneController,
        afterRequestSequence: Int
    ) async throws {
        await controller.worktreeRefreshDriver.awaitActiveFileOperations()
        guard let installation = await controller.productSessionOwner.activeInstallation,
            await installation.session.waitUntilControlReplayIdle(
                afterRequestSequence: afterRequestSequence
            )
        else {
            throw JourneyError.conditionFailed(
                "native Review activation did not settle its control admission"
            )
        }
        guard await installation.session.waitUntilProducerFramesQuiescent() else {
            throw JourneyError.conditionFailed("native Review activation lost its producer session")
        }
        var owner = await controller.productSessionOwner.snapshot()
        if owner.queuedFrameCount > 0 || owner.inFlightFrameReceiptCount > 0 {
            // A Review publication admitted after the first idle observation is still in flight.
            guard await installation.session.waitUntilProducerFramesQuiescent() else {
                throw JourneyError.conditionFailed("native Review activation lost its producer session")
            }
            owner = await controller.productSessionOwner.snapshot()
        }
        guard owner.queuedFrameCount == 0, owner.inFlightFrameReceiptCount == 0 else {
            throw JourneyError.conditionFailed(
                "native Review activation left frame delivery queued after producer quiescence "
                    + "(ownerQueued=\(owner.queuedFrameCount), "
                    + "ownerReceipts=\(owner.inFlightFrameReceiptCount), "
                    + "retiring=\(owner.retiringInstallationCount))"
            )
        }
    }

    private static func requireHiddenRefreshSettled(
        _ controller: BridgePaneController
    ) async throws {
        let retiringTasks = Array(controller.retiringReviewRefreshTaskById.values)
        for task in retiringTasks { await task.value }
        let snapshot = controller.refreshAdmissionCoordinator.diagnosticSnapshot
        guard snapshot.activity == .loadedHidden,
            snapshot.activeRefreshPass == nil,
            snapshot.dirtyFact != nil,
            controller.activeReviewRefreshTask == nil
        else { throw JourneyError.conditionFailed("hidden refresh did not settle") }
    }

    private static func requireHiddenFileRetirementBoundary(
        _ controller: BridgePaneController
    ) async throws {
        guard await waitForRetiringFileRefreshTasksToDrain(controller) else {
            throw JourneyError.conditionFailed("hidden File refresh did not retire")
        }
        // File retirement drops its custody after scheduling its terminal presentation.
        // Chain behind that presentation before sampling the hidden invalidation boundary.
        let presentationBarrier =
            controller.worktreeRefreshDriver.schedulePresentationTransition { _ in }
        await presentationBarrier?.value
    }

    private static func requireRefreshIdle(
        _ controller: BridgePaneController,
        terminalExpectation: BridgeProductWebKitCatchUpTerminalExpectation
    ) async throws {
        try await terminalExpectation.wait()
        while let activeReviewTask = controller.activeReviewRefreshTask {
            await activeReviewTask.value
        }
        await controller.worktreeRefreshDriver.awaitActiveFileOperations()
        let snapshot = controller.refreshAdmissionCoordinator.diagnosticSnapshot
        guard snapshot.activity == .foreground,
            snapshot.activeRefreshPass == nil,
            snapshot.dirtyFact == nil,
            controller.activeReviewRefreshTask == nil
        else {
            throw JourneyError.conditionFailed(terminalExpectation.describeUnsettledCatchUp(controller))
        }
    }

    /// Arms the W6 region observation before File catch-up can publish Updating.
    /// U13 renders the shared region indicator rather than the legacy status copy.
    ///
    /// A deadline here would be a verdict about machine speed on a page that
    /// renders no frames.
    private static func armFileTreeUpdatingObservation(_ page: WebPage) async throws {
        _ = try await page.callJavaScript(
            """
            window.__bridgeTwoPaneStatusObservation = new Promise(resolve => {
              const capture = () => {
                const encodedSnapshot = (() => { \(positionSnapshotReaderBody) })();
                const snapshot = JSON.parse(encodedSnapshot);
                if (snapshot.activeMode !== 'file') return false;
                if (snapshot.fileTreePresentationState !== 'updating' || snapshot.reviewStatusText !== null) return false;
                resolve(encodedSnapshot);
                return true;
              };
              if (capture()) return;
              const observer = new MutationObserver(() => {
                if (capture()) observer.disconnect();
              });
              observer.observe(document.documentElement, {
                attributes: true,
                characterData: true,
                childList: true,
                subtree: true
              });
            });
            return true;
            """
        )
    }

    private static func requireArmedStatus(_ page: WebPage) async throws
        -> BridgeProductWebKitTwoPanePositionSnapshot
    {
        do {
            let encoded = try await awaitBridgeWebKitMilestone("FiletreeUpdating") {
                try await page.callJavaScript("return await window.__bridgeTwoPaneStatusObservation;")
            }
            guard let encoded = encoded as? String,
                let data = encoded.data(using: .utf8)
            else {
                throw JourneyError.conditionFailed(
                    "matching active-surface status did not return its position snapshot"
                )
            }
            return try JSONDecoder().decode(
                BridgeProductWebKitTwoPanePositionSnapshot.self,
                from: data
            )
        } catch {
            throw JourneyError.conditionFailed(
                "armed active-surface updating chrome could not be read: \(error)"
            )
        }
    }

    /// Asserts, with one read, that neither surface is showing updating chrome.
    ///
    /// Every caller reaches this only after the owner's own barrier has been awaited
    /// (`requireHiddenFileRetirementBoundary`, `requireBlockedComparison`). This is a
    /// NEGATIVE claim, so it is read once: polling until the chrome disappears would
    /// accept a pane that showed "Updating…" it was never supposed to show.
    private static func requireNoUpdatingStatus(
        _ page: WebPage
    ) async throws -> BridgeProductWebKitTwoPanePositionSnapshot {
        let observed = try await requirePositionSnapshot(page)
        guard observed.fileStatusText == nil, observed.reviewStatusText == nil else {
            let observedFileStatusText = observed.fileStatusText ?? "nil"
            let observedReviewStatusText = observed.reviewStatusText ?? "nil"
            throw JourneyError.conditionFailed(
                "loaded-hidden pane retained updating chrome "
                    + "(fileStatusText: \(observedFileStatusText), "
                    + "reviewStatusText: \(observedReviewStatusText))"
            )
        }
        return observed
    }

    private static func requirePositionSnapshot(
        _ page: WebPage
    ) async throws -> BridgeProductWebKitTwoPanePositionSnapshot {
        guard let snapshot = try await positionSnapshot(page) else {
            throw JourneyError.conditionFailed("WebKit position snapshot was unavailable")
        }
        return snapshot
    }

    private static func positionSnapshot(
        _ page: WebPage
    ) async throws -> BridgeProductWebKitTwoPanePositionSnapshot? {
        let encoded = try await page.callJavaScript(
            "return (() => { \(positionSnapshotReaderBody) })();"
        )
        guard let encoded = encoded as? String,
            let data = encoded.data(using: .utf8)
        else { return nil }
        return try JSONDecoder().decode(BridgeProductWebKitTwoPanePositionSnapshot.self, from: data)
    }

    private static let positionSnapshotReaderBody =
        """
        const queryOpen = (root, selector) => {
          const direct = root.querySelector(selector);
          if (direct !== null) return direct;
          for (const element of root.querySelectorAll('*')) {
            if (element.shadowRoot === null) continue;
            const nested = queryOpen(element.shadowRoot, selector);
            if (nested !== null) return nested;
          }
          return null;
        };
        const fileHost = document.querySelector('[data-testid="bridge-viewer-mode-host-file"]');
        const reviewHost = document.querySelector('[data-testid="bridge-viewer-mode-host-review"]');
        const fileShell = fileHost?.querySelector('[data-testid="bridge-file-viewer-shell"]');
        const fileCanvas = fileHost?.querySelector('[data-testid="bridge-file-viewer-code-canvas"]');
        const reviewShell = reviewHost?.querySelector('[data-testid="review-viewer-shell"]');
        const fileTreeScroll = fileHost === null ? null : queryOpen(fileHost, '[data-file-tree-virtualized-scroll="true"]');
        const reviewTreeScroll = reviewHost === null ? null : queryOpen(reviewHost, '[data-file-tree-virtualized-scroll="true"]');
        const fileCodeScroll = fileHost?.querySelector('.bridge-code-view-scroll-owner');
        const reviewCodeScroll = reviewHost?.querySelector('.bridge-code-view-scroll-owner');
        const collapsedDirectory = reviewHost === null
          ? null
          : queryOpen(reviewHost, '[data-item-path="Sources/Group00"][aria-expanded]');
        const activeHost = document.querySelector('[data-bridge-viewer-mode-active="true"]');
        return JSON.stringify({
          activeMode: activeHost?.getAttribute('data-bridge-viewer-mode-host') ?? null,
          comparisonStatusText: reviewHost?.querySelector('[data-testid="bridge-review-comparison-status-banner"]')?.textContent ?? null,
          fileCodeScrollTop: fileCodeScroll?.scrollTop ?? 0,
          fileRenderedPath: fileCanvas?.getAttribute('data-worktree-rendered-file-path') ?? null,
          fileSelectedPath: fileShell?.getAttribute('data-selected-display-path') ?? null,
          fileStatusText: fileHost?.querySelector('[data-testid="bridge-viewer-content-status"]')?.textContent ?? null,
          fileTreePresentationState: fileHost?.querySelector('[data-bridge-region="file-tree"]')?.getAttribute('data-presentation-state') ?? null,
          fileTreeScrollTop: fileTreeScroll?.scrollTop ?? 0,
          hasAppRoot: document.querySelector('[data-testid="bridge-app-root"]') !== null,
          reviewCodeScrollTop: reviewCodeScroll?.scrollTop ?? 0,
          reviewCollapsedDirectoryExpansion: collapsedDirectory?.getAttribute('aria-expanded') ?? null,
          reviewSelectedItemId: reviewHost?.querySelector('[data-testid="bridge-code-view-panel"]')?.getAttribute('data-selected-item-id') ?? null,
          reviewSelectedPath: reviewShell?.getAttribute('data-selected-display-path') ?? null,
          reviewStatusText: reviewHost?.querySelector('[data-testid="bridge-viewer-content-status"]')?.textContent ?? null,
          reviewTreeScrollTop: reviewTreeScroll?.scrollTop ?? 0
        });
        """

    private static func activateReviewMode(_ page: WebPage) async -> Bool {
        (try? await page.callJavaScript(
            """
            const button = document.querySelector('[data-testid="bridge-viewer-context-review"]');
            if (!(button instanceof HTMLElement)) return false;
            button.click();
            return true;
            """
        )) as? Bool ?? false
    }

    private enum JourneyError: Error {
        case conditionFailed(String)
    }
}
