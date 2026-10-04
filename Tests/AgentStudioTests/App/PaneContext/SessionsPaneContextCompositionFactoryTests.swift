import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import GRDB
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("Sessions and PaneContext assembly factory", .serialized)
struct SessionsPaneContextCompositionFactoryTests {
    @Test("the factory connects asks and the IPC port to the same real Sessions owner")
    func factoryConnectsOwnerPorts() async throws {
        try await withCompositionFactory { fixture in
            let composition = fixture.composition
            _ = try await composition.prepareForLaunch(at: fixture.now)
            let binding = try await fixture.bind(paneId: fixture.ownerId, usingLateAdapter: false)
            let messageId = UUIDv7.generate()
            let sent = try await composition.paneContextIPCAdapter.sendMessage(
                paneId: fixture.ownerId.uuid,
                params: .init(
                    handle: fixture.ownerId.uuid.uuidString, messageId: messageId,
                    writer: .init(provider: binding.providerIdentifier, conversationId: binding.providerConversationId),
                    importance: .attention,
                    body: "Choose a response", actions: [],
                    shape: .ask(reason: .question, form: .freeText(placeholder: nil), waiting: .nonBlocking),
                    correlationId: UUIDv7.generate()))
            #expect(sent == .created(id: messageId))
            #expect(
                try await composition.ingestion.sessionSummary(paneId: fixture.ownerId.uuid)?.status
                    == .needsYou(.question))
            let read = await composition.paneContextService.readDetail(.init(paneId: fixture.ownerId, page: .first))
            let detail: PaneContextDetail?
            if case .detail(let value) = read { detail = value } else { detail = nil }
            #expect(try #require(detail).session?.bindingGeneration == binding.bindingGenerationId)
            #expect(try #require(detail).messages.count == 1)
            #expect(try #require(detail).messages.first?.id.uuid == messageId)
            await composition.presentationLane.publishPending()
            #expect(await fixture.presentationAtom.value(for: fixture.ownerId)?.own.needsReplyCount == 1)
        }
    }

    @Test("both adapters resolve drawer ownership through the supplied directory", arguments: [false, true])
    func factoryInjectsOwnerLookup(usingLateAdapter: Bool) async throws {
        try await withCompositionFactory { fixture in
            let binding = try await fixture.bind(paneId: fixture.drawerId, usingLateAdapter: usingLateAdapter)
            #expect(binding.ownerPaneId == fixture.ownerId.uuid)
            #expect(binding.paneId == fixture.drawerId.uuid)
            #expect(binding.status == .active)
        }
    }

    @Test("the factory mailbox uses current directory presence and only retirement is absorbing")
    func factoryMailboxUsesCurrentPresence() async throws {
        try await withCompositionFactory { fixture in
            let mailbox = fixture.composition.presentationLane.mailbox
            let display = PaneContextDisplay(
                revision: .init(1), agentTitle: nil, agentLine: nil,
                own: .zero, includingDrawers: .zero,
                pullRequests: .notApplicable)
            #expect(mailbox.offer(display, for: fixture.ownerId))
            fixture.directory.commit(changed: [], removed: [fixture.ownerId])
            mailbox.reconcile([fixture.ownerId: display])
            #expect(mailbox.takeBatch()[fixture.ownerId] == .remove)
            #expect(!mailbox.offer(display, for: fixture.ownerId))
            fixture.directory.commit(
                changed: [.init(paneId: fixture.ownerId, placement: .layout, ownedDrawerChildIds: [fixture.drawerId])],
                removed: [])
            #expect(mailbox.offer(display, for: fixture.ownerId))
            #expect(mailbox.takeBatch()[fixture.ownerId] == .set(display))
            let switchedWorkspaceId = UUIDv7.generate()
            fixture.directory.install(
                .init(
                    workspaceId: switchedWorkspaceId, membershipRevision: 3,
                    entries: [.init(paneId: fixture.ownerId, placement: .layout, ownedDrawerChildIds: [])]))
            #expect(!mailbox.offer(display, for: fixture.ownerId))
            mailbox.reconcile([fixture.ownerId: display])
            #expect(mailbox.takeBatch()[fixture.ownerId] == .remove)
            fixture.directory.install(
                .init(
                    workspaceId: fixture.workspaceId, membershipRevision: 4,
                    entries: [.init(paneId: fixture.ownerId, placement: .layout, ownedDrawerChildIds: [])]))
            #expect(mailbox.offer(display, for: fixture.ownerId))
            #expect(mailbox.takeBatch()[fixture.ownerId] == .set(display))
            mailbox.retire(fixture.ownerId)
            #expect(!mailbox.offer(display, for: fixture.ownerId))
            #expect(mailbox.takeBatch()[fixture.ownerId] == .remove)
        }
    }

    @Test("shutdown delivers blocking-ask settlement while Sessions still accepts the bridge update")
    func shutdownSettlesBeforeClosingSessions() async throws {
        try await withCompositionFactory { fixture in
            let binding = try await fixture.bind(paneId: fixture.ownerId, usingLateAdapter: false)
            let askId = AgentMessageId.generateUUIDv7()
            #expect(
                await fixture.composition.paneContextService.send(
                    .init(
                        paneId: fixture.ownerId, messageId: askId, sender: try fixture.sender(binding),
                        sourceOccurredAt: nil, importance: .attention, body: "Approve the action", why: nil,
                        actions: [],
                        shape: .ask(
                            reason: .approval, form: .freeText(placeholder: nil),
                            waiting: .blocking(deadline: fixture.now.addingTimeInterval(60))))) == .created(askId))
            #expect(
                try await fixture.composition.ingestion.sessionSummary(paneId: fixture.ownerId.uuid)?.status
                    == .needsYou(.approval))
            await fixture.composition.shutdown()
            #expect(
                await fixture.composition.paneContextService.waitForAskOutcome(
                    messageId: askId, paneId: fixture.ownerId) == .stale)
            #expect(
                try await fixture.composition.ingestion.sessionSummary(paneId: fixture.ownerId.uuid)?.status == .unknown
            )
            await #expect(throws: SessionsRepositoryError.ingestionFinished) {
                _ = try await fixture.composition.ingestion.prepareForLaunch(at: fixture.now)
            }
            await fixture.composition.shutdown()
        }
    }

    @Test("a failed prepare closes both assembled owners")
    func failedPrepareCleansUpAssembly() async throws {
        try await withCompositionFactory { fixture in
            try await fixture.localPool.write { database in
                try database.execute(
                    sql: """
                        CREATE TRIGGER reject_composition_prepare BEFORE INSERT ON sessions_operation
                        WHEN NEW.operation_kind = 'prepareForLaunch'
                        BEGIN SELECT RAISE(ABORT, 'forced composition preparation failure'); END
                        """)
            }
            await #expect(throws: (any Error).self) {
                _ = try await fixture.composition.prepareForLaunch(at: fixture.now)
            }
            let closed = await fixture.requireClosedOwners()
            #expect(closed == .unavailable(.decodeFailed("serviceStopped")))
        }
    }

    @Test("a cancelled prepare closes both owners without attempting launch preparation")
    func cancelledPrepareCleansUpAssembly() async throws {
        try await withCompositionFactory { fixture in
            let held = HeldStep<Void>("cancel before composition preparation", cancellation: .holdThroughCancellation)
            let pending = Task {
                try await held.arrive(())
                _ = try await fixture.composition.prepareForLaunch(at: fixture.now)
            }
            do {
                try await held.firstArrival()
                pending.cancel()
                held.release()
                await #expect(throws: CancellationError.self) { try await pending.value }
            } catch {
                held.retire()
                pending.cancel()
                _ = try? await pending.value
                throw error
            }
            let closed = await fixture.requireClosedOwners()
            #expect(closed == .unavailable(.decodeFailed("serviceStopped")))
        }
    }
}

private struct CompositionFactoryFixture: Sendable {
    let root: URL
    let corePool: DatabasePool
    let localPool: DatabasePool
    let composition: SessionsPaneContextComposition
    let directory: PaneContextMembershipDirectory
    let workspaceId: UUID
    let presentationAtom: PaneContextPresentationAtom
    let ownerId: PaneId
    let drawerId: PaneId
    let now: Date

    @concurrent static func make() async throws -> Self {
        let (root, corePool, localPool) = try await withoutBlockingCooperativePool {
            let root = FileManager.default.temporaryDirectory.appending(path: "as-composition-\(UUIDv7.generate())")
            let corePool = try SQLiteDatabaseFactory.makeFileBackedPool(
                at: root.appending(path: "core.sqlite"), label: "AgentStudio.sqlite.composition-core")
            let localPool: DatabasePool
            do {
                localPool = try SQLiteDatabaseFactory.makeFileBackedPool(
                    at: root.appending(path: "local.sqlite"), label: "AgentStudio.sqlite.composition-local")
            } catch {
                try? corePool.close()
                try? FileManager.default.removeItem(at: root)
                throw error
            }
            do {
                try WorkspaceCoreMigrations.migrate(corePool)
                try WorkspaceLocalMigrations.migrate(localPool)
                return (root, corePool, localPool)
            } catch {
                try? localPool.close()
                try? corePool.close()
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }
        let workspaceId = UUIDv7.generate()
        let datastore = WorkspaceSQLiteDatastoreActor(
            preparedCoreRepository: WorkspaceCoreRepository(databaseWriter: corePool),
            preparationReceipt: .init(core: .uninitialized, local: .available(recovery: nil)),
            preparedApplicationLocalRepository: WorkspaceLocalRepository(
                workspaceId: workspaceId, databaseWriter: localPool))
        let ownerId = PaneId.generateUUIDv7()
        let drawerId = PaneId.generateUUIDv7()
        let directory = PaneContextMembershipDirectory()
        // Recorded graph installation is a stand-in for S3b's canonical publisher.
        directory.install(
            .init(
                workspaceId: workspaceId, membershipRevision: 1,
                entries: [
                    .init(paneId: ownerId, placement: .layout, ownedDrawerChildIds: [drawerId]),
                    .init(
                        paneId: drawerId, placement: .drawerChild(parentPaneID: ownerId.uuid),
                        ownedDrawerChildIds: []),
                ]))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let presentationAtom = await PaneContextPresentationAtom()
        let composition = SessionsPaneContextComposition.make(
            inputs: .init(
                datastore: datastore, directory: directory, workspaceId: workspaceId, clock: TestPushClock(),
                wallNow: { now },
                providerProfiles: [.claudeCodeCommandLine],
                limits: .init(maximumPendingPerPane: 32, maximumPendingGlobal: 128),
                paneViewedMailbox: .init(), presentationAtom: presentationAtom))
        return Self(
            root: root, corePool: corePool, localPool: localPool, composition: composition, directory: directory,
            workspaceId: workspaceId,
            presentationAtom: presentationAtom,
            ownerId: ownerId,
            drawerId: drawerId, now: now)
    }

    func bind(paneId: PaneId, usingLateAdapter: Bool) async throws -> SessionsBindingRecord {
        let adapter = usingLateAdapter ? composition.lateSessionsAdapter : composition.liveSessionsAdapter
        let result = try await adapter.recordProviderEvent(
            paneId: paneId.uuid,
            params: .init(
                handle: paneId.uuid.uuidString,
                provider: .init(
                    identifier: ClaudeCodeProviderIdentity.identifier,
                    version: ClaudeCodeProviderIdentity.supportedExactVersion,
                    mode: ClaudeCodeProviderIdentity.operatingMode),
                event: .init(
                    name: .sessionStart, conversationId: UUIDv7.generate().uuidString, turnId: nil, requestId: nil,
                    toolId: nil, subagentId: nil, occurrenceId: UUIDv7.generate()),
                correlationId: UUIDv7.generate()), provenance: .matchingPane)
        #expect(result.disposition == .admitted)
        return try #require(
            try await composition.ingestion.snapshot(.pane(paneId.uuid, page: .init(limit: 100, after: nil)))
                .currentBinding)
    }

    func sender(_ binding: SessionsBindingRecord) throws -> AgentMessageSender {
        .session(
            provider: try BridgeAgentProviderName(binding.providerIdentifier),
            sessionRef: try BridgeAgentSessionRef(binding.providerConversationId),
            bindingGeneration: binding.bindingGenerationId)
    }

    func requireClosedOwners() async -> PaneContextReadResult {
        await #expect(throws: SessionsRepositoryError.ingestionFinished) {
            _ = try await composition.ingestion.prepareForLaunch(at: now)
        }
        return await composition.paneContextService.readDetail(.init(paneId: ownerId, page: .first))
    }

    @concurrent func close() async throws {
        await composition.shutdown()
        try await withoutBlockingCooperativePool { [localPool, corePool, root] in
            try localPool.close()
            try corePool.close()
            try FileManager.default.removeItem(at: root)
        }
    }
}

@MainActor
private func withCompositionFactory(operation: @Sendable (CompositionFactoryFixture) async throws -> Void) async throws
{
    let fixture = try await CompositionFactoryFixture.make()
    do {
        try await operation(fixture)
        try await fixture.close()
    } catch {
        try? await fixture.close()
        throw error
    }
}
