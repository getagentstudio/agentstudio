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

actor BridgeProductWebKitGatedReviewSourceProvider: BridgeReviewSourceProvider {
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
            let step = HeldStep<Void>("blocked review comparison", cancellation: .holdThroughCancellation)
            blockedSteps.append(step)
            blockedComparisonCount += 1
            let readyWaiters = blockedCountWaiters.filter { blockedComparisonCount >= $0.count }
            blockedCountWaiters.removeAll { blockedComparisonCount >= $0.count }
            for waiter in readyWaiters { waiter.continuation.resume() }
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
        let closingSource: WebPageDocumentWaitClosingSource
        let gitReadContext: BridgeGitReadContext
        let initialActivity: BridgePaneActivity
        let gitWorkingTreeStatusProvider: any GitWorkingTreeStatusProvider
        let repoURL: URL
        let reviewProvider: any BridgeReviewSourceProvider
        let title: String
        let traceRecorder: BridgeProductWebKitCarrierTraceRecorder
        let worktreeProductConstructionCoordinator: BridgeWorktreeProductConstructionCoordinator
    }

    struct JourneyInput {
        let paneOne: BridgePaneController
        let paneOneClosingSource: WebPageDocumentWaitClosingSource
        let paneOneGitStatusProvider: BridgeProductWebKitGatedGitStatusProvider
        let paneOneRepoURL: URL
        let paneOneReviewProvider: BridgeProductWebKitGatedReviewSourceProvider
        let paneOneTrace: BridgeProductWebKitCarrierTraceRecorder
        let paneTwo: BridgePaneController
        let paneTwoClosingSource: WebPageDocumentWaitClosingSource
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

    struct JourneyUpdatingState {
        let fileStatus: BridgeProductWebKitTwoPanePositionSnapshot
        let reviewModeIdentity: BridgeProductWebKitActiveViewerModeIdentity
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
        let paneOneClosingSource = try WebPageDocumentWaitClosingSource(pane: "Hosted Pane One")
        let paneTwoClosingSource = try WebPageDocumentWaitClosingSource(pane: "Hosted Pane Two")
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
                closingSource: paneOneClosingSource,
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
                closingSource: paneTwoClosingSource,
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

        do {
            let proof = try await withHostedControllers([paneOne, paneTwo]) {
                try await exerciseJourney(
                    JourneyInput(
                        paneOne: paneOne,
                        paneOneClosingSource: paneOneClosingSource,
                        paneOneGitStatusProvider: paneOneGitStatusProvider,
                        paneOneRepoURL: paneOneRepoURL,
                        paneOneReviewProvider: paneOneReviewProvider,
                        paneOneTrace: paneOneTrace,
                        paneTwo: paneTwo,
                        paneTwoClosingSource: paneTwoClosingSource,
                        paneTwoReviewProvider: paneTwoReviewProvider,
                        paneTwoTrace: paneTwoTrace
                    ))
            }
            try await paneOneClosingSource.finish()
            try await paneTwoClosingSource.finish()
            return proof
        } catch {
            try? await paneOneClosingSource.finish()
            try? await paneTwoClosingSource.finish()
            throw error
        }
    }

    private static func prepareJourney(_ input: JourneyInput) async throws -> JourneyPreparation {
        input.paneOneClosingSource.observePage(input.paneOne.page)
        input.paneTwoClosingSource.observePage(input.paneTwo.page)
        input.paneOne.loadApp()
        input.paneTwo.loadApp()
        _ = try await input.paneOneClosingSource.requireMountedApp(input.paneOne)
        _ = try await input.paneTwoClosingSource.requireMountedApp(input.paneTwo)

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
        _ = try await requireReadyReview(
            input.paneOne,
            paneLabel: "pane one",
            closingSource: input.paneOneClosingSource,
            reviewProvider: input.paneOneReviewProvider,
            traceRecorder: input.paneOneTrace
        )
        _ = try await requireReadyReview(
            input.paneTwo,
            paneLabel: "pane two",
            closingSource: input.paneTwoClosingSource,
            reviewProvider: input.paneTwoReviewProvider,
            traceRecorder: input.paneTwoTrace
        )

        let initialReviewState = try await requirePositionSnapshot(input.paneOne.page)
        try await input.paneOneClosingSource.activateReadyFileMode(
            input.paneOne, failure: "pane one File mode did not activate")
        _ = try await activateReviewMode(input.paneOne)
        _ = try await requireReadyReview(
            input.paneOne,
            paneLabel: "pane one after mode round-trip",
            closingSource: input.paneOneClosingSource,
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
        let staleForegroundAdmissionWasRejected = hasRejectedStaleForegroundAdmission(preparation)
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
        guard let catchUpDirtyFact = input.paneOne.refreshAdmissionCoordinator.diagnosticSnapshot.dirtyFact,
            catchUpDirtyFact.requiresReviewRefresh,
            catchUpDirtyFact.latestBatchSequence == 703
        else {
            throw JourneyError.conditionFailed(
                "foreground recovery did not retain Review dirty batch 703"
            )
        }
        let catchUpTerminal = await input.paneOneTrace.prepareForegroundCatchUp(
            dirtyFact: catchUpDirtyFact,
            reviewModeIdentity: updatingState.reviewModeIdentity
        )
        let paneOneForegroundTransition = input.paneOne.applyBridgePaneActivity(.foreground)
        await paneOneForegroundTransition?.value
        try await requireRefreshIdle(input.paneOne, terminalExpectation: catchUpTerminal)
        _ = try await requireReadyReview(
            input.paneOne,
            paneLabel: "pane one after foreground return",
            closingSource: input.paneOneClosingSource,
            reviewProvider: input.paneOneReviewProvider,
            traceRecorder: input.paneOneTrace
        )
        let reviewStateAfterReturn = try await requirePositionSnapshot(input.paneOne.page)
        try await input.paneOneClosingSource.activateReadyFileMode(
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
        let hiddenStorm = summarizeHiddenStorm(
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

    private static func summarizeHiddenStorm(
        nativeBefore: BridgeProductWebKitCarrierNativeSnapshot,
        nativeAfter: BridgeProductWebKitCarrierNativeSnapshot,
        traceBefore: BridgeProductWebKitCarrierTrace,
        traceAfter: BridgeProductWebKitCarrierTrace
    ) -> BridgeProductWebKitHiddenStormSummary {
        BridgeProductWebKitMetadataStormDiagnostic.summarize(
            nativeBefore: nativeBefore,
            nativeAfter: nativeAfter,
            traceBefore: traceBefore,
            traceAfter: traceAfter
        )
    }

    private static func hasRejectedStaleForegroundAdmission(
        _ preparation: JourneyPreparation
    ) -> Bool {
        preparation.staleForegroundAdmission?.withValidAdmission { true } == nil
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
        guard let heldReviewTask = input.paneOne.activeReviewRefreshTask else {
            throw JourneyError.conditionFailed(
                "batch 701 Review invalidation did not admit a catch-up task before its comparison wait"
            )
        }
        _ = try await requireBlockedComparison(
            input.paneOneReviewProvider,
            expectedCount: 1,
            milestone: "batch 701 Review comparison hold"
        )
        let heldReviewAttempt = try await requireHeldReviewAttempt(input.paneOneTrace)
        let updatingReviewStatus = try await requireNoUpdatingStatus(input.paneOne.page)
        guard updatingReviewStatus.activeMode == "review" else {
            let observedActiveMode = updatingReviewStatus.activeMode ?? "nil"
            throw JourneyError.conditionFailed(
                "ordinary Review refresh changed the active surface "
                    + "(observedActiveMode: \(observedActiveMode))"
            )
        }
        let precedingModeSignal = input.paneOne.activeViewerModeSignalState
        try await input.paneOneClosingSource.activateReadyFileMode(
            input.paneOne,
            failure: "File mode did not activate during refresh"
        )
        let fileModeAcceptance = try await requireNativeFileModeAcceptance(
            input.paneOne,
            after: precedingModeSignal
        )
        try requireFencedReviewBuild(fileModeAcceptance, batchSequence: 701)
        await input.paneOneReviewProvider.releaseBlockedComparisons()
        await heldReviewTask.value
        let updatingFileStatus = try await performBatch704FileCatchUp(input)
        let reviewModeIdentity = try await requireSingleReviewReactivation(
            input,
            previousOperationID: heldReviewAttempt.operationCorrelationID
        )
        return JourneyUpdatingState(
            fileStatus: updatingFileStatus,
            reviewModeIdentity: reviewModeIdentity,
            reviewStatus: updatingReviewStatus
        )
    }

    static func withHostedControllers<Value>(
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
            initialPaneActivity: input.initialActivity,
            productSessionBootstrapFailureSink: { page, requestId, reason, contentWorld in
                input.closingSource.recordBootstrapFailure(reason)
                try await BridgePaneController.dispatchProductSessionBootstrapFailure(
                    page: page, requestId: requestId, reason: reason, contentWorld: contentWorld)
            }
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

    static func appendTrackedChange(at repoURL: URL) throws {
        let trackedURL = repoURL.appending(path: "tracked.txt")
        let current = try String(contentsOf: trackedURL, encoding: .utf8)
        try "\(current)hosted hidden refresh\n".write(
            to: trackedURL,
            atomically: true,
            encoding: .utf8
        )
    }

    static func makeChangeset(
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

    private static func requireReadyReview(
        _ controller: BridgePaneController,
        paneLabel: String,
        closingSource: WebPageDocumentWaitClosingSource,
        reviewProvider: BridgeProductWebKitGatedReviewSourceProvider,
        traceRecorder: BridgeProductWebKitCarrierTraceRecorder
    ) async throws -> BridgeProductWebKitCarrierTrace {
        _ = try await WebPageEventWaits.waitForDocumentValue(
            controller.page,
            reader: """
                const reviewShell = document.querySelector('[data-testid="review-viewer-shell"]');
                return reviewShell?.getAttribute('data-selected-content-state') === 'ready' ? true : null;
                """, milestone: "\(paneLabel) Review selected content ready", closingSource: closingSource
        )
        let trace = await traceRecorder.waitForTrace(.canonicalSubscriptionsAndReviewPublication)
        guard let trace, trace.hasCanonicalEagerSubscriptions,
            trace.hasReviewMetadataPublication
        else {
            let dom = await BridgeProductWebKitCarrierTestSupport.domSnapshot(controller.page)
            let native = await BridgeProductWebKitCarrierTestSupport.nativeSnapshot(controller)
            let providerSnapshot = await reviewProvider.snapshot()
            throw JourneyError.conditionFailed(
                "\(paneLabel) real-git Review did not become ready; appRoot=\(dom?.hasAppRoot == true), canonicalSubscriptions=\(trace?.hasCanonicalEagerSubscriptions == true), reviewPublication=\(trace?.hasReviewMetadataPublication == true), reviewState=\(dom?.reviewSelectedContentState ?? "missing"), comparisons=\(providerSnapshot.comparisonCount), blockedComparisons=\(providerSnapshot.blockedComparisonCount), native=\(native)"
            )
        }
        return trace
    }

    static func requireBlockedComparison(
        _ provider: BridgeProductWebKitGatedReviewSourceProvider,
        expectedCount: Int,
        milestone: String
    ) async throws -> Int {
        try await awaitBridgeWebKitMilestone(milestone) {
            let blockedComparisonCount = await provider.waitForBlockedComparisonCount(expectedCount)
            guard blockedComparisonCount == expectedCount else {
                throw JourneyError.conditionFailed(
                    "\(milestone) observed comparison count \(blockedComparisonCount), expected \(expectedCount)"
                )
            }
            return blockedComparisonCount
        }
    }

    static func requireNativeControlQuiescence(
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
        let terminalObservations = try await terminalExpectation.wait()
        while let activeReviewTask = controller.activeReviewRefreshTask {
            await activeReviewTask.value
        }
        await controller.worktreeRefreshDriver.awaitActiveFileOperations()
        let snapshot = controller.refreshAdmissionCoordinator.diagnosticSnapshot
        let terminalResultsDescription = terminalExpectation.describeTerminalResults(
            terminalObservations, snapshot: snapshot,
            reviewAttemptDescription: String(
                describing: controller.refreshAdmissionCoordinator.productPresentationSnapshot.reviewComparison?.attempt
            ))
        print("Bridge native catch-up terminals: \(terminalResultsDescription)")
        let allCurrentAttemptsSucceeded =
            terminalExpectation.currentAttemptsSucceeded(terminalObservations)
        #expect(
            allCurrentAttemptsSucceeded,
            Comment(rawValue: terminalResultsDescription)
        )
        let currentModeSignal = controller.activeViewerModeSignalState
        let acceptedExpectedReviewMode =
            terminalExpectation.reviewModeIdentity.map { expectedIdentity in
                currentModeSignal.sessionId == expectedIdentity.sessionId
                    && currentModeSignal.acceptedMode == .review
                    && (currentModeSignal.lastSequence ?? 0) >= expectedIdentity.sequence
            } == true
        #expect(
            acceptedExpectedReviewMode,
            Comment(rawValue: "nativeReviewMode=\(currentModeSignal)")
        )
        guard snapshot.activity == .foreground,
            snapshot.activeRefreshPass == nil,
            snapshot.dirtyFact == nil,
            controller.activeReviewRefreshTask == nil,
            allCurrentAttemptsSucceeded,
            acceptedExpectedReviewMode
        else {
            throw JourneyError.conditionFailed(
                terminalExpectation.describeUnsettledCatchUp(
                    snapshot: snapshot,
                    reviewTaskPresent: controller.activeReviewRefreshTask != nil,
                    terminalResultsDescription: terminalResultsDescription
                )
            )
        }
    }

    static func activateReviewMode(
        _ controller: BridgePaneController
    ) async throws -> BridgeProductWebKitActiveViewerModeIdentity {
        let precedingSignal = controller.activeViewerModeSignalState
        guard let sessionId = precedingSignal.sessionId,
            let precedingSequence = precedingSignal.lastSequence
        else {
            throw JourneyError.conditionFailed(
                "Review activation had no preceding native mode session and sequence"
            )
        }
        guard
            (try? await controller.page.callJavaScript(
                """
                const button = document.querySelector('[data-testid="bridge-viewer-context-review"]');
                if (!(button instanceof HTMLElement)) return false;
                button.click();
                return true;
                """
            )) as? Bool == true
        else {
            throw JourneyError.conditionFailed("Review mode control could not be activated")
        }
        let acceptedSequence: Int = try await BridgePaneControllerEventWaits.waitForValue(
            {
                let currentSignal = controller.activeViewerModeSignalState
                guard currentSignal.sessionId == sessionId,
                    currentSignal.acceptedMode == .review,
                    let currentSequence = currentSignal.lastSequence,
                    currentSequence > precedingSequence
                else { return nil }
                return currentSequence
            },
            milestone:
                "native Review mode acceptance for session \(sessionId) "
                + "after sequence \(precedingSequence)",
            lastObservation: {
                let signal = controller.activeViewerModeSignalState
                return "session=\(signal.sessionId ?? "nil"),"
                    + "sequence=\(signal.lastSequence.map { String($0) } ?? "nil"),"
                    + "mode=\(signal.acceptedMode?.rawValue ?? "nil")"
            }
        )
        return BridgeProductWebKitActiveViewerModeIdentity(
            sessionId: sessionId,
            sequence: acceptedSequence
        )
    }

    enum JourneyError: Error {
        case conditionFailed(String)
    }
}
