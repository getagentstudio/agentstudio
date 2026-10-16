import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

@testable import AgentStudioCore

@MainActor
@Suite("Pane context membership startup race", .serialized)
struct PaneContextMembershipStartupRaceTests {
    @Test("A drawer moved to an uncaptured owner during lazy reconciliation is published there")
    func initialReconciliationPublishesDrawerMovedDuringCapture() async throws {
        try await withStartupMembershipCapture { fixture in
            let demand = fixture.beginDemand()
            do {
                try await fixture.captureReached()
                let newOwner = fixture.graph.addPane(title: "Created after initial owner capture")
                let newOwnerId = PaneId(existingUUID: newOwner.id)
                let detached = try #require(
                    fixture.graph.graph.detachDrawerPane(fixture.child.uuid, from: fixture.graph.seed.id))
                try #require(
                    fixture.graph.graph.restoreDrawerPane(detached.pane(isDrawerExpanded: false), to: newOwner.id))
                #expect(fixture.graph.directory.ownerPaneId(for: fixture.child) == newOwnerId)
                fixture.capture.held.release()
                _ = await demand.value
                await fixture.service.reconcileMembership()
                await fixture.lane.publishPending()

                let original = try #require(fixture.atom.value(for: fixture.graph.seedId))
                let added = try #require(fixture.atom.value(for: newOwnerId))
                let child = try #require(fixture.atom.value(for: fixture.child))
                #expect(original.own.informationalCount == 0)
                #expect(original.includingDrawers.informationalCount == 0)
                #expect(added.own.informationalCount == 0)
                #expect(added.includingDrawers.informationalCount == 1)
                #expect(child.own.informationalCount == 1)
                #expect(fixture.graph.directory.sources(for: newOwnerId) == [newOwnerId, fixture.child])
                #expect(fixture.graph.directory.sources(for: fixture.graph.seedId) == [fixture.graph.seedId])
                #expect(fixture.graph.directory.takeAffectedOwners() == .owners([]))
            } catch {
                fixture.capture.held.retire()
                demand.cancel()
                _ = await demand.value
                throw error
            }
        }
    }

    @Test("Closing a captured owner during lazy reconciliation cannot publish it or its children")
    func initialReconciliationRemovesPaneClosedDuringCapture() async throws {
        try await withStartupMembershipCapture { fixture in
            let demand = fixture.beginDemand()
            do {
                try await fixture.captureReached()
                try #require(fixture.graph.graph.deletePaneAndOwnedDrawerChildren(fixture.graph.seed.id))
                fixture.capture.held.release()
                #expect(await demand.value == nil)
                await fixture.service.reconcileMembership()
                await fixture.lane.publishPending()

                #expect(fixture.atom.value(for: fixture.graph.seedId) == nil)
                #expect(fixture.atom.value(for: fixture.child) == nil)
                #expect(fixture.graph.directory.currentOwners().isEmpty)
                #expect(fixture.graph.directory.takeAffectedOwners() == .owners([]))
                #expect(!fixture.mailbox.offer(presentationDisplay(), for: fixture.graph.seedId))
            } catch {
                fixture.capture.held.retire()
                demand.cancel()
                _ = await demand.value
                throw error
            }
        }
    }
}

private enum StartupMembershipCaptureFact: Equatable, Sendable {
    case captured
    case demandFinished
}

private final class StartupMembershipCapture: Sendable {
    let scope = UUIDv7.generate()
    let held = HeldStep<PaneId>("initial service reconciliation captured membership before summary read")
    let facts = FactRecorder<UUID, StartupMembershipCaptureFact>(
        vocabulary: .init(
            describeScope: { "lazy service demand \($0)" },
            describeFact: { $0 == .captured ? "initial owner capture reached" : "initial demand returned" },
            isClosing: { _, fact in fact == .demandFinished }))
    private let owner: PaneId
    private let hasCaptured = Mutex(false)

    init(owner: PaneId) { self.owner = owner }

    func readSummary(for paneId: PaneId) async throws -> SessionSummary? {
        let shouldHold = hasCaptured.withLock { captured in
            guard paneId == owner, !captured else { return false }
            captured = true
            return true
        }
        if shouldHold {
            facts.append(scope: scope, fact: .captured)
            try await held.arrive(paneId)
        }
        return nil
    }
}

@MainActor
private final class StartupMembershipFixture {
    let storage: PaneContextServiceFixture
    let graph: PaneContextMembershipGraphFixture
    let child: PaneId
    let capture: StartupMembershipCapture
    let atom = PaneContextPresentationAtom()
    let mailbox: PaneContextPublicationMailbox
    let lane: PaneContextPublicationLane
    let service: PaneContextService

    init() async throws {
        let storage = try await PaneContextServiceFixture.make()
        self.storage = storage
        let graph = try PaneContextMembershipGraphFixture(
            initialPane: PaneContextMembershipGraphFixture.makePane(
                title: "Initial owner", paneId: storage.paneId.uuid))
        self.graph = graph
        child = PaneId(existingUUID: try graph.addDrawer(to: graph.seed.id).id)
        let capture = StartupMembershipCapture(owner: graph.seedId)
        self.capture = capture
        let directory = graph.directory
        let mailbox = PaneContextPublicationMailbox(isPresent: { directory.sources(for: $0) != nil })
        self.mailbox = mailbox
        let atom = self.atom
        let lane = PaneContextPublicationLane(mailbox: mailbox, sink: { atom.apply($0) })
        self.lane = lane
        service = storage.makeService(
            sessionSummary: { try await capture.readSummary(for: $0) },
            presentationLane: lane, membership: directory)
    }

    func seedNotice() async throws {
        _ = try graph.requireInstalled()
        let bootstrap = storage.makeService(membership: graph.directory)
        let request = PaneMessageSendRequest(
            paneId: child, messageId: .generateUUIDv7(), sender: .pane(child), sourceOccurredAt: nil,
            importance: .info, body: "Retained drawer notice", why: nil, actions: [], shape: .notice)
        do {
            try #require(await bootstrap.send(request) == .created(request.messageId))
            let detail = try await storage.detail(bootstrap, paneId: child)
            try #require(detail.messages.first?.id == request.messageId)
            await bootstrap.stop()
        } catch {
            await bootstrap.stop()
            throw error
        }
    }

    func beginDemand() -> Task<PaneContextDisplay?, Never> {
        let service = self.service
        let owner = graph.seedId
        let capture = self.capture
        return Task {
            let value = await service.readDisplay(paneId: owner)
            capture.facts.append(scope: capture.scope, fact: .demandFinished)
            return value
        }
    }

    func captureReached() async throws {
        try await capture.facts.expectNext(in: capture.scope, .captured)
        #expect(try await capture.held.firstArrival() == graph.seedId)
    }

    func close() async throws {
        capture.held.retire()
        await service.stop()
        await lane.shutdown()
        try await storage.removeFiles()
    }
}

@MainActor
private func withStartupMembershipCapture(
    _ operation: (StartupMembershipFixture) async throws -> Void
) async throws {
    let fixture = try await StartupMembershipFixture()
    do {
        try await fixture.seedNotice()
        try await operation(fixture)
        try await fixture.close()
    } catch {
        try? await fixture.close()
        throw error
    }
}
