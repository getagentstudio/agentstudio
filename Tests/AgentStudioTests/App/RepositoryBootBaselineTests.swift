import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite("Repository boot baseline", .serialized)
struct RepositoryBootBaselineTests {
    @Test("boot replay forwards one current repository, watched-path, and revision capture")
    func bootReplayForwardsOneCurrentRepositoryWatchedPathAndRevisionCapture() async {
        await withAsyncTestAtomRegistry { atomRegistry in
            let traceRuntime = AgentStudioTraceRuntime(
                configuration: AgentStudioTraceConfiguration.from(
                    environment: [:],
                    releaseChannel: .stable,
                    isDebugBuild: false
                ),
                processIdentifier: 9012,
                sessionID: "repository-boot-baseline-test",
                timeUnixNano: { 1 }
            )
            let appDelegate = AppDelegate(
                traceRuntime: traceRuntime,
                startupTraceRecorder: AgentStudioStartupTraceRecorder(traceRuntime: traceRuntime)
            )

            let coreAtoms = atomRegistry.core
            let workspaceStore = WorkspaceStore(
                identityAtom: coreAtoms.workspaceIdentity,
                windowMemoryAtom: coreAtoms.workspaceWindowMemory,
                repositoryTopologyAtom: coreAtoms.workspaceRepositoryTopology,
                paneAtom: coreAtoms.workspacePane,
                tabLayoutAtom: coreAtoms.workspaceTabLayout,
                mutationCoordinator: coreAtoms.workspaceMutationCoordinator,
                startsObserving: false
            )
            appDelegate.store = workspaceStore

            _ = workspaceStore.addRepo(at: URL(fileURLWithPath: "/fixtures/repositories/initial"))
            _ = workspaceStore.addWatchedPath(URL(fileURLWithPath: "/fixtures/watched/initial"))

            let recordedScopeChanges = RepositoryBootRecordedScopeChanges()
            let coordinator = WorkspaceCacheCoordinator(
                bus: EventBus<RuntimeEnvelope>(),
                workspaceStore: workspaceStore,
                repoCache: coreAtoms.repoCache,
                scopeSyncHandler: { change in
                    await recordedScopeChanges.record(change)
                }
            )
            let replayGate = RepositoryBootReplayGate()
            let replayTask = Task { @MainActor in
                await appDelegate.replayBootTopology(
                    store: workspaceStore,
                    coordinator: coordinator,
                    postTopologyEnvelope: { _ in
                        await replayGate.suspendReplay()
                    }
                )
            }

            let replayDidSuspend = await waitForRepositoryBootReplaySuspension(replayGate)
            guard replayDidSuspend else {
                await replayGate.resumeReplay()
                await replayTask.value
                await coordinator.shutdown()
                try? await traceRuntime.shutdown()
                Issue.record("boot topology replay did not reach the injected post gate")
                return
            }

            _ = workspaceStore.addRepo(at: URL(fileURLWithPath: "/fixtures/repositories/current"))
            _ = workspaceStore.addWatchedPath(URL(fileURLWithPath: "/fixtures/watched/current"))
            let expectedRepositories = Set(workspaceStore.repos)
            let expectedWatchedPaths = Set(workspaceStore.watchedPaths)
            let expectedMembershipRevision = workspaceStore.repositoryTopologyAtom.worktreePathIndexGeneration

            await replayGate.resumeReplay()
            await replayTask.value
            await coordinator.shutdown()
            try? await traceRuntime.shutdown()

            guard let forwardedBaseline = await recordedScopeChanges.latestWatchedFolderBaseline() else {
                Issue.record("boot topology replay did not forward a watched-folder baseline")
                return
            }
            #expect(Set(forwardedBaseline.repositories) == expectedRepositories)
            #expect(Set(forwardedBaseline.watchedPaths) == expectedWatchedPaths)
            #expect(forwardedBaseline.membershipRevision == expectedMembershipRevision)
        }
    }
}

private struct RepositoryBootBaselineCapture: Sendable {
    let watchedPaths: [WatchedPath]
    let repositories: [Repo]
    let membershipRevision: UInt64
}

private actor RepositoryBootRecordedScopeChanges {
    private var watchedFolderBaselines: [RepositoryBootBaselineCapture] = []

    func record(_ change: ScopeChange) {
        guard case .updateWatchedFolders(let watchedPaths, let repositories, let membershipRevision) = change else {
            return
        }
        watchedFolderBaselines.append(
            RepositoryBootBaselineCapture(
                watchedPaths: watchedPaths,
                repositories: repositories,
                membershipRevision: membershipRevision
            )
        )
    }

    func latestWatchedFolderBaseline() -> RepositoryBootBaselineCapture? {
        watchedFolderBaselines.last
    }
}

private actor RepositoryBootReplayGate {
    private var replayIsSuspended = false
    private var replayWasReleased = false
    private var replayReleaseContinuation: CheckedContinuation<Void, Never>?

    func suspendReplay() async {
        guard !replayWasReleased else { return }
        await withCheckedContinuation { continuation in
            replayReleaseContinuation = continuation
            replayIsSuspended = true
        }
    }

    func isReplaySuspended() -> Bool {
        replayIsSuspended
    }

    func resumeReplay() {
        replayWasReleased = true
        replayReleaseContinuation?.resume()
        replayReleaseContinuation = nil
        replayIsSuspended = false
    }
}

private func waitForRepositoryBootReplaySuspension(
    _ replayGate: RepositoryBootReplayGate,
    minimumTurns: Int = 200,
    timeout: Duration = .seconds(10)
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var turn = 0
    while turn < minimumTurns || clock.now < deadline {
        if await replayGate.isReplaySuspended() {
            return true
        }
        await Task.yield()
        turn += 1
    }
    return await replayGate.isReplaySuspended()
}
