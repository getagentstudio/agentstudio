import AgentStudioInfrastructure
import AgentStudioTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentStudioCore

@MainActor
@Suite("ArrangementPanel mounted behavior", .serialized)
struct ArrangementPanelMountTests {
    @Test("worktree groups replace the table headers")
    func groupedRowsExposeHeaders() {
        withTestCoreAtoms { _ in
            let rows = arrangementTableFrameRows(longText: false)
            let host = makeArrangementPanelHostingView(panes: rows, zoomMode: nil)
            for group in ArrangementTableProjector.groupedPanes(rows) {
                let header = findArrangementPanelView(
                    in: host, identifier: "arrangement-panel-group-\(group.id.accessibilityKey)")
                #expect(header?.accessibilityLabel() == group.title)
            }
            #expect(findArrangementPanelView(in: host, identifier: "arrangement-panel-column-pane") == nil)
        }
    }

    @Test(
        "grouped token layout fits its mounted width and keeps actions inside", arguments: [false, true])
    func groupedPanelMountedFrame(longText: Bool) throws {
        try withTestCoreAtoms { _ in
            let rows = arrangementTableFrameRows(longText: longText)
            let measured = ArrangementTableMetrics.measuring(rows)
            let metrics = longText ? measured : ArrangementTableMetrics(panelWidth: 520)
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
                    in: host, identifier: "arrangement-panel-pane-\(rows[2].id.uuidString)-agent", visited: &visited))
            #expect(needsYou.accessibilityLabel() == "Codex")
            #expect(needsYou.accessibilityValue() as? String == "Needs you")
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

    @Test("Agent Line owns its inline age; title has no age and Hidden remains separate")
    func conditionalTokensAndHiddenAge() throws {
        try withTestCoreAtoms { _ in
            let rows = arrangementTableFrameRows(longText: false)
            let host = makeArrangementPanelHostingView(panes: rows, zoomMode: nil)
            let shell = rows[1]
            #expect(
                findArrangementPanelView(in: host, identifier: "arrangement-panel-pane-\(shell.id.uuidString)-agent")
                    == nil)
            #expect(
                findArrangementPanelView(in: host, identifier: "arrangement-panel-pane-\(shell.id.uuidString)-age")
                    == nil)
            let cwd = try #require(
                findArrangementPanelView(
                    in: host, identifier: "arrangement-panel-pane-\(shell.id.uuidString)-cwd"))
            #expect(cwd.accessibilityLabel() == "~/code/projects/scratch")
            let claude = rows[0]
            let line = try #require(
                findArrangementPanelView(
                    in: host, identifier: "arrangement-panel-pane-\(claude.id.uuidString)-detail"))
            #expect(line.accessibilityLabel() == "Running Swift tests • 212/412 [Now]")
            #expect(
                findArrangementPanelView(in: host, identifier: "arrangement-panel-pane-\(claude.id.uuidString)-age")
                    == nil)
            #expect(
                findArrangementPanelView(in: host, identifier: "arrangement-panel-pane-\(claude.id.uuidString)-cwd")
                    == nil)
            let hidden = rows[4]
            #expect(
                findArrangementPanelView(in: host, identifier: "arrangement-panel-pane-\(hidden.id.uuidString)-age")
                    == nil)
            let hiddenValue = try #require(
                findArrangementPanelView(
                    in: host, identifier: "arrangement-panel-pane-\(hidden.id.uuidString)-hidden"))
            #expect(hiddenValue.accessibilityLabel() == "Hidden")
            let detail = try #require(
                findArrangementPanelView(
                    in: host, identifier: "arrangement-panel-pane-\(hidden.id.uuidString)-detail"))
            #expect(detail.accessibilityLabel() == "Test output")
        }
    }

    @Test("a pane note suppresses an existing Agent Line and its age", arguments: [false, true])
    func noteHasNoAge(hidden: Bool) throws {
        try withTestCoreAtoms { _ in
            let paneId = UUIDv7.generate()
            let host = makeArrangementPanelHostingView(
                panes: [
                    .init(
                        id: paneId, title: "Shell", isMinimized: hidden,
                        agentLine: .init(summary: "Invisible summary", ageText: "[2 min ago]"),
                        paneNote: "Pinned note")
                ], zoomMode: nil)
            let detail = try #require(
                findArrangementPanelView(in: host, identifier: "arrangement-panel-pane-\(paneId.uuidString)-detail"))
            #expect(detail.accessibilityLabel() == "Pinned note")
            #expect(
                findArrangementPanelView(in: host, identifier: "arrangement-panel-pane-\(paneId.uuidString)-age") == nil
            )
            #expect(
                (findArrangementPanelView(in: host, identifier: "arrangement-panel-pane-\(paneId.uuidString)-hidden")
                    != nil) == hidden)
        }
    }

    @Test("missing unlinked cwd is an em dash and missing optional lines stay absent")
    func missingOptionalTokens() throws {
        try withTestCoreAtoms { _ in
            let row = PaneVisibilityInfo(id: UUIDv7.generate(), title: "Shell", isMinimized: false)
            let host = makeArrangementPanelHostingView(panes: [row], zoomMode: nil)
            let cwd = try #require(
                findArrangementPanelView(
                    in: host, identifier: "arrangement-panel-pane-\(row.id.uuidString)-cwd"))
            #expect(cwd.accessibilityLabel() == "—")
            for suffix in ["agent", "age", "detail"] {
                #expect(
                    findArrangementPanelView(
                        in: host, identifier: "arrangement-panel-pane-\(row.id.uuidString)-\(suffix)") == nil)
            }
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
                    onDismiss: {},
                    paneGroups: [
                        .init(
                            id: .other, title: "Other",
                            panes: [
                                .init(
                                    id: paneId, title: "repo | feature/pane-zoom | worktree", isMinimized: false,
                                    supportsZoom: true)
                            ])
                    ]
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
            paneGroups: ArrangementTableProjector.groupedPanes(panes), tableMetrics: tableMetrics
        )
    )
    hostingView.frame = CGRect(origin: .zero, size: hostingView.fittingSize)
    hostingView.layoutSubtreeIfNeeded()
    return hostingView
}

private func arrangementTableFrameRows(longText: Bool) -> [PaneVisibilityInfo] {
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
            repositoryName: "agentstudio", worktreeName: "agentstudio.pane-fixes", branchName: "restore-r3-port",
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
            repositoryName: "agentstudio", worktreeName: "agentstudio.pane-context", branchName: "pane-context",
            agentStatus: needsYou, section: .worktree(secondWorktree), providerName: "Codex"),
        .init(
            id: UUIDv7.generate(), title: "Bridge • Code review", isMinimized: false,
            paneIcon: .octicon(.gitBranch), paneNote: "Review pane changes", repositoryName: "agentstudio",
            worktreeName: "agentstudio.pane-fixes", branchName: "restore-r3-port", section: .worktree(firstWorktree)),
        .init(
            id: UUIDv7.generate(), title: "mise run test", isMinimized: true, supportsZoom: true,
            paneNote: "Test output", repositoryName: "agentstudio", worktreeName: "agentstudio.pane-fixes",
            branchName: "restore-r3-port", section: .worktree(firstWorktree)),
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
