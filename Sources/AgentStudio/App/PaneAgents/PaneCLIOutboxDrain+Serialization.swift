import AgentStudioInfrastructure
import Foundation

extension PaneCLIOutboxDrain {
    /// A turn includes history adoption and every effect/cursor commit. Each
    /// successor executes its own read; a completed report cannot serve B1 again.
    func acquireDrainTurn() async -> Bool {
        let requestId = UUIDv7.generate()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            guard isDraining else {
                isDraining = true
                return true
            }
            return await withCheckedContinuation { continuation in
                pendingDrains.append(.init(id: requestId, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelPendingDrain(requestId) }
        }
    }

    func releaseDrainTurn() {
        guard !pendingDrains.isEmpty else {
            isDraining = false
            return
        }
        // Retain ownership during handoff so a newcomer cannot overtake FIFO.
        pendingDrains.removeFirst().continuation.resume(returning: true)
    }

    private func cancelPendingDrain(_ requestId: UUID) {
        guard let index = pendingDrains.firstIndex(where: { $0.id == requestId }) else { return }
        pendingDrains.remove(at: index).continuation.resume(returning: false)
    }
}

struct PendingDrainTurn {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
}
