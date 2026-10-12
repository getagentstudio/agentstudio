import AgentStudioCore
import Foundation

@testable import AgentStudio
@testable import AgentStudioTerminal

@MainActor
final class AppTerminalFixtureCommandDispatcher: AppCommandDispatching {
    func dispatch(_: AppCommand) -> Bool { false }
    func dispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) {}
    func dispatchKeyboardShortcut(_: AppShortcut) {}
    func dispatchExtractPaneToTab(tabId _: UUID, paneId _: UUID, targetTabInsertionIndex _: Int?) {}
    func canDispatch(_: AppCommand) -> Bool { false }
    func canDispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool { false }
    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? { nil }
    func dispatchMovePaneToTab(sourcePaneId _: UUID, sourceTabId _: UUID?, targetTabId _: UUID) {}
}

@MainActor
final class AppTerminalFixtureSurfaceCommands: TerminalSurfaceCommandDispatching {
    func sendInput(_: String, toPaneId _: UUID) -> Result<Void, SurfaceError> { .failure(.surfaceNotFound) }
    func clearScrollback(forPaneId _: UUID) -> Result<Void, SurfaceError> { .failure(.surfaceNotFound) }
    func scrollToBottom(forPaneId _: UUID) -> Result<Void, SurfaceError> { .failure(.surfaceNotFound) }
    func scrollPageFractional(fraction _: Double, forPaneId _: UUID) -> Result<Void, SurfaceError> {
        .failure(.surfaceNotFound)
    }
    func jumpToPrompt(delta _: Int, forPaneId _: UUID) -> Result<Void, SurfaceError> { .failure(.surfaceNotFound) }
}

@MainActor
func makeAppTerminalFixtureSurfaceManager(
    callbackHandlingAccess: @escaping @MainActor () -> Ghostty.ActionRouter? = { nil }
) -> SurfaceManager {
    SurfaceManager(
        appCommandDispatcher: AppTerminalFixtureCommandDispatcher(), engineAccess: { .unavailable },
        callbackHandlingAccess: callbackHandlingAccess, healthCheckInterval: 3600
    )
}

@MainActor
func makeAppTerminalFixtureMountOperations(
    surfaceManager: (any WorkspaceSurfaceManaging)? = nil
) -> TerminalPaneMountView.SurfaceOperations {
    if let manager = surfaceManager as? SurfaceManager {
        return manager.makeTerminalPaneSurfaceOperations()
    }
    return .init(
        registerHealthDelegate: { _ in },
        destroySurface: { [weak surfaceManager] in surfaceManager?.destroy($0) },
        hasProcessExited: { _ in true }, setFocus: { _, _ in })
}
