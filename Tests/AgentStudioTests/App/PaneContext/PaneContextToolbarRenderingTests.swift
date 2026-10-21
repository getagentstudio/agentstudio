import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioRepoExplorer

@MainActor
@Suite(.serialized)
struct PaneContextToolbarRenderingTests {
    @Test("Agent Line uses the sidebar's keyed source and leaves both button groups fixed", arguments: [480.0, 900.0])
    func agentLineOnlyUsesRemainingWidth(width: Double) async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let pane = PaneId.generateUUIDv7()
            let statuses = SessionStatusAtom()
            statuses.apply([pane: .set(.init(status: .working(.active), connectionIssue: .credentialNotRecognized))])
            let readers = PaneContextUIReaders(
                sessionStatus: statuses, presentation: atoms.paneContextPresentation, pane: { _ in nil })
            var baseline: [String: CGRect]?
            var baselineHeight: CGFloat?
            var emptyTextPixels: Data?
            var fixedGroupPixels: [Data]?
            for summary in [
                nil, "Checking toolbar spacing", String(repeating: "Wide agent work description ", count: 20),
            ] {
                let line = summary.map {
                    AgentLineDetail(
                        summary: $0, work: .done, detail: nil, refs: [], writer: .pane(pane),
                        updatedAt: .distantPast, lifetime: .untilReplaced, stale: false)
                }
                atoms.paneContextPresentation.apply([
                    pane: .set(
                        .init(
                            revision: .init(1), agentTitle: nil, agentLine: line, own: .zero,
                            includingDrawers: .zero, pullRequests: .notApplicable))
                ])
                let mounted = mount(pane: pane, readers: readers, width: width)
                defer { mounted.window.orderOut(nil) }
                let controls = buttonFrames(in: mounted.host)
                let barHeight = mounted.host.bounds.height
                #expect(barHeight == DrawerLayout.iconStripHeight)
                #expect(mounted.host.fittingSize.height == barHeight)
                if let baselineHeight { #expect(barHeight == baselineHeight) } else { baselineHeight = barHeight }
                #expect(controls.count == 9)
                #expect(controls.values.allSatisfy { $0.width > 0 && $0.height > 0 })
                if let baseline { #expect(controls == baseline) } else { baseline = controls }
                let leadingIdentifiers: Set<String> = [
                    "paneSurfaceToolbar.drawerToggle", "paneSurfaceToolbar.drawerAdd",
                    "paneSurfaceToolbar.pinPane", "paneSurfaceToolbar.note",
                ]
                let middleStart = try #require(
                    controls.filter { leadingIdentifiers.contains($0.key) }.values.map(\.maxX).max())
                let middleEnd = try #require(
                    controls.filter { !leadingIdentifiers.contains($0.key) }.values.map(\.minX).min())
                let textStart =
                    middleStart + AppStyles.Shell.DrawerToolbar.trailingClusterSpacing
                    + AppStyles.Shell.Sidebar.rowLeadingIconColumnWidth
                    + AppStyles.Shell.Sidebar.groupIconTitleSpacing
                let textRect = CGRect(x: textStart, y: 0, width: middleEnd - textStart, height: barHeight)
                #expect(textRect.width > 0)
                let textPixels = try pixels(in: mounted.host, rect: textRect)
                let groupPixels = try [
                    pixels(in: mounted.host, rect: CGRect(x: 0, y: 0, width: middleStart, height: barHeight)),
                    pixels(
                        in: mounted.host,
                        rect: CGRect(x: middleEnd, y: 0, width: width - middleEnd, height: barHeight)),
                ]
                if summary != nil {
                    #expect(textPixels != (try #require(emptyTextPixels)), "Agent Line text must paint in the middle")
                    #expect(groupPixels == (try #require(fixedGroupPixels)), "Agent Line must not paint over controls")
                } else {
                    emptyTextPixels = textPixels
                    fixedGroupPixels = groupPixels
                }
                let labels = accessibilityLabels(in: mounted.host)
                #expect(!labels.contains("Working"))
                #expect(!labels.contains(where: { $0.contains("Messages unavailable") || $0.contains("credential") }))
                if let summary {
                    #expect(labels.contains(summary))
                } else {
                    #expect(!labels.contains("Checking toolbar spacing"))
                }
                #expect(abs(mounted.host.bounds.width - CGFloat(width)) < 0.5)
                #expect(mounted.host.fittingSize.width <= width)
            }
            atoms.paneContextPresentation.remove([pane])
        }
    }

    @Test("the toolbar Agent Line is absent without a display, even with Working and a credential refusal")
    func missingDisplayKeepsMiddleEmpty() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let pane = PaneId.generateUUIDv7()
            let statuses = SessionStatusAtom()
            statuses.apply([pane: .set(.init(status: .working(.active), connectionIssue: .credentialNotRecognized))])
            let readers = PaneContextUIReaders(
                sessionStatus: statuses, presentation: atoms.paneContextPresentation, pane: { _ in nil })
            let mounted = mount(pane: pane, readers: readers, width: 480)
            defer { mounted.window.orderOut(nil) }
            let warningPixels = try pixels(in: mounted.host)
            statuses.apply([pane: .remove])
            let baseline = mount(pane: pane, readers: readers, width: 480)
            defer { baseline.window.orderOut(nil) }
            #expect(warningPixels == (try pixels(in: baseline.host)))
            let labels = accessibilityLabels(in: mounted.host)
            #expect(!labels.contains("Working"))
            #expect(!labels.contains(where: { $0.contains("Messages unavailable") || $0.contains("credential") }))
            #expect(buttonFrames(in: mounted.host).count == 9)
        }
    }

    @Test("the card keeps sidebar lines, known identities and omits unknown Git placeholders")
    func cardMatchesSidebarInformation() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)
            let pane = store.createPane(title: "Proof terminal")
            let paneId = PaneId(existingUUID: pane.id)
            let statuses = SessionStatusAtom()
            statuses.apply([paneId: .set(.init(status: .working(.active), connectionIssue: .credentialNotRecognized))])
            let readers = PaneContextUIReaders(
                sessionStatus: statuses, presentation: atoms.paneContextPresentation,
                pane: { store.paneAtom.pane($0.uuid) })
            let session = SessionSummary(
                id: UUIDv7.generate(), provider: try .init("codex"), sessionRef: try .init("known-conversation"),
                bindingGeneration: UUIDv7.generate(), status: .working(.active), providerPrompts: [])
            let projected = PaneManagementContext.project(paneId: pane.id, store: store)
                .includingVerifiedLiveSession(session)
            let context = PaneManagementContext(
                paneId: pane.id, identityRows: projected.identityRows,
                statusChips: .init(branchStatus: .unknown), targetPath: nil, showsIdentityBlock: true)
            let input = PaneManagementIdentityCapture.input(context: context, store: store, readers: readers)
            let lines = await PaneManagementIdentityCapture.lines(input)
            #expect(
                lines.contains(.sessionStatus(try #require(RepoExplorerPaneContextLine.session(.working(.active))))))
            #expect(lines.contains(.connectionIssue(.connection(.credentialNotRecognized))))
            #expect(!SidebarGitStatusChips.hasContent(branchStatus: .unknown, usesPanesLoadingChip: true))
            for width in [420.0, 1000.0] {
                let host = NSHostingView(
                    rootView:
                        ManagementPaneIdentityStrip(
                            context: context, octiconLoader: makeTestOcticonLoader(), lines: lines
                        )
                        .frame(width: width))
                host.frame = CGRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
                let window = NSWindow(
                    contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderFront(nil)
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
                defer { window.orderOut(nil) }
                let labels = accessibilityLabels(in: host)
                #expect(labels.contains(where: { $0.contains("Working") }))
                #expect(
                    labels.contains(where: { $0.contains("Messages unavailable · restart this shell to reconnect") }))
                #expect(labels.contains(where: { $0.contains("Pane \(pane.id.uuidString)") }))
                #expect(labels.contains(where: { $0.contains("Session codex · known-conversation") }))
                #expect(!labels.contains(where: { $0.contains("credentialNotRecognized") || $0.contains("?") }))
                #expect(host.fittingSize.width <= width)
            }
        }
    }

    private func mount(pane: PaneId, readers: PaneContextUIReaders, width: CGFloat) -> MountedToolbar {
        let loader = makeTestOcticonLoader()
        let trailing = DrawerOverlay.TrailingActions(
            editPaneNoteAction: action(.editPaneNote), openEditorMenuAction: action(.openPaneLocationInEditorMenu),
            openFinderAction: action(.openPaneLocationInFinder), copyPathAction: action(.copyCurrentPanePath),
            gitStatusPresentation: .resolve(
                branchStatus: .init(
                    isDirty: true, syncState: .unknown, prCount: 1, linesAdded: 0, linesDeleted: 0,
                    untrackedFileCount: 1)),
            openPullRequestAction: surfaceAction(.openPullRequest),
            editorMenuContent: AnyView(EmptyView()), editorMenuPresented: .constant(false), buttonTitle: nil
        ).withPaneContextContent(
            AnyView(
                PaneContextToolbarControls(paneId: pane, readers: readers, octiconLoader: loader, onGoToPane: { _ in }))
        )
        let host = NSHostingView(
            rootView: AnyView(
                DrawerIconBar(
                    octiconLoader: loader,
                    leadingControls: .drawer(
                        isExpanded: false, addDrawerPaneAction: action(.addDrawerPane),
                        toggleDrawerAction: action(.toggleDrawer)),
                    pinPaneAction: action(.pinPane), trailingActions: trailing,
                    paneContextActions: [surfaceAction(.zoomPane)],
                    middleContent: AnyView(
                        PaneContextToolbarAgentLine(paneId: pane, readers: readers, octiconLoader: loader))
                ).frame(width: width)))
        host.frame = CGRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return MountedToolbar(host: host, window: window)
    }

    private func action(_ command: AppCommand) -> TargetedCommandControlAction {
        .init(commandSpec: command.definition, isEnabled: true, perform: {})
    }

    private func surfaceAction(_ command: AppCommand) -> PaneSurfaceToolbarAction {
        let spec = command.definition
        return .init(
            state: .init(
                label: spec.label, accessibilityIdentifier: "proof.\(command.rawValue)", icon: spec.icon,
                tooltip: spec.controlTooltipRenderValue(), isEnabled: true, isSelected: false), perform: {})
    }

    private func pixels(in host: NSView, rect: CGRect? = nil) throws -> Data {
        let region = rect ?? host.bounds
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: region))
        host.cacheDisplay(in: region, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func buttonFrames(in host: NSView) -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        func visit(_ view: NSView) {
            if let button = view as? AccessibilityPressBridgeView {
                frames[button.accessibilityIdentifier()] = host.convert(button.bounds, from: button)
            }
            view.subviews.forEach(visit)
        }
        visit(host)
        return frames
    }

    private func accessibilityLabels(in view: NSView) -> Set<String> {
        var labels = Set<String>()
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            let labelSelector = NSSelectorFromString("accessibilityLabel")
            if object.responds(to: labelSelector),
                let label = object.perform(labelSelector)?.takeUnretainedValue() as? String
            {
                labels.insert(label)
            }
            let childrenSelector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: childrenSelector),
                let children = object.perform(childrenSelector)?.takeUnretainedValue() as? [NSObject]
            {
                children.forEach(visit)
            }
            if let nativeView = object as? NSView { nativeView.subviews.forEach(visit) }
        }
        visit(view)
        return labels
    }
}

@MainActor
private struct MountedToolbar {
    let host: NSHostingView<AnyView>
    let window: NSWindow
}
