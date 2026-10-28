import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation

@MainActor
enum PaneContextPopoverHostActions {
    static func messages(
        handle: PaneContextPopoverConsumerHandle, bindings: PaneContextPopoverHostBindings,
        isCurrentOpening: @escaping @MainActor () -> Bool,
        onGoToPane: @escaping @MainActor (UUID) -> Void,
        onDismissPopover: @escaping @MainActor () -> Void = {},
        onActionCompleted: @escaping @MainActor () -> Void = {},
        onActionTaskStarted: @escaping @MainActor (Task<Void, Never>) -> Void = { _ in },
        presentationObservation: PaneContextPopoverPresentationObservation? = nil
    ) -> MessagesPopoverActions {
        func person(_ intent: PaneContextPopoverPersonIntent) {
            start(onCompleted: onActionCompleted, onStarted: onActionTaskStarted, presentation: presentationObservation)
            {
                let result = await bindings.performPerson(intent, handle: handle)
                if result.presentation == .dismissPopover, isCurrentOpening() { onDismissPopover() }
            }
        }
        func page(_ scope: PaneContextPopoverPageScope) {
            start(onCompleted: onActionCompleted, onStarted: onActionTaskStarted, presentation: presentationObservation)
            {
                _ = await bindings.loadPage(scope, handle: handle)
            }
        }
        return .init(
            answer: { message, source, draft in
                person(
                    .answer(.init(paneId: .init(existingUUID: source), messageId: .init(existingUUID: message)), draft))
            },
            dismiss: { message, source in
                person(.dismiss(.init(paneId: .init(existingUUID: source), messageId: .init(existingUUID: message))))
            },
            dismissAllNotices: { person(.dismissAllNotices) },
            runAction: { message, source, action in
                person(
                    .runAction(
                        .init(paneId: .init(existingUUID: source), messageId: .init(existingUUID: message)), action))
            },
            goToPane: onGoToPane,
            moreMessages: { cursor in
                page(
                    .messages(
                        source: .init(existingUUID: cursor.sourcePaneId), rank: cursor.rank, position: cursor.position))
            },
            moreSources: { source in page(.sources(after: .init(existingUUID: source))) },
            captureBodyGeometry: { row, geometry in
                guard isCurrentOpening() else { return }
                // fire-and-forget: Input capture retains and drains the producer with this opening.
                _ = bindings.inputs.forwardBodyGeometry(
                    geometry, row: row, for: handle.key, opening: handle.opening.epoch)
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
