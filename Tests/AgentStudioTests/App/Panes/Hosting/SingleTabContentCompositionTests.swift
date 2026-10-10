import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@MainActor
private final class SingleTabContentTraceClock {
    private var instant = ContinuousClock().now

    func nextInstant() -> ContinuousClock.Instant {
        defer {
            instant = instant.advanced(
                by: AppPolicies.Diagnostics.atomReadTraceAdmissionWindow
            )
        }
        return instant
    }
}

@MainActor
@Suite("SingleTabContent composition", .serialized)
struct SingleTabContentCompositionTests {
    @Test("ordinary body composes its tab graph once")
    func ordinaryBodyComposesTabGraphOnce() async throws {
        let coreAtoms = makeInstalledTestCoreAtoms()

        try await withAsyncTestCoreAtoms(using: coreAtoms) { coreAtoms in
            let store = WorkspaceStore(
                identityAtom: coreAtoms.workspaceIdentity,
                windowMemoryAtom: coreAtoms.workspaceWindowMemory,
                repositoryTopologyAtom: coreAtoms.workspaceRepositoryTopology,
                paneAtom: coreAtoms.workspacePane,
                tabLayoutAtom: coreAtoms.workspaceTabLayout,
                mutationCoordinator: coreAtoms.workspaceMutationCoordinator,
                startsObserving: false
            )
            let pane = store.createPane()
            let tab = Tab(paneId: pane.id)
            store.appendTab(tab)
            store.setActiveTab(tab.id)
            let atomRegistry = AtomRegistry(core: coreAtoms)
            let traceDirectory = FileManager.default.temporaryDirectory.appending(
                path: "single-tab-content-composition-\(UUIDv7.generate().uuidString)"
            )
            defer { try? FileManager.default.removeItem(at: traceDirectory) }
            let traceRuntime = AgentStudioTraceRuntime(
                configuration: AgentStudioTraceConfiguration.from(environment: [
                    "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
                    "AGENTSTUDIO_TRACE_DIR": traceDirectory.path,
                    "AGENTSTUDIO_TRACE_NAME": "single-tab-content-composition",
                    "AGENTSTUDIO_TRACE_TAGS": "atoms",
                ]),
                processIdentifier: 933,
                timeUnixNano: { 933 }
            )
            let content = SingleTabContent(
                tabId: tab.id,
                octiconLoader: makeTestOcticonLoader(),
                store: store,
                repoCache: coreAtoms.repoCache,
                editorChooser: atomRegistry.editorChooser,
                viewRegistry: ViewRegistry(),
                heldPanePreviewState: HeldPanePreviewState(),
                appLifecycleStore: AppLifecycleAtom(),
                closeTransitionCoordinator: PaneCloseTransitionCoordinator(),
                actionDispatcher: makeNoOpPaneActionDispatcher(),
                commandDispatcher: AppTerminalFixtureCommandDispatcher(),
                arrangementInlineRenameState: ArrangementInlineRenameState(),
                onPaneFocusTrigger: { _ in },
                onFocusPane: { _ in },
                onOpenPaneGitHub: { _ in },
                paneSurfaceToolbarPresentation: { _ in .hidden },
                zoomPaneSurfaceToolbarPresentation: { _, _ in .hidden }
            )
            let traceClock = SingleTabContentTraceClock()
            AtomPerformanceTelemetry.shared.configure(
                traceRuntime: traceRuntime,
                now: { traceClock.nextInstant() }
            )
            defer { AtomPerformanceTelemetry.shared.resetForTests() }

            withExtendedLifetime(content.body) {}
            try await AtomPerformanceTelemetry.shared.drainForTests()

            let outputFileURL = try #require(traceRuntime.outputFileURL)
            let traceLines = try String(contentsOf: outputFileURL, encoding: .utf8)
                .split(separator: "\n")
            let workspaceTabGraphReadCount = traceLines.filter { traceLine in
                traceLine.contains("\"body\":\"performance.atom.read\"")
                    && traceLine.contains(
                        "\"agentstudio.performance.atom.label\":\"workspace_tab_graph\""
                    )
                    && traceLine.contains(
                        "\"agentstudio.performance.atom.operation\":\"value\""
                    )
            }.count
            let paneStructuralReadCount = traceLines.filter { traceLine in
                traceLine.contains("\"body\":\"performance.atom.read\"")
                    && traceLine.contains(
                        "\"agentstudio.performance.atom.label\":\"pane_graph_structural\""
                    )
                    && traceLine.contains(
                        "\"agentstudio.performance.atom.operation\":\"value\""
                    )
            }.count

            #expect(
                workspaceTabGraphReadCount == 1,
                "SingleTabContent.body must reuse its already-composed Tab"
            )
            #expect(
                paneStructuralReadCount == 2,
                "SingleTabContent.body must reuse its already-projected active layout"
            )
        }
    }

    @Test("mounted ordinary path consumes the supplied active layout")
    func mountedOrdinaryPathConsumesSuppliedActiveLayout() async throws {
        let coreAtoms = makeInstalledTestCoreAtoms()

        try await withAsyncTestCoreAtoms(using: coreAtoms) { coreAtoms in
            let store = WorkspaceStore(
                identityAtom: coreAtoms.workspaceIdentity,
                windowMemoryAtom: coreAtoms.workspaceWindowMemory,
                repositoryTopologyAtom: coreAtoms.workspaceRepositoryTopology,
                paneAtom: coreAtoms.workspacePane,
                tabLayoutAtom: coreAtoms.workspaceTabLayout,
                mutationCoordinator: coreAtoms.workspaceMutationCoordinator,
                startsObserving: false
            )
            let pane = store.createPane()
            let tab = Tab(paneId: pane.id)
            store.appendTab(tab)
            store.setActiveTab(tab.id)
            let atomRegistry = AtomRegistry(core: coreAtoms)
            let viewRegistry = ViewRegistry()
            viewRegistry.register(PaneHostView(paneId: pane.id), for: pane.id)
            let traceDirectory = FileManager.default.temporaryDirectory.appending(
                path: "mounted-single-tab-content-composition-\(UUIDv7.generate().uuidString)"
            )
            defer { try? FileManager.default.removeItem(at: traceDirectory) }
            let traceRuntime = AgentStudioTraceRuntime(
                configuration: AgentStudioTraceConfiguration.from(environment: [
                    "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
                    "AGENTSTUDIO_TRACE_DIR": traceDirectory.path,
                    "AGENTSTUDIO_TRACE_NAME": "mounted-single-tab-content-composition",
                    "AGENTSTUDIO_TRACE_TAGS": "atoms",
                ]),
                processIdentifier: 934,
                timeUnixNano: { 934 }
            )
            let content = SingleTabContent(
                tabId: tab.id,
                octiconLoader: makeTestOcticonLoader(),
                store: store,
                repoCache: coreAtoms.repoCache,
                editorChooser: atomRegistry.editorChooser,
                viewRegistry: viewRegistry,
                heldPanePreviewState: HeldPanePreviewState(),
                appLifecycleStore: AppLifecycleAtom(),
                closeTransitionCoordinator: PaneCloseTransitionCoordinator(),
                actionDispatcher: makeNoOpPaneActionDispatcher(),
                commandDispatcher: AppTerminalFixtureCommandDispatcher(),
                arrangementInlineRenameState: ArrangementInlineRenameState(),
                onPaneFocusTrigger: { _ in },
                onFocusPane: { _ in },
                onOpenPaneGitHub: { _ in },
                paneSurfaceToolbarPresentation: { _ in .hidden },
                zoomPaneSurfaceToolbarPresentation: { _, _ in .hidden }
            )
            let traceClock = SingleTabContentTraceClock()
            AtomPerformanceTelemetry.shared.configure(
                traceRuntime: traceRuntime,
                now: { traceClock.nextInstant() }
            )
            defer { AtomPerformanceTelemetry.shared.resetForTests() }
            let hostingView = NSHostingView(
                rootView: content.frame(width: 640, height: 360)
            )
            hostingView.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
            let window = NSWindow(contentViewController: NSViewController())
            window.isReleasedWhenClosed = false
            window.contentView = hostingView
            window.setContentSize(hostingView.frame.size)
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }

            hostingView.layoutSubtreeIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            try await AtomPerformanceTelemetry.shared.drainForTests()

            let outputFileURL = try #require(traceRuntime.outputFileURL)
            let traceLines = try String(contentsOf: outputFileURL, encoding: .utf8)
                .split(separator: "\n")
            let paneStructuralReadCount = atomReadCount(
                label: "pane_graph_structural",
                traceLines: traceLines
            )

            #expect(
                paneStructuralReadCount == 2,
                "Mounted FlatTabStripContainer must consume its supplied active layout"
            )
        }
    }

    @Test("held preview keeps its rendered surface until the branch disappears")
    func heldPreviewKeepsRenderedSurfaceUntilBranchDisappears() async throws {
        let coreAtoms = makeInstalledTestCoreAtoms()

        await withAsyncTestCoreAtoms(using: coreAtoms) { coreAtoms in
            let store = WorkspaceStore(
                identityAtom: coreAtoms.workspaceIdentity,
                windowMemoryAtom: coreAtoms.workspaceWindowMemory,
                repositoryTopologyAtom: coreAtoms.workspaceRepositoryTopology,
                paneAtom: coreAtoms.workspacePane,
                tabLayoutAtom: coreAtoms.workspaceTabLayout,
                mutationCoordinator: coreAtoms.workspaceMutationCoordinator,
                startsObserving: false
            )
            let pane = store.createPane()
            let tab = Tab(paneId: pane.id)
            store.appendTab(tab)
            store.setActiveTab(tab.id)

            let viewRegistry = ViewRegistry()
            let paneHost = PaneHostView(paneId: pane.id)
            viewRegistry.register(paneHost, for: pane.id)
            let previewState = HeldPanePreviewState()
            let target = ValidatedPanePreviewTarget(
                paneID: pane.id,
                owningTabID: tab.id,
                provider: pane.provider,
                sessionID: pane.terminalState?.zmxSessionID
            )
            #expect(previewState.beginSpaceHold(requestedTarget: target))
            #expect(previewState.acceptPresentedTarget(target, generation: 1))

            let hostingView = NSHostingView(
                rootView: HeldPanePreviewContainer(
                    tabId: tab.id,
                    paneHost: paneHost,
                    viewRegistry: viewRegistry
                )
                .frame(width: 640, height: 360)
            )
            hostingView.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
            let window = NSWindow(
                contentRect: hostingView.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = hostingView
            window.makeKeyAndOrderFront(nil)
            defer {
                window.orderOut(nil)
                window.close()
            }

            hostingView.layoutSubtreeIfNeeded()
            viewRegistry.retireSlot(for: pane.id)

            #expect(viewRegistry.isRetiredForTesting(pane.id))
            #expect(viewRegistry.peekSlotForTesting(pane.id) != nil)

            viewRegistry.unregisterSurface("held-preview:\(tab.id)")
            #expect(viewRegistry.isRetiredForTesting(pane.id) == false)
            #expect(viewRegistry.peekSlotForTesting(pane.id) == nil)
        }
    }

    private func makeNoOpPaneActionDispatcher() -> PaneTabActionDispatcher {
        PaneTabActionDispatcher(
            dispatch: { _ in },
            shouldHandleSplitDragPayload: { _ in false },
            shouldAcceptDrop: { _, _, _, _ in false },
            handleDrop: { _, _, _, _ in }
        )
    }

    private func atomReadCount(
        label: String,
        traceLines: [Substring]
    ) -> Int {
        traceLines.filter { traceLine in
            traceLine.contains("\"body\":\"performance.atom.read\"")
                && traceLine.contains(
                    "\"agentstudio.performance.atom.label\":\"\(label)\""
                )
                && traceLine.contains(
                    "\"agentstudio.performance.atom.operation\":\"value\""
                )
        }.count
    }
}
