import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioProgrammaticControl
import Synchronization

/// An independent waiter consumes the service's committed outcome even after
/// the reader cancels its caller. The cancellation settlement is always joined.
@concurrent
func waitForPaneContextAsk(
    service: PaneContextService, paneId: PaneId, messageId: AgentMessageId,
    connectionEndCause: @escaping @Sendable () -> AppIPCConnectionEndCause
) async throws -> IPCPaneAskOutcome {
    let waiter = Task { await service.waitForAskOutcome(messageId: messageId, paneId: paneId) }
    let cancellationSettlement = Mutex<Task<AskSettlementResult, Never>?>(nil)
    let outcome = await withTaskCancellationHandler {
        await waiter.value
    } onCancel: {
        let cause: AskSettlementCause
        switch connectionEndCause() {
        case .eof, .error: cause = .callerGone
        case .stopping: cause = .appStopping
        }
        cancellationSettlement.withLock { settlement in
            guard settlement == nil else { return }
            settlement = Task {
                let result = await service.settleAsk(messageId, paneId: paneId, cause: cause)
                // A failed settlement cannot leave the independent waiter parked.
                if case .unavailable = result { waiter.cancel() }
                return result
            }
        }
    }
    if let settlement = cancellationSettlement.withLock({ $0 }) {
        if case .unavailable = await settlement.value {
            throw AppIPCPaneContextError(reason: .unavailable)
        }
    }
    return PaneContextIPCMapping.outcome(outcome)
}
