import AgentStudioInfrastructure
import Foundation
import os.log

private let bridgeProductResultAcknowledgementLogger = Logger(
    subsystem: "com.agentstudio",
    category: "BridgeProductResultAcknowledgement"
)

extension BridgeProductSession {
    func operationIsMutation(_ request: BridgeProductControlRequest) -> Bool {
        guard case .productCall(let callRequest) = request else { return false }
        switch callRequest.call {
        case .fileAnnotationsOutputInspect, .fileAnnotationsProjectionQuery,
            .fileSourceCurrent, .reviewAnnotationsOutputInspect,
            .reviewAnnotationsProjectionQuery, .reviewComparisonTargetsQuery,
            .reviewPublicationInstallAdmission:
            return false
        case .fileAnnotationsCommand, .fileRefreshRetry, .fileActiveViewerModeUpdate,
            .reviewActiveViewerModeUpdate, .reviewComparisonUpdate,
            .reviewIntakeReady, .reviewMarkFileViewed,
            .reviewPublicationApplied, .reviewAnnotationsCommand:
            return true
        }
    }

    func operationWaitKind(
        for request: BridgeProductControlRequest
    ) -> BridgeProductOperationWaitKind {
        guard case .productCall(let callRequest) = request else { return .ordinary }
        let annotationOperation: BridgeProductWorktreeAnnotationOperation
        switch callRequest.call {
        case .fileAnnotationsCommand(let command), .reviewAnnotationsCommand(let command):
            annotationOperation = command.operation
        default:
            return .ordinary
        }
        switch annotationOperation {
        case .repeatOutput:
            return .human
        case .outputPreferenceChangeFolder:
            return .human
        case .outputReveal:
            return .ordinary
        case .outputScopeCommit(let body) where body.outputKind == .jsonFile:
            return .human
        default:
            return .ordinary
        }
    }

    func admitControlOperation(
        token: BridgeProductControlAdmissionToken,
        execute: @escaping @Sendable (String) async -> Void
    ) throws -> (operationId: String, responseBytes: Data, waitKind: BridgeProductOperationWaitKind) {
        guard let pendingControl, pendingControl.token == token, lifecycle != .revoked else {
            throw BridgeProductSessionError.invalidAdmissionToken
        }
        let waitKind = operationWaitKind(for: pendingControl.request)
        guard operationTable.hasCapacity(for: waitKind) else {
            throw BridgeProductSessionError.resultCapacityExhausted
        }
        let isMutation = operationIsMutation(pendingControl.request)
        guard !isMutation || operationTable.hasMutationWatchCapacity else {
            throw BridgeProductSessionError.mutationWatchCapacityExhausted
        }
        let operationId = UUIDv7.generate().uuidString
        let response = BridgeProductOperationAdmittedResponse(
            correlation: pendingControl.request.correlation,
            operationId: operationId,
            waitKind: waitKind
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let responseBytes = try encoder.encode(response)
        try controlReplay.complete(token: token, exactResponseBytes: responseBytes)
        operationTable.admit(
            operationId: operationId,
            waitKind: waitKind,
            isMutation: isMutation,
            admission: pendingControl
        )
        if case .viewScope(let scope) = pendingControl.request {
            let view = BridgeProductViewOperationKey(
                subscriptionId: scope.subscriptionId,
                domain: scope.domain
            )
            if let priorOperationId = pendingScopeOperationIdByView[view],
                let prior = operationTable.entriesById[priorOperationId],
                prior.settlement == nil
            {
                _ = operationTable.settle(
                    .init(operationId: priorOperationId, outcome: .cancelled)
                )
                prior.executionTask?.cancel()
            }
            pendingScopeOperationIdByView[view] = operationId
        }
        // Provider work must start off this session actor's executor.
        // swiftlint:disable:next no_task_detached
        let executionTask = Task.detached { [self] in
            await execute(operationId)
            await finishOperationExecution(operationId: operationId)
        }
        let deadlineTask: Task<Void, Never>?
        switch waitKind {
        case .human:
            deadlineTask = nil
        case .ordinary:
            deadlineTask = Task { [self] in
                do {
                    try await operationDelay.wait(
                        AppPolicies.Bridge.productOperationSettlementDeadline
                    )
                    expireOperation(operationId: operationId)
                } catch is CancellationError {
                    // A settled operation cancelled its deadline.
                } catch {
                    expireOperation(operationId: operationId)
                }
            }
        }
        operationTable.registerTasks(
            operationId: operationId,
            executionTask: executionTask,
            deadlineTask: deadlineTask
        )
        self.pendingControl = nil
        return (operationId, responseBytes, waitKind)
    }

    func completeEscapeControl(
        token: BridgeProductControlAdmissionToken,
        response: BridgeProductControlResponse
    ) throws -> BridgeProductSessionCompletionEffect {
        guard let pendingControl, pendingControl.token == token,
            pendingControl.request.isSlotFreeEscape,
            lifecycle == .active
        else { throw BridgeProductSessionError.invalidAdmissionToken }
        try BridgeProductSessionControlTransitionBuilder.validateResponseShape(
            request: pendingControl.request,
            response: response
        )
        let transition = try BridgeProductSessionControlTransitionBuilder.prepare(
            request: pendingControl.request,
            response: response,
            subscriptionState: subscriptionState,
            resyncEpochs: pendingControl.deferredResyncEpochs,
            currentEpochs: workerDerivationEpochBySurface,
            snapshotRequiredSubscriptionIds: []
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let responseBytes = try encoder.encode(response)
        try admitRequiredProtocolLifecycleFrame(for: transition.effect)
        try controlReplay.complete(token: token, exactResponseBytes: responseBytes)
        subscriptionState = transition.subscriptionState
        self.pendingControl = nil
        return transition.effect
    }

    func waitForOperationExecution(operationId: String) async {
        let executionTask = operationTable.executionTasksById[operationId]
        await executionTask?.value
    }

    func waitForOutstandingOperationExecutions() async {
        let tasks = Array(operationTable.executionTasksById.values)
        for task in tasks {
            await task.value
        }
    }

    func finishOperationExecution(operationId: String) {
        operationTable.finishExecution(operationId: operationId)
    }

    /// A deadline during prerequisite work prevents the effect from starting.
    func markOperationDispatched(operationId: String) -> Bool {
        guard lifecycle != .revoked,
            let entry = operationTable.entriesById[operationId],
            entry.settlement == nil
        else { return false }
        return entry.admission.productAdmission.withValidAdmission {
            operationTable.markMutationDispatched(operationId: operationId)
            return true
        } ?? false
    }

    func beginEscapeEffect() -> UUID? {
        guard lifecycle == .active else { return nil }
        let effectId = UUIDv7.generate()
        activeEscapeEffectIds.insert(effectId)
        return effectId
    }

    func attachEscapeEffect(_ task: Task<Void, Never>, effectId: UUID) {
        guard activeEscapeEffectIds.contains(effectId), lifecycle != .revoked else {
            task.cancel()
            return
        }
        escapeEffectTasksById[effectId] = task
    }

    func finishEscapeEffect(effectId: UUID) {
        activeEscapeEffectIds.remove(effectId)
        escapeEffectTasksById.removeValue(forKey: effectId)
    }

    func waitForOutstandingEscapeEffects() async {
        let tasks = Array(escapeEffectTasksById.values)
        for task in tasks {
            await task.value
        }
    }

    private func expireOperation(operationId: String) {
        guard let entry = operationTable.entriesById[operationId], entry.settlement == nil else {
            return
        }
        let outcome: BridgeProductOperationSettlement =
            entry.isMutation && entry.didDispatchMutation ? .outcomeUnknown : .failed
        guard
            operationTable.settle(
                .init(operationId: operationId, outcome: outcome)
            )
        else { return }
        entry.executionTask?.cancel()
    }

    func readOperationResult(
        _ request: BridgeProductOperationResultRequest,
        productAdmission: BridgeProductAdmissionContext
    ) async -> BridgeProductOperationResultResponse? {
        guard request.paneSessionId == paneSessionId,
            request.workerInstanceId == workerInstanceId,
            productAdmission.withValidAdmission({ true }) == true
        else { return nil }
        let waiterId = UUIDv7.generate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    let didPark = operationTable.observeResult(
                        operationId: request.operationId,
                        waiterId: waiterId,
                        resume: { continuation.resume(returning: $0) }
                    )
                    if didPark {
                        resultWaiterRegistrationObserver?(request.operationId)
                    }
                }
            }
        } onCancel: {
            Task {
                await self.cancelOperationResultWaiter(
                    operationId: request.operationId,
                    waiterId: waiterId
                )
            }
        }
    }

    private func cancelOperationResultWaiter(operationId: String, waiterId: UUID) {
        operationTable.cancelResultWaiter(operationId: operationId, waiterId: waiterId)
    }

    func observeOperation(
        _ request: BridgeProductOperationObservationRequest,
        productAdmission: BridgeProductAdmissionContext
    ) async -> BridgeProductOperationObservationResponse? {
        guard request.paneSessionId == paneSessionId,
            request.workerInstanceId == workerInstanceId,
            productAdmission.withValidAdmission({ true }) == true
        else { return nil }
        let waiterId = UUIDv7.generate()
        let observation: BridgeProductOperationObservationResponse? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                let didPark = operationTable.observeAfter(
                    operationId: request.operationId,
                    revision: request.after,
                    waiterId: waiterId,
                    resume: { continuation.resume(returning: $0) }
                )
                guard didPark else { return }
                observationDeadlineTasksByWaiterId[waiterId] = Task { [self] in
                    do {
                        try await operationDelay.wait(AppPolicies.Bridge.productMutationObservationDeadline)
                        operationTable.expireObservation(
                            operationId: request.operationId,
                            revision: request.after,
                            waiterId: waiterId
                        )
                    } catch is CancellationError {
                        // A receipt, cancellation, or session end removed this observer.
                    } catch {
                        operationTable.expireObservation(
                            operationId: request.operationId,
                            revision: request.after,
                            waiterId: waiterId
                        )
                    }
                }
            }
        } onCancel: {
            Task {
                await self.cancelOperationObservation(
                    operationId: request.operationId,
                    waiterId: waiterId
                )
            }
        }
        observationDeadlineTasksByWaiterId.removeValue(forKey: waiterId)?.cancel()
        return observation
    }

    private func cancelOperationObservation(operationId: String, waiterId: UUID) {
        observationDeadlineTasksByWaiterId.removeValue(forKey: waiterId)?.cancel()
        operationTable.cancelObservation(operationId: operationId, waiterId: waiterId)
    }

    func acknowledgeLateOutcome(
        _ request: BridgeProductOperationLateOutcomeAcknowledgement,
        exactRequestBytes: Data,
        productAdmission: BridgeProductAdmissionContext
    ) -> Bool {
        guard request.correlation.paneSessionId == paneSessionId,
            request.correlation.workerInstanceId == workerInstanceId,
            productAdmission.withValidAdmission({ true }) == true
        else { return false }
        switch controlReplay.begin(
            requestSequence: request.correlation.requestSequence,
            exactRequestBytes: exactRequestBytes
        ) {
        case .replay:
            return true
        case .rejected:
            return false
        case .execute(let token):
            guard let watch = operationTable.mutationWatchesById[request.operationId],
                watch.unknownAcknowledged,
                case .lateOutcome(let evidence)? = watch.lateOutcome,
                evidence.revision == request.revision
            else {
                try? controlReplay.abandon(token: token)
                return false
            }
            guard (try? controlReplay.complete(token: token, exactResponseBytes: Data())) != nil else {
                try? controlReplay.abandon(token: token)
                return false
            }
            return operationTable.acknowledgeLateOutcome(
                operationId: request.operationId,
                revision: request.revision
            )
        }
    }

    func acknowledgeOperationResult(
        _ request: BridgeProductOperationResultAcknowledgement,
        exactRequestBytes: Data,
        productAdmission: BridgeProductAdmissionContext
    ) -> Result<Data, BridgeProductOperationResultAckRefusal> {
        guard request.correlation.paneSessionId == paneSessionId else {
            return .failure(.init(.paneSessionMismatch))
        }
        guard request.correlation.workerInstanceId == workerInstanceId else {
            return .failure(.init(.workerInstanceMismatch))
        }
        guard productAdmission.withValidAdmission({ true }) == true else {
            bridgeProductResultAcknowledgementLogger.notice("Ack refused reason=admissionInvalid")
            return .failure(.init(.admissionInvalid))
        }
        switch controlReplay.begin(
            requestSequence: request.correlation.requestSequence,
            exactRequestBytes: exactRequestBytes
        ) {
        case .replay(let exactResponseBytes):
            return .success(exactResponseBytes)
        case .rejected(let rejection):
            let rejectionKind: BridgeProductOperationResultAckReplayRejectionKind
            switch rejection {
            case .payloadTooLarge: rejectionKind = .payloadTooLarge
            case .requestInFlight: rejectionKind = .requestInFlight
            case .sequenceExhausted: rejectionKind = .sequenceExhausted
            case .sequenceConflict: rejectionKind = .sequenceConflict
            }
            return .failure(
                .init(
                    replayRejectionKind: rejectionKind,
                    nextExpectedRequestSequence: controlReplay.snapshot.nextExpectedRequestSequence
                )
            )
        case .execute(let token):
            guard operationTable.entriesById[request.operationId]?.settlement != nil else {
                try? controlReplay.abandon(token: token)
                return .failure(.init(.unknownOperation))
            }
            let response = BridgeProductOperationResultAcknowledgedResponse(
                correlation: request.correlation,
                operationId: request.operationId
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let bytes = try? encoder.encode(response) else {
                try? controlReplay.abandon(token: token)
                return .failure(.init(.responseEncodingFailed))
            }
            guard (try? controlReplay.complete(token: token, exactResponseBytes: bytes)) != nil else {
                try? controlReplay.abandon(token: token)
                return .failure(.init(.replayCompletionRejected))
            }
            _ = operationTable.acknowledge(operationId: request.operationId)
            return .success(bytes)
        }
    }

    func settleOperation(
        operationId: String,
        response: BridgeProductControlResponse
    ) {
        let outcome: BridgeProductOperationSettlement
        let failureCode: BridgeProductRequestErrorCode?
        switch response {
        case .requestError(let error):
            outcome = .refused
            failureCode = error.code
        default:
            outcome = .succeeded
            failureCode = nil
        }
        let encodedResponse = try? JSONEncoder().encode(response)
        let result = encodedResponse.flatMap {
            try? JSONDecoder().decode(BridgeProductJSONValue.self, from: $0)
        }
        let didSettle = operationTable.settle(
            .init(
                failureCode: failureCode,
                operationId: operationId,
                outcome: outcome,
                result: outcome == .succeeded ? result : nil
            )
        )
        if !didSettle {
            _ = operationTable.recordLateOutcome(
                operationId: operationId,
                outcome: outcome,
                failureCode: failureCode,
                result: outcome == .succeeded ? result : nil
            )
        }
    }

    func isOperationSettledUnknown(_ operationId: String) -> Bool {
        operationTable.mutationWatchesById[operationId]?.wasSettledUnknown == true
    }

}
