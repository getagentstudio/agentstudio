import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation

struct PaneContextReadOperation: Equatable, Sendable {
    let id = UUIDv7.generate()
    let key: PaneContextRefreshKey
    let location: PaneContextPopoverLocation
}

typealias PaneContextReadTaskObserver = @MainActor (PaneContextReadOperation, Task<Void, Never>) -> Void
typealias PaneContextReadCompletionObserver =
    @MainActor (PaneContextReadOperation, PaneContextPopoverController?) -> Void

@MainActor
enum PaneContextPopoverHostActions {
    static func read(
        key: PaneContextRefreshKey, location: PaneContextPopoverLocation,
        onStarted: PaneContextReadTaskObserver,
        operation: @escaping @MainActor (PaneContextReadOperation) async -> Void
    ) async {
        let read = PaneContextReadOperation(key: key, location: location)
        let task = Task { await operation(read) }
        onStarted(read, task)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func messages(
        controller: PaneContextPopoverController, readers: PaneContextUIReaders,
        onGoToPane: @escaping @MainActor (UUID) -> Void,
        onDismissPopover: @escaping @MainActor () -> Void = {},
        onActionCompleted: @escaping @MainActor () -> Void = {},
        onActionTaskStarted: @escaping @MainActor (Task<Void, Never>) -> Void = { _ in },
        presentationObservation: PaneContextPopoverPresentationObservation? = nil
    ) -> MessagesPopoverActions {
        MessagesPopoverActions(
            answer: { message, pane, draft in
                start(
                    onCompleted: onActionCompleted, onStarted: onActionTaskStarted,
                    presentation: presentationObservation
                ) {
                    guard controller.useCurrentService(readers.serviceProvider()) else { return }
                    await controller.answerDraft(
                        messageId: .init(existingUUID: message), source: .init(existingUUID: pane), draft: draft)
                }
            },
            dismiss: { message, pane in
                start(
                    onCompleted: onActionCompleted, onStarted: onActionTaskStarted,
                    presentation: presentationObservation
                ) {
                    guard controller.useCurrentService(readers.serviceProvider()) else { return }
                    await controller.dismiss(messageId: .init(existingUUID: message), source: .init(existingUUID: pane))
                }
            },
            dismissAllNotices: {
                start(
                    onCompleted: onActionCompleted, onStarted: onActionTaskStarted,
                    presentation: presentationObservation
                ) {
                    guard controller.useCurrentService(readers.serviceProvider()) else { return }
                    await controller.dismissAllNotices()
                }
            },
            runAction: { message, pane, action in
                start(
                    onCompleted: onActionCompleted, onStarted: onActionTaskStarted,
                    presentation: presentationObservation
                ) {
                    guard controller.useCurrentService(readers.serviceProvider()), let action = await coreAction(action)
                    else { return }
                    let result = await controller.runAction(
                        messageId: .init(existingUUID: message), source: .init(existingUUID: pane), action: action)
                    if result == .goToPane(.focused) { onDismissPopover() }
                }
            },

            goToPane: onGoToPane,
            moreMessages: { cursor in
                start(
                    onCompleted: onActionCompleted, onStarted: onActionTaskStarted,
                    presentation: presentationObservation
                ) {
                    guard controller.useCurrentService(readers.serviceProvider()) else { return }
                    await controller.moreMessages(
                        source: .init(existingUUID: cursor.sourcePaneId),
                        after: .init(rank: cursor.rank, position: cursor.position))
                }
            },
            moreSources: { source in
                start(
                    onCompleted: onActionCompleted, onStarted: onActionTaskStarted,
                    presentation: presentationObservation
                ) {
                    guard controller.useCurrentService(readers.serviceProvider()) else { return }
                    await controller.moreSources(after: .init(existingUUID: source))
                }
            })
    }
    private static func start(
        onCompleted: @escaping @MainActor () -> Void,
        onStarted: @escaping @MainActor (Task<Void, Never>) -> Void,
        presentation: PaneContextPopoverPresentationObservation?,
        operation: @escaping @MainActor () async -> Void
    ) {
        let presentationOperation = presentation?.operation()
        let task = Task {
            defer {
                presentationOperation?.decided()
                onCompleted()
            }
            await operation()
        }
        presentationOperation?.started(.task(task))
        onStarted(task)
    }

    @concurrent nonisolated static func coreAction(_ model: MessageActionModel) async -> MessageAction? {
        switch model {
        case .openFile(let path, let line): .openFile(path: path, line: line)
        case .goToPane(let pane): .goToPane(.init(existingUUID: pane))
        case .openPullRequest(let identity):
            (try? ForgePullRequestIdentity(
                host: identity.host, owner: identity.owner, repository: identity.repository, number: identity.number))
                .map(MessageAction.openPullRequest)
        }
    }
}
