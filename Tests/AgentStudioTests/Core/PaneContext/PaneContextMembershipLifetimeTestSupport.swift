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

    init() async throws {
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
        let lane = PaneContextPublicationLane(mailbox: mailbox, sink: { atom.apply($0) })
        self.lane = lane
        service = storage.makeService(presentationLane: lane, membership: directory)
    }

    func display() async throws -> PaneContextDisplay {
        try #require(await service.readDisplay(paneId: storage.paneId))
    }

    func close() async throws {
        await service.stop()
        await lane.shutdown()
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
