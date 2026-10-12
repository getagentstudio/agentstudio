import Synchronization

private typealias GhosttyCallbackTaskJoinOperation = @Sendable () async -> Void

final class GhosttyCallbackTaskOwner: Sendable {
    private struct State: Sendable {
        var isAcceptingWork = true
        var nextTaskID: UInt64 = 0
        var taskJoinOperations: [UInt64: GhosttyCallbackTaskJoinOperation] = [:]
    }

    private let state = Mutex(State())

    var isAcceptingWork: Bool {
        state.withLock { $0.isAcceptingWork }
    }

    var pendingTaskCount: Int {
        state.withLock { $0.taskJoinOperations.count }
    }

    func enqueueTask<Output: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async -> Output
    ) -> Task<Output, Never>? {
        state.withLock { state in
            guard state.isAcceptingWork else { return nil }

            state.nextTaskID += 1
            let taskID = state.nextTaskID
            let owner = self
            let task = Task { @MainActor [owner] in
                let output = await operation()
                owner.removeCompletedTask(taskID)
                return output
            }
            let joinOperation: GhosttyCallbackTaskJoinOperation = {
                _ = await task.value
            }
            state.taskJoinOperations[taskID] = joinOperation
            return task
        }
    }

    func closeAdmissionAndSnapshot() -> GhosttyCallbackTaskSnapshot {
        let taskJoinOperations = state.withLock { state -> [GhosttyCallbackTaskJoinOperation] in
            state.isAcceptingWork = false
            return Array(state.taskJoinOperations.values)
        }
        return GhosttyCallbackTaskSnapshot(taskJoinOperations: taskJoinOperations)
    }

    private func removeCompletedTask(_ taskID: UInt64) {
        state.withLock { state in
            _ = state.taskJoinOperations.removeValue(forKey: taskID)
        }
    }
}

struct GhosttyCallbackTaskSnapshot: Sendable {
    private let taskJoinOperations: [GhosttyCallbackTaskJoinOperation]

    fileprivate init(taskJoinOperations: [GhosttyCallbackTaskJoinOperation]) {
        self.taskJoinOperations = taskJoinOperations
    }

    func joinAdmittedTasks(isolation: isolated (any Actor)? = #isolation) async {
        for taskJoinOperation in taskJoinOperations {
            await taskJoinOperation()
        }
    }
}
