import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

@testable import AgentStudioCore

private enum PaneContextPresentationFact: Sendable {
    case published
    case drainFinished
}

private final class PaneContextPresentationBatchRecorder: Sendable {
    let values = Mutex<[[PaneId: PaneContextPublication]]>([])
    private let scope = Mutex(UUIDv7.generate())
    let facts = FactRecorder<UUID, PaneContextPresentationFact>(
        vocabulary: .init(
            describeScope: { "publication operation \($0)" },
            describeFact: { fact in
                switch fact {
                case .published: "MainActor batch applied"
                case .drainFinished: "awaited publication drain returned"
                }
            },
            isClosing: { _, fact in if case .drainFinished = fact { true } else { false } }))

    func record(_ batch: [PaneId: PaneContextPublication]) {
        values.withLock { $0.append(batch) }
        facts.append(scope: scope.withLock { $0 }, fact: .published)
    }

    func beginScope() -> UUID {
        scope.withLock {
            $0 = UUIDv7.generate()
            return $0
        }
    }
}

final class PaneContextPresentationServiceFixture: Sendable {
    let storage: PaneContextServiceFixture
    let directory = PaneContextMembershipDirectory()
    let mailbox: PaneContextPublicationMailbox
    private let batches = PaneContextPresentationBatchRecorder()
    let lane: PaneContextPublicationLane
    let service: PaneContextService

    init() async throws {
        let storage = try await PaneContextServiceFixture.make()
        self.storage = storage
        let directory = self.directory
        mailbox = PaneContextPublicationMailbox(isPresent: { directory.sources(for: $0) != nil })
        directory.install(
            .init(
                workspaceId: UUIDv7.generate(), membershipRevision: 1,
                entries: [.init(paneId: storage.paneId, placement: .layout, ownedDrawerChildIds: [])]))
        let batches = self.batches
        lane = PaneContextPublicationLane(
            mailbox: mailbox,
            sink: { batch in
                MainActor.preconditionIsolated()
                batches.record(batch)
            })
        service = storage.makeService(presentationLane: lane, membership: directory)
    }

    func display(_ paneId: PaneId? = nil) async throws -> PaneContextDisplay {
        try #require(
            await service.readDisplay(paneId: paneId ?? storage.paneId),
            "Inert display must fail before a HeldStep or clock wait")
    }

    func attachDrawer() async throws -> PaneId {
        let child = PaneId.generateUUIDv7()
        directory.commit(
            changed: [
                .init(paneId: storage.paneId, placement: .layout, ownedDrawerChildIds: [child]),
                .init(
                    paneId: child, placement: .drawerChild(parentPaneID: storage.paneId.uuid), ownedDrawerChildIds: []),
            ], removed: [])
        try await storage.bind(storage.sender, to: child)
        await service.reconcileMembership()
        return child
    }

    func publishedBatches() async -> [[PaneId: PaneContextPublication]] {
        await lane.publishPending()
        return batches.values.withLock { $0 }
    }

    func latestPublished(_ paneId: PaneId) async -> PaneContextPublication? {
        await publishedBatches().reversed().compactMap { $0[paneId] }.first
    }

    func withNoPublication<Output: Sendable>(
        _ operation: @Sendable () async throws -> Output
    ) async throws -> Output {
        await lane.publishPending()
        let scope = batches.beginScope()
        let opening = await batches.facts.mark(scope)
        defer { _ = batches.beginScope() }
        let result = try await operation()
        await lane.publishPending()
        batches.facts.append(scope: scope, fact: .drainFinished)
        try await batches.facts.expectNone(
            of: { fact in if case .published = fact { true } else { false } }, "MainActor sink call",
            from: opening, closedBy: { fact in if case .drainFinished = fact { true } else { false } })
        return result
    }

    func close() async throws {
        await service.stop()
        await lane.shutdown()
        batches.facts.receive(.ended)
        try await batches.facts.finish()
        try await storage.removeFiles()
    }
}

func withPaneContextPresentationService(
    _ operation: @Sendable (PaneContextPresentationServiceFixture) async throws -> Void
) async throws {
    let fixture = try await PaneContextPresentationServiceFixture()
    do {
        try await operation(fixture)
        try await fixture.close()
    } catch {
        try? await fixture.close()
        throw error
    }
}
