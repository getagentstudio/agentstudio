import AgentStudioInfrastructure
import Foundation

/// Session-owned operation results. Admission and settlement are serialized by
/// BridgeProductSession; provider tasks never own a result slot themselves.
struct BridgeProductOperationTable {
    struct Entry {
        let admission: BridgeProductSessionPendingControl
        let operationId: String
        let waitKind: BridgeProductOperationWaitKind
        let isMutation: Bool
        var didDispatchMutation = false
        var deadlineTask: Task<Void, Never>?
        var executionTask: Task<Void, Never>?
        var resultWaiters: [UUID: @Sendable (BridgeProductOperationResultResponse?) -> Void] = [:]
        var settlement: BridgeProductOperationResultResponse?
    }

    struct MutationWatch {
        var wasSettledUnknown = false
        var unknownAcknowledged = false
        var lateOutcome: BridgeProductOperationObservationResponse?
        var observers: [UUID: @Sendable (BridgeProductOperationObservationResponse?) -> Void] = [:]
    }

    private let maximumMutationWatches: Int
    private(set) var entriesById: [String: Entry] = [:]
    private(set) var executionTasksById: [String: Task<Void, Never>] = [:]
    private var operationIdByToken: [BridgeProductControlAdmissionToken: String] = [:]
    private(set) var mutationWatchesById: [String: MutationWatch] = [:]

    init(maximumMutationWatches: Int = AppPolicies.Bridge.maximumProductMutationWatches) {
        precondition(maximumMutationWatches > 0)
        self.maximumMutationWatches = maximumMutationWatches
    }

    var hasMutationWatchCapacity: Bool {
        mutationWatchesById.count < maximumMutationWatches
    }

    func entry(for token: BridgeProductControlAdmissionToken) -> Entry? {
        guard let operationId = operationIdByToken[token] else { return nil }
        return entriesById[operationId]
    }

    func hasCapacity(for waitKind: BridgeProductOperationWaitKind) -> Bool {
        let capacity: Int =
            switch waitKind {
            case .ordinary: AppPolicies.Bridge.maximumOrdinaryProductOperations
            case .human: AppPolicies.Bridge.maximumHumanWaitProductOperations
            }
        return entriesById.values.filter { $0.waitKind == waitKind }.count < capacity
    }

    mutating func admit(
        operationId: String,
        waitKind: BridgeProductOperationWaitKind,
        isMutation: Bool = false,
        admission: BridgeProductSessionPendingControl
    ) {
        precondition(hasCapacity(for: waitKind))
        precondition(!isMutation || hasMutationWatchCapacity)
        precondition(entriesById[operationId] == nil)
        entriesById[operationId] = Entry(
            admission: admission,
            operationId: operationId,
            waitKind: waitKind,
            isMutation: isMutation
        )
        operationIdByToken[admission.token] = operationId
        if isMutation {
            mutationWatchesById[operationId] = MutationWatch()
        }
    }

    mutating func markMutationDispatched(operationId: String) {
        guard var entry = entriesById[operationId], entry.isMutation else { return }
        entry.didDispatchMutation = true
        entriesById[operationId] = entry
    }

    mutating func registerTasks(
        operationId: String,
        executionTask: Task<Void, Never>,
        deadlineTask: Task<Void, Never>?
    ) {
        guard var entry = entriesById[operationId], entry.settlement == nil else {
            executionTask.cancel()
            deadlineTask?.cancel()
            return
        }
        entry.executionTask = executionTask
        entry.deadlineTask = deadlineTask
        entriesById[operationId] = entry
        executionTasksById[operationId] = executionTask
    }

    mutating func finishExecution(operationId: String) {
        executionTasksById.removeValue(forKey: operationId)
    }

    @discardableResult
    mutating func observeResult(
        operationId: String,
        waiterId: UUID,
        resume: @escaping @Sendable (BridgeProductOperationResultResponse?) -> Void
    ) -> Bool {
        guard var entry = entriesById[operationId] else {
            resume(nil)
            return false
        }
        if let settlement = entry.settlement {
            resume(settlement)
            return false
        }
        // Keep the optional at the session boundary so an unknown id can be
        // reported without fabricating an operation settlement.
        entry.resultWaiters[waiterId] = resume
        entriesById[operationId] = entry
        return true
    }

    mutating func cancelResultWaiter(operationId: String, waiterId: UUID) {
        guard var entry = entriesById[operationId],
            let waiter = entry.resultWaiters.removeValue(forKey: waiterId)
        else { return }
        entriesById[operationId] = entry
        waiter(nil)
    }

    @discardableResult
    mutating func settle(_ result: BridgeProductOperationResultResponse) -> Bool {
        guard var entry = entriesById[result.operationId], entry.settlement == nil else {
            return false
        }
        entry.settlement = result
        if result.outcome == .outcomeUnknown,
            var watch = mutationWatchesById[result.operationId]
        {
            watch.wasSettledUnknown = true
            mutationWatchesById[result.operationId] = watch
        }
        entry.deadlineTask?.cancel()
        let waiters = Array(entry.resultWaiters.values)
        entry.resultWaiters.removeAll(keepingCapacity: false)
        entriesById[result.operationId] = entry
        for waiter in waiters {
            waiter(result)
        }
        return true
    }

    mutating func acknowledge(operationId: String) -> Bool {
        guard let entry = entriesById[operationId], entry.settlement != nil else { return false }
        entry.deadlineTask?.cancel()
        if entry.settlement?.outcome == .outcomeUnknown,
            var watch = mutationWatchesById[operationId]
        {
            watch.unknownAcknowledged = true
            mutationWatchesById[operationId] = watch
        } else {
            mutationWatchesById.removeValue(forKey: operationId)
        }
        entriesById.removeValue(forKey: operationId)
        operationIdByToken.removeValue(forKey: entry.admission.token)
        return true
    }

    @discardableResult
    mutating func recordLateOutcome(
        operationId: String,
        outcome: BridgeProductOperationSettlement,
        failureCode: BridgeProductRequestErrorCode? = nil,
        result: BridgeProductJSONValue? = nil
    ) -> Bool {
        guard outcome != .outcomeUnknown,
            var watch = mutationWatchesById[operationId],
            watch.wasSettledUnknown,
            watch.lateOutcome == nil
        else { return false }
        let evidence = BridgeProductOperationObservationResponse.lateOutcome(
            .init(
                operationId: operationId,
                revision: 2,
                outcome: outcome,
                failureCode: failureCode,
                result: result
            ))
        watch.lateOutcome = evidence
        let observers = Array(watch.observers.values)
        watch.observers.removeAll(keepingCapacity: false)
        mutationWatchesById[operationId] = watch
        for observer in observers { observer(evidence) }
        return true
    }

    @discardableResult
    mutating func observeAfter(
        operationId: String,
        revision: Int,
        waiterId: UUID,
        resume: @escaping @Sendable (BridgeProductOperationObservationResponse?) -> Void
    ) -> Bool {
        guard var watch = mutationWatchesById[operationId],
            watch.wasSettledUnknown,
            watch.unknownAcknowledged
        else {
            resume(nil)
            return false
        }
        if let evidence = watch.lateOutcome {
            if case .lateOutcome(let late) = evidence, late.revision > revision {
                resume(evidence)
                return false
            }
        }
        watch.observers[waiterId] = resume
        mutationWatchesById[operationId] = watch
        return true
    }

    mutating func expireObservation(operationId: String, revision: Int, waiterId: UUID) {
        guard var watch = mutationWatchesById[operationId],
            let observer = watch.observers.removeValue(forKey: waiterId)
        else { return }
        mutationWatchesById[operationId] = watch
        observer(.stillUnknown(operationId: operationId, revision: revision))
    }

    mutating func cancelObservation(operationId: String, waiterId: UUID) {
        guard var watch = mutationWatchesById[operationId],
            let observer = watch.observers.removeValue(forKey: waiterId)
        else { return }
        mutationWatchesById[operationId] = watch
        observer(nil)
    }

    mutating func acknowledgeLateOutcome(operationId: String, revision: Int) -> Bool {
        guard let watch = mutationWatchesById[operationId],
            watch.unknownAcknowledged,
            case .lateOutcome(let evidence)? = watch.lateOutcome,
            evidence.revision == revision
        else { return false }
        mutationWatchesById.removeValue(forKey: operationId)
        return true
    }

    mutating func cancelUnsettledOperations() {
        for task in executionTasksById.values { task.cancel() }
        for operationId in Array(entriesById.keys) {
            guard let entry = entriesById[operationId], entry.settlement == nil else { continue }
            settle(
                BridgeProductOperationResultResponse(
                    operationId: operationId,
                    outcome: .cancelled
                )
            )
        }
    }

    mutating func cancelAndForgetAllOperations() {
        cancelUnsettledOperations()
        for entry in entriesById.values {
            entry.deadlineTask?.cancel()
        }
        entriesById.removeAll(keepingCapacity: false)
        operationIdByToken.removeAll(keepingCapacity: false)
        for watch in mutationWatchesById.values {
            for observer in watch.observers.values { observer(nil) }
        }
        mutationWatchesById.removeAll(keepingCapacity: false)
    }
}
