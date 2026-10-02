import Foundation

struct BridgePaneProductMetadataProducerExecutionContext: Sendable {
    let foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    let metadataLease: BridgeProductProducerLease
    let productAdmission: BridgeProductAdmissionContext
    let session: BridgeProductSession
    let fileSurfaceAttempt: BridgeFileSurfaceReconciler.Attempt?
}

enum BridgePaneProductMetadataProducerCompletion: Equatable, Sendable {
    case completed
    case interrupted
    case failedWithoutReset
    case resetEnqueued
    case staleProducer
}

struct BridgePaneProductMetadataProducerTaskLifecycle {
    private struct BootstrapProducerTask: Sendable {
        let taskId: UUID
        let task: Task<Void, Never>
    }

    private struct ProducerTaskStart {
        let subscriptionId: String
        let subscriptionKind: BridgeProductSubscriptionKind
        let executionContext: BridgePaneProductMetadataProducerExecutionContext
        let taskFinished:
            @Sendable (
                String,
                UUID,
                BridgePaneProductMetadataProducerCompletion,
                (any Error)?
            ) async -> Void
        let operation: @Sendable (BridgeTraceContext?) async throws -> Void
    }

    private let lifecycleTraceRecorder: (any BridgeProductMetadataLifecycleTraceRecording)?
    private var bootstrapTaskBySubscriptionId: [String: BootstrapProducerTask] = [:]

    init(lifecycleTraceRecorder: (any BridgeProductMetadataLifecycleTraceRecording)?) {
        self.lifecycleTraceRecorder = lifecycleTraceRecorder
    }

    mutating func startBootstrapTask(
        subscriptionId: String,
        subscriptionKind: BridgeProductSubscriptionKind,
        executionContext: BridgePaneProductMetadataProducerExecutionContext,
        taskFinished:
            @escaping @Sendable (
                String,
                UUID,
                BridgePaneProductMetadataProducerCompletion,
                (any Error)?
            ) async -> Void,
        operation: @escaping @Sendable (BridgeTraceContext?) async throws -> Void
    ) {
        startTask(
            ProducerTaskStart(
                subscriptionId: subscriptionId,
                subscriptionKind: subscriptionKind,
                executionContext: executionContext,
                taskFinished: taskFinished,
                operation: operation
            )
        )
    }

    private mutating func startTask(_ request: ProducerTaskStart) {
        let subscriptionId = request.subscriptionId
        let subscriptionKind = request.subscriptionKind
        let productAdmission = request.executionContext.productAdmission
        let foregroundWorkAdmission = request.executionContext.foregroundWorkAdmission
        let originatingMetadataLease = request.executionContext.metadataLease
        let session = request.executionContext.session
        let taskFinished = request.taskFinished
        let operation = request.operation
        let taskId = UUID()
        let lifecycleTraceRecorder = lifecycleTraceRecorder
        let task = Task {
            let traceContext = BridgeTraceContextFactory.live.makeRootContext()
            var completion = BridgePaneProductMetadataProducerCompletion.completed
            var surfacedError: (any Error)?
            await lifecycleTraceRecorder?.record(
                .init(
                    stage: .bootstrapStarted,
                    subscriptionKind: subscriptionKind,
                    result: .success,
                    traceContext: traceContext
                )
            )
            do {
                try Task.checkCancellation()
                try await operation(traceContext)
            } catch {
                let foregroundWorkWasInvalidated =
                    BridgePaneProductMetadataCoordinator.isForegroundWorkInvalidation(error)
                if Task.isCancelled || foregroundWorkWasInvalidated {
                    completion = .interrupted
                    await lifecycleTraceRecorder?.record(
                        .init(
                            stage: .producerCancelled,
                            subscriptionKind: subscriptionKind,
                            result: .failure,
                            failureReason: Task.isCancelled ? .taskCancellation : .cancellation,
                            traceContext: traceContext
                        )
                    )
                } else {
                    completion = .failedWithoutReset
                    if subscriptionKind == .fileMetadata,
                        request.executionContext.fileSurfaceAttempt != nil
                    {
                        surfacedError = error
                    }
                    await lifecycleTraceRecorder?.record(
                        .init(
                            stage: .producerFailed,
                            subscriptionKind: subscriptionKind,
                            result: .failure,
                            failureReason: BridgePaneProductMetadataCoordinator.producerFailureReason(
                                for: error
                            ),
                            traceContext: traceContext
                        )
                    )
                    if surfacedError == nil {
                        let resetResult = try? await session.enqueueSubscriptionReset(
                            originatingMetadataLease: originatingMetadataLease,
                            subscriptionId: subscriptionId,
                            reason: .staleSource,
                            productAdmission: productAdmission,
                            foregroundWorkAdmission: foregroundWorkAdmission
                        )
                        if case .enqueued? = resetResult {
                            completion = .resetEnqueued
                            await lifecycleTraceRecorder?.record(
                                .init(
                                    stage: .subscriptionResetEnqueued,
                                    subscriptionKind: subscriptionKind,
                                    result: .queued,
                                    traceContext: traceContext
                                )
                            )
                        } else if case .rejected(.unknownLease)? = resetResult {
                            completion = .staleProducer
                        }
                    }
                }
            }
            await taskFinished(subscriptionId, taskId, completion, surfacedError)
            await lifecycleTraceRecorder?.record(
                .init(
                    stage: .bootstrapFinished,
                    subscriptionKind: subscriptionKind,
                    result: completion == .completed ? .success : .failure,
                    failureReason: completion == .staleProducer
                        ? .producerRejection(.unknownLease) : nil,
                    traceContext: traceContext
                )
            )
        }
        bootstrapTaskBySubscriptionId[subscriptionId]?.task.cancel()
        bootstrapTaskBySubscriptionId[subscriptionId] = .init(taskId: taskId, task: task)
    }

    mutating func bootstrapTaskFinished(subscriptionId: String, taskId: UUID) -> Bool {
        guard bootstrapTaskBySubscriptionId[subscriptionId]?.taskId == taskId else { return false }
        bootstrapTaskBySubscriptionId.removeValue(forKey: subscriptionId)
        return true
    }

    mutating func takeAndCancelProducerTasks(
        subscriptionId: String
    ) -> [Task<Void, Never>] {
        var tasks: [Task<Void, Never>] = []
        if let bootstrapTask = bootstrapTaskBySubscriptionId.removeValue(
            forKey: subscriptionId
        )?.task {
            tasks.append(bootstrapTask)
        }
        for task in tasks { task.cancel() }
        return tasks
    }

    mutating func takeAndCancelEveryProducerTask() -> [Task<Void, Never>] {
        let bootstrapTasks = bootstrapTaskBySubscriptionId.values.map(\.task)
        bootstrapTaskBySubscriptionId.removeAll(keepingCapacity: false)
        for task in bootstrapTasks { task.cancel() }
        return bootstrapTasks
    }

    static func drain(_ tasks: [Task<Void, Never>]) async {
        for task in tasks {
            await task.value
        }
    }
}
