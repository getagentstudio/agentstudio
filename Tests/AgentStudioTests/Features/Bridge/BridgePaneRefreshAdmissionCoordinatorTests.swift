import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge pane refresh admission coordinator")
@MainActor
struct BridgePaneRefreshAdmissionCoordinatorTests {
    @Test("Review intent floor is monotonic within E1 and resets for a new E1")
    func reviewIntentFloorIsKeyedToProductAdmission() throws {
        let coordinator = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        let source = coordinator.workAdmissionSource
        let firstAdmission = try BridgeProductAdmissionTestContext.make()
        let secondAdmission = try BridgeProductAdmissionTestContext.make()

        _ = firstAdmission.context.withValidAdmission {
            source.admitReviewComparisonIntent(
                workerDerivationEpoch: 3,
                productAdmission: firstAdmission.context
            )
        }
        _ = firstAdmission.context.withValidAdmission {
            source.admitReviewComparisonIntent(
                workerDerivationEpoch: 2,
                productAdmission: firstAdmission.context
            )
        }
        let olderIntentWasAdmitted =
            firstAdmission.context.withValidAdmission {
                source.withCurrentReviewComparisonIntent(
                    workerDerivationEpoch: 2,
                    productAdmission: firstAdmission.context
                ) { true } == true
            } == true

        _ = secondAdmission.context.withValidAdmission {
            source.admitReviewComparisonIntent(
                workerDerivationEpoch: 1,
                productAdmission: secondAdmission.context
            )
        }
        let newE1IntentWasAdmitted =
            secondAdmission.context.withValidAdmission {
                source.withCurrentReviewComparisonIntent(
                    workerDerivationEpoch: 1,
                    productAdmission: secondAdmission.context
                ) { true } == true
            } == true
        let oldE1CannotReuseItsHigherEpoch =
            firstAdmission.context.withValidAdmission {
                source.withCurrentReviewComparisonIntent(
                    workerDerivationEpoch: 99,
                    productAdmission: firstAdmission.context
                ) { true } == true
            } == true

        #expect(!olderIntentWasAdmitted)
        #expect(newE1IntentWasAdmitted)
        #expect(!oldE1CannotReuseItsHigherEpoch)
    }

    @Test("explicit File retry cannot bypass stream-reset recovery without unavailable state")
    func explicitFileRetryRequiresUnavailableState() {
        let coordinator = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        coordinator.recordInvalidation(
            fileChangeset: makeFileChangeset(
                paths: ["Sources/App/StreamReset.swift"],
                batchSequence: 63
            ),
            requiresReviewRefresh: false
        )

        #expect(!coordinator.beginExplicitFileRefreshRetry())
        #expect(coordinator.diagnosticSnapshot.dirtyFact != nil)
        #expect(coordinator.productPresentationSnapshot.fileRefreshFailure == nil)
    }

    @Test("explicit File retry advances authority and clears retained failure")
    func explicitFileRetryAdvancesAuthorityAndClearsRetainedFailure() throws {
        // Arrange
        let coordinator = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        coordinator.recordInvalidation(
            fileChangeset: makeFileChangeset(
                paths: ["Sources/App/Retry.swift"],
                batchSequence: 64
            ),
            requiresReviewRefresh: false
        )
        let failedReservation = try #require(
            coordinator.reserveForegroundRefreshPass(for: .file)
        )
        coordinator.completeRefreshPass(failedReservation, outcome: .failed)
        coordinator.recordCurrentFileRefreshFailure(
            .init(failureKind: .fileSourceUnavailable)
        )

        // Act
        let retryBegan = coordinator.beginExplicitFileRefreshRetry()
        let retryReservation = try #require(
            coordinator.reserveForegroundRefreshPass(for: .file)
        )

        // Assert
        #expect(retryBegan)
        #expect(retryReservation.authorityGeneration > failedReservation.authorityGeneration)
        #expect(retryReservation.filePaths == ["Sources/App/Retry.swift"])
        #expect(coordinator.productPresentationSnapshot.fileRefreshFailure == nil)
    }

    @Test("new File invalidation clears retained refresh failure and admits current dirty work")
    func newFileInvalidationClearsRetainedRefreshFailureAndAdmitsCurrentDirtyWork() throws {
        // Arrange
        let coordinator = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        coordinator.recordCurrentFileRefreshFailure(
            .init(failureKind: .fileSourceUnavailable)
        )
        let unavailableRevision = coordinator.productPresentationSnapshot.presentationRevision

        // Act
        coordinator.recordInvalidation(
            fileChangeset: makeFileChangeset(
                paths: ["Sources/App/Recovered.swift"],
                batchSequence: 65
            ),
            requiresReviewRefresh: false
        )
        let reservation = try #require(coordinator.reserveForegroundRefreshPass(for: .file))

        // Assert
        let presentation = coordinator.productPresentationSnapshot
        #expect(presentation.fileRefreshFailure == nil)
        #expect(presentation.presentationRevision > unavailableRevision)
        #expect(presentation.refreshingLanes == [.file])
        #expect(reservation.filePaths == ["Sources/App/Recovered.swift"])
    }

    @Test("only the pending comparison attempt is current for publication")
    func onlyPendingComparisonAttemptIsCurrentForPublication() {
        // Arrange
        let coordinator = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)

        // Act
        coordinator.beginReviewComparisonAttempt(
            activeTarget: .branch(name: "stack/first"),
            reviewGeneration: 8
        )
        let firstAttemptWasPending = coordinator.isReviewComparisonAttemptPending(
            reviewGeneration: 8
        )
        coordinator.beginReviewComparisonAttempt(
            activeTarget: .branch(name: "stack/second"),
            reviewGeneration: 9
        )

        // Assert
        #expect(firstAttemptWasPending)
        #expect(!coordinator.isReviewComparisonAttemptPending(reviewGeneration: 8))
        #expect(coordinator.isReviewComparisonAttemptPending(reviewGeneration: 9))
    }

    @Test("successor comparison keeps the displayed predecessor stale until settlement")
    func successorComparisonKeepsDisplayedPredecessorStaleUntilSettlement() throws {
        // Arrange
        let predecessor = BridgePaneReviewDisplayedSnapshotIdentity(
            packageId: "package-7",
            reviewGeneration: 7,
            revision: 11
        )
        let successor = BridgePaneReviewDisplayedSnapshotIdentity(
            packageId: "package-8",
            reviewGeneration: 8,
            revision: 12
        )
        let coordinator = BridgePaneRefreshAdmissionCoordinator(
            initialActivity: .foreground,
            initialReviewComparison: BridgePaneReviewComparisonPresentation(
                activeTarget: .branch(name: "main"),
                attempt: .settled(reviewGeneration: 7),
                displayedSnapshot: .current(predecessor)
            )
        )
        let initialRevision = coordinator.productPresentationSnapshot.presentationRevision

        // Act
        coordinator.beginReviewComparisonAttempt(
            activeTarget: .branch(name: "stack/base"),
            reviewGeneration: 8
        )
        let pending = coordinator.productPresentationSnapshot
        coordinator.settleReviewComparisonAttempt(
            reviewGeneration: 8,
            displayedSnapshotIdentity: successor
        )
        let settled = coordinator.productPresentationSnapshot

        // Assert
        #expect(pending.presentationRevision == initialRevision + 1)
        #expect(pending.reviewComparison?.activeTarget == .branch(name: "stack/base"))
        #expect(pending.reviewComparison?.attempt == .pending(reviewGeneration: 8))
        #expect(pending.reviewComparison?.displayedSnapshot == .stale(predecessor))
        #expect(settled.presentationRevision == initialRevision + 2)
        #expect(settled.reviewComparison?.attempt == .settled(reviewGeneration: 8))
        #expect(settled.reviewComparison?.displayedSnapshot == .current(successor))
    }

    @Test("committed refresh advances the displayed comparison snapshot without a pending target attempt")
    func committedRefreshAdvancesDisplayedComparisonSnapshotWithoutPendingTargetAttempt() {
        // Arrange
        let predecessor = BridgePaneReviewDisplayedSnapshotIdentity(
            packageId: "package-7",
            reviewGeneration: 7,
            revision: 11
        )
        let refreshed = BridgePaneReviewDisplayedSnapshotIdentity(
            packageId: "package-8",
            reviewGeneration: 8,
            revision: 12
        )
        let coordinator = BridgePaneRefreshAdmissionCoordinator(
            initialActivity: .foreground,
            initialReviewComparison: BridgePaneReviewComparisonPresentation(
                activeTarget: .branch(name: "main"),
                attempt: .settled(reviewGeneration: 7),
                displayedSnapshot: .current(predecessor)
            )
        )
        let initialRevision = coordinator.productPresentationSnapshot.presentationRevision

        // Act
        coordinator.recordCommittedReviewComparisonSnapshot(
            reviewGeneration: 8,
            displayedSnapshotIdentity: refreshed
        )

        // Assert
        let presentation = coordinator.productPresentationSnapshot
        #expect(presentation.presentationRevision == initialRevision + 1)
        #expect(presentation.reviewComparison?.attempt == .settled(reviewGeneration: 7))
        #expect(presentation.reviewComparison?.displayedSnapshot == .current(refreshed))
    }

    @Test("newer committed generation settles a pending comparison attempt")
    func newerCommittedGenerationSettlesPendingComparisonAttempt() {
        // Arrange — foreground cancellation may re-arm the same target under a successor generation.
        let predecessor = BridgePaneReviewDisplayedSnapshotIdentity(
            packageId: "package-7",
            reviewGeneration: 7,
            revision: 11
        )
        let successor = BridgePaneReviewDisplayedSnapshotIdentity(
            packageId: "package-9",
            reviewGeneration: 9,
            revision: 13
        )
        let coordinator = BridgePaneRefreshAdmissionCoordinator(
            initialActivity: .foreground,
            initialReviewComparison: BridgePaneReviewComparisonPresentation(
                activeTarget: .branch(name: "main"),
                attempt: .settled(reviewGeneration: 7),
                displayedSnapshot: .current(predecessor)
            )
        )
        coordinator.beginReviewComparisonAttempt(
            activeTarget: .branch(name: "stack/base"),
            reviewGeneration: 8
        )

        // Act
        coordinator.recordCommittedReviewComparisonSnapshot(
            reviewGeneration: 9,
            displayedSnapshotIdentity: successor
        )

        // Assert
        #expect(
            coordinator.productPresentationSnapshot.reviewComparison
                == BridgePaneReviewComparisonPresentation(
                    activeTarget: .branch(name: "stack/base"),
                    attempt: .settled(reviewGeneration: 9),
                    displayedSnapshot: .current(successor)
                )
        )
    }

    @Test("committed refresh repairs an unavailable comparison attempt")
    func committedRefreshRepairsUnavailableComparisonAttempt() {
        // Arrange
        let predecessor = BridgePaneReviewDisplayedSnapshotIdentity(
            packageId: "package-7",
            reviewGeneration: 7,
            revision: 11
        )
        let recovered = BridgePaneReviewDisplayedSnapshotIdentity(
            packageId: "package-9",
            reviewGeneration: 9,
            revision: 13
        )
        let coordinator = BridgePaneRefreshAdmissionCoordinator(
            initialActivity: .foreground,
            initialReviewComparison: BridgePaneReviewComparisonPresentation(
                activeTarget: .branch(name: "main"),
                attempt: .settled(reviewGeneration: 7),
                displayedSnapshot: .current(predecessor)
            )
        )
        coordinator.beginReviewComparisonAttempt(
            activeTarget: .branch(name: "stack/base"),
            reviewGeneration: 8
        )
        coordinator.failReviewComparisonAttempt(
            reviewGeneration: 8,
            failureKind: "providerUnavailable",
            retryable: true
        )

        // Act
        coordinator.recordCommittedReviewComparisonSnapshot(
            reviewGeneration: 9,
            displayedSnapshotIdentity: recovered
        )

        // Assert
        #expect(
            coordinator.productPresentationSnapshot.reviewComparison
                == BridgePaneReviewComparisonPresentation(
                    activeTarget: .branch(name: "stack/base"),
                    attempt: .settled(reviewGeneration: 9),
                    displayedSnapshot: .current(recovered)
                )
        )
    }

    @Test("comparison transitions retain the published repository default target")
    func comparisonTransitionsRetainPublishedRepositoryDefaultTarget() throws {
        let repositoryDefaultTarget = BridgeReviewComparisonDefaultTargetIdentity(
            remoteName: "origin",
            branchName: "main"
        )
        let coordinator = BridgePaneRefreshAdmissionCoordinator(
            initialActivity: .foreground,
            initialReviewComparison: BridgePaneReviewComparisonPresentation(
                activeTarget: nil,
                attempt: .selectionRequired,
                displayedSnapshot: .absent
            )
        )

        coordinator.publishReviewComparisonDefaultTarget(repositoryDefaultTarget)
        coordinator.beginReviewComparisonAttempt(
            activeTarget: .originDefaultBranch(remoteName: "origin", branchName: "main"),
            reviewGeneration: 8
        )
        coordinator.failReviewComparisonAttempt(
            reviewGeneration: 8,
            failureKind: "git.unresolvedTarget",
            retryable: true
        )

        #expect(
            coordinator.productPresentationSnapshot.reviewComparison?.repositoryDefaultTarget
                == repositoryDefaultTarget
        )
    }

    @Test("current comparison failure retains the displayed predecessor as stale")
    func currentComparisonFailureRetainsDisplayedPredecessorAsStale() {
        // Arrange
        let predecessor = BridgePaneReviewDisplayedSnapshotIdentity(
            packageId: "package-7",
            reviewGeneration: 7,
            revision: 11
        )
        let coordinator = BridgePaneRefreshAdmissionCoordinator(
            initialActivity: .foreground,
            initialReviewComparison: BridgePaneReviewComparisonPresentation(
                activeTarget: .branch(name: "main"),
                attempt: .settled(reviewGeneration: 7),
                displayedSnapshot: .current(predecessor)
            )
        )
        coordinator.beginReviewComparisonAttempt(
            activeTarget: .branch(name: "stack/base"),
            reviewGeneration: 8
        )

        // Act
        coordinator.failReviewComparisonAttempt(
            reviewGeneration: 8,
            failureKind: "git.unresolvedTarget",
            retryable: true
        )

        // Assert
        #expect(
            coordinator.productPresentationSnapshot.reviewComparison
                == BridgePaneReviewComparisonPresentation(
                    activeTarget: .branch(name: "stack/base"),
                    attempt: .unavailable(
                        failureKind: "git.unresolvedTarget",
                        retryable: true
                    ),
                    displayedSnapshot: .stale(predecessor)
                )
        )
    }

    @Test("successor failure clears pending attempt while stale failure does not")
    func successorFailureClearsPendingAttemptWhileStaleFailureDoesNot() {
        // Arrange
        let predecessor = BridgePaneReviewDisplayedSnapshotIdentity(
            packageId: "package-7",
            reviewGeneration: 7,
            revision: 11
        )
        let coordinator = BridgePaneRefreshAdmissionCoordinator(
            initialActivity: .foreground,
            initialReviewComparison: BridgePaneReviewComparisonPresentation(
                activeTarget: .branch(name: "main"),
                attempt: .settled(reviewGeneration: 7),
                displayedSnapshot: .current(predecessor)
            )
        )
        coordinator.beginReviewComparisonAttempt(
            activeTarget: .branch(name: "stack/base"),
            reviewGeneration: 8
        )

        // Act
        coordinator.failReviewComparisonAttempt(
            reviewGeneration: 7,
            failureKind: "stale_failure",
            retryable: true
        )

        // Assert
        #expect(coordinator.productPresentationSnapshot.reviewComparison?.attempt == .pending(reviewGeneration: 8))

        // Act
        coordinator.failReviewComparisonAttempt(
            reviewGeneration: 9,
            failureKind: "successor_failure",
            retryable: true
        )

        // Assert
        #expect(
            coordinator.productPresentationSnapshot.reviewComparison?.attempt
                == .unavailable(failureKind: "successor_failure", retryable: true)
        )
    }

    @Test("loaded-hidden invalidation storms accumulate in one pane-wide dirty fact")
    func loadedHiddenInvalidationStormAccumulatesOneDirtyFact() throws {
        // Arrange
        let coordinator = BridgePaneRefreshAdmissionCoordinator()
        coordinator.applyActivity(.loadedHidden)

        // Act
        coordinator.recordInvalidation(
            fileChangeset: makeFileChangeset(
                paths: ["Sources/App/First.swift"],
                batchSequence: 41
            ),
            requiresReviewRefresh: true
        )
        let firstDirtyFact = try #require(coordinator.diagnosticSnapshot.dirtyFact)
        coordinator.recordInvalidation(
            fileChangeset: makeFileChangeset(
                paths: ["Sources/App/Second.swift", "Sources/App/First.swift"],
                batchSequence: 42
            ),
            requiresReviewRefresh: true
        )
        coordinator.recordInvalidation(
            fileChangeset: makeFileChangeset(
                paths: ["Tests/App/FirstTests.swift"],
                batchSequence: 43
            ),
            requiresReviewRefresh: true
        )

        // Assert
        let accumulatedDirtyFact = try #require(coordinator.diagnosticSnapshot.dirtyFact)
        #expect(accumulatedDirtyFact.generation == firstDirtyFact.generation)
        #expect(
            accumulatedDirtyFact.filePaths
                == [
                    "Sources/App/First.swift",
                    "Sources/App/Second.swift",
                    "Tests/App/FirstTests.swift",
                ]
        )
        #expect(accumulatedDirtyFact.latestBatchSequence == 43)
        #expect(accumulatedDirtyFact.requiresReviewRefresh)
        #expect(coordinator.diagnosticSnapshot.activeRefreshPass == nil)
        #expect(coordinator.diagnosticSnapshot.refreshPassCount == 0)
    }

    @Test("foreground transition reserves independent latest File and Review catch-ups")
    func foregroundTransitionReservesIndependentLatestCatchUps() throws {
        // Arrange
        let coordinator = BridgePaneRefreshAdmissionCoordinator()
        coordinator.applyActivity(.loadedHidden)
        coordinator.recordInvalidation(
            fileChangeset: makeFileChangeset(
                paths: ["Sources/App/First.swift"],
                batchSequence: 51
            ),
            requiresReviewRefresh: true
        )
        coordinator.recordInvalidation(
            fileChangeset: makeFileChangeset(
                paths: ["Sources/App/Latest.swift"],
                batchSequence: 52
            ),
            requiresReviewRefresh: true
        )

        // Act
        coordinator.applyActivity(.foreground)
        let reservation = try #require(coordinator.reserveForegroundRefreshPass())
        coordinator.applyActivity(.foreground)
        let reviewReservation = try #require(coordinator.reserveForegroundRefreshPass())
        coordinator.applyActivity(.foreground)
        let thirdForegroundReservation = coordinator.reserveForegroundRefreshPass()

        // Assert
        #expect(
            reservation.filePaths
                == [
                    "Sources/App/First.swift",
                    "Sources/App/Latest.swift",
                ]
        )
        #expect(reservation.latestBatchSequence == 52)
        #expect(reservation.lanes == [.file])
        #expect(!reservation.requiresReviewRefresh)
        #expect(reviewReservation.lanes == [.review])
        #expect(reviewReservation.requiresReviewRefresh)
        #expect(reservation.operationCorrelationID.count == 64)
        #expect(reviewReservation.operationCorrelationID.count == 64)
        #expect(reservation.operationCorrelationID != reviewReservation.operationCorrelationID)
        #expect(
            coordinator.productPresentationSnapshot.operationCorrelationID
                == reviewReservation.operationCorrelationID
        )
        #expect(thirdForegroundReservation == nil)
        #expect(coordinator.diagnosticSnapshot.activeRefreshPass?.id == reservation.id)
        #expect(coordinator.productPresentationSnapshot.refreshingLanes == [.file, .review])
        #expect(coordinator.diagnosticSnapshot.refreshPassCount == 2)
    }

    @Test("File reservation proceeds while a Review-only reservation remains active")
    func fileReservationProceedsWhileReviewReservationRemainsActive() throws {
        // Arrange
        let coordinator = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        coordinator.recordInvalidation(
            fileChangeset: nil,
            requiresReviewRefresh: true
        )
        let reviewReservation = try #require(coordinator.reserveForegroundRefreshPass())

        // Act
        coordinator.recordInvalidation(
            fileChangeset: makeFileChangeset(
                paths: ["Sources/App/FileWhileReviewDrains.swift"],
                batchSequence: 53
            ),
            requiresReviewRefresh: false
        )
        let fileReservation = coordinator.reserveForegroundRefreshPass()

        // Assert
        #expect(reviewReservation.lanes == [.review])
        #expect(fileReservation?.lanes == [.file])
        #expect(fileReservation?.filePaths == ["Sources/App/FileWhileReviewDrains.swift"])
        #expect(coordinator.productPresentationSnapshot.refreshingLanes == [.file, .review])
    }

    @Test("Review authority 12 rejects late completion from 10 and 11")
    func newestReviewAuthorityRejectsLatePredecessorCompletion() throws {
        // Arrange — operation 10 owns the first Review invalidation.
        let coordinator = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        coordinator.recordInvalidation(fileChangeset: nil, requiresReviewRefresh: true)
        let operation10 = try #require(
            coordinator.reserveForegroundRefreshPass(for: .review)
        )

        // Act — 11 and then 12 supersede current authority before either predecessor settles.
        coordinator.recordInvalidation(fileChangeset: nil, requiresReviewRefresh: true)
        let operation11 = try #require(
            coordinator.reserveForegroundRefreshPass(for: .review)
        )
        coordinator.recordInvalidation(fileChangeset: nil, requiresReviewRefresh: true)
        let operation12 = try #require(
            coordinator.reserveForegroundRefreshPass(for: .review)
        )
        coordinator.completeRefreshPass(operation10, outcome: .succeeded)
        coordinator.completeRefreshPass(operation11, outcome: .failed)

        // Assert — late predecessors cannot clear 12 or restore their facts over it.
        #expect(operation10.authorityGeneration < operation11.authorityGeneration)
        #expect(operation11.authorityGeneration < operation12.authorityGeneration)
        #expect(operation10.operationCorrelationID != operation11.operationCorrelationID)
        #expect(operation11.operationCorrelationID != operation12.operationCorrelationID)
        #expect(!coordinator.isRefreshPassCurrent(operation10))
        #expect(!coordinator.isRefreshPassCurrent(operation11))
        #expect(coordinator.isRefreshPassCurrent(operation12))
        #expect(coordinator.diagnosticSnapshot.activeRefreshPass?.id == operation12.id)
        #expect(coordinator.diagnosticSnapshot.dirtyFact == nil)

        // Act / Assert — only 12 can settle current Review authority.
        coordinator.completeRefreshPass(operation12, outcome: .succeeded)
        #expect(coordinator.diagnosticSnapshot.activeRefreshPass == nil)
        #expect(coordinator.diagnosticSnapshot.dirtyFact == nil)
    }

    @Test("loaded-hidden coalescing retains only the latest File status snapshot")
    func loadedHiddenCoalescingRetainsLatestFileStatusSnapshot() throws {
        // Arrange
        let coordinator = BridgePaneRefreshAdmissionCoordinator()
        coordinator.applyActivity(.loadedHidden)
        let earlierStatus = makeGitWorkingTreeStatus(
            branch: "feature/earlier",
            changed: 1,
            staged: 0,
            untracked: 0
        )
        let latestStatus = makeGitWorkingTreeStatus(
            branch: "feature/latest",
            changed: 2,
            staged: 1,
            untracked: 3
        )

        // Act
        coordinator.recordInvalidation(
            fileChangeset: nil,
            latestFileStatus: earlierStatus,
            requiresReviewRefresh: true
        )
        coordinator.recordInvalidation(
            fileChangeset: nil,
            latestFileStatus: latestStatus,
            requiresReviewRefresh: true
        )
        coordinator.applyActivity(.foreground)
        let fileReservation = try #require(coordinator.reserveForegroundRefreshPass())
        let reviewReservation = try #require(coordinator.reserveForegroundRefreshPass())

        // Assert
        #expect(fileReservation.fileChangeset == nil)
        #expect(fileReservation.latestFileStatus == latestStatus)
        #expect(fileReservation.lanes == [.file])
        #expect(reviewReservation.lanes == [.review])
        #expect(coordinator.diagnosticSnapshot.refreshPassCount == 2)
    }

    @Test("successful completion clears dirty while failure retains it for explicit retry")
    func catchUpCompletionControlsDirtyRetentionWithoutSpinning() throws {
        // Arrange
        let coordinator = BridgePaneRefreshAdmissionCoordinator()
        coordinator.applyActivity(.loadedHidden)
        coordinator.recordInvalidation(
            fileChangeset: makeFileChangeset(
                paths: ["Sources/App/Retry.swift"],
                batchSequence: 61
            ),
            requiresReviewRefresh: true
        )
        coordinator.applyActivity(.foreground)
        let failedReservation = try #require(coordinator.reserveForegroundRefreshPass())

        // Act — a failed pass releases its reservation but retains the pane dirty fact.
        coordinator.completeRefreshPass(failedReservation, outcome: .failed)

        // Assert
        #expect(coordinator.diagnosticSnapshot.dirtyFact != nil)
        #expect(coordinator.diagnosticSnapshot.activeRefreshPass == nil)
        #expect(coordinator.diagnosticSnapshot.refreshPassCount == 1)
        coordinator.applyActivity(.foreground)
        #expect(coordinator.diagnosticSnapshot.refreshPassCount == 1)

        // Act — only an explicit retry can reserve the retained fact.
        let retryReservation = try #require(coordinator.reserveForegroundRefreshPass())
        coordinator.completeRefreshPass(retryReservation, outcome: .succeeded)

        // Assert — the File lane is current, while the independent Review lane remains dirty.
        #expect(retryReservation.dirtyGeneration == failedReservation.dirtyGeneration)
        #expect(coordinator.diagnosticSnapshot.dirtyFact?.requiresReviewRefresh == true)
        #expect(coordinator.diagnosticSnapshot.activeRefreshPass == nil)
        #expect(coordinator.diagnosticSnapshot.refreshPassCount == 2)

        // Act — settle the retained Review lane independently.
        let reviewReservation = try #require(coordinator.reserveForegroundRefreshPass())
        coordinator.completeRefreshPass(reviewReservation, outcome: .succeeded)

        // Assert
        #expect(reviewReservation.lanes == [.review])
        #expect(coordinator.diagnosticSnapshot.dirtyFact == nil)
        #expect(coordinator.diagnosticSnapshot.activeRefreshPass == nil)
        #expect(coordinator.diagnosticSnapshot.refreshPassCount == 3)
        #expect(coordinator.reserveForegroundRefreshPass() == nil)
    }

    @Test("foreground to loaded-hidden invalidates the admitted activity epoch")
    func loadedHiddenTransitionRejectsLateReviewAndFileOutput() throws {
        // Arrange
        let coordinator = BridgePaneRefreshAdmissionCoordinator()
        coordinator.applyActivity(.foreground)
        let admittedActivityEpoch = try #require(coordinator.acquireForegroundWork())
        let admittedEpoch = coordinator.diagnosticSnapshot.foregroundWorkEpoch
        var reviewPublicationCount = 0
        var fileMetadataPublicationCount = 0
        var fileBodyPublicationCount = 0

        // Act
        coordinator.applyActivity(.loadedHidden)
        let lateReviewPublication = admittedActivityEpoch.withValidAdmission {
            reviewPublicationCount += 1
            return true
        }
        let lateFileMetadataPublication = admittedActivityEpoch.withValidAdmission {
            fileMetadataPublicationCount += 1
            return true
        }
        let lateFileBodyPublication = admittedActivityEpoch.withValidAdmission {
            fileBodyPublicationCount += 1
            return true
        }

        // Assert
        #expect(coordinator.diagnosticSnapshot.activity == .loadedHidden)
        #expect(coordinator.diagnosticSnapshot.foregroundWorkEpoch == admittedEpoch + 1)
        #expect(lateReviewPublication == nil)
        #expect(lateFileMetadataPublication == nil)
        #expect(lateFileBodyPublication == nil)
        #expect(reviewPublicationCount == 0)
        #expect(fileMetadataPublicationCount == 0)
        #expect(fileBodyPublicationCount == 0)
        #expect(coordinator.acquireForegroundWork() == nil)
    }

    @Test("started Review continuation remains valid while hidden and invalidates on close")
    func startedReviewContinuationSurvivesLoadedHiddenOnly() throws {
        // Arrange
        let coordinator = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        let reviewContinuation = try #require(coordinator.acquireReviewContentContinuation())
        let invalidationCounter = BridgePaneRefreshInvalidationCounter()
        let handlerId = try #require(
            reviewContinuation.registerInvalidationHandler {
                invalidationCounter.record()
            }
        )

        // Act
        coordinator.applyActivity(.loadedHidden)
        let hiddenMutation = reviewContinuation.withValidAdmission { true }

        // Assert
        #expect(hiddenMutation == true)
        #expect(invalidationCounter.isEmpty)

        // Act
        coordinator.close()
        let closedMutation = reviewContinuation.withValidAdmission { true }

        // Assert
        #expect(closedMutation == nil)
        #expect(invalidationCounter.count == 1)
        reviewContinuation.removeInvalidationHandler(handlerId)
    }

    @Test("stale completion retains dirty after its activity epoch is invalidated")
    func staleCompletionRetainsDirtyForLaterExplicitRetry() throws {
        // Arrange
        let coordinator = BridgePaneRefreshAdmissionCoordinator()
        coordinator.applyActivity(.loadedHidden)
        coordinator.recordInvalidation(
            fileChangeset: makeFileChangeset(
                paths: ["Sources/App/Stale.swift"],
                batchSequence: 71
            ),
            requiresReviewRefresh: true
        )
        coordinator.applyActivity(.foreground)
        let staleReservation = try #require(coordinator.reserveForegroundRefreshPass())

        // Act
        coordinator.applyActivity(.loadedHidden)
        coordinator.completeRefreshPass(staleReservation, outcome: .stale)

        // Assert
        #expect(coordinator.diagnosticSnapshot.activity == .loadedHidden)
        #expect(coordinator.diagnosticSnapshot.dirtyFact?.generation == staleReservation.dirtyGeneration)
        #expect(coordinator.diagnosticSnapshot.activeRefreshPass == nil)
        #expect(coordinator.diagnosticSnapshot.refreshPassCount == 1)
    }

    @Test("close is synchronous terminal and discards pending dirty work")
    func closeSynchronouslyInvalidatesPendingWorkAndClearsDirty() throws {
        // Arrange
        let coordinator = BridgePaneRefreshAdmissionCoordinator()
        coordinator.applyActivity(.loadedHidden)
        coordinator.recordInvalidation(
            fileChangeset: makeFileChangeset(
                paths: ["Sources/App/Close.swift"],
                batchSequence: 81
            ),
            requiresReviewRefresh: true
        )
        coordinator.applyActivity(.foreground)
        let reservation = try #require(coordinator.reserveForegroundRefreshPass())
        let activityEpochBeforeClose = coordinator.diagnosticSnapshot.foregroundWorkEpoch
        var lateMutationCount = 0

        // Act
        coordinator.close()
        let lateMutation = reservation.foregroundWorkAdmission.withValidAdmission {
            lateMutationCount += 1
            return true
        }
        coordinator.completeRefreshPass(reservation, outcome: .succeeded)
        let firstClosedSnapshot = coordinator.diagnosticSnapshot
        coordinator.close()

        // Assert
        #expect(lateMutation == nil)
        #expect(lateMutationCount == 0)
        #expect(firstClosedSnapshot.activity == .closed)
        #expect(firstClosedSnapshot.foregroundWorkEpoch == activityEpochBeforeClose + 1)
        #expect(firstClosedSnapshot.dirtyFact == nil)
        #expect(firstClosedSnapshot.activeRefreshPass == nil)
        #expect(coordinator.diagnosticSnapshot.foregroundWorkEpoch == firstClosedSnapshot.foregroundWorkEpoch)
        #expect(coordinator.diagnosticSnapshot.dirtyFact == nil)
        coordinator.applyActivity(.foreground)
        #expect(coordinator.reserveForegroundRefreshPass() == nil)
        #expect(coordinator.acquireForegroundWork() == nil)
    }
}

private final class BridgePaneRefreshInvalidationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var isEmpty: Bool {
        lock.withLock { storedCount == 0 }
    }

    var count: Int {
        lock.withLock { storedCount }
    }

    func record() {
        lock.withLock { storedCount += 1 }
    }
}

private func makeFileChangeset(
    paths: [String],
    batchSequence: UInt64,
    worktreeId: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
    containsGitInternalChanges: Bool = false,
    suppressedIgnoredPathCount: Int = 0,
    suppressedGitInternalPathCount: Int = 0
) -> FileChangeset {
    FileChangeset(
        worktreeId: worktreeId,
        repoId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        rootPath: URL(fileURLWithPath: "/tmp/bridge-pane-refresh-admission"),
        paths: paths,
        containsGitInternalChanges: containsGitInternalChanges,
        suppressedIgnoredPathCount: suppressedIgnoredPathCount,
        suppressedGitInternalPathCount: suppressedGitInternalPathCount,
        timestamp: .now,
        batchSeq: batchSequence
    )
}

private func makeGitWorkingTreeStatus(
    branch: String,
    changed: Int,
    staged: Int,
    untracked: Int
) -> GitWorkingTreeStatus {
    GitWorkingTreeStatus(
        summary: GitWorkingTreeSummary(
            changed: changed,
            staged: staged,
            untracked: untracked
        ),
        branch: branch,
        origin: nil
    )
}
