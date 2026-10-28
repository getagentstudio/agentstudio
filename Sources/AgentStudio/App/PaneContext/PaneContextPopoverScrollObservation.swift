import AgentStudioInfrastructure
import AgentStudioSharedComponents
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

enum PaneContextPopoverScrollRequest: Equatable, Sendable {
    case top
    case section(MessagesGroupModel.Kind)
    case message(MessageRowModel.Key)
}

enum PaneContextPopoverScrollEvent {
    case started(PaneContextPopoverScrollOperation, Task<Void, Never>)
    case requested(PaneContextPopoverScrollOperation, PaneContextPopoverScrollRequest)
    case ended(PaneContextPopoverScrollOperation, PaneContextPopoverScrollOutcome)
}

typealias PaneContextPopoverScrollObserver = @MainActor (PaneContextPopoverScrollEvent) -> Void

/// Announces the scroll producer's lifetime; native layout remains a separate observation.
@MainActor
enum PaneContextPopoverScrollObservation {
    // D44: observe the exact argument expression handed to scrollTo; no native-layout claim.
    static func target(
        _ kind: MessagesGroupModel.Kind, operation: PaneContextPopoverScrollOperation,
        observe: PaneContextPopoverScrollObserver
    ) -> MessagesGroupModel.Kind {
        observe(.requested(operation, .section(kind)))
        return kind
    }

    static func target(
        _ key: MessageRowModel.Key, operation: PaneContextPopoverScrollOperation,
        observe: PaneContextPopoverScrollObserver
    ) -> MessageRowModel.Key {
        observe(.requested(operation, .message(key)))
        return key
    }

    static func target(
        _ anchor: PaneContextPopoverPanelAnchor, operation: PaneContextPopoverScrollOperation,
        observe: PaneContextPopoverScrollObserver
    ) -> PaneContextPopoverPanelAnchor {
        observe(.requested(operation, .top))
        return anchor
    }

    static func perform(
        requested: PaneContextMessagesTarget, effective: PaneContextMessagesTarget,
        isPresented: @escaping @MainActor () -> Bool,
        observe: @escaping PaneContextPopoverScrollObserver,
        apply: @escaping @MainActor (PaneContextPopoverScrollOperation) -> Void
    ) async {
        let operation = PaneContextPopoverScrollOperation(requested: requested)
        let task = Task {
            let outcome: PaneContextPopoverScrollOutcome
            if !isPresented() {
                outcome = .retired
            } else if Task.isCancelled {
                outcome = .cancelled
            } else {
                apply(operation)
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
