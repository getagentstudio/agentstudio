import AgentStudioInfrastructure
import AgentStudioTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentStudioCore

@MainActor
func makeArrangementPanelHostingView(
    panes: [PaneVisibilityInfo],
    zoomMode: ArrangementPanelZoomMode?,
    commandActionResolver: @escaping TargetedCommandControlActionResolver =
        makePresentedCommandAction,
    onPaneAction: @escaping (WorkspaceActionCommand) -> Void = { _ in },
    tableMetrics: ArrangementTableMetrics = .minimum,
    arrangements: [ArrangementInfo]? = nil
) -> NSHostingView<some View> {
    let hostingView = NSHostingView(
        rootView: ArrangementPanel(
            tabId: UUIDv7.generate(),
            workspaceWindowId: nil,
            octiconLoader: makeCoreTestOcticonLoader(),
            panes: panes,
            zoomMode: zoomMode,
            arrangements: arrangements ?? [
                ArrangementInfo(
                    id: UUIDv7.generate(),
                    name: "Default",
                    role: .defaultArrangement,
                    isActive: true
                )
            ],
            inlineRenameState: ArrangementInlineRenameState(),
            commandActionResolver: commandActionResolver,
            onPaneAction: onPaneAction,
            onDismiss: {},
            paneGroups: ArrangementTableProjector.groupedPanes(panes), tableMetrics: tableMetrics
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .dark)
    )
    hostingView.appearance = NSAppearance(named: .darkAqua)
    hostingView.frame = CGRect(origin: .zero, size: hostingView.fittingSize)
    hostingView.layoutSubtreeIfNeeded()
    return hostingView
}

func arrangementTableFrameRows(longText: Bool) -> [PaneVisibilityInfo] {
    let firstWorktree = UUIDv7.generate()
    let secondWorktree = UUIDv7.generate()
    let working = ArrangementPaneStatus.agent(
        .init(kind: .working, label: "Working", detail: "Working", icon: .system(.circleFill)))
    let needsYou = ArrangementPaneStatus.agent(
        .init(kind: .needsYou, label: "Needs you", detail: "Needs you · question", icon: .system(.flag)))
    return [
        .init(
            id: UUIDv7.generate(),
            title: longText
                ? "claude — investigating pane context publication and reviewing arrangement behavior" : "claude",
            isMinimized: false, supportsZoom: true,
            agentLine: .init(
                summary: longText
                    ? "Running Swift tests • 212/412 • Checking linked worktrees, unlinked working directories, and preserved per-pane Agent Lines"
                    : "Running Swift tests • 212/412", ageText: "[Now]"),
            cwdPath: "~/code/projects/agentstudio.pane-fixes", repositoryName: "agentstudio",
            worktreeName: "agentstudio.pane-fixes", branchName: "restore-r3-port",
            agentStatus: working, section: .worktree(firstWorktree), providerName: "Claude"),
        .init(
            id: UUIDv7.generate(), title: "zsh", isMinimized: false, supportsZoom: true,
            paneNote: "Scratch shell",
            cwdPath: longText
                ? "~/code/projects/a-long-unlinked-working-directory/with-a-subdirectory-that-must-wrap-without-losing-text"
                : "~/code/projects/scratch"),
        .init(
            id: UUIDv7.generate(), title: "codex", isMinimized: false, supportsZoom: true,
            agentLine: .init(summary: "Waiting for your review", ageText: "[2 min ago]"),
            cwdPath: "~/code/projects/agentstudio.pane-context", repositoryName: "agentstudio",
            worktreeName: "agentstudio.pane-context", branchName: "pane-context",
            agentStatus: needsYou, section: .worktree(secondWorktree), providerName: "Codex"),
        .init(
            id: UUIDv7.generate(), title: "Bridge • Code review", isMinimized: false,
            paneIcon: .octicon(.gitBranch), paneNote: "Review pane changes",
            cwdPath: "~/code/projects/agentstudio.pane-fixes", repositoryName: "agentstudio",
            worktreeName: "agentstudio.pane-fixes", branchName: "restore-r3-port", section: .worktree(firstWorktree)),
        .init(
            id: UUIDv7.generate(), title: "mise run test", isMinimized: true, supportsZoom: true,
            paneNote: "Test output", cwdPath: "~/code/projects/agentstudio.pane-fixes", repositoryName: "agentstudio",
            worktreeName: "agentstudio.pane-fixes",
            branchName: "restore-r3-port", section: .worktree(firstWorktree)),
    ]
}

struct ArrangementPanelActionRequest: Equatable {
    let command: AppCommand
    let surface: AppCommandSurface
    let target: UUID
    let targetType: SearchItemType
}

@MainActor
final class RecordingArrangementPanelActionResolver {
    private(set) var requests: [ArrangementPanelActionRequest] = []
    private(set) var performedRequests: [ArrangementPanelActionRequest] = []

    func resolve(
        command: AppCommand,
        surface: AppCommandSurface,
        target: UUID,
        targetType: SearchItemType
    ) -> TargetedCommandControlAction? {
        let request = ArrangementPanelActionRequest(
            command: command,
            surface: surface,
            target: target,
            targetType: targetType
        )
        requests.append(request)
        let commandSpec = command.definition
        guard
            commandSpec.shouldPresent(
                AppCommandPresentationQuery(
                    surface: surface,
                    subject: .targeted(targetType)
                )
            )
        else {
            return nil
        }
        return TargetedCommandControlAction(
            commandSpec: commandSpec,
            isEnabled: true,
            perform: { [weak self] in
                self?.performedRequests.append(request)
            }
        )
    }
}

@MainActor
func makePresentedCommandAction(
    command: AppCommand,
    surface: AppCommandSurface,
    target _: UUID,
    targetType: SearchItemType
) -> TargetedCommandControlAction? {
    let commandSpec = command.definition
    guard
        commandSpec.shouldPresent(
            AppCommandPresentationQuery(
                surface: surface,
                subject: .targeted(targetType)
            )
        )
    else {
        return nil
    }
    return TargetedCommandControlAction(
        commandSpec: commandSpec,
        isEnabled: true,
        perform: {}
    )
}

@MainActor
func findArrangementPanelView(
    in root: NSView,
    identifier: String
) -> NSView? {
    if root.identifier?.rawValue == identifier {
        return root
    }

    for subview in root.subviews {
        if let match = findArrangementPanelView(in: subview, identifier: identifier) {
            return match
        }
    }
    return nil
}

@MainActor
func findArrangementAccessibility(
    in element: AnyObject, identifier: String, visited: inout Set<ObjectIdentifier>
) -> (any NSAccessibilityProtocol)? {
    guard visited.insert(ObjectIdentifier(element)).inserted else { return nil }
    if let accessible = element as? any NSAccessibilityProtocol {
        if accessible.accessibilityIdentifier() == identifier { return accessible }
        for child in accessible.accessibilityChildren() ?? [] {
            if let found = findArrangementAccessibility(
                in: child as AnyObject, identifier: identifier, visited: &visited)
            {
                return found
            }
        }
    }
    for child in (element as? NSView)?.subviews ?? [] {
        if let found = findArrangementAccessibility(in: child, identifier: identifier, visited: &visited) {
            return found
        }
    }
    return nil
}

@MainActor
func findArrangementRenameField(in root: NSView) -> ArrangementRenameNSTextField? {
    if let field = root as? ArrangementRenameNSTextField {
        return field
    }
    for subview in root.subviews {
        if let field = findArrangementRenameField(in: subview) {
            return field
        }
    }
    return nil
}

@MainActor
func captureArrangementPanel(_ host: NSView, named name: String) throws {
    guard let directory = ProcessInfo.processInfo.environment["AGENTSTUDIO_ARRANGEMENT_FRAME_DIRECTORY"] else {
        return
    }
    host.appearance = NSAppearance(named: .darkAqua)
    let ownedWindow: NSWindow?
    if host.window == nil {
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.contentView = host
        window.orderFront(nil)
        ownedWindow = window
    } else {
        ownedWindow = nil
    }
    defer {
        ownedWindow?.contentView = nil
        ownedWindow?.close()
    }
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    #expect(host.bounds.width == (name.contains("760") ? 760 : 520))
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    Attachment.record(Array(png), named: name + ".png")
    let root = URL(filePath: directory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try png.write(to: root.appending(path: name + ".png"))
}
