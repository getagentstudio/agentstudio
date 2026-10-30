import AgentStudioInfrastructure
import AgentStudioTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentStudioCore

@MainActor
@Suite("ArrangementPanel mounted behavior", .serialized)
struct ArrangementPanelMountTests {
    @Test("compact table exposes Pane, Worktree and Status columns")
    func compactTableExposesColumnHeaders() {
        withTestCoreAtoms { _ in
            let host = makeArrangementPanelHostingView(
                panes: [.init(id: UUIDv7.generate(), title: "claude", isMinimized: false)],
                zoomMode: nil)
            for (column, label) in [("pane", "Pane"), ("worktree", "Worktree"), ("status", "Status")] {
                let header = findArrangementPanelView(in: host, identifier: "arrangement-panel-column-\(column)")
                #expect(header?.accessibilityLabel() == label)
            }
        }
    }

    @Test(
        "compact table fits its real mounted width and keeps actions inside", arguments: [false, true])
    func compactTableMountedFrame(longText: Bool) throws {
        try withTestCoreAtoms { _ in
            let rows = arrangementTableFrameRows(longText: longText)
            let measured = ArrangementTableMetrics.measuring(rows)
            let metrics = longText ? measured : ArrangementTableMetrics(paneWidth: 171, worktreeWidth: 130)
            let width = metrics.panelWidth
            let panel = makeArrangementPanelHostingView(
                panes: rows, zoomMode: nil, tableMetrics: metrics,
                arrangements: [
                    .init(id: UUIDv7.generate(), name: "Default", role: .defaultArrangement, isActive: true),
                    .init(id: UUIDv7.generate(), name: "Layout 1", role: .userLayout, isActive: false),
                    .init(id: UUIDv7.generate(), name: "Layout 3", role: .userLayout, isActive: false),
                ]
            ).rootView
            let host = NSHostingView(
                rootView:
                    panel
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, .dark))
            host.frame = CGRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
            let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
            window.contentView = host
            window.orderFront(nil)
            defer {
                window.contentView = nil
                window.close()
            }
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            #expect(host.fittingSize.width >= AppStyles.Components.ArrangementPanel.minimumWidth)
            #expect(host.fittingSize.width <= AppStyles.Components.ArrangementPanel.maximumWidth)
            #expect(host.bounds.width == width)
            var visited = Set<ObjectIdentifier>()
            let needsYou = try #require(
                findArrangementAccessibility(
                    in: host, identifier: "arrangement-panel-pane-\(rows[2].id.uuidString)-status", visited: &visited))
            #expect(needsYou.accessibilityLabel() == "Needs you")
            #expect(needsYou.accessibilityValue() as? String == "Needs you · question")
            for row in rows {
                let action = try #require(
                    findArrangementPanelView(
                        in: host, identifier: "arrangement-panel-pane-\(row.id.uuidString)-visibility"))
                let frame = action.convert(action.bounds, to: host)
                #expect(frame.minX >= 0 && frame.maxX <= width)
            }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            Attachment.record(Array(png), named: "arrangements-\(Int(width)).png")
            if let directory = ProcessInfo.processInfo.environment["AGENTSTUDIO_ARRANGEMENT_FRAME_DIRECTORY"] {
                let root = URL(filePath: directory)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try png.write(to: root.appending(path: "arrangements-\(Int(width)).png"))
            }
            print("arrangements mounted frame: width=\(host.bounds.width) height=\(host.bounds.height)")
        }
    }

    @Test("normal terminal rows expose a targeted canonical Zoom action")
    func normalTerminalRowsExposeTargetedZoomAction() throws {
        try withTestCoreAtoms { _ in
            let paneId = UUID()
            let actionResolver = RecordingArrangementPanelActionResolver()
            let hostingView = NSHostingView(
                rootView: ArrangementPanel(
                    tabId: UUID(),
                    workspaceWindowId: nil,
                    octiconLoader: makeCoreTestOcticonLoader(),
                    panes: [
                        PaneVisibilityInfo(
                            id: paneId,
                            title: "repo | feature/pane-zoom | worktree",
                            isMinimized: false,
                            supportsZoom: true
                        )
                    ],
                    zoomMode: nil,
                    arrangements: [
                        ArrangementInfo(
                            id: UUID(),
                            name: "Default",
                            role: .defaultArrangement,
                            isActive: true
                        )
                    ],
                    inlineRenameState: ArrangementInlineRenameState(),
                    commandActionResolver: actionResolver.resolve,
                    onPaneAction: { _ in },
                    onDismiss: {}
                )
            )
            hostingView.frame = CGRect(origin: .zero, size: hostingView.fittingSize)
            hostingView.layoutSubtreeIfNeeded()

            let zoomView = try #require(
                findArrangementPanelView(
                    in: hostingView,
                    identifier: "arrangement-panel-pane-\(paneId.uuidString)-zoom"
                )
            )
            #expect(zoomView.isAccessibilityElement())
            #expect(zoomView.accessibilityLabel() == "Pane Zoom")
            #expect(zoomView.accessibilityPerformPress())
            #expect(
                actionResolver.performedRequests == [
                    ArrangementPanelActionRequest(
                        command: .zoomPane,
                        surface: .inlineControl,
                        target: paneId,
                        targetType: .pane
                    )
                ]
            )
        }
    }

    @Test("nonterminal rows expose a disabled Zoom slot with the terminal-only explanation")
    func nonterminalRowsDisableZoom() throws {
        try withTestCoreAtoms { _ in
            let paneId = UUIDv7.generate()
            let actionResolver = RecordingArrangementPanelActionResolver()
            let host = makeArrangementPanelHostingView(
                panes: [.init(id: paneId, title: "Bridge review", isMinimized: false, supportsZoom: false)],
                zoomMode: nil, commandActionResolver: actionResolver.resolve)

            let zoomView = try #require(
                findArrangementPanelView(in: host, identifier: "arrangement-panel-pane-\(paneId.uuidString)-zoom"))
            #expect(!zoomView.isAccessibilityEnabled())
            #expect(zoomView.accessibilityHelp() == "Zoom is for terminal panes")
            #expect(!zoomView.accessibilityPerformPress())
            #expect(actionResolver.performedRequests.isEmpty)
        }
    }

    @Test("active Pane Zoom exposes a status block with explicit Cancel Zoom")
    func activePaneZoomExposesStatusBlockWithExplicitCancelZoom() throws {
        try withTestCoreAtoms { _ in
            let sourcePaneId = UUID()
            let actionResolver = RecordingArrangementPanelActionResolver()
            let hostingView = makeArrangementPanelHostingView(
                panes: [
                    PaneVisibilityInfo(
                        id: UUID(),
                        title: "repo | feature/pane-zoom | worktree",
                        isMinimized: false,
                        supportsZoom: true
                    )
                ],
                zoomMode: ArrangementPanelZoomMode(
                    label: "Cancel Zoom",
                    sourcePaneId: sourcePaneId,
                    sourceIdentity: ArrangementPanelZoomSourceIdentity(
                        title: "repo | feature/pane-zoom | worktree",
                        detail: "/Users/example/project/worktree",
                        fullPath: "/Users/example/project/worktree"
                    )
                ),
                commandActionResolver: actionResolver.resolve
            )

            let zoomView = try #require(
                findArrangementPanelView(
                    in: hostingView,
                    identifier: "arrangement-panel-zoom-pane"
                )
            )
            let statusBlock = try #require(
                findArrangementPanelView(
                    in: hostingView,
                    identifier: "arrangement-panel-zoom-status"
                )
            )
            #expect(statusBlock.isAccessibilityElement())
            #expect(zoomView.accessibilityLabel() == "Cancel Zoom")
            #expect(zoomView.accessibilityValue() == nil)
            #expect(zoomView.accessibilityPerformPress())
            #expect(
                actionResolver.performedRequests == [
                    ArrangementPanelActionRequest(
                        command: .zoomPane,
                        surface: .inlineControl,
                        target: sourcePaneId,
                        targetType: .pane
                    )
                ]
            )
        }
    }

    @Test("pane visibility controls use targeted inline commands")
    func paneVisibilityControlsUseTargetedInlineCommands() throws {
        try withTestCoreAtoms { _ in
            let paneId = UUID()
            let actionResolver = RecordingArrangementPanelActionResolver()
            var legacyActions: [WorkspaceActionCommand] = []
            let hostingView = makeArrangementPanelHostingView(
                panes: [
                    PaneVisibilityInfo(
                        id: paneId,
                        title: "Terminal",
                        isMinimized: false
                    )
                ],
                zoomMode: nil,
                commandActionResolver: actionResolver.resolve,
                onPaneAction: { legacyActions.append($0) }
            )

            let visibilityView = try #require(
                findArrangementPanelView(
                    in: hostingView,
                    identifier: "arrangement-panel-pane-\(paneId.uuidString)-visibility"
                )
            )
            #expect(visibilityView.accessibilityPerformPress())
            #expect(
                actionResolver.performedRequests == [
                    ArrangementPanelActionRequest(
                        command: .minimizePane,
                        surface: .inlineControl,
                        target: paneId,
                        targetType: .pane
                    )
                ]
            )
            #expect(legacyActions.isEmpty)
        }
    }

    @Test("visibility controls expose the canonical eye-action help", arguments: [false, true])
    func paneVisibilityControlsUseTypedCommandTooltips(hidden: Bool) throws {
        try withTestCoreAtoms { _ in
            let paneId = UUIDv7.generate()
            let host = makeArrangementPanelHostingView(
                panes: [.init(id: paneId, title: "Shell", isMinimized: hidden)], zoomMode: nil)

            let button = try #require(
                findArrangementPanelView(
                    in: host, identifier: "arrangement-panel-pane-\(paneId.uuidString)-visibility"))
            #expect(button.accessibilityLabel() == (hidden ? "Show Pane" : "Hide Pane"))
            #expect(button.accessibilityHelp() == (hidden ? "Show pane" : "Hide pane"))
        }
    }

    @Test("arrangement rename survives transient AppKit focus churn")
    func arrangementRenameSurvivesTransientFocusChurn() async throws {
        try await withAsyncTestCoreAtoms { _ in
            let arrangementId = UUID()
            let renameState = ArrangementInlineRenameState()
            renameState.beginEditing(
                arrangementId: arrangementId,
                currentName: "Layout 1",
                isDefault: false
            )
            let hostingView = NSHostingView(
                rootView: ArrangementPanel(
                    tabId: UUID(),
                    workspaceWindowId: nil,
                    octiconLoader: makeCoreTestOcticonLoader(),
                    panes: [],
                    zoomMode: nil,
                    arrangements: [
                        ArrangementInfo(
                            id: arrangementId,
                            name: "Layout 1",
                            role: .userLayout,
                            isActive: true
                        )
                    ],
                    inlineRenameState: renameState,
                    commandActionResolver: makePresentedCommandAction,
                    onPaneAction: { _ in },
                    onDismiss: {}
                )
            )
            let window = NSWindow(contentViewController: NSViewController())
            window.contentView = hostingView
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            hostingView.frame = CGRect(origin: .zero, size: hostingView.fittingSize)
            hostingView.layoutSubtreeIfNeeded()

            var mountedRenameField: ArrangementRenameNSTextField?
            await assertEventuallyMain("arrangement rename field should mount") {
                mountedRenameField = findArrangementRenameField(in: hostingView)
                return mountedRenameField != nil
            }
            let renameField = try #require(mountedRenameField)
            renameField.focusAndSelectAll()
            await assertEventuallyMain("arrangement rename field should become first responder") {
                window.firstResponder === renameField.currentEditor()
            }
            let fieldEditor = try #require(renameField.currentEditor())

            window.makeFirstResponder(nil)
            await assertEventuallyMain("arrangement rename field should report editing ended") {
                renameField.currentEditor() == nil && window.firstResponder !== fieldEditor
            }

            #expect(renameState.editingArrangementId == arrangementId)
        }
    }
}

@MainActor
private func makeArrangementPanelHostingView(
    panes: [PaneVisibilityInfo],
    zoomMode: ArrangementPanelZoomMode?,
    commandActionResolver: @escaping TargetedCommandControlActionResolver =
        makePresentedCommandAction,
    onPaneAction: @escaping (WorkspaceActionCommand) -> Void = { _ in },
    tableMetrics: ArrangementTableMetrics = .minimum,
    arrangements: [ArrangementInfo]? = nil
) -> NSHostingView<ArrangementPanel> {
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
            repositoryName: "agentstudio", tableMetrics: tableMetrics
        )
    )
    hostingView.frame = CGRect(origin: .zero, size: hostingView.fittingSize)
    hostingView.layoutSubtreeIfNeeded()
    return hostingView
}

private func arrangementTableFrameRows(longText: Bool) -> [PaneVisibilityInfo] {
    let working = ArrangementPaneStatus.agent(
        .init(kind: .working, label: "Working", detail: "Working", icon: .system(.circleFill)))
    let needsYou = ArrangementPaneStatus.agent(
        .init(kind: .needsYou, label: "Needs you", detail: "Needs you · question", icon: .system(.flag)))
    let agentLine =
        longText
        ? "Running Swift tests • 212/412 • Checking linked worktrees, unlinked working directories, and preserved per-pane Agent Lines [2 min ago]"
        : "Running Swift tests • 212/412 [2 min ago]"
    return [
        .init(
            id: UUIDv7.generate(),
            title: longText
                ? "claude — investigating pane context publication and reviewing arrangement behavior" : "claude",
            isMinimized: false, supportsZoom: true,
            agentLine: agentLine, worktreeName: "pane-fixes", branchName: "restore-r3-port",
            agentStatus: working),
        .init(
            id: UUIDv7.generate(), title: "zsh", isMinimized: false, supportsZoom: true,
            paneNote: "Scratch shell",
            cwdPath: longText
                ? "~/code/projects/a-long-unlinked-working-directory/with-a-subdirectory-that-must-wrap-without-losing-text"
                : "~/code/projects/scratch"),
        .init(
            id: UUIDv7.generate(), title: "codex", isMinimized: false, supportsZoom: true,
            agentLine: "Waiting for your review [Now]", worktreeName: "pane-context", branchName: "pane-context",
            agentStatus: needsYou),
        .init(
            id: UUIDv7.generate(), title: "Bridge • Review", isMinimized: false,
            paneIcon: .system(.bubbleLeft), paneNote: "Review pane changes", worktreeName: "pane-fixes",
            branchName: "restore-r3-port"),
        .init(
            id: UUIDv7.generate(), title: "mise run test", isMinimized: true, supportsZoom: true,
            paneNote: "Test output", worktreeName: "pane-fixes", branchName: "restore-r3-port", agentStatus: .hidden),
    ]
}

private struct ArrangementPanelActionRequest: Equatable {
    let command: AppCommand
    let surface: AppCommandSurface
    let target: UUID
    let targetType: SearchItemType
}

@MainActor
private final class RecordingArrangementPanelActionResolver {
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
private func makePresentedCommandAction(
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
private func findArrangementPanelView(
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
private func findArrangementAccessibility(
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
private func findArrangementRenameField(in root: NSView) -> ArrangementRenameNSTextField? {
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
