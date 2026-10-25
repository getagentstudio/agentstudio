import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import AppKit
import Testing

@testable import AgentStudioRepoExplorer

@MainActor
@Suite("Stored sidebar message deadline host", .serialized)
struct RepoExplorerMessageDeadlineHostTests {
    @Test(
        "stored E4 refreshes independently of absent or older E6 and retires on hidden demand",
        arguments: [false, true])
    func messageOnlyDeadlineReachesVisibleRow(hasActivity: Bool) async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let fixture = try await RepoExplorerMessageDeadlineHostFixture.make(atoms: atoms)
            let peerID = hasActivity ? installActivityWitness(fixture, atoms: atoms) : nil
            defer { if let peerID { fixture.store.removePane(peerID) } }
            let originalActivity = atoms.paneActivityTime.value(for: fixture.paneID)
            let expectedOrder = peerID.map { [$0, fixture.paneID] } ?? [fixture.paneID]
            do {
                fixture.adapter.updateDemand(isVisible: true, query: "")
                let generation = try #require(fixture.adapter.cachedProjectionRequest?.generation)
                try await fixture.expectPublished(generation)
                await fixture.adapter.waitForDeadlineWorkerUpdate()
                try #require(
                    await fixture.adapter.deadlineWorker.hasPendingPresentationDeadline(),
                    "The real adapter dropped the message-only deadline")
                try await fixture.clock.expectRegistration(after: .seconds(55), at: .seconds(55))
                let rowID = try fixture.expectVisibleMessage(
                    age: "[2 min ago]", activityText: hasActivity ? "30d" : "—")
                #expect(try fixture.paneOrder() == expectedOrder)
                let hostIdentity = ObjectIdentifier(fixture.host.host)
                #expect(fixture.adapter.publishedResult?.snapshot.sortField == .activity)
                #expect(fixture.adapter.publishedResult?.snapshot.groupingMode == .activity)
                #expect(
                    fixture.adapter.publishedResult?.preparedPresentationDeadline?.deadline
                        == fixture.written.updatedAt.addingTimeInterval(180))
                // No line, hook, activity, preference, or demand write occurs during advancement.
                #expect(
                    try await fixture.advanceMessageAge(
                        by: .seconds(55), generation: generation + 1, nextDelay: .seconds(60),
                        nextElapsed: .seconds(115), age: "[3 min ago]", activityText: hasActivity ? "30d" : "—")
                        == rowID)
                #expect(ObjectIdentifier(fixture.host.host) == hostIdentity)
                try await fixture.expectStoredMessageUnchanged()

                #expect(
                    try await fixture.advanceMessageAge(
                        by: .seconds(3420), generation: generation + 2, nextDelay: .seconds(3600),
                        nextElapsed: .seconds(7075), age: "[1 hr ago]", activityText: hasActivity ? "30d" : "—")
                        == rowID)
                #expect(
                    try await fixture.advanceMessageAge(
                        by: .seconds(82_800), generation: generation + 3, nextDelay: .seconds(86_400),
                        nextElapsed: .seconds(172_675), age: "[1 day ago]", activityText: hasActivity ? "31d" : "—")
                        == rowID)
                #expect(
                    try await fixture.advanceMessageAge(
                        by: .seconds(86_400), generation: generation + 4, nextDelay: .seconds(86_400),
                        nextElapsed: .seconds(259_075), age: "[2 days ago]", activityText: hasActivity ? "32d" : "—")
                        == rowID)
                #expect(ObjectIdentifier(fixture.host.host) == hostIdentity)
                #expect(atoms.paneActivityTime.value(for: fixture.paneID) == originalActivity)
                #expect(try fixture.paneOrder() == expectedOrder)

                fixture.adapter.updateDemand(isVisible: false, query: "")
                await fixture.adapter.waitForDeadlineWorkerUpdate()
                try #require(
                    await fixture.adapter.deadlineWorker.hasPendingPresentationDeadline() == false,
                    "The real adapter retained a deadline after visible demand ended")
                try await fixture.clock.facts.expectNext(in: 0, .ended(cancelled: true))
                #expect(fixture.clock.controlled.pendingSleepCount == 0)
                try await fixture.closeProducers()
                try await fixture.clock.facts.expectNext(in: 0, .retired)
                try await fixture.finishFacts()
            } catch {
                try? await fixture.closeProducers()
                try? await fixture.finishFacts()
                throw error
            }
        }
    }

    private func installActivityWitness(_ fixture: RepoExplorerMessageDeadlineHostFixture, atoms: CoreAtoms) -> UUID {
        let peer = fixture.store.createPane(title: "Independent activity")
        fixture.store.appendTab(Tab(paneId: peer.id))
        let ownerTime = PaneActivityTime(
            orderingInstant: fixture.clock.continuousNow.advanced(by: .seconds(-(30 * 86_400 + 125))),
            wallTime: fixture.written.updatedAt.addingTimeInterval(-30 * 86_400), source: .terminal)
        let peerTime = PaneActivityTime(
            orderingInstant: fixture.clock.continuousNow.advanced(by: .seconds(-(5 * 86_400 + 125))),
            wallTime: fixture.written.updatedAt.addingTimeInterval(-5 * 86_400), source: .terminal)
        atoms.paneActivityTime.apply([.set(fixture.paneID, ownerTime), .set(peer.id, peerTime)])
        return peer.id
    }

    @Test("Repos name organization admits no message observation or message deadline")
    func reposDoesNotAcquireMessageDemand() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let fixture = try await RepoExplorerMessageDeadlineHostFixture.make(
                atoms: atoms, surface: .repos)
            let opening = await fixture.clock.facts.mark(0)
            do {
                fixture.adapter.updateDemand(isVisible: true, query: "")
                let generation = try #require(fixture.adapter.cachedProjectionRequest?.generation)
                try await fixture.expectPublished(generation)
                await fixture.adapter.waitForDeadlineWorkerUpdate()
                #expect(!fixture.adapter.observationRegistration.observesPanePresentation)
                #expect(fixture.adapter.publishedResult?.sidebarPresentationTransitionAtByPaneId.isEmpty == true)
                #expect(await fixture.adapter.deadlineWorker.hasPendingPresentationDeadline() == false)
                try await fixture.closeProducers()
                try await fixture.clock.facts.expectNone(
                    of: { $0 != .retired }, "message-clock work on Repos", from: opening,
                    closedBy: { $0 == .retired })
                try await fixture.finishFacts()
            } catch {
                try? await fixture.closeProducers()
                try? await fixture.finishFacts()
                throw error
            }
        }
    }
}
