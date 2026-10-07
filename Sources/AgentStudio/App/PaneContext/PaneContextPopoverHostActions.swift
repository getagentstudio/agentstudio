import AgentStudioCore
import AgentStudioSharedComponents
import Foundation

@MainActor
enum PaneContextPopoverHostActions {
    static func messages(
        controller: PaneContextPopoverController, readers: PaneContextUIReaders,
        onGoToPane: @escaping @MainActor (UUID) -> Void,
        onActionCompleted: @escaping @MainActor () -> Void = {}
    ) -> MessagesPopoverActions {
        MessagesPopoverActions(
            answer: { message, pane, draft in
                Task {
                    defer { onActionCompleted() }
                    guard controller.useCurrentService(readers.serviceProvider()) else { return }
                    await controller.answerDraft(
                        messageId: .init(existingUUID: message), source: .init(existingUUID: pane), draft: draft)
                }
            },
            dismiss: { message, pane in
                Task {
                    defer { onActionCompleted() }
                    guard controller.useCurrentService(readers.serviceProvider()) else { return }
                    await controller.dismiss(messageId: .init(existingUUID: message), source: .init(existingUUID: pane))
                }
            },
            dismissAllNotices: {
                Task {
                    defer { onActionCompleted() }
                    guard controller.useCurrentService(readers.serviceProvider()) else { return }
                    await controller.dismissAllNotices()
                }
            },
            markRead: { message, pane in
                Task {
                    defer { onActionCompleted() }
                    guard controller.useCurrentService(readers.serviceProvider()) else { return }
                    await controller.markRead(
                        messageId: .init(existingUUID: message), source: .init(existingUUID: pane))
                }
            },
            runAction: { message, pane, action in
                Task {
                    defer { onActionCompleted() }
                    guard controller.useCurrentService(readers.serviceProvider()), let action = await coreAction(action)
                    else { return }
                    await controller.runAction(
                        messageId: .init(existingUUID: message), source: .init(existingUUID: pane), action: action)
                }
            },

            goToPane: onGoToPane,
            moreMessages: { cursor in
                Task {
                    defer { onActionCompleted() }
                    guard controller.useCurrentService(readers.serviceProvider()) else { return }
                    await controller.moreMessages(
                        source: .init(existingUUID: cursor.sourcePaneId),
                        after: .init(rank: cursor.rank, position: cursor.position))
                }
            },
            moreSources: { source in
                Task {
                    defer { onActionCompleted() }
                    guard controller.useCurrentService(readers.serviceProvider()) else { return }
                    await controller.moreSources(after: .init(existingUUID: source))
                }
            })
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
