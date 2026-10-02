import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

@MainActor
final class BridgePaneFileSourceAcceptanceRelay {
    typealias Consumer = @MainActor (BridgeProductFileSourceIdentity) -> Void

    private var consumer: Consumer?
    private var latestAcceptedSource: BridgeProductFileSourceIdentity?

    func accept(_ source: BridgeProductFileSourceIdentity) {
        latestAcceptedSource = source
        consumer?(source)
    }

    func bind(_ consumer: @escaping Consumer) {
        self.consumer = consumer
        if let latestAcceptedSource {
            consumer(latestAcceptedSource)
        }
    }
}

@MainActor
final class BridgePaneWorktreeRefreshDriver {
    typealias ProductAdmissionProvider = @MainActor @Sendable () -> BridgeProductAdmissionContext?
    typealias FileChangesetPublisher =
        @Sendable (
            FileChangeset,
            BridgeProductAdmissionContext,
            BridgePaneRefreshWorkAdmission,
            String,
            Int
        ) async -> BridgePaneProductFileRefreshPublicationDisposition
    typealias FileStatusPublisher =
        @Sendable (
            GitWorkingTreeStatus,
            BridgeProductAdmissionContext,
            BridgePaneRefreshWorkAdmission,
            String,
            Int
        ) async -> BridgePaneProductFileRefreshPublicationDisposition
    typealias PresentationPublisher =
        @Sendable (
            BridgePaneProductPresentationSnapshot,
            BridgeTraceContext?
        ) async -> Void
    typealias OperationLifecyclePublisher =
        @Sendable (BridgeOperationLifecycleTraceEvent) async -> Void

    private enum FileCatchUpResult {
        case completed(
            outcome: BridgePaneRefreshCatchUpOutcome,
            failure: BridgePaneProductFileRefreshFailure?
        )
        case streamReset(sourceAtOperationStart: BridgeProductFileSourceIdentity?)
    }

    private struct PendingFileStreamRecovery {
        let sourceAtReset: BridgeProductFileSourceIdentity
    }

    private let acquireProductAdmission: ProductAdmissionProvider
    private let coordinator: BridgePaneRefreshAdmissionCoordinator
    private let publishFileChangeset: FileChangesetPublisher
    private let publishFileStatus: FileStatusPublisher
    private let publishPresentation: PresentationPublisher
    private let publishOperationLifecycle: OperationLifecyclePublisher
    private var activeFileTask: Task<Void, Never>?
    private var activeFileTaskID: UUID?
    private var isClosed = false
    private var latestAcceptedFileSource: BridgeProductFileSourceIdentity?
    private var pendingFileStreamRecovery: PendingFileStreamRecovery?
    private var presentationTransitionGeneration: UInt64 = 0
    private var presentationTransitionTail: Task<Void, Never>?
    private var retiringFileTaskByID: [UUID: Task<Void, Never>] = [:]

    init(
        coordinator: BridgePaneRefreshAdmissionCoordinator,
        acquireProductAdmission: @escaping ProductAdmissionProvider,
        publishFileChangeset: @escaping FileChangesetPublisher,
        publishFileStatus: @escaping FileStatusPublisher,
        publishPresentation: @escaping PresentationPublisher,
        publishOperationLifecycle: @escaping OperationLifecyclePublisher = { _ in }
    ) {
        self.acquireProductAdmission = acquireProductAdmission
        self.coordinator = coordinator
        self.publishFileChangeset = publishFileChangeset
        self.publishFileStatus = publishFileStatus
        self.publishPresentation = publishPresentation
        self.publishOperationLifecycle = publishOperationLifecycle
    }

    var hasActiveFileOperation: Bool { activeFileTask != nil }
    var hasRetiringFileOperations: Bool { !retiringFileTaskByID.isEmpty }
    var hasPendingFileStreamRecovery: Bool { pendingFileStreamRecovery != nil }

    func awaitRetiringFileOperations() async {
        while !retiringFileTaskByID.isEmpty {
            let retiringTasks = Array(retiringFileTaskByID.values)
            for retiringTask in retiringTasks {
                await retiringTask.value
            }
        }
    }

    func awaitActiveFileOperations() async {
        while let activeFileTask {
            await activeFileTask.value
        }
    }

    @discardableResult
    func recordInvalidation(
        fileChangeset: FileChangeset?,
        latestFileStatus: GitWorkingTreeStatus? = nil,
        requiresReviewRefresh: Bool
    ) -> Set<BridgePaneRefreshLane> {
        guard !isClosed else { return [] }
        var affectedLanes: Set<BridgePaneRefreshLane> = []
        if fileChangeset != nil || latestFileStatus != nil {
            affectedLanes.insert(.file)
        }
        if requiresReviewRefresh {
            affectedLanes.insert(.review)
        }
        coordinator.recordInvalidation(
            fileChangeset: fileChangeset,
            latestFileStatus: latestFileStatus,
            requiresReviewRefresh: requiresReviewRefresh
        )
        if affectedLanes.contains(.file) {
            retireActiveFileOperation()
            scheduleFileCatchUpIfPossible()
        }
        return affectedLanes
    }

    func scheduleFileCatchUpIfPossible() {
        guard !isClosed,
            pendingFileStreamRecovery == nil,
            activeFileTask == nil,
            let firstReservation = coordinator.reserveForegroundRefreshPass(for: .file)
        else { return }

        // fire-and-forget: publication joins the presentation tail; closeAndDrain awaits it
        _ = schedulePresentationPublication()
        let taskID = UUIDv7.generate()
        activeFileTaskID = taskID
        activeFileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var reservation: BridgePaneRefreshCatchUpReservation? = firstReservation
            var finalOutcome = BridgePaneRefreshCatchUpOutcome.stale
            var automaticRetryCount = 0
            while let currentReservation = reservation {
                await publishOperationLifecycle(
                    .init(
                        operationCorrelationID: currentReservation.operationCorrelationID,
                        result: .success,
                        stage: .refreshReserved,
                        stageAttempt: currentReservation.operationStageAttempt,
                        surface: .file
                    )
                )
                let result = await performFileCatchUp(currentReservation)
                let outcome: BridgePaneRefreshCatchUpOutcome
                let failure: BridgePaneProductFileRefreshFailure?
                switch result {
                case .completed(let completedOutcome, let completedFailure):
                    outcome = completedOutcome
                    failure = completedFailure
                case .streamReset(let sourceAtOperationStart):
                    if let sourceAtOperationStart {
                        outcome = .streamReset
                        failure = nil
                        pendingFileStreamRecovery = PendingFileStreamRecovery(
                            sourceAtReset: sourceAtOperationStart
                        )
                    } else {
                        outcome = .failed
                        failure = .init(failureKind: .fileRefreshFailed)
                    }
                }
                finalOutcome = outcome
                await publishOperationLifecycle(
                    .init(
                        operationCorrelationID: currentReservation.operationCorrelationID,
                        result: Self.operationResult(for: outcome),
                        stage: .refreshOperationTerminal,
                        stageAttempt: currentReservation.operationStageAttempt,
                        surface: .file
                    )
                )
                coordinator.completeRefreshPass(
                    currentReservation,
                    outcome: outcome
                )
                if outcome == .succeeded {
                    automaticRetryCount = 0
                    reservation = coordinator.reserveForegroundRefreshPass(for: .file)
                } else if outcome == .failed,
                    failure?.retryable == true,
                    automaticRetryCount < AppPolicies.Bridge.fileRefreshMaximumAutomaticRetryCount
                {
                    automaticRetryCount += 1
                    reservation = coordinator.reserveForegroundRefreshPass(for: .file)
                } else {
                    reservation = nil
                    if outcome == .failed, let failure {
                        coordinator.recordCurrentFileRefreshFailure(failure)
                    }
                }
                // fire-and-forget: publication joins the presentation tail; closeAndDrain awaits it
                _ = schedulePresentationPublication()
                guard reservation != nil else { break }
            }
            retiringFileTaskByID.removeValue(forKey: taskID)
            guard activeFileTaskID == taskID else { return }
            activeFileTask = nil
            activeFileTaskID = nil
            if pendingFileStreamRecovery != nil {
                releasePendingFileStreamRecoveryIfPossible()
            } else if finalOutcome != .failed {
                scheduleFileCatchUpIfPossible()
            }
        }
    }

    func recordFileSourceAccepted(_ source: BridgeProductFileSourceIdentity) {
        guard !isClosed else { return }
        if let pendingFileStreamRecovery {
            guard
                Self.isReplacementSource(
                    source,
                    for: pendingFileStreamRecovery.sourceAtReset
                )
            else { return }
            latestAcceptedFileSource = source
            releasePendingFileStreamRecoveryIfPossible()
            return
        }
        guard let currentSource = latestAcceptedFileSource else {
            latestAcceptedFileSource = source
            return
        }
        guard Self.hasMatchingAuthority(source, currentSource),
            source.subscriptionGeneration >= currentSource.subscriptionGeneration
        else { return }
        latestAcceptedFileSource = source
    }

    func retryUnavailableFileRefresh() {
        guard let admission = acquireProductAdmission() else { return }
        retryUnavailableFileRefresh(ifAdmittedBy: admission)
    }

    func retryUnavailableFileRefresh(ifAdmittedBy admission: BridgeProductAdmissionContext) {
        guard !isClosed, admission.withValidAdmission({ coordinator.beginExplicitFileRefreshRetry() }) == true else {
            return
        }
        // fire-and-forget: publication joins the presentation tail; closeAndDrain awaits it
        _ = schedulePresentationPublication()
        scheduleFileCatchUpIfPossible()
    }

    func retryUnavailableFileRefreshAndWait(ifAdmittedBy admission: BridgeProductAdmissionContext) async {
        guard !isClosed,
            admission.withValidAdmission({ true }) == true,
            coordinator.hasPendingFileRefreshWork
        else { return }

        if admission.withValidAdmission({ coordinator.beginExplicitFileRefreshRetry() }) == true {
            scheduleFileCatchUpIfPossible()
        }

        while coordinator.hasPendingFileRefreshWork,
            let task = activeFileTask,
            let taskID = activeFileTaskID
        {
            await task.value
            if activeFileTaskID == taskID { return }
        }
    }

    func retireActiveFileOperation() {
        guard let taskID = activeFileTaskID,
            let task = activeFileTask
        else { return }
        task.cancel()
        retiringFileTaskByID[taskID] = task
        activeFileTask = nil
        activeFileTaskID = nil
    }

    func schedulePresentationPublication(
        traceContext: BridgeTraceContext? = nil
    ) -> Task<Void, Never>? {
        schedulePresentationTransition { [publishPresentation] snapshot in
            await publishPresentation(snapshot, traceContext)
        }
    }

    func schedulePresentationTransition(
        _ operation:
            @escaping @MainActor @Sendable (
                BridgePaneProductPresentationSnapshot
            ) async -> Void
    ) -> Task<Void, Never>? {
        guard !isClosed else { return nil }
        let snapshot = coordinator.productPresentationSnapshot
        presentationTransitionGeneration &+= 1
        let transitionGeneration = presentationTransitionGeneration
        let precedingTransition = presentationTransitionTail
        let transition = Task { @MainActor [weak self] in
            await precedingTransition?.value
            guard let self, !isClosed else { return }
            await operation(snapshot)
            guard presentationTransitionGeneration == transitionGeneration else { return }
            presentationTransitionTail = nil
        }
        presentationTransitionTail = transition
        return transition
    }

    func closeAndDrain() async {
        guard !isClosed else {
            await presentationTransitionTail?.value
            for task in retiringFileTaskByID.values { await task.value }
            return
        }
        isClosed = true
        latestAcceptedFileSource = nil
        pendingFileStreamRecovery = nil
        let tasks = Array(retiringFileTaskByID.values) + [activeFileTask].compactMap { $0 }
        for task in tasks { task.cancel() }
        activeFileTask = nil
        activeFileTaskID = nil
        retiringFileTaskByID.removeAll()
        let transitionTail = presentationTransitionTail
        presentationTransitionTail = nil
        await transitionTail?.value
        for task in tasks { await task.value }
    }

    private func performFileCatchUp(
        _ reservation: BridgePaneRefreshCatchUpReservation
    ) async -> FileCatchUpResult {
        let sourceAtOperationStart = latestAcceptedFileSource
        guard reservation.foregroundWorkAdmission.withValidAdmission({ true }) == true,
            let productAdmission = acquireProductAdmission()
        else { return .completed(outcome: .stale, failure: nil) }

        var fileRefreshFailure: BridgePaneProductFileRefreshFailure?
        var filePrepareStageAttempt = reservation.operationStageAttempt * 2
        if let changeset = reservation.fileChangeset {
            let disposition = await publishFileChangeset(
                changeset,
                productAdmission,
                reservation.foregroundWorkAdmission,
                reservation.operationCorrelationID,
                filePrepareStageAttempt
            )
            guard disposition != .stale,
                reservation.foregroundWorkAdmission.withValidAdmission({ true }) == true,
                !Task.isCancelled
            else { return .completed(outcome: .stale, failure: nil) }
            switch disposition {
            case .failed(let failure):
                fileRefreshFailure = Self.mergedFileRefreshFailure(fileRefreshFailure, failure)
            case .streamResetRequired:
                return .streamReset(sourceAtOperationStart: sourceAtOperationStart)
            case .applied, .notRequired, .stale:
                break
            }
            filePrepareStageAttempt += 1
        }

        if let status = reservation.latestFileStatus {
            let disposition = await publishFileStatus(
                status,
                productAdmission,
                reservation.foregroundWorkAdmission,
                reservation.operationCorrelationID,
                filePrepareStageAttempt
            )
            guard disposition != .stale,
                reservation.foregroundWorkAdmission.withValidAdmission({ true }) == true,
                !Task.isCancelled
            else { return .completed(outcome: .stale, failure: nil) }
            switch disposition {
            case .failed(let failure):
                fileRefreshFailure = Self.mergedFileRefreshFailure(fileRefreshFailure, failure)
            case .streamResetRequired:
                return .streamReset(sourceAtOperationStart: sourceAtOperationStart)
            case .applied, .notRequired, .stale:
                break
            }
        }

        return fileRefreshFailure.map { .completed(outcome: .failed, failure: $0) }
            ?? .completed(outcome: .succeeded, failure: nil)
    }

    private func releasePendingFileStreamRecoveryIfPossible() {
        guard activeFileTask == nil,
            let pendingFileStreamRecovery,
            let latestAcceptedFileSource,
            Self.isReplacementSource(
                latestAcceptedFileSource,
                for: pendingFileStreamRecovery.sourceAtReset
            )
        else { return }
        self.pendingFileStreamRecovery = nil
        scheduleFileCatchUpIfPossible()
    }

    private static func isReplacementSource(
        _ candidate: BridgeProductFileSourceIdentity,
        for sourceAtReset: BridgeProductFileSourceIdentity
    ) -> Bool {
        hasMatchingAuthority(candidate, sourceAtReset)
            && candidate.subscriptionGeneration > sourceAtReset.subscriptionGeneration
    }

    private static func hasMatchingAuthority(
        _ lhs: BridgeProductFileSourceIdentity,
        _ rhs: BridgeProductFileSourceIdentity
    ) -> Bool {
        lhs.repoId == rhs.repoId
            && lhs.worktreeId == rhs.worktreeId
            && lhs.rootRevisionToken == rhs.rootRevisionToken
    }

    private static func operationResult(
        for outcome: BridgePaneRefreshCatchUpOutcome
    ) -> BridgeOperationLifecycleTraceEvent.Result {
        switch outcome {
        case .succeeded:
            .success
        case .failed:
            .failure
        case .stale, .streamReset:
            .stale
        }
    }

    private static func mergedFileRefreshFailure(
        _ current: BridgePaneProductFileRefreshFailure?,
        _ candidate: BridgePaneProductFileRefreshFailure
    ) -> BridgePaneProductFileRefreshFailure {
        guard let current else { return candidate }
        return current.retryable && !candidate.retryable ? candidate : current
    }
}
