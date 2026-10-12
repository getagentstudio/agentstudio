import AgentStudioCore
import Foundation

@testable import AgentStudioTerminal

@MainActor
final class TerminalFixtureCommandDispatcher: AppCommandDispatching {
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
final class TerminalFixtureSurfaceCommands: TerminalSurfaceCommandDispatching {
    func sendInput(_: String, toPaneId _: UUID) -> Result<Void, SurfaceError> { .failure(.surfaceNotFound) }
    func clearScrollback(forPaneId _: UUID) -> Result<Void, SurfaceError> { .failure(.surfaceNotFound) }
    func scrollToBottom(forPaneId _: UUID) -> Result<Void, SurfaceError> { .failure(.surfaceNotFound) }
    func scrollPageFractional(fraction _: Double, forPaneId _: UUID) -> Result<Void, SurfaceError> {
        .failure(.surfaceNotFound)
    }
    func jumpToPrompt(delta _: Int, forPaneId _: UUID) -> Result<Void, SurfaceError> { .failure(.surfaceNotFound) }
}

@MainActor
func makeTerminalFixtureSurfaceManager(
    callbackHandlingAccess: @escaping @MainActor () -> Ghostty.ActionRouter? = { nil }
) -> SurfaceManager {
    SurfaceManager(
        appCommandDispatcher: TerminalFixtureCommandDispatcher(), engineAccess: { .unavailable },
        callbackHandlingAccess: callbackHandlingAccess, healthCheckInterval: 3600
    )
}

@MainActor
func makeTerminalFixtureMountOperations() -> TerminalPaneMountView.SurfaceOperations {
    .init(
        registerHealthDelegate: { _ in }, destroySurface: { _ in },
        hasProcessExited: { _ in true }, setFocus: { _, _ in })
}
