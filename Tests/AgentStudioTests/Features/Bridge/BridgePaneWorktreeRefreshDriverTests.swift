import AgentStudioCore
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge pane worktree refresh driver")
@MainActor
struct BridgePaneWorktreeRefreshDriverTests {
    @Test("one normalized invalidation drives File work and returns the affected Review lane")
    func normalizedInvalidationDrivesFileAndReview() async throws {
        // Arrange
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let coordinator = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        let probe = try BridgePaneWorktreeRefreshDriverProbe(
            dispositions: [.notRequired]
        )
        let driver = makeRefreshDriver(
            coordinator: coordinator,
            productAdmission: productAdmission,
            probe: probe
        )

        // Act
        let affectedLanes = driver.recordInvalidation(
            fileChangeset: makeRefreshDriverChangeset(batchSequence: 71),
            latestFileStatus: nil,
            requiresReviewRefresh: true
        )
        await probe.waitForChangesetAttemptCount(1)
        try await probe.waitForSettledFilePresentation()

        // Assert
        #expect(affectedLanes == [.file, .review])
        #expect(await probe.changesetAttemptCount == 1)
        #expect(coordinator.diagnosticSnapshot.dirtyFact?.requiresReviewRefresh == true)
        #expect(coordinator.productPresentationSnapshot.refreshingLanes.isEmpty)
        await driver.closeAndDrain()
        try await probe.finishPresentationObservation()
        productAdmission.close()
    }

    @Test("retryable File failure retries once through the shared driver")
    func retryableFailureRetriesOnce() async throws {
        // Arrange
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let coordinator = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        let probe = try BridgePaneWorktreeRefreshDriverProbe(
            dispositions: [
                .failed(.init(failureKind: .fileSourceUnavailable)),
                .notRequired,
            ]
        )
        let driver = makeRefreshDriver(
            coordinator: coordinator,
            productAdmission: productAdmission,
            probe: probe
        )

        // Act
        _ = driver.recordInvalidation(
            fileChangeset: makeRefreshDriverChangeset(batchSequence: 72),
            latestFileStatus: nil,
            requiresReviewRefresh: false
        )
        await probe.waitForChangesetAttemptCount(2)
        try await probe.waitForSettledFilePresentation()

        // Assert
        #expect(await probe.changesetAttemptCount == 2)
        #expect(coordinator.diagnosticSnapshot.dirtyFact == nil)
        #expect(coordinator.productPresentationSnapshot.fileRefreshFailure == nil)
        await driver.closeAndDrain()
        try await probe.finishPresentationObservation()
        productAdmission.close()
    }

    @Test("terminal current File failure is recorded by the driver")
    func terminalCurrentFileFailureIsRecorded() async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let coordinator = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        let probe = try BridgePaneWorktreeRefreshDriverProbe(
            dispositions: [.failed(.init(failureKind: .fileRefreshFailed))]
        )
        let driver = makeRefreshDriver(
            coordinator: coordinator,
            productAdmission: productAdmission,
            probe: probe
        )

        _ = driver.recordInvalidation(
            fileChangeset: makeRefreshDriverChangeset(batchSequence: 72),
            latestFileStatus: nil,
            requiresReviewRefresh: false
        )
        await probe.waitForChangesetAttemptCount(1)
        try await probe.waitForSettledFilePresentation()

        #expect(
            coordinator.productPresentationSnapshot.fileRefreshFailure?.failureKind
                == .fileRefreshFailed
        )
        await driver.closeAndDrain()
        try await probe.finishPresentationObservation()
        productAdmission.close()
    }

    @Test("queue reset waits for a newer matching File source before replaying once")
    func queueResetWaitsForNewerMatchingSource() async throws {
        // Arrange
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let coordinator = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        let probe = try BridgePaneWorktreeRefreshDriverProbe(
            dispositions: [.streamResetRequired, .notRequired]
        )
        let driver = makeRefreshDriver(
            coordinator: coordinator,
            productAdmission: productAdmission,
            probe: probe
        )
        driver.recordFileSourceAccepted(try makeRefreshDriverSource(generation: 10))

        // Act
        _ = driver.recordInvalidation(
            fileChangeset: makeRefreshDriverChangeset(batchSequence: 73),
            latestFileStatus: nil,
            requiresReviewRefresh: false
        )
        await probe.waitForChangesetAttemptCount(1)
        try await probe.waitForSettledFilePresentation()

        // Assert
        #expect(driver.hasPendingFileStreamRecovery)
        #expect(await probe.changesetAttemptCount == 1)
        #expect(coordinator.diagnosticSnapshot.dirtyFact != nil)
        #expect(coordinator.productPresentationSnapshot.fileRefreshFailure == nil)

        // Act
        driver.recordFileSourceAccepted(try makeRefreshDriverSource(generation: 11))
        await probe.waitForChangesetAttemptCount(2)
        try await probe.waitForSettledFilePresentation()

        // Assert
        #expect(!driver.hasPendingFileStreamRecovery)
        #expect(await probe.changesetAttemptCount == 2)
        let operationCorrelationIDs = await probe.operationCorrelationIDs
        #expect(operationCorrelationIDs.count == 2)
        #expect(operationCorrelationIDs[0] == operationCorrelationIDs[1])
        #expect(await probe.operationStageAttempts == [0, 2])
        let lifecycleEvents = await probe.operationLifecycleEvents
        #expect(
            lifecycleEvents.map(\.stage) == [
                .refreshReserved,
                .refreshOperationTerminal,
                .refreshReserved,
                .refreshOperationTerminal,
            ])
        #expect(lifecycleEvents.map(\.stageAttempt) == [0, 0, 1, 1])
        #expect(lifecycleEvents.map(\.result) == [.success, .stale, .success, .success])
        #expect(coordinator.diagnosticSnapshot.dirtyFact == nil)
        #expect(coordinator.productPresentationSnapshot.fileRefreshFailure == nil)
        await driver.closeAndDrain()
        try await probe.finishPresentationObservation()
        productAdmission.close()
    }

    @Test("a replacement File source accepted before reset settlement releases replay")
    func sourceBeforeResetSettlementReleasesReplay() async throws {
        // Arrange
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let coordinator = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        let probe = try BridgePaneWorktreeRefreshDriverProbe(
            dispositions: [.notRequired],
            blocksFirstChangesetAttempt: true
        )
        let driver = makeRefreshDriver(
            coordinator: coordinator,
            productAdmission: productAdmission,
            probe: probe
        )
        driver.recordFileSourceAccepted(try makeRefreshDriverSource(generation: 20))
        _ = driver.recordInvalidation(
            fileChangeset: makeRefreshDriverChangeset(batchSequence: 74),
            latestFileStatus: nil,
            requiresReviewRefresh: false
        )
        await probe.waitForChangesetAttemptCount(1)

        // Act
        driver.recordFileSourceAccepted(try makeRefreshDriverSource(generation: 21))
        await probe.releaseBlockedChangeset(with: .streamResetRequired)
        await probe.waitForChangesetAttemptCount(2)
        try await probe.waitForSettledFilePresentation()

        // Assert
        #expect(!driver.hasPendingFileStreamRecovery)
        #expect(await probe.changesetAttemptCount == 2)
        #expect(coordinator.diagnosticSnapshot.dirtyFact == nil)
        #expect(coordinator.productPresentationSnapshot.fileRefreshFailure == nil)
        await driver.closeAndDrain()
        try await probe.finishPresentationObservation()
        productAdmission.close()
    }

    @Test("duplicate older and foreign File sources cannot release reset recovery")
    func nonReplacementSourcesCannotReleaseRecovery() async throws {
        // Arrange
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let coordinator = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        let probe = try BridgePaneWorktreeRefreshDriverProbe(
            dispositions: [.streamResetRequired, .notRequired]
        )
        let driver = makeRefreshDriver(
            coordinator: coordinator,
            productAdmission: productAdmission,
            probe: probe
        )
        driver.recordFileSourceAccepted(try makeRefreshDriverSource(generation: 30))
        _ = driver.recordInvalidation(
            fileChangeset: makeRefreshDriverChangeset(batchSequence: 75),
            latestFileStatus: nil,
            requiresReviewRefresh: false
        )
        await probe.waitForChangesetAttemptCount(1)
        try await probe.waitForSettledFilePresentation()

        // Act
        driver.recordFileSourceAccepted(try makeRefreshDriverSource(generation: 30))
        driver.recordFileSourceAccepted(try makeRefreshDriverSource(generation: 29))
        driver.recordFileSourceAccepted(
            try makeRefreshDriverSource(
                generation: 31,
                repoId: "00000000-0000-7000-8000-000000000099"
            )
        )
        driver.recordFileSourceAccepted(
            try makeRefreshDriverSource(
                generation: 31,
                rootRevisionToken: "foreign-root"
            )
        )
        await Task.yield()

        // Assert
        #expect(driver.hasPendingFileStreamRecovery)
        #expect(await probe.changesetAttemptCount == 1)

        // Act
        driver.recordFileSourceAccepted(try makeRefreshDriverSource(generation: 31))
        await probe.waitForChangesetAttemptCount(2)
        try await probe.waitForSettledFilePresentation()

        // Assert
        #expect(!driver.hasPendingFileStreamRecovery)
        #expect(await probe.changesetAttemptCount == 2)
        await driver.closeAndDrain()
        try await probe.finishPresentationObservation()
        productAdmission.close()
    }

    @Test("an invalidation during reset recovery merges into the replacement replay")
    func invalidationDuringRecoveryMergesIntoReplay() async throws {
        // Arrange
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let coordinator = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        let probe = try BridgePaneWorktreeRefreshDriverProbe(
            dispositions: [.streamResetRequired, .notRequired]
        )
        let driver = makeRefreshDriver(
            coordinator: coordinator,
            productAdmission: productAdmission,
            probe: probe
        )
        driver.recordFileSourceAccepted(try makeRefreshDriverSource(generation: 40))
        _ = driver.recordInvalidation(
            fileChangeset: makeRefreshDriverChangeset(
                batchSequence: 76,
                path: "Sources/First.swift"
            ),
            latestFileStatus: nil,
            requiresReviewRefresh: false
        )
        await probe.waitForChangesetAttemptCount(1)
        try await probe.waitForSettledFilePresentation()

        // Act
        _ = driver.recordInvalidation(
            fileChangeset: makeRefreshDriverChangeset(
                batchSequence: 77,
                path: "Sources/Second.swift"
            ),
            latestFileStatus: nil,
            requiresReviewRefresh: false
        )
        await Task.yield()

        // Assert
        #expect(await probe.changesetAttemptCount == 1)
        #expect(driver.hasPendingFileStreamRecovery)

        // Act
        driver.recordFileSourceAccepted(try makeRefreshDriverSource(generation: 41))
        await probe.waitForChangesetAttemptCount(2)
        try await probe.waitForSettledFilePresentation()

        // Assert
        let replayedChangeset = try #require(await probe.changesets.last)
        #expect(replayedChangeset.batchSeq == 77)
        #expect(replayedChangeset.paths == ["Sources/First.swift", "Sources/Second.swift"])
        #expect(coordinator.diagnosticSnapshot.dirtyFact == nil)
        await driver.closeAndDrain()
        try await probe.finishPresentationObservation()
        productAdmission.close()
    }

    @Test("close clears reset recovery and late source acceptance cannot restart File work")
    func closeRejectsLateSourceAcceptance() async throws {
        // Arrange
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let coordinator = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        let probe = try BridgePaneWorktreeRefreshDriverProbe(
            dispositions: [.streamResetRequired]
        )
        let driver = makeRefreshDriver(
            coordinator: coordinator,
            productAdmission: productAdmission,
            probe: probe
        )
        driver.recordFileSourceAccepted(try makeRefreshDriverSource(generation: 50))
        _ = driver.recordInvalidation(
            fileChangeset: makeRefreshDriverChangeset(batchSequence: 78),
            latestFileStatus: nil,
            requiresReviewRefresh: false
        )
        await probe.waitForChangesetAttemptCount(1)
        try await probe.waitForSettledFilePresentation()

        // Act
        await driver.closeAndDrain()
        try await probe.finishPresentationObservation()
        driver.recordFileSourceAccepted(try makeRefreshDriverSource(generation: 51))
        await Task.yield()

        // Assert
        #expect(!driver.hasPendingFileStreamRecovery)
        #expect(await probe.changesetAttemptCount == 1)
        productAdmission.close()
    }
}

private actor BridgePaneWorktreeRefreshDriverProbe {
    private let presentationFacts = LocalFactSource<Int, BridgePaneProductPresentationSnapshot>(
        vocabulary: .init(
            describeScope: { "File publication attempt \($0)" },
            describeFact: { "presentation \($0.presentationRevision), refreshing \($0.refreshingLanes)" },
            isClosing: { _, _ in false }
        )
    )
    private let presentationRecorder: FactRecorder<Int, BridgePaneProductPresentationSnapshot>
    private var dispositions: [BridgePaneProductFileRefreshPublicationDisposition]
    private let blocksFirstChangesetAttempt: Bool
    private var blockedChangesetContinuation:
        CheckedContinuation<BridgePaneProductFileRefreshPublicationDisposition, Never>?
    private var changesetAttemptWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var changesetAttemptCount = 0
    private(set) var changesets: [FileChangeset] = []
    private(set) var operationCorrelationIDs: [String] = []
    private(set) var operationStageAttempts: [Int] = []
    private(set) var operationLifecycleEvents: [BridgeOperationLifecycleTraceEvent] = []
    private(set) var presentations: [BridgePaneProductPresentationSnapshot] = []

    init(
        dispositions: [BridgePaneProductFileRefreshPublicationDisposition],
        blocksFirstChangesetAttempt: Bool = false
    ) throws {
        presentationRecorder = try presentationFacts.attach()
        self.dispositions = dispositions
        self.blocksFirstChangesetAttempt = blocksFirstChangesetAttempt
    }

    func publishChangeset(
        _ changeset: FileChangeset,
        _: BridgeProductAdmissionContext,
        _: BridgePaneRefreshWorkAdmission,
        operationCorrelationID: String,
        operationStageAttempt: Int
    ) async -> BridgePaneProductFileRefreshPublicationDisposition {
        changesetAttemptCount += 1
        changesets.append(changeset)
        operationCorrelationIDs.append(operationCorrelationID)
        operationStageAttempts.append(operationStageAttempt)
        resumeChangesetAttemptWaiters()
        if blocksFirstChangesetAttempt, changesetAttemptCount == 1 {
            return await withCheckedContinuation { continuation in
                blockedChangesetContinuation = continuation
            }
        }
        guard !dispositions.isEmpty else { return .notRequired }
        return dispositions.removeFirst()
    }

    func releaseBlockedChangeset(
        with disposition: BridgePaneProductFileRefreshPublicationDisposition
    ) {
        blockedChangesetContinuation?.resume(returning: disposition)
        blockedChangesetContinuation = nil
    }

    func publishStatus(
        _: GitWorkingTreeStatus,
        _: BridgeProductAdmissionContext,
        _: BridgePaneRefreshWorkAdmission,
        operationCorrelationID _: String,
        operationStageAttempt _: Int
    ) -> BridgePaneProductFileRefreshPublicationDisposition {
        .notRequired
    }

    func publishPresentation(
        _ snapshot: BridgePaneProductPresentationSnapshot,
        _: BridgeTraceContext?,
        isCurrentPresentation: Bool
    ) {
        presentations.append(snapshot)
        if isCurrentPresentation, !snapshot.refreshingLanes.contains(.file) {
            presentationFacts.sink(changesetAttemptCount, snapshot)
        }
    }

    func waitForSettledFilePresentation() async throws {
        _ = try await presentationRecorder.expectNext(
            in: changesetAttemptCount,
            where: { !$0.refreshingLanes.contains(.file) },
            "File pass has completed and published its settled presentation"
        )
    }

    func finishPresentationObservation() async throws {
        presentationFacts.end()
        try await presentationRecorder.finish()
    }

    func publishOperationLifecycle(_ event: BridgeOperationLifecycleTraceEvent) {
        operationLifecycleEvents.append(event)
    }

    func waitForChangesetAttemptCount(_ expectedCount: Int) async {
        guard changesetAttemptCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            changesetAttemptWaiters.append((expectedCount, continuation))
        }
    }

    private func resumeChangesetAttemptWaiters() {
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for (expectedCount, continuation) in changesetAttemptWaiters {
            if changesetAttemptCount >= expectedCount {
                continuation.resume()
            } else {
                pending.append((expectedCount, continuation))
            }
        }
        changesetAttemptWaiters = pending
    }
}

@MainActor
private func makeRefreshDriver(
    coordinator: BridgePaneRefreshAdmissionCoordinator,
    productAdmission: BridgeProductAdmissionTestContext,
    probe: BridgePaneWorktreeRefreshDriverProbe
) -> BridgePaneWorktreeRefreshDriver {
    BridgePaneWorktreeRefreshDriver(
        coordinator: coordinator,
        acquireProductAdmission: { productAdmission.context },
        publishFileChangeset: { changeset, admission, work, correlationID, attempt in
            await probe.publishChangeset(
                changeset,
                admission,
                work,
                operationCorrelationID: correlationID,
                operationStageAttempt: attempt
            )
        },
        publishFileStatus: { status, admission, work, correlationID, attempt in
            await probe.publishStatus(
                status,
                admission,
                work,
                operationCorrelationID: correlationID,
                operationStageAttempt: attempt
            )
        },
        publishPresentation: { snapshot, traceContext in
            let isCurrentPresentation = await MainActor.run {
                coordinator.productPresentationSnapshot == snapshot
            }
            await probe.publishPresentation(
                snapshot, traceContext, isCurrentPresentation: isCurrentPresentation
            )
        },
        publishOperationLifecycle: { event in
            await probe.publishOperationLifecycle(event)
        }
    )
}

private func makeRefreshDriverChangeset(
    batchSequence: UInt64,
    path: String = "Sources/App.swift"
) -> FileChangeset {
    FileChangeset(
        worktreeId: UUID(uuidString: "00000000-0000-7000-8000-000000000001")!,
        repoId: UUID(uuidString: "00000000-0000-7000-8000-000000000002")!,
        rootPath: URL(fileURLWithPath: "/tmp/bridge-refresh-driver"),
        paths: [path],
        timestamp: .now,
        batchSeq: batchSequence
    )
}

private func makeRefreshDriverSource(
    generation: Int,
    repoId: String = "00000000-0000-7000-8000-000000000002",
    rootRevisionToken: String = "bridge-refresh-driver-root",
    worktreeId: String = "00000000-0000-7000-8000-000000000001"
) throws -> BridgeProductFileSourceIdentity {
    try BridgeProductFileSourceIdentity(
        repoId: repoId,
        rootRevisionToken: rootRevisionToken,
        sourceCursor: "generation-\(generation)",
        sourceId: "bridge-refresh-driver-source-\(generation)",
        subscriptionGeneration: generation,
        worktreeId: worktreeId
    )
}
