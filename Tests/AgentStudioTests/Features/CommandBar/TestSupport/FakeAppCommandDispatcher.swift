import AgentStudioCore
import Foundation

@testable import AgentStudioCommandBar

@MainActor
final class FakeAppCommandDispatcher: AppCommandDispatching {
    func dispatchKeyboardShortcut(_: AppShortcut) {}
    func dispatchExtractPaneToTab(tabId _: UUID, paneId _: UUID, targetTabInsertionIndex _: Int?) {}

    var availableCommands = Set(AppCommand.allCases)
    var dispatchedCommands: [AppCommand] = []
    var targetedDispatches: [(command: AppCommand, target: UUID, targetType: SearchItemType)] = []
    var bridgeTargetsByWorktreeId: [UUID: BridgePaneCommandTarget] = [:]
    var bridgeTargetLookupCount = 0
    var bridgeTargetLookupWorktreeIds: [UUID] = []
    var movePaneDispatches: [(sourcePaneId: UUID, sourceTabId: UUID?, targetTabId: UUID)] = []
    var worktreeCreationDispatches: [WorktreeCreationRequest] = []

    func dispatch(_ command: AppCommand) -> Bool {
        dispatchedCommands.append(command)
        return availableCommands.contains(command)
    }

    func dispatch(_ command: AppCommand, target: UUID, targetType: SearchItemType) {
        targetedDispatches.append((command, target, targetType))
    }

    func canDispatch(_ command: AppCommand) -> Bool {
        availableCommands.contains(command)
    }

    func canDispatch(_ command: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool {
        availableCommands.contains(command)
    }

    func bridgePaneCommandTarget(worktreeId: UUID) -> BridgePaneCommandTarget? {
        bridgeTargetLookupCount += 1
        bridgeTargetLookupWorktreeIds.append(worktreeId)
        return bridgeTargetsByWorktreeId[worktreeId]
    }

    func dispatchMovePaneToTab(sourcePaneId: UUID, sourceTabId: UUID?, targetTabId: UUID) {
        movePaneDispatches.append((sourcePaneId, sourceTabId, targetTabId))
    }

    func dispatchWorktreeCreation(_ request: WorktreeCreationRequest) -> Bool {
        worktreeCreationDispatches.append(request)
        return availableCommands.contains(request.kind.command)
    }
}
