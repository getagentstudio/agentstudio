import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioCore

@MainActor
final class PaneContextMembershipLifetimeFixture {
    let storage: PaneContextServiceFixture
    let graph: PaneContextMembershipGraphFixture
    let atom: PaneContextPresentationAtom
    let mailbox: PaneContextPublicationMailbox
    let lane: PaneContextPublicationLane
    let service: PaneContextService
    private let publications: PaneContextPresentationBatchRecorder
    private var publicationScope: UUID

    init() async throws {
        let publications = PaneContextPresentationBatchRecorder()
        self.publications = publications
        publicationScope = publications.beginScope()
        let storage = try await PaneContextServiceFixture.make()
        self.storage = storage
        let graph = try PaneContextMembershipGraphFixture(
            initialPane: PaneContextMembershipGraphFixture.makePane(
                title: "Undo member", paneId: storage.paneId.uuid))
        self.graph = graph
        let directory = graph.directory
        let mailbox = PaneContextPublicationMailbox(isPresent: { directory.sources(for: $0) != nil })
        self.mailbox = mailbox
        let atom = PaneContextPresentationAtom()
        self.atom = atom
        let lane = PaneContextPublicationLane(
            mailbox: mailbox,
            sink: { batch in
                atom.apply(batch)
                publications.record(batch)
            })
        self.lane = lane
        service = storage.makeService(presentationLane: lane, membership: directory)
    }

    func display() async throws -> PaneContextDisplay {
        try #require(await service.readDisplay(paneId: storage.paneId))
    }

    func expectApplied(_ value: PaneContextPublication) async throws {
        let paneId = storage.paneId
        _ = try await publications.facts.expectNext(
            in: publicationScope,
            where: { fact in
                if case .published(let batch) = fact { return batch[paneId] == value }
                return false
            }, "membership pane value applied")
    }

    func withNoPublication<Output: Sendable>(
        _ operation: @MainActor () async throws -> Output
    ) async throws -> Output {
        await lane.publishPending()
        let scope = publications.beginScope()
        publicationScope = scope
        let opening = await publications.facts.mark(scope)
        defer { publicationScope = publications.beginScope() }
        let result = try await operation()
        await lane.publishPending()
        publications.facts.append(scope: scope, fact: .drainFinished)
        try await publications.facts.expectNone(
            of: { fact in if case .published = fact { true } else { false } }, "membership sink apply",
            from: opening, closedBy: { fact in if case .drainFinished = fact { true } else { false } })
        return result
    }

    func close() async throws {
        await service.stop()
        await lane.shutdown()
        publications.facts.receive(.ended)
        try await publications.facts.finish()
        try await storage.removeFiles()
    }
}

@MainActor
func withPaneContextMembershipLifetime(
    _ operation: (PaneContextMembershipLifetimeFixture) async throws -> Void
) async throws {
    let fixture = try await PaneContextMembershipLifetimeFixture()
    do {
        try await operation(fixture)
        try await fixture.close()
    } catch {
        try? await fixture.close()
        throw error
    }
}
