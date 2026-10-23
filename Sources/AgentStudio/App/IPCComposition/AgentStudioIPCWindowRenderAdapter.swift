import AgentStudioAppIPC
import AgentStudioProgrammaticControl
import AppKit
import Foundation

@MainActor
protocol AgentStudioIPCWindowOwning: AnyObject {
    func renderingWindow(workspaceWindowId: UUID) throws -> NSWindow
}

@MainActor
final class AgentStudioIPCWindowRenderAdapter: AppIPCWindowRenderPort {
    private weak var owner: (any AgentStudioIPCWindowOwning)?
    private let rendersDirectory: URL

    init(owner: any AgentStudioIPCWindowOwning, rendersDirectory: URL) {
        self.owner = owner
        self.rendersDirectory = rendersDirectory
    }

    func render(_ params: IPCWindowRenderParams) async throws -> IPCWindowRenderResult {
        guard let owner else { throw AppIPCWindowRenderError.targetNotFound }
        let window = try owner.renderingWindow(workspaceWindowId: params.workspaceWindowId)
        return try await WindowContentRenderer.render(
            window: window, workspaceWindowId: params.workspaceWindowId, rendersDirectory: rendersDirectory)
    }

    func resize(_ params: IPCWindowResizeParams) async throws -> IPCWindowResizeResult {
        guard params.contentWidth.isFinite, params.contentHeight.isFinite,
            params.contentWidth > 0, params.contentHeight > 0
        else { throw AppIPCWindowRenderError.invalidSize }
        guard let owner else { throw AppIPCWindowRenderError.targetNotFound }
        let window = try owner.renderingWindow(workspaceWindowId: params.workspaceWindowId)
        guard let contentView = window.contentView else { throw AppIPCWindowRenderError.noContentView }
        window.setContentSize(NSSize(width: params.contentWidth, height: params.contentHeight))
        window.layoutIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        return IPCWindowResizeResult(
            workspaceWindowId: params.workspaceWindowId,
            contentSize: .init(width: contentView.bounds.width, height: contentView.bounds.height),
            correlationId: params.correlationId)
    }
}

extension AppDelegate: AgentStudioIPCWindowOwning {
    func renderingWindow(workspaceWindowId: UUID) throws -> NSWindow {
        guard let controller = mainWindowController,
            controller.workspaceWindowId == workspaceWindowId,
            controller.acceptsIPCCommands,
            let window = controller.window
        else { throw AppIPCWindowRenderError.targetNotFound }
        return window
    }
}
