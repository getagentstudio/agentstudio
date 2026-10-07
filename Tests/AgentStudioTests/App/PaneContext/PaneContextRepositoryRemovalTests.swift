import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("Pane context repository removal", .serialized)
struct PaneContextRepositoryRemovalTests {
    @Test(
        "Repository removal unassigns ordinary panes and drawer families without retirement", arguments: [false, true])
    func repositoryRemovalUnassignsWithoutRetiringPanes(drawers: Bool) async throws {
        let owners = try await makeCanonicalIPCWorkspaceOwners()
        try await CoreAtomScope.$override.withValue(owners.core) {
            let harness = makeHarness(store: owners.store, paneEventBus: EventBus<RuntimeEnvelope>())
            let directory = owners.core.workspacePaneGraph.paneContextMembershipDirectory
            let service = PaneContextService(
                sqliteAccess: WorkspacePaneContextSQLiteAccess(datastore: owners.datastore),
                clock: TestPushClock(), wallNow: { Date(timeIntervalSince1970: 100) }, membership: directory,
                currentBindingGeneration: PaneContextSessionsBridge.currentBindingGeneration)
            harness.coordinator.paneContextService = service
            let scopes = FactRecorder<UUID, Bool>(
                vocabulary: .init(
                    describeScope: { "removed repository \($0)" }, describeFact: { _ in "Forge unregister consumed" },
                    isClosing: { _, _ in true }))
            let cache = WorkspaceCacheCoordinator(
                bus: EventBus<RuntimeEnvelope>(), workspaceStore: owners.store, repoCache: harness.repoCache,
                topologyEffectHandler: harness.coordinator,
                scopeSyncHandler: { change in
                    if case .unregisterForgeRepo(let repoId, _) = change { scopes.append(scope: repoId, fact: true) }
                })
            do {
                let repository = owners.store.addRepo(at: harness.tempDir.appending(path: "removed-repository"))
                let worktree = try #require(repository.worktrees.first)
                let expectedCWD = URL(filePath: worktree.path.standardizedFileURL.path, directoryHint: .isDirectory)
                let pane = Pane(
                    id: UUIDv7.generate(),
                    content: .terminal(
                        TerminalState(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())),
                    metadata: PaneMetadata(
                        launchDirectory: worktree.path, title: "Association survives as pane",
                        facets: .init(repoId: repository.id, worktreeId: worktree.id, cwd: worktree.path)))
                owners.core.workspacePane.addPane(pane)
                owners.core.workspaceTabLayout.appendTab(Tab(paneId: pane.id))
                var paneIds = [PaneId(existingUUID: pane.id)]
                if drawers {
                    let child = try #require(
                        owners.core.workspacePane.addDrawerPane(
                            to: pane.id, parentFallbackCWD: worktree.path, zmxSessionID: .generateUUIDv7()))
                    paneIds.append(PaneId(existingUUID: child.id))
                }
                var before: [PaneId: PaneContextMembershipView] = [:]
                var noticeIds: [PaneId: AgentMessageId] = [:]
                for paneId in paneIds {
                    let membershipView: PaneContextMembershipView = try #require(directory.view(for: paneId))
                    before[paneId] = membershipView
                    let state = try #require(owners.core.workspacePaneGraph.paneState(paneId.uuid))
                    try #require(state.durableContextFacets.repoId == repository.id)
                    try #require(state.durableContextFacets.worktreeId == worktree.id)
                    try #require(state.durableContextFacets.cwd?.standardizedFileURL.path == expectedCWD.path)
                    let notice = PaneMessageSendRequest(
                        paneId: paneId, messageId: .generateUUIDv7(), sender: .pane(paneId), sourceOccurredAt: nil,
                        importance: .info, body: "Still live after repository removal", why: nil, actions: [],
                        shape: .notice)
                    try #require(await service.send(notice) == .created(notice.messageId))
                    noticeIds[paneId] = notice.messageId
                }
                _ = directory.takeAffectedOwners()
                cache.handleRepoRemoval(repoId: repository.id)
                try #require(owners.store.repositoryTopologyAtom.repo(repository.id) == nil)
                for paneId in paneIds {
                    let state = try #require(owners.core.workspacePaneGraph.paneState(paneId.uuid))
                    #expect(state.durableContextFacets.repoId == nil)
                    #expect(state.durableContextFacets.worktreeId == nil)
                    #expect(state.durableContextFacets.cwd == expectedCWD)
                    #expect(directory.view(for: paneId) == before[paneId])
                    #expect(
                        directory.contains(paneID: paneId.uuid, inWorkspace: owners.core.workspaceIdentity.workspaceId))
                    let read = await service.readDetail(.init(paneId: paneId, page: .first))
                    let detail: PaneContextDetail?
                    if case .detail(let value) = read { detail = value } else { detail = nil }
                    let live = try #require(detail, "Repository removal must not retire the live service key")
                    let noticeId = try #require(noticeIds[paneId])
                    #expect(live.messages.contains { $0.id == noticeId })
                }
                #expect(directory.sources(for: paneIds[0]) == paneIds)
                #expect(directory.takeAffectedOwners() == .owners([]))
                try await scopes.expectNext(in: repository.id, true)

                cache.handleRepoRemoval(repoId: repository.id)
                #expect(directory.takeAffectedOwners() == .owners([]))
                for paneId in paneIds { #expect(directory.view(for: paneId) == before[paneId]) }
                harness.coordinator.paneContextService = nil
                await service.stop()
                await cache.shutdown()
                await harness.executor.stopAcceptingCommandsAndDrain()
                await harness.coordinator.shutdown()
            } catch {
                harness.coordinator.paneContextService = nil
                await service.stop()
                await cache.shutdown()
                await harness.executor.stopAcceptingCommandsAndDrain()
                await harness.coordinator.shutdown()
                throw error
            }
        }
    }
}
