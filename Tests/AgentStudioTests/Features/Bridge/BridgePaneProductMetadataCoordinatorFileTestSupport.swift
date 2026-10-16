import AgentStudioCore
import AgentStudioTestHarness
import Foundation

@testable import AgentStudioBridge

struct CoordinatorFileUpdateStartObservation: Sendable {
    let openFinished: Bool
    let sourceAccepted: Bool
}

private enum CoordinatorFileTestError: Error {
    case unexpectedSourceAcceptedEvent
}

actor CoordinatorGatedFileMetadataSource: BridgePaneProductFileMetadataProducing {
    func captureKeyedSnapshot(
        subscriptionId _: String,
        demand _: BridgePaneProductFileViewDemand,
        productAdmission _: BridgeProductAdmissionContext
    ) async -> BridgeWorktreeFileKeyedSnapshot? { nil }

    private var didFinishOpen = false
    private var acceptedSource: BridgeProductFileSourceIdentity?
    private var openStartCount = 0
    private var updateStartObservation: CoordinatorFileUpdateStartObservation?
    private var acceptanceWaiters: [CheckedContinuation<BridgeProductFileSourceIdentity, Never>] = []
    private var finishWaiters: [CheckedContinuation<Bool, Never>] = []
    private var isSourceAcceptanceReleased = false
    private var isOpenReleased = false
    private let openCompletionStep = HeldStep<Void>("file open completion", cancellation: .holdThroughCancellation)
    private let sourceAcceptanceStep = HeldStep<Void>("file source acceptance", cancellation: .holdThroughCancellation)
    private var startWaiters: [CheckedContinuation<Int, Never>] = []
    private var updateWaiters: [CheckedContinuation<CoordinatorFileUpdateStartObservation, Never>] = []
    private(set) var openObservedCancellation = false
    private(set) var updateObservedOpenFinished = false
    private(set) var updateObservedSourceAccepted = false

    func currentSource() -> BridgeProductFileSourceCurrentResult {
        .unavailable(.noFileSourceAuthority)
    }

    func open(
        subscription _: BridgeProductSubscriptionSnapshot,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission,
        emit: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {
        openStartCount += 1
        for waiter in startWaiters { waiter.resume(returning: openStartCount) }
        startWaiters.removeAll(keepingCapacity: false)
        if !isSourceAcceptanceReleased {
            try await sourceAcceptanceStep.arrive(())
        }
        let sourceEvent = try coordinatorSourceAcceptedEvent()
        try await emit(sourceEvent)
        guard case .sourceAccepted(let accepted) = sourceEvent else {
            throw CoordinatorFileTestError.unexpectedSourceAcceptedEvent
        }
        acceptedSource = accepted
        for waiter in acceptanceWaiters { waiter.resume(returning: accepted) }
        acceptanceWaiters.removeAll(keepingCapacity: false)
        if !isOpenReleased {
            try await openCompletionStep.arrive(())
        }
        openObservedCancellation = Task.isCancelled
        didFinishOpen = true
        for waiter in finishWaiters { waiter.resume(returning: openObservedCancellation) }
        finishWaiters.removeAll(keepingCapacity: false)
    }

    func applyViewDemand(
        subscriptionId _: String,
        demand _: BridgePaneProductFileViewDemand,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission,
        forceRecapture _: Bool,
        emit _: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {
        updateObservedOpenFinished = didFinishOpen
        updateObservedSourceAccepted = acceptedSource != nil
        let observation = CoordinatorFileUpdateStartObservation(
            openFinished: didFinishOpen,
            sourceAccepted: acceptedSource != nil
        )
        updateStartObservation = observation
        for waiter in updateWaiters { waiter.resume(returning: observation) }
        updateWaiters.removeAll(keepingCapacity: false)
    }

    func cancel(subscriptionId _: String) {}

    func publish(
        status _: GitWorkingTreeStatus,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission
    ) -> [BridgePaneProductFileMetadataEmission] { [] }

    func publish(
        changeset _: FileChangeset,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission
    ) async throws -> [BridgePaneProductFileMetadataEmission] { [] }

    func contentReadPlan(
        for _: BridgeProductFileContentRequest,
        productAdmission _: BridgeProductAdmissionContext
    ) -> BridgePaneProductFileContentReadPlan? { nil }

    func waitUntilOpenStarted() async -> Int {
        guard openStartCount == 0 else { return openStartCount }
        return await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilUpdateStarted() async -> CoordinatorFileUpdateStartObservation {
        if let updateStartObservation { return updateStartObservation }
        return await withCheckedContinuation { continuation in
            updateWaiters.append(continuation)
        }
    }

    func releaseSourceAcceptance() {
        isSourceAcceptanceReleased = true
        sourceAcceptanceStep.release()
    }

    func waitUntilSourceAccepted() async -> BridgeProductFileSourceIdentity {
        if let acceptedSource { return acceptedSource }
        return await withCheckedContinuation { continuation in
            acceptanceWaiters.append(continuation)
        }
    }

    func releaseOpen() {
        isOpenReleased = true
        openCompletionStep.release()
    }

    func waitUntilOpenFinished() async -> Bool {
        guard !didFinishOpen else { return openObservedCancellation }
        return await withCheckedContinuation { continuation in
            finishWaiters.append(continuation)
        }
    }
}

actor CoordinatorFileMetadataSource: BridgePaneProductFileMetadataProducing {
    private(set) var cancelledSubscriptionIds: [String] = []
    private(set) var openCount = 0
    private var openWaiters: [CheckedContinuation<Int, Never>] = []

    func captureKeyedSnapshot(
        subscriptionId: String,
        demand _: BridgePaneProductFileViewDemand,
        productAdmission: BridgeProductAdmissionContext
    ) async -> BridgeWorktreeFileKeyedSnapshot? {
        guard subscriptionId == "file-subscription-1",
            productAdmission.withValidAdmission({ true }) == true
        else { return nil }
        guard
            let source = try? BridgeProductFileSourceIdentity(
                repoId: "00000000-0000-4000-8000-000000000001",
                rootRevisionToken: "root-token-1",
                sourceCursor: "source-cursor-1",
                sourceId: "file-source-1",
                subscriptionGeneration: 1,
                worktreeId: "00000000-0000-4000-8000-000000000002"
            )
        else { return nil }
        return .init(
            isEnumerationComplete: true,
            memberStatus: .init(record: .init(source: source), revision: 1),
            records: [],
            targetRevision: 1,
            tombstoneRevisionByKey: [:],
            absenceFloorRevisionByRange: [:]
        )
    }

    func currentSource() -> BridgeProductFileSourceCurrentResult {
        .unavailable(.noFileSourceAuthority)
    }

    func open(
        subscription _: BridgeProductSubscriptionSnapshot,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission,
        emit: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {
        openCount += 1
        let waiters = openWaiters
        openWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: openCount) }
        try await emit(
            .sourceAccepted(
                try .init(
                    repoId: "00000000-0000-4000-8000-000000000001",
                    rootRevisionToken: "root-token-1",
                    sourceCursor: "source-cursor-1",
                    sourceId: "file-source-1",
                    subscriptionGeneration: 1,
                    worktreeId: "00000000-0000-4000-8000-000000000002"
                ))
        )
    }

    func waitUntilOpened() async -> Int {
        if openCount > 0 { return openCount }
        return await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func applyViewDemand(
        subscriptionId _: String,
        demand _: BridgePaneProductFileViewDemand,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission,
        forceRecapture _: Bool,
        emit _: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {}

    func cancel(subscriptionId: String) {
        cancelledSubscriptionIds.append(subscriptionId)
    }

    func publish(
        status _: GitWorkingTreeStatus,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission
    ) -> [BridgePaneProductFileMetadataEmission] { [] }

    func publish(
        changeset _: FileChangeset,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission
    ) async throws -> [BridgePaneProductFileMetadataEmission] { [] }

    func contentReadPlan(
        for _: BridgeProductFileContentRequest,
        productAdmission _: BridgeProductAdmissionContext
    ) -> BridgePaneProductFileContentReadPlan? { nil }
}
