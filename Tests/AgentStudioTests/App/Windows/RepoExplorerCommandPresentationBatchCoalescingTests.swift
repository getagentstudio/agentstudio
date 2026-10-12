import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioRepoExplorer
@testable import AgentStudioTestSupport

/// Proof seam for the batch's bounded global fingerprint (active tab, its active pane, its zoom
/// presentation, management layer) and per-turn Observation-wake coalescing. Split from
/// `RepoExplorerCommandPresentationBatchTests` to keep both files under the file-length ceiling.
extension RepoExplorerCommandPresentationBatchTests {
    @Test("pane write outside the active selection produces no observation refresh")
    func paneWriteOutsideActiveSelectionProducesNoObservationRefresh() async throws {
        let handler = RepoExplorerCoalescingRecordingHandler()

        try await withCommandDispatcherFixture(
            configure: { configuration in
                configuration.workspaceOwner = handler
                configuration.shellOwner = nil
            },
            body: { dispatcher in
                try await withAsyncTestCoreAtoms { _ in
                    let fixture = try makeCoalescingFixture()
                    let trace = makeCoalescingTraceRecorder(
                        name: "repo-command-coalescing-outside-selection",
                        processIdentifier: 941
                    )
                    defer { try? FileManager.default.removeItem(at: trace.directory) }
                    let batch = RepoExplorerCommandPresentationBatch(
                        store: fixture.store,
                        repoExplorerPrefs: RepoExplorerSidebarPrefsAtom(),
                        resolveCommandCapabilities: {
                            dispatcher.repoExplorerCommandPresentationSnapshot(requests: $0, generation: $1)
                        },
                        executionOwnerIdentities: dispatcher.executionOwnerIdentities,
                        performanceTraceRecorder: trace.recorder
                    )
                    batch.start()
                    defer { batch.stop() }
                    batch.acceptVisibleWorktreeSnapshot(
                        makeCoalescingVisibleWorktreeSnapshot(
                            worktreeIDs: [fixture.worktree.id],
                            repositoryIDs: [fixture.repo.id]
                        )
                    )
                    _ = await handler.batchArrivals.wait { _ in true }
                    try await trace.recorder.flush()
                    let outputFileURL = try #require(trace.runtime.outputFileURL)
                    let observationBefore = try coalescingRefreshCount(at: outputFileURL, trigger: "observation")

                    // A pane write in the inactive tab, and a drawer toggle on the active tab's
                    // non-active pane, are both outside the bounded global fingerprint.
                    fixture.store.setActivePane(fixture.paneB1.id, inTab: fixture.tabB.id)
                    fixture.store.toggleDrawer(for: fixture.paneA2.id)

                    for _ in 0..<500 { await Task.yield() }
                    try await trace.recorder.drain()
                    let observationAfter = try coalescingRefreshCount(at: outputFileURL, trigger: "observation")

                    #expect(observationAfter - observationBefore == 0)
                }
            }
        )
    }

    @Test("active pane change in the active tab produces one observation refresh")
    func activePaneChangeInActiveTabProducesOneObservationRefresh() async throws {
        let handler = RepoExplorerCoalescingRecordingHandler()

        try await withCommandDispatcherFixture(
            configure: { configuration in
                configuration.workspaceOwner = handler
                configuration.shellOwner = nil
            },
            body: { dispatcher in
                try await withAsyncTestCoreAtoms { _ in
                    let fixture = try makeCoalescingFixture()
                    let trace = makeCoalescingTraceRecorder(
                        name: "repo-command-coalescing-active-pane",
                        processIdentifier: 942
                    )
                    defer { try? FileManager.default.removeItem(at: trace.directory) }
                    let batch = RepoExplorerCommandPresentationBatch(
                        store: fixture.store,
                        repoExplorerPrefs: RepoExplorerSidebarPrefsAtom(),
                        resolveCommandCapabilities: {
                            dispatcher.repoExplorerCommandPresentationSnapshot(requests: $0, generation: $1)
                        },
                        executionOwnerIdentities: dispatcher.executionOwnerIdentities,
                        performanceTraceRecorder: trace.recorder
                    )
                    batch.start()
                    defer { batch.stop() }
                    batch.acceptVisibleWorktreeSnapshot(
                        makeCoalescingVisibleWorktreeSnapshot(
                            worktreeIDs: [fixture.worktree.id],
                            repositoryIDs: [fixture.repo.id]
                        )
                    )
                    _ = await handler.batchArrivals.wait { _ in true }
                    try await trace.recorder.flush()
                    let outputFileURL = try #require(trace.runtime.outputFileURL)
                    let observationBefore = try coalescingRefreshCount(at: outputFileURL, trigger: "observation")

                    fixture.store.setActivePane(fixture.paneA2.id, inTab: fixture.tabA.id)

                    _ = await handler.batchArrivals.wait { _ in true }
                    for _ in 0..<500 { await Task.yield() }
                    try await trace.recorder.drain()
                    let observationAfter = try coalescingRefreshCount(at: outputFileURL, trigger: "observation")

                    #expect(observationAfter - observationBefore == 1)
                }
            }
        )
    }

    @Test("a visible snapshot refresh during the coalescing yield supersedes the pending observation refresh")
    func visibleSnapshotRefreshDuringCoalescingYieldSupersedesPendingObservationRefresh() async throws {
        let handler = RepoExplorerCoalescingRecordingHandler()

        try await withCommandDispatcherFixture(
            configure: { configuration in
                configuration.workspaceOwner = handler
                configuration.shellOwner = nil
            },
            body: { dispatcher in
                try await withAsyncTestCoreAtoms { _ in
                    let fixture = try makeCoalescingFixture()
                    let trace = makeCoalescingTraceRecorder(
                        name: "repo-command-coalescing-superseded-wake",
                        processIdentifier: 943
                    )
                    defer { try? FileManager.default.removeItem(at: trace.directory) }
                    let yieldGate = RepoExplorerCoalescingYieldGate()
                    let resumedYield = ExactEventAcknowledgement<Bool>()
                    defer { yieldGate.release() }
                    let batch = RepoExplorerCommandPresentationBatch(
                        store: fixture.store,
                        repoExplorerPrefs: RepoExplorerSidebarPrefsAtom(),
                        resolveCommandCapabilities: {
                            dispatcher.repoExplorerCommandPresentationSnapshot(requests: $0, generation: $1)
                        },
                        executionOwnerIdentities: dispatcher.executionOwnerIdentities,
                        performanceTraceRecorder: trace.recorder,
                        coalescingYield: {
                            await yieldGate.wait()
                            resumedYield.record(true)
                        }
                    )
                    batch.start()
                    defer { batch.stop() }
                    batch.acceptVisibleWorktreeSnapshot(
                        makeCoalescingVisibleWorktreeSnapshot(
                            worktreeIDs: [fixture.worktree.id],
                            repositoryIDs: [fixture.repo.id]
                        )
                    )
                    _ = await handler.batchArrivals.wait { _ in true }
                    try await trace.recorder.flush()
                    let outputFileURL = try #require(trace.runtime.outputFileURL)
                    let observationBefore = try coalescingRefreshCount(at: outputFileURL, trigger: "observation")
                    let visibleSnapshotBefore = try coalescingRefreshCount(
                        at: outputFileURL, trigger: "visible_snapshot")

                    // Hold the old observation wake at its coalescing boundary while the
                    // visible snapshot synchronously supersedes its tracking generation.
                    fixture.store.setActivePane(fixture.paneA2.id, inTab: fixture.tabA.id)
                    await eventually("coalescer reached its suspension boundary") { yieldGate.isSuspended }
                    batch.acceptVisibleWorktreeSnapshot(
                        makeCoalescingVisibleWorktreeSnapshot(
                            worktreeIDs: [fixture.worktree.id],
                            repositoryIDs: [fixture.repo.id],
                            visibleRevision: 2
                        )
                    )
                    _ = await handler.batchArrivals.wait { _ in true }
                    yieldGate.release()
                    _ = await resumedYield.wait { $0 }
                    try await trace.recorder.drain()
                    let observationAfter = try coalescingRefreshCount(at: outputFileURL, trigger: "observation")
                    let visibleSnapshotAfter = try coalescingRefreshCount(
                        at: outputFileURL, trigger: "visible_snapshot")

                    #expect(visibleSnapshotAfter - visibleSnapshotBefore == 1)
                    #expect(observationAfter - observationBefore == 0)
                }
            }
        )
    }

    @Test("a tracked write after a visible snapshot refresh during the yield still produces one observation refresh")
    func trackedWriteAfterVisibleSnapshotRefreshDuringYieldStillProducesOneObservationRefresh() async throws {
        let handler = RepoExplorerCoalescingRecordingHandler()

        try await withCommandDispatcherFixture(
            configure: { configuration in
                configuration.workspaceOwner = handler
                configuration.shellOwner = nil
            },
            body: { dispatcher in
                try await withAsyncTestCoreAtoms { _ in
                    let fixture = try makeCoalescingFixture()
                    let trace = makeCoalescingTraceRecorder(
                        name: "repo-command-coalescing-superseded-wake-then-write",
                        processIdentifier: 944
                    )
                    defer { try? FileManager.default.removeItem(at: trace.directory) }
                    let yieldGate = RepoExplorerCoalescingYieldGate()
                    defer { yieldGate.release() }
                    let batch = RepoExplorerCommandPresentationBatch(
                        store: fixture.store,
                        repoExplorerPrefs: RepoExplorerSidebarPrefsAtom(),
                        resolveCommandCapabilities: {
                            dispatcher.repoExplorerCommandPresentationSnapshot(requests: $0, generation: $1)
                        },
                        executionOwnerIdentities: dispatcher.executionOwnerIdentities,
                        performanceTraceRecorder: trace.recorder,
                        coalescingYield: { await yieldGate.wait() }
                    )
                    batch.start()
                    defer { batch.stop() }
                    batch.acceptVisibleWorktreeSnapshot(
                        makeCoalescingVisibleWorktreeSnapshot(
                            worktreeIDs: [fixture.worktree.id],
                            repositoryIDs: [fixture.repo.id]
                        )
                    )
                    _ = await handler.batchArrivals.wait { _ in true }
                    try await trace.recorder.flush()
                    let outputFileURL = try #require(trace.runtime.outputFileURL)
                    let observationBefore = try coalescingRefreshCount(at: outputFileURL, trigger: "observation")
                    let visibleSnapshotBefore = try coalescingRefreshCount(
                        at: outputFileURL, trigger: "visible_snapshot")

                    // Same race as the superseded-wake test, but a second tracked write lands
                    // after the superseding visible-snapshot refresh: the coalescing task must
                    // still see this newer wake and refresh once (no lost update).
                    fixture.store.setActivePane(fixture.paneA2.id, inTab: fixture.tabA.id)
                    await eventually("coalescer reached its suspension boundary") { yieldGate.isSuspended }
                    batch.acceptVisibleWorktreeSnapshot(
                        makeCoalescingVisibleWorktreeSnapshot(
                            worktreeIDs: [fixture.worktree.id],
                            repositoryIDs: [fixture.repo.id],
                            visibleRevision: 2
                        )
                    )
                    _ = await handler.batchArrivals.wait { _ in true }
                    fixture.store.setActivePane(fixture.paneA1.id, inTab: fixture.tabA.id)
                    yieldGate.release()
                    _ = await handler.batchArrivals.wait { _ in true }
                    try await trace.recorder.drain()
                    let observationAfter = try coalescingRefreshCount(at: outputFileURL, trigger: "observation")
                    let visibleSnapshotAfter = try coalescingRefreshCount(
                        at: outputFileURL, trigger: "visible_snapshot")

                    #expect(observationAfter - observationBefore == 1)
                    #expect(visibleSnapshotAfter - visibleSnapshotBefore == 1)
                }
            }
        )
    }

    @Test("a burst of tracked writes in one turn produces one refresh")
    func burstOfTrackedWritesInOneTurnProducesOneRefresh() async throws {
        let handler = RepoExplorerCoalescingRecordingHandler()

        try await withCommandDispatcherFixture(
            configure: { configuration in
                configuration.workspaceOwner = handler
                configuration.shellOwner = nil
            },
            body: { dispatcher in
                try await withAsyncTestCoreAtoms { coreAtoms in
                    let fixture = try makeCoalescingFixture()
                    let trace = makeCoalescingTraceRecorder(
                        name: "repo-command-coalescing-burst",
                        processIdentifier: 943
                    )
                    defer { try? FileManager.default.removeItem(at: trace.directory) }
                    let batch = RepoExplorerCommandPresentationBatch(
                        store: fixture.store,
                        repoExplorerPrefs: RepoExplorerSidebarPrefsAtom(),
                        resolveCommandCapabilities: {
                            dispatcher.repoExplorerCommandPresentationSnapshot(requests: $0, generation: $1)
                        },
                        executionOwnerIdentities: dispatcher.executionOwnerIdentities,
                        performanceTraceRecorder: trace.recorder
                    )
                    batch.start()
                    defer { batch.stop() }
                    batch.acceptVisibleWorktreeSnapshot(
                        makeCoalescingVisibleWorktreeSnapshot(
                            worktreeIDs: [fixture.worktree.id],
                            repositoryIDs: [fixture.repo.id]
                        )
                    )
                    _ = await handler.batchArrivals.wait { _ in true }
                    try await trace.recorder.flush()
                    let outputFileURL = try #require(trace.runtime.outputFileURL)
                    let observationBefore = try coalescingRefreshCount(at: outputFileURL, trigger: "observation")

                    // No await between these writes: they must land in the same MainActor turn.
                    for iteration in 0..<10 {
                        coreAtoms.repoCache.setRepositoryFactUpdateProgress(
                            .captured(repoId: fixture.repo.id, attemptId: UUIDv7.generate())
                        )
                        fixture.store.setActivePane(
                            iteration.isMultiple(of: 2) ? fixture.paneA2.id : fixture.paneA1.id,
                            inTab: fixture.tabA.id
                        )
                    }

                    _ = await handler.batchArrivals.wait { _ in true }
                    for _ in 0..<1000 { await Task.yield() }
                    try await trace.recorder.drain()
                    let observationAfter = try coalescingRefreshCount(at: outputFileURL, trigger: "observation")

                    #expect(observationAfter - observationBefore == 1)
                }
            }
        )
    }

    @Test("each global capability fact triggers full re-resolution")
    func eachGlobalCapabilityFactTriggersFullReresolution() async throws {
        let handler = RepoExplorerCoalescingRecordingHandler()

        try await withCommandDispatcherFixture(
            configure: { configuration in
                configuration.workspaceOwner = handler
                configuration.shellOwner = nil
            },
            body: { dispatcher in
                try await withAsyncTestCoreAtoms { coreAtoms in
                    coreAtoms.managementLayer.deactivate()
                    defer { coreAtoms.managementLayer.deactivate() }

                    let fixture = try makeCoalescingFixture()
                    let batch = RepoExplorerCommandPresentationBatch(
                        store: fixture.store,
                        repoExplorerPrefs: RepoExplorerSidebarPrefsAtom(),
                        resolveCommandCapabilities: {
                            dispatcher.repoExplorerCommandPresentationSnapshot(requests: $0, generation: $1)
                        }, executionOwnerIdentities: dispatcher.executionOwnerIdentities
                    )
                    batch.start()
                    defer { batch.stop() }
                    batch.acceptVisibleWorktreeSnapshot(
                        makeCoalescingVisibleWorktreeSnapshot(
                            worktreeIDs: [fixture.worktree.id],
                            repositoryIDs: [fixture.repo.id]
                        )
                    )
                    let initialRequests = await handler.batchArrivals.wait { _ in true }
                    handler.repoExplorerCapabilityRequestBatches.removeAll()

                    // (a) active tab changes.
                    fixture.store.setActiveTab(fixture.tabB.id)
                    var resolved = await handler.batchArrivals.wait { _ in true }
                    #expect(resolved == initialRequests)

                    // (b) active pane changes within the (now restored) active tab.
                    fixture.store.setActiveTab(fixture.tabA.id)
                    resolved = await handler.batchArrivals.wait { _ in true }
                    #expect(resolved == initialRequests)
                    fixture.store.setActivePane(fixture.paneA2.id, inTab: fixture.tabA.id)
                    resolved = await handler.batchArrivals.wait { _ in true }
                    #expect(resolved == initialRequests)

                    // (c) management layer activation changes.
                    coreAtoms.managementLayer.toggle()
                    resolved = await handler.batchArrivals.wait { _ in true }
                    #expect(resolved == initialRequests)

                    // (d) the active tab's zoom presentation changes.
                    fixture.store.panePresentationAtom.enterZoom(
                        inTab: fixture.tabA.id,
                        sourcePaneId: fixture.paneA2.id,
                        viewerPresentation: .unavailable
                    )
                    resolved = await handler.batchArrivals.wait { _ in true }
                    #expect(resolved == initialRequests)
                }
            }
        )
    }
}

@MainActor
private struct CoalescingFixture {
    let store: WorkspaceStore
    let repo: Repo
    let worktree: Worktree
    let tabA: Tab
    let tabB: Tab
    let paneA1: Pane
    let paneA2: Pane
    let paneB1: Pane
}

/// One repo/worktree, two tabs: tab A (active) holds panes A1 (active, bound to the worktree) and
/// A2; tab B holds pane B1. Active tab is restored to A before returning.
@MainActor
private func makeCoalescingFixture() throws -> CoalescingFixture {
    let store = WorkspaceStore()
    let repo = store.addRepo(
        at: FileManager.default.temporaryDirectory.appending(
            path: "repo-command-coalescing-\(UUIDv7.generate().uuidString)"
        )
    )
    let worktree = try #require(repo.worktrees.first)
    let paneA1 = store.createPane(
        launchDirectory: worktree.path,
        facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
    )
    let tabA = Tab(paneId: paneA1.id)
    store.appendTab(tabA)
    let paneA2 = store.createPane()
    _ = store.insertPane(
        paneA2.id,
        inTab: tabA.id,
        at: paneA1.id,
        direction: .horizontal,
        position: .after,
        sizingMode: .halveTarget
    )
    store.setActivePane(paneA1.id, inTab: tabA.id)

    let paneB1 = store.createPane()
    let tabB = Tab(paneId: paneB1.id)
    store.appendTab(tabB)
    store.setActiveTab(tabA.id)

    return CoalescingFixture(
        store: store,
        repo: repo,
        worktree: worktree,
        tabA: tabA,
        tabB: tabB,
        paneA1: paneA1,
        paneA2: paneA2,
        paneB1: paneB1
    )
}

private func makeCoalescingVisibleWorktreeSnapshot(
    hostLifetimeID: RepoExplorerMaterializationHostLifetimeID = RepoExplorerMaterializationHostLifetimeID(
        rawValue: UUIDv7.generate()
    ),
    worktreeIDs: Set<UUID>,
    repositoryIDs: Set<UUID> = [],
    materializationGeneration: UInt64 = 1,
    visibleRevision: UInt64 = 1
) -> RepoExplorerVisibleWorktreeSnapshot {
    RepoExplorerVisibleWorktreeSnapshot(
        target: RepoExplorerCommandPresentationTarget(
            materializationHostLifetimeID: hostLifetimeID,
            materializationGeneration: materializationGeneration,
            visibleRevision: visibleRevision
        ),
        worktreeIDs: worktreeIDs,
        repositoryIDs: repositoryIDs
    )
}

private func makeCoalescingTraceRecorder(
    name: String,
    processIdentifier: Int32
) -> (recorder: AgentStudioPerformanceTraceRecorder, runtime: AgentStudioTraceRuntime, directory: URL) {
    let traceDirectory = FileManager.default.temporaryDirectory.appending(
        path: "\(name)-\(UUIDv7.generate().uuidString)"
    )
    let runtime = AgentStudioTraceRuntime(
        configuration: AgentStudioTraceConfiguration.from(environment: [
            "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
            "AGENTSTUDIO_TRACE_DIR": traceDirectory.path,
            "AGENTSTUDIO_TRACE_NAME": name,
            "AGENTSTUDIO_TRACE_TAGS": "performance",
        ]),
        processIdentifier: processIdentifier,
        timeUnixNano: { UInt64(processIdentifier) }
    )
    return (AgentStudioPerformanceTraceRecorder(traceRuntime: runtime), runtime, traceDirectory)
}

private func coalescingRefreshCount(at outputFileURL: URL, trigger: String) throws -> Int {
    try String(contentsOf: outputFileURL, encoding: .utf8)
        .split(separator: "\n")
        .count { line in
            line.contains("\"body\":\"performance.repo_explorer.command_presentation\"")
                && line.contains(
                    "\"agentstudio.performance.repo_explorer.wake_trigger\":\"\(trigger)\""
                )
        }
}

@MainActor
private final class RepoExplorerCoalescingRecordingHandler: WorkspaceCommandHandling {
    let batchArrivals = ExactEventAcknowledgement<Set<RepoExplorerCommandPresentationRequest>>()
    var repoExplorerCapabilityRequestBatches: [Set<RepoExplorerCommandPresentationRequest>] = []
    var capabilityResult = true

    func execute(_: AppCommand) {}

    func execute(_: AppCommand, target _: UUID, targetType _: SearchItemType) {}

    func canExecute(_: AppCommand) -> Bool {
        true
    }

    func executeExtractPaneToTab(tabId _: UUID, paneId _: UUID, targetTabInsertionIndex _: Int?) {}

    func executeMovePaneToTab(sourcePaneId _: UUID, sourceTabId _: UUID?, targetTabId _: UUID) {}

    func repoExplorerCommandCapabilities(
        _ requests: Set<RepoExplorerCommandPresentationRequest>
    ) -> [RepoExplorerCommandPresentationRequest: Bool] {
        repoExplorerCapabilityRequestBatches.append(requests)
        batchArrivals.record(requests)
        return Dictionary(uniqueKeysWithValues: requests.map { ($0, capabilityResult) })
    }
}

@MainActor
private final class RepoExplorerCoalescingYieldGate {
    private(set) var isSuspended = false
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isSuspended = true
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
