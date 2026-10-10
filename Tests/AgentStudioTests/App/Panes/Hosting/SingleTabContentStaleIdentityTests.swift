import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@MainActor
private final class SingleTabContentStaleIdentityTraceClock {
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
@Suite("SingleTabContent stale identity", .serialized)
struct SingleTabContentStaleIdentityTests {
    @Test("stale held preview provider or session falls back to canonical content")
    func staleHeldPreviewIdentityFallsBackToCanonicalContent() async throws {
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
            let previewState = HeldPanePreviewState()
            let currentProvider = try #require(pane.provider)
            let staleProvider: SessionProvider = currentProvider == .zmx ? .ghostty : .zmx
            let staleTarget = ValidatedPanePreviewTarget(
                paneID: pane.id,
                owningTabID: tab.id,
                provider: staleProvider,
                sessionID: .generateUUIDv7()
            )
            #expect(previewState.beginSpaceHold(requestedTarget: staleTarget))
            #expect(previewState.acceptPresentedTarget(staleTarget, generation: 1))

            let traceDirectory = FileManager.default.temporaryDirectory.appending(
                path: "stale-single-tab-content-composition-\(UUIDv7.generate().uuidString)"
            )
            defer { try? FileManager.default.removeItem(at: traceDirectory) }
            let traceRuntime = AgentStudioTraceRuntime(
                configuration: AgentStudioTraceConfiguration.from(environment: [
                    "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
                    "AGENTSTUDIO_TRACE_DIR": traceDirectory.path,
                    "AGENTSTUDIO_TRACE_NAME": "stale-single-tab-content-composition",
                    "AGENTSTUDIO_TRACE_TAGS": "atoms",
                ]),
                processIdentifier: 935,
                timeUnixNano: { 935 }
            )
            let content = SingleTabContent(
                tabId: tab.id,
                octiconLoader: makeTestOcticonLoader(),
                store: store,
                repoCache: coreAtoms.repoCache,
                editorChooser: atomRegistry.editorChooser,
                viewRegistry: viewRegistry,
                heldPanePreviewState: previewState,
                appLifecycleStore: AppLifecycleAtom(),
                closeTransitionCoordinator: PaneCloseTransitionCoordinator(),
                actionDispatcher: PaneTabActionDispatcher(
                    dispatch: { _ in },
                    shouldHandleSplitDragPayload: { _ in false },
                    shouldAcceptDrop: { _, _, _, _ in false },
                    handleDrop: { _, _, _, _ in }
                ),
                commandDispatcher: AppTerminalFixtureCommandDispatcher(),
                arrangementInlineRenameState: ArrangementInlineRenameState(),
                onPaneFocusTrigger: { _ in },
                onFocusPane: { _ in },
                onOpenPaneGitHub: { _ in },
                paneSurfaceToolbarPresentation: { _ in .hidden },
                zoomPaneSurfaceToolbarPresentation: { _, _ in .hidden }
            )
            let traceClock = SingleTabContentStaleIdentityTraceClock()
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
            let canonicalGraphReadCount = traceLines.filter { traceLine in
                traceLine.contains("\"body\":\"performance.atom.read\"")
                    && traceLine.contains("\"agentstudio.performance.atom.label\":\"workspace_tab_graph\"")
                    && traceLine.contains("\"agentstudio.performance.atom.operation\":\"value\"")
            }.count
            #expect(
                canonicalGraphReadCount > 0,
                "stale provider/session must bypass the preview branch and build canonical content"
            )
        }
    }
}
