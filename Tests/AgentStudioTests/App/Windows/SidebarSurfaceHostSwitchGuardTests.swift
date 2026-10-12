import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioRepoExplorer
@testable import AgentStudioTestSupport

/// Gate lane for `PD-2026-09-04-PANE-SWITCH-MAINACTOR-RESIDUALS`, "Switch guard
/// lane" (plan slice S5; obligations R2 end-to-end and R7). Mounts the real
/// `SidebarSurfaceHost` -> `RepoExplorerView` -> `RepoExplorerPresentationHostView`
/// composition on a `WorkspaceStore` bound to the test core atoms: the parked
/// probe (`tmp/parked-storm-probe.swift.txt`) never engaged the command
/// presentation batch because it built an unbound `WorkspaceStore()`, while
/// `RepoExplorerProjectionInputCapture` reads `CoreAtomScope.store`. This lane
/// ages the composition with 100 sidebar preference updates, then performs one
/// active-pane switch and one tab switch, and asserts both stay within the
/// refresh and materializer-apply bound the design specifies.
@MainActor
@Suite("Sidebar surface host switch guard", .serialized)
struct SidebarSurfaceHostSwitchGuardTests {
    @Test("pane and tab switches stay within the refresh bound after many sidebar updates")
    func paneAndTabSwitchesStayWithinRefreshBoundAfterManySidebarUpdates() async throws {
        try await withAsyncTestCoreAtoms { coreAtoms in
            try await Self.runSwitchGuard(coreAtoms: coreAtoms)
        }
    }

    // MARK: - Orchestration

    private static func runSwitchGuard(coreAtoms: CoreAtoms) async throws {
        let trace = makeSwitchGuardTraceHarness()
        defer { try? FileManager.default.removeItem(at: trace.traceDirectory) }

        let workspace = try makeBoundWorkspace(coreAtoms: coreAtoms)
        let topology = makeTabsAndPanes(in: workspace)

        let mounted = mountSwitchGuardHost(
            store: workspace.store,
            coreAtoms: coreAtoms,
            performanceTraceRecorder: trace.recorder
        )
        defer { mounted.window.close() }

        let engaged = try await waitForEngagement(
            hostingView: mounted.hostingView,
            runtime: trace.runtime,
            recorder: trace.recorder
        )
        guard engaged else {
            printNeverEngagedDiagnostic(runtime: trace.runtime)
            #expect(Bool(false), "batch never engaged: no command_presentation record was produced")
            try await trace.recorder.drain()
            return
        }

        await performSidebarUpdates(prefs: mounted.repoExplorerSidebarPrefs, hostingView: mounted.hostingView)
        try await trace.recorder.flush()
        let refreshesBeforeSwitches = commandPresentationLines(runtime: trace.runtime).count

        // The materializer is not exposed by any test seam on the mounted
        // composition, so it is located the same way production code finds it:
        // it is the data source of the one NSTableView in the view hierarchy.
        let tableView = await waitForTableView(hostingView: mounted.hostingView, maxIterations: 2000)
        let materializer = tableView?.dataSource as? RepoExplorerTableMaterializer
        let applyCountBeforeSwitches = materializer?.nativeTransactionApplyCount

        let paneSwitchMeasurement = try await measureSwitch(
            hostingView: mounted.hostingView,
            runtime: trace.runtime,
            recorder: trace.recorder,
            materializer: materializer
        ) {
            workspace.store.setActivePane(topology.secondPaneId, inTab: topology.firstTabId)
        }
        let tabSwitchMeasurement = try await measureSwitch(
            hostingView: mounted.hostingView,
            runtime: trace.runtime,
            recorder: trace.recorder,
            materializer: materializer
        ) {
            workspace.store.setActiveTab(topology.secondTabId)
        }

        reportAndAssertSwitchGuard(
            refreshesBeforeSwitches: refreshesBeforeSwitches,
            applyCountBeforeSwitches: applyCountBeforeSwitches,
            paneSwitchMeasurement: paneSwitchMeasurement,
            tabSwitchMeasurement: tabSwitchMeasurement,
            allLines: commandPresentationLines(runtime: trace.runtime)
        )

        try await trace.recorder.drain()
    }

    // MARK: - Fixture construction

    private struct BoundWorkspace {
        let store: WorkspaceStore
        let firstRepo: Repo
        let secondRepo: Repo
        let thirdRepo: Repo
        let firstWorktree: Worktree
        let secondWorktree: Worktree
        let thirdWorktree: Worktree
    }

    private static func makeBoundWorkspace(coreAtoms: CoreAtoms) throws -> BoundWorkspace {
        // A store bound to the ambient test core atoms: `RepoExplorerProjectionInputCapture`
        // reads `CoreAtomScope.store`, so the same atom instances must back both.
        let store = WorkspaceStore(
            catalogAtom: coreAtoms.workspaceRepositoryTopology,
            graphAtom: coreAtoms.workspacePane,
            interactionAtom: coreAtoms.workspaceTabLayout
        )
        let firstRepo = store.addRepo(
            at: FileManager.default.temporaryDirectory.appending(
                path: "sidebar-switch-guard-repo-first-\(UUIDv7.generate().uuidString)"
            )
        )
        let secondRepo = store.addRepo(
            at: FileManager.default.temporaryDirectory.appending(
                path: "sidebar-switch-guard-repo-second-\(UUIDv7.generate().uuidString)"
            )
        )
        let thirdRepo = store.addRepo(
            at: FileManager.default.temporaryDirectory.appending(
                path: "sidebar-switch-guard-repo-third-\(UUIDv7.generate().uuidString)"
            )
        )
        return BoundWorkspace(
            store: store,
            firstRepo: firstRepo,
            secondRepo: secondRepo,
            thirdRepo: thirdRepo,
            firstWorktree: try #require(firstRepo.worktrees.first),
            secondWorktree: try #require(secondRepo.worktrees.first),
            thirdWorktree: try #require(thirdRepo.worktrees.first)
        )
    }

    private struct SwitchGuardTopology {
        let firstPaneId: UUID
        let secondPaneId: UUID
        let thirdPaneId: UUID
        let firstTabId: UUID
        let secondTabId: UUID
    }

    private static func makeTabsAndPanes(in workspace: BoundWorkspace) -> SwitchGuardTopology {
        let store = workspace.store
        let firstPane = store.createPane(
            launchDirectory: workspace.firstWorktree.path,
            facets: PaneContextFacets(
                repoId: workspace.firstRepo.id,
                worktreeId: workspace.firstWorktree.id,
                cwd: workspace.firstWorktree.path
            )
        )
        let secondPane = store.createPane(
            launchDirectory: workspace.secondWorktree.path,
            facets: PaneContextFacets(
                repoId: workspace.secondRepo.id,
                worktreeId: workspace.secondWorktree.id,
                cwd: workspace.secondWorktree.path
            )
        )
        let thirdPane = store.createPane(
            launchDirectory: workspace.thirdWorktree.path,
            facets: PaneContextFacets(
                repoId: workspace.thirdRepo.id,
                worktreeId: workspace.thirdWorktree.id,
                cwd: workspace.thirdWorktree.path
            )
        )

        let firstTab = makeTab(
            paneIds: [firstPane.id, secondPane.id],
            activePaneId: firstPane.id,
            name: "Tab 1"
        )
        let secondTab = makeTab(paneIds: [thirdPane.id], name: "Tab 2")
        store.appendTab(firstTab)
        store.appendTab(secondTab)
        store.setActiveTab(firstTab.id)
        store.setActivePane(firstPane.id, inTab: firstTab.id)

        return SwitchGuardTopology(
            firstPaneId: firstPane.id,
            secondPaneId: secondPane.id,
            thirdPaneId: thirdPane.id,
            firstTabId: firstTab.id,
            secondTabId: secondTab.id
        )
    }

    private struct MountedSwitchGuardHost {
        let hostingView: NSHostingView<AnyView>
        let window: NSWindow
        let repoExplorerSidebarPrefs: RepoExplorerSidebarPrefsAtom
    }

    private static func mountSwitchGuardHost(
        store: WorkspaceStore,
        coreAtoms: CoreAtoms,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder
    ) -> MountedSwitchGuardHost {
        let repoExplorerSidebarPrefs = RepoExplorerSidebarPrefsAtom()
        let applicationLifecycleMonitor = ApplicationLifecycleMonitor(
            appLifecycleStore: AppLifecycleAtom(),
            windowLifecycleStore: coreAtoms.windowLifecycle
        )
        let dispatcher = CommandDispatcherFixtureConfiguration().makeDispatcher()
        let host = SidebarSurfaceHost(
            commandDispatcher: dispatcher,
            resolveCommandCapabilities: {
                dispatcher.repoExplorerCommandPresentationSnapshot(requests: $0, generation: $1)
            },
            executionOwnerIdentities: dispatcher.executionOwnerIdentities,
            store: store,
            octiconLoader: makeTestOcticonLoader(),
            paneActivityStatusAtom: coreAtoms.paneActivityStatus,
            applicationLifecycleMonitor: applicationLifecycleMonitor,
            sidebarTimeInvalidationConsumerID: UUIDv7.generate(),
            sidebarState: coreAtoms.workspaceSidebarState,
            repoExplorerSidebarPrefs: repoExplorerSidebarPrefs,
            bridgeAttendanceSnapshot: { _ in nil },
            performanceTraceRecorder: performanceTraceRecorder,
            onRefocusActivePane: {},
            onSidebarVisibleWorktreesChanged: {},
            onPerformanceProofReadback: { _ in },
            onRepositoryFactUpdateProgressPresented: { _, _ in }
        )
        let hostingView = NSHostingView(rootView: AnyView(host.frame(width: 320, height: 600)))
        let window = makeSwitchGuardWindow(hostingView)
        return MountedSwitchGuardHost(
            hostingView: hostingView,
            window: window,
            repoExplorerSidebarPrefs: repoExplorerSidebarPrefs
        )
    }

    private struct SwitchGuardTraceHarness {
        let traceDirectory: URL
        let runtime: AgentStudioTraceRuntime
        let recorder: AgentStudioPerformanceTraceRecorder
    }

    private static func makeSwitchGuardTraceHarness() -> SwitchGuardTraceHarness {
        let traceDirectory = FileManager.default.temporaryDirectory.appending(
            path: "sidebar-switch-guard-\(UUIDv7.generate().uuidString)"
        )
        let runtime = AgentStudioTraceRuntime(
            configuration: AgentStudioTraceConfiguration.from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
                "AGENTSTUDIO_TRACE_DIR": traceDirectory.path,
                "AGENTSTUDIO_TRACE_NAME": "sidebar-switch-guard",
                "AGENTSTUDIO_TRACE_TAGS": "performance",
            ]),
            processIdentifier: 935,
            timeUnixNano: { 935 }
        )
        return SwitchGuardTraceHarness(
            traceDirectory: traceDirectory,
            runtime: runtime,
            recorder: AgentStudioPerformanceTraceRecorder(traceRuntime: runtime)
        )
    }

    // MARK: - Engagement and aging

    /// Pumps the run loop until the composition has reached the batch and at
    /// least one command_presentation record has been flushed to disk. A lane
    /// that never engages must fail loudly rather than pass trivially (see
    /// plan risk: "S5 must verify engagement first").
    private static func waitForEngagement(
        hostingView: NSView,
        runtime: AgentStudioTraceRuntime,
        recorder: AgentStudioPerformanceTraceRecorder
    ) async throws -> Bool {
        for iteration in 0..<20_000 {
            if iteration.isMultiple(of: 100) {
                hostingView.layoutSubtreeIfNeeded()
            }
            if iteration.isMultiple(of: 500) {
                try await recorder.flush()
                if !commandPresentationLines(runtime: runtime).isEmpty {
                    return true
                }
            }
            await Task.yield()
        }
        return false
    }

    private static func printNeverEngagedDiagnostic(runtime: AgentStudioTraceRuntime) {
        let observedBodies: Set<String> = {
            guard let outputFileURL = runtime.outputFileURL,
                let contents = try? String(contentsOf: outputFileURL, encoding: .utf8)
            else { return [] }
            var bodies: Set<String> = []
            for line in contents.split(separator: "\n") {
                guard let range = line.range(of: "\"body\":\"") else { continue }
                let remainder = line[range.upperBound...]
                guard let endQuote = remainder.firstIndex(of: "\"") else { continue }
                bodies.insert(String(remainder[remainder.startIndex..<endQuote]))
            }
            return bodies
        }()
        print("SWITCH_GUARD never_engaged bodies=\(observedBodies.sorted())")
    }

    /// 100 sidebar preference updates, each re-projecting the sidebar, to prove
    /// the refresh bound is age-invariant rather than only true on a freshly
    /// mounted composition.
    private static func performSidebarUpdates(
        prefs: RepoExplorerSidebarPrefsAtom,
        hostingView: NSView
    ) async {
        for update in 0..<100 {
            prefs.setSortDirection(
                update.isMultiple(of: 2) ? .descending : .ascending,
                for: .repos
            )
            for iteration in 0..<50 {
                if iteration.isMultiple(of: 10) { hostingView.layoutSubtreeIfNeeded() }
                await Task.yield()
            }
        }
    }

    // MARK: - Switch measurement

    private struct SwitchMeasurement {
        let refreshCount: Int
        let applyCount: Int?
    }

    private static func measureSwitch(
        hostingView: NSView,
        runtime: AgentStudioTraceRuntime,
        recorder: AgentStudioPerformanceTraceRecorder,
        materializer: RepoExplorerTableMaterializer?,
        action: () -> Void
    ) async throws -> SwitchMeasurement {
        action()
        for iteration in 0..<2000 {
            if iteration.isMultiple(of: 100) { hostingView.layoutSubtreeIfNeeded() }
            await Task.yield()
        }
        try await recorder.flush()
        return SwitchMeasurement(
            refreshCount: commandPresentationLines(runtime: runtime).count,
            applyCount: materializer?.nativeTransactionApplyCount
        )
    }

    // MARK: - Reporting and assertions

    private static func reportAndAssertSwitchGuard(
        refreshesBeforeSwitches: Int,
        applyCountBeforeSwitches: Int?,
        paneSwitchMeasurement: SwitchMeasurement,
        tabSwitchMeasurement: SwitchMeasurement,
        allLines: [Substring]
    ) {
        let paneSwitchRefreshes = paneSwitchMeasurement.refreshCount - refreshesBeforeSwitches
        let tabSwitchRefreshes = tabSwitchMeasurement.refreshCount - paneSwitchMeasurement.refreshCount

        let paneSwitchAppliesDescription: String
        let tabSwitchAppliesDescription: String
        if let applyCountBeforeSwitches,
            let applyCountAfterPaneSwitch = paneSwitchMeasurement.applyCount,
            let applyCountAfterTabSwitch = tabSwitchMeasurement.applyCount
        {
            paneSwitchAppliesDescription = "\(applyCountAfterPaneSwitch - applyCountBeforeSwitches)"
            tabSwitchAppliesDescription = "\(applyCountAfterTabSwitch - applyCountAfterPaneSwitch)"
        } else {
            // Honest fallback: the materializer was not reachable through the
            // mounted view hierarchy, so applies are unobservable in this
            // harness. Do not fabricate a count; report refreshes only.
            paneSwitchAppliesDescription = "unobservable"
            tabSwitchAppliesDescription = "unobservable"
        }

        let visibleSnapshotTriggerCount = countTrigger("visible_snapshot", in: allLines)
        let observationTriggerCount = countTrigger("observation", in: allLines)

        print(
            "SWITCH_GUARD refreshesBefore=\(refreshesBeforeSwitches)"
                + " paneSwitchRefreshes=\(paneSwitchRefreshes) tabSwitchRefreshes=\(tabSwitchRefreshes)"
                + " paneSwitchApplies=\(paneSwitchAppliesDescription) tabSwitchApplies=\(tabSwitchAppliesDescription)"
                + " observationTriggers=\(observationTriggerCount)"
                + " visibleSnapshotTriggers=\(visibleSnapshotTriggerCount)"
        )

        #expect(paneSwitchRefreshes <= 2)
        #expect(tabSwitchRefreshes <= 2)
        if let applyCountBeforeSwitches,
            let applyCountAfterPaneSwitch = paneSwitchMeasurement.applyCount,
            let applyCountAfterTabSwitch = tabSwitchMeasurement.applyCount
        {
            #expect(applyCountAfterPaneSwitch - applyCountBeforeSwitches <= 1)
            #expect(applyCountAfterTabSwitch - applyCountAfterPaneSwitch <= 1)
        }
    }

    // MARK: - Trace line helpers

    private static func commandPresentationLines(runtime: AgentStudioTraceRuntime) -> [Substring] {
        guard let outputFileURL = runtime.outputFileURL,
            let contents = try? String(contentsOf: outputFileURL, encoding: .utf8)
        else { return [] }
        return contents.split(separator: "\n").filter { line in
            line.contains("\"body\":\"performance.repo_explorer.command_presentation\"")
        }
    }

    private static func countTrigger(_ trigger: String, in lines: [Substring]) -> Int {
        lines.count { line in
            line.contains("\"agentstudio.performance.repo_explorer.wake_trigger\":\"\(trigger)\"")
        }
    }
}

@MainActor
private func makeSwitchGuardWindow(_ hostingView: NSView) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 600),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    window.layoutIfNeeded()
    hostingView.layoutSubtreeIfNeeded()
    return window
}

@MainActor
private func firstDescendantTableView(in view: NSView) -> NSTableView? {
    if let tableView = view as? NSTableView { return tableView }
    for subview in view.subviews {
        if let found = firstDescendantTableView(in: subview) { return found }
    }
    return nil
}

@MainActor
private func waitForTableView(hostingView: NSView, maxIterations: Int) async -> NSTableView? {
    for iteration in 0..<maxIterations {
        if iteration.isMultiple(of: 100) {
            hostingView.layoutSubtreeIfNeeded()
            if let tableView = firstDescendantTableView(in: hostingView) {
                return tableView
            }
        }
        await Task.yield()
    }
    return firstDescendantTableView(in: hostingView)
}
