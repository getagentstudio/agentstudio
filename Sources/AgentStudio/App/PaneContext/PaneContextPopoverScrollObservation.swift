import AgentStudioInfrastructure
import Foundation

struct PaneContextPopoverScrollOperation: Equatable, Sendable {
    let id = UUIDv7.generate()
    let requested: PaneContextMessagesTarget
}

enum PaneContextPopoverScrollOutcome: Equatable, Sendable {
    case applied
    case fellBackToTop
    case cancelled
    case retired
}

enum PaneContextPopoverScrollEvent {
    case started(PaneContextPopoverScrollOperation, Task<Void, Never>)
    case ended(PaneContextPopoverScrollOperation, PaneContextPopoverScrollOutcome)
}

typealias PaneContextPopoverScrollObserver = @MainActor (PaneContextPopoverScrollEvent) -> Void

/// Announces the scroll producer's lifetime; native layout remains a separate observation.
@MainActor
enum PaneContextPopoverScrollObservation {
    static func perform(
        requested: PaneContextMessagesTarget, effective: PaneContextMessagesTarget,
        isPresented: @escaping @MainActor () -> Bool,
        observe: @escaping PaneContextPopoverScrollObserver,
        apply: @escaping @MainActor () -> Void
    ) async {
        let operation = PaneContextPopoverScrollOperation(requested: requested)
        let task = Task {
            let outcome: PaneContextPopoverScrollOutcome
            if !isPresented() {
                outcome = .retired
            } else if Task.isCancelled {
                outcome = .cancelled
            } else {
                apply()
                if case .section = requested, effective == .top {
                    outcome = .fellBackToTop
                } else {
                    outcome = .applied
                }
            }
            observe(.ended(operation, outcome))
        }
        observe(.started(operation, task))
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
