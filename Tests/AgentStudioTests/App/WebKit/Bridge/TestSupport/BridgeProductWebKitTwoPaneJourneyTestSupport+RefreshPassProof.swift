import Foundation
import Testing
import WebKit

@testable import AgentStudioBridge

extension BridgeProductWebKitTwoPaneJourneyTestSupport {
    static func requireHeldReviewAttempt(
        _ traceRecorder: BridgeProductWebKitCarrierTraceRecorder
    ) async throws -> BridgeOperationLifecycleTraceEvent {
        let lifecycleEvents = await traceRecorder.operationLifecycleEvents()
        let preparationEvent = try #require(
            lifecycleEvents.last {
                $0.surface == .review && $0.stage == .reviewPrepareStarted
            }
        )
        let reservationEvents = lifecycleEvents.filter {
            $0.operationCorrelationID == preparationEvent.operationCorrelationID
                && $0.stage == .refreshReserved
        }
        #expect(preparationEvent.result == .started)
        #expect(reservationEvents.count == 1)
        return preparationEvent
    }

    /// The page shows File before native admission accepts it; only native acceptance
    /// fences an in-flight Review build, so the journey waits for that owner fact and
    /// captures the refresh facts from the same read that satisfied the wait.
    static func requireNativeFileModeAcceptance(
        _ controller: BridgePaneController,
        after precedingSignal: BridgeActiveViewerModeSignalState
    ) async throws -> BridgeProductWebKitNativeFileModeAcceptance {
        guard let sessionId = precedingSignal.sessionId,
            let precedingSequence = precedingSignal.lastSequence
        else {
            throw JourneyError.conditionFailed(
                "File activation had no preceding native mode session and sequence"
            )
        }
        return try await BridgePaneControllerEventWaits.waitForValue(
            { () -> BridgeProductWebKitNativeFileModeAcceptance? in
                let currentSignal = controller.activeViewerModeSignalState
                guard currentSignal.sessionId == sessionId,
                    currentSignal.acceptedMode == .file,
                    let currentSequence = currentSignal.lastSequence,
                    currentSequence > precedingSequence
                else { return nil }
                let coordinator = controller.refreshAdmissionCoordinator
                return BridgeProductWebKitNativeFileModeAcceptance(
                    isReviewRefreshActive: coordinator.isRefreshLaneActive(.review),
                    dirtyFact: coordinator.diagnosticSnapshot.dirtyFact
                )
            },
            milestone: "native File mode acceptance after sequence \(precedingSequence)",
            lastObservation: {
                let signal = controller.activeViewerModeSignalState
                return "session=\(signal.sessionId ?? "nil"),"
                    + "sequence=\(signal.lastSequence.map { String($0) } ?? "nil"),"
                    + "mode=\(signal.acceptedMode?.rawValue ?? "nil")"
            }
        )
    }

    /// Native File acceptance fences the held Review build: its pass is gone and its
    /// Review input is restored as the pane's dirty fact before the comparison resumes.
    static func requireFencedReviewBuild(
        _ acceptance: BridgeProductWebKitNativeFileModeAcceptance,
        batchSequence: UInt64
    ) throws {
        try #require(!acceptance.isReviewRefreshActive)
        let restoredDirtyFact = try #require(acceptance.dirtyFact)
        try #require(restoredDirtyFact.requiresReviewRefresh)
        try #require(restoredDirtyFact.latestBatchSequence == batchSequence)
    }

    static func performBatch704FileCatchUp(
        _ input: JourneyInput
    ) async throws -> BridgeProductWebKitTwoPanePositionSnapshot {
        await input.paneOneGitStatusProvider.armNextStatusRead()
        try await armFileTreeUpdatingObservation(input.paneOne.page)
        try appendTrackedChange(at: input.paneOneRepoURL)
        let fileChangeset = try makeChangeset(
            for: input.paneOne,
            paths: ["tracked.txt"],
            batchSequence: 704,
            containsGitInternalChanges: true
        )
        let passCountBeforeFileOnlyInvalidation =
            input.paneOne.refreshAdmissionCoordinator.diagnosticSnapshot.refreshPassCount
        _ = input.paneOne.worktreeRefreshDriver.recordInvalidation(
            fileChangeset: fileChangeset,
            requiresReviewRefresh: false
        )
        input.paneOne.worktreeRefreshDriver.scheduleFileCatchUpIfPossible()
        let fileReservation = try #require(
            input.paneOne.refreshAdmissionCoordinator.diagnosticSnapshot.activeRefreshPass
        )
        #expect(fileReservation.lanes == [.file])
        #expect(fileReservation.fileChangeset?.batchSeq == 704)
        #expect(
            input.paneOne.refreshAdmissionCoordinator.diagnosticSnapshot.refreshPassCount
                == passCountBeforeFileOnlyInvalidation + 1
        )
        guard try await input.paneOneGitStatusProvider.waitForBlockedStatusReadCount(1) == 1 else {
            throw JourneyError.conditionFailed("File catch-up did not reach its held status read")
        }
        let updatingFileStatus = try await requireArmedStatus(input.paneOne.page)
        await input.paneOneGitStatusProvider.releaseBlockedStatusRead()
        await input.paneOne.worktreeRefreshDriver.awaitActiveFileOperations()
        let fileOperationEvents = await input.paneOneTrace.operationLifecycleEvents().filter {
            $0.operationCorrelationID == fileReservation.operationCorrelationID
        }
        let fileReservations = fileOperationEvents.filter { $0.stage == .refreshReserved }
        let fileTerminals = fileOperationEvents.filter { $0.stage == .refreshOperationTerminal }
        #expect(fileReservations.count == 1)
        #expect(fileTerminals.count == 1)
        #expect(fileTerminals.first?.result == .success)
        return updatingFileStatus
    }

    static func requireSingleReviewReactivation(
        _ input: JourneyInput,
        previousOperationID: String
    ) async throws -> BridgeProductWebKitActiveViewerModeIdentity {
        await input.paneOneReviewProvider.armNextComparison()
        let nativeBeforeReviewActivation =
            await BridgeProductWebKitCarrierTestSupport.nativeSnapshot(input.paneOne)
        let reviewModeIdentity = try await activateReviewMode(input.paneOne)
        try await requireNativeControlQuiescence(
            input.paneOne,
            afterRequestSequence: nativeBeforeReviewActivation.nextControlRequestSequence
        )
        _ = try await requireBlockedComparison(
            input.paneOneReviewProvider,
            expectedCount: 2,
            milestone: "Review reactivation comparison hold"
        )
        // The reactivated comparison is now held at the gate, so its task and reservation exist.
        guard let reactivatedReviewTask = input.paneOne.activeReviewRefreshTask else {
            throw JourneyError.conditionFailed(
                "Review mode reactivation did not admit a catch-up task while its comparison is held"
            )
        }
        guard
            let reactivatedOperationID = input.paneOne.refreshAdmissionCoordinator.productPresentationSnapshot
                .operationCorrelationID,
            reactivatedOperationID != previousOperationID
        else {
            throw JourneyError.conditionFailed(
                "Review mode reactivation did not reserve a distinct catch-up operation while its comparison is held"
            )
        }
        let lifecycleEvents = await input.paneOneTrace.operationLifecycleEvents()
        let reactivatedReviewStart = try #require(
            lifecycleEvents.last {
                $0.surface == .review && $0.stage == .reviewPrepareStarted
            }
        )
        let reactivatedReviewReservation = reactivatedReviewStart.operationCorrelationID
        #expect(reactivatedReviewReservation == reactivatedOperationID)
        #expect(reactivatedReviewStart.result == .started)
        #expect(
            lifecycleEvents.filter {
                $0.operationCorrelationID == reactivatedReviewReservation
                    && $0.stage == .refreshReserved
            }.count == 1
        )
        await input.paneOneReviewProvider.releaseBlockedComparisons()
        await reactivatedReviewTask.value
        let reactivatedReviewTerminal = await input.paneOneTrace.operationLifecycleEvents().filter {
            $0.operationCorrelationID == reactivatedReviewReservation
                && $0.stage == .refreshOperationTerminal
        }
        #expect(reactivatedReviewTerminal.count == 1)
        #expect(reactivatedReviewTerminal.first?.result == .success)
        return reviewModeIdentity
    }

    /// Holds a foreground Review attempt at its comparison so loaded-hidden admission
    /// must retire it while its physical construction is still running.
    static func beginHeldReviewAttempt(
        _ input: JourneyInput,
        batchSequence: UInt64
    ) async throws -> String {
        await input.paneOneReviewProvider.armNextComparison()
        try appendTrackedChange(at: input.paneOneRepoURL)
        await input.paneOne.handleWorktreeProductInvalidation(
            .filesChanged(
                try makeChangeset(
                    for: input.paneOne,
                    paths: ["tracked.txt"],
                    batchSequence: batchSequence
                )
            )
        )
        guard input.paneOne.activeReviewRefreshTask != nil else {
            throw JourneyError.conditionFailed(
                "batch \(batchSequence) Review invalidation did not admit a catch-up task before its comparison wait"
            )
        }
        _ = try await requireBlockedComparison(
            input.paneOneReviewProvider,
            expectedCount: 3,
            milestone: "batch \(batchSequence) Review comparison hold"
        )
        let heldAttempt = try await requireHeldReviewAttempt(input.paneOneTrace)
        // The same batch's File pass settles in the foreground, so hiding retires only the held Review attempt.
        await input.paneOne.worktreeRefreshDriver.awaitActiveFileOperations()
        return heldAttempt.operationCorrelationID
    }

    /// Releases the held comparison only after loaded-hidden admission retired its attempt,
    /// then joins the late physical construction and the attempt's correlated terminal.
    static func releaseHeldReviewWhileHidden(
        _ input: JourneyInput,
        heldOperationID: String
    ) async throws {
        let physicalConstructions = input.paneOne.reviewConstructionProgress.physicalTaskHandles()
        let releasedComparisonCount = await input.paneOneReviewProvider.releaseBlockedComparisons()
        try #require(releasedComparisonCount == 1)
        for construction in physicalConstructions { await construction.value }
        try await requireHiddenRefreshSettled(input.paneOne)
        let heldTerminals = await input.paneOneTrace.operationLifecycleEvents().filter {
            $0.operationCorrelationID == heldOperationID && $0.stage == .refreshOperationTerminal
        }
        try #require(heldTerminals.count == 1)
        try #require(heldTerminals.first?.result == .stale)
    }

}

/// Review refresh facts read in the same MainActor turn that observed native File acceptance.
struct BridgeProductWebKitNativeFileModeAcceptance: Sendable {
    let isReviewRefreshActive: Bool
    let dirtyFact: BridgePaneRefreshDirtyFact?
}
