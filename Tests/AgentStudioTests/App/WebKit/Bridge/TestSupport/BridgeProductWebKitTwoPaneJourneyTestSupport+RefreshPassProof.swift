import Foundation
import Testing
import WebKit

@testable import AgentStudioBridge

extension BridgeProductWebKitTwoPaneJourneyTestSupport {
    static func requireFencedReviewAttempt(_ controller: BridgePaneController) throws -> String {
        let operationID = try #require(
            controller.refreshAdmissionCoordinator.productPresentationSnapshot.operationCorrelationID
        )
        #expect(controller.refreshAdmissionCoordinator.isRefreshLaneActive(.review))
        return operationID
    }

    static func requireFencedReviewAttemptRetired(
        _ input: JourneyInput,
        operationID: String
    ) async throws {
        await input.paneOneReviewProvider.releaseBlockedComparisons()
        let retiringReviewTasks = Array(input.paneOne.retiringReviewRefreshTaskById.values)
        for retiringTask in retiringReviewTasks { await retiringTask.value }
        let fencedReviewEvents = await input.paneOneTrace.operationLifecycleEvents().filter {
            $0.operationCorrelationID == operationID
        }
        let fencedReviewReservations = fencedReviewEvents.filter { $0.stage == .refreshReserved }
        let fencedReviewTerminals = fencedReviewEvents.filter {
            $0.stage == .refreshOperationTerminal
        }
        let restoredReviewDirtyFact = input.paneOne.refreshAdmissionCoordinator.diagnosticSnapshot.dirtyFact
        #expect(!input.paneOne.refreshAdmissionCoordinator.isRefreshLaneActive(.review))
        #expect(restoredReviewDirtyFact?.requiresReviewRefresh == true)
        #expect(restoredReviewDirtyFact?.latestBatchSequence == 701)
        #expect(fencedReviewReservations.count == 1)
        #expect(fencedReviewTerminals.count == 1)
        #expect(
            fencedReviewTerminals.first?.result == .stale
                || fencedReviewTerminals.first?.result == .cancelled
        )
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
        fencedOperationID: String
    ) async throws -> BridgeProductWebKitActiveViewerModeIdentity {
        await input.paneOneReviewProvider.armNextComparison()
        let passCountBeforeReviewReactivation =
            input.paneOne.refreshAdmissionCoordinator.diagnosticSnapshot.refreshPassCount
        let nativeBeforeReviewActivation =
            await BridgeProductWebKitCarrierTestSupport.nativeSnapshot(input.paneOne)
        let reviewModeIdentity = try await activateReviewMode(input.paneOne)
        try await requireNativeControlQuiescence(
            input.paneOne,
            afterRequestSequence: nativeBeforeReviewActivation.nextControlRequestSequence
        )
        try await requireBlockedComparison(input.paneOneReviewProvider, expectedCount: 2)
        let reactivatedReviewReservation = try #require(
            input.paneOne.refreshAdmissionCoordinator.productPresentationSnapshot.operationCorrelationID
        )
        #expect(reactivatedReviewReservation != fencedOperationID)
        #expect(input.paneOne.refreshAdmissionCoordinator.isRefreshLaneActive(.review))
        #expect(
            input.paneOne.refreshAdmissionCoordinator.diagnosticSnapshot.refreshPassCount
                == passCountBeforeReviewReactivation + 1
        )
        let reactivatedReviewEvents = await input.paneOneTrace.operationLifecycleEvents().filter {
            $0.operationCorrelationID == reactivatedReviewReservation
        }
        #expect(reactivatedReviewEvents.filter { $0.stage == .refreshReserved }.count == 1)
        let reactivatedReviewTask = try #require(input.paneOne.activeReviewRefreshTask)
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

}
