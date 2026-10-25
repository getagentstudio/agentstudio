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
    @Test("a stored message without activity refreshes the same visible Panes row and retires on hidden demand")
    func messageOnlyDeadlineReachesVisibleRow() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let fixture = try await RepoExplorerMessageDeadlineHostFixture.make(atoms: atoms)
            do {
                fixture.adapter.updateDemand(isVisible: true, query: "")
                let generation = try #require(fixture.adapter.cachedProjectionRequest?.generation)
                try await fixture.expectPublished(generation)
                await fixture.adapter.waitForDeadlineWorkerUpdate()
                try #require(
                    await fixture.adapter.deadlineWorker.hasPendingPresentationDeadline(),
                    "The real adapter dropped the message-only deadline")
                try await fixture.clock.expectRegistration(after: .seconds(55), at: .seconds(55))
                let rowID = try fixture.expectVisibleMessage(age: "[2 min ago]")
                let hostIdentity = ObjectIdentifier(fixture.host.host)
                #expect(fixture.adapter.publishedResult?.snapshot.sortField == .activity)
                #expect(fixture.adapter.publishedResult?.snapshot.groupingMode == .activity)
                #expect(
                    fixture.adapter.publishedResult?.preparedPresentationDeadline?.deadline
                        == fixture.written.updatedAt.addingTimeInterval(180))
                #expect(atoms.paneActivityTime.value(for: fixture.paneID) == nil)

                let deadlineTask = try #require(await fixture.adapter.deadlineWorker.presentationDeadlineTask)
                // No line, hook, activity, preference, or demand write occurs here.
                fixture.clock.controlled.advance(by: .seconds(55))
                await deadlineTask.value
                try await fixture.clock.facts.expectNext(in: 0, .ended(cancelled: false))
                let admittedGeneration = fixture.adapter.cachedProjectionRequest?.generation
                try #require(
                    admittedGeneration == generation + 1,
                    "Deadline ended without admission: cancelled=\(deadlineTask.isCancelled), expected generation \(generation + 1), saw \(String(describing: admittedGeneration))"
                )
                try await fixture.expectPublished(generation + 1)
                await fixture.adapter.waitForDeadlineWorkerUpdate()
                try await fixture.clock.expectRegistration(after: .seconds(60), at: .seconds(115))
                #expect(try fixture.expectVisibleMessage(age: "[3 min ago]") == rowID)
                #expect(ObjectIdentifier(fixture.host.host) == hostIdentity)
                try await fixture.expectStoredMessageUnchanged()
                #expect(atoms.paneActivityTime.value(for: fixture.paneID) == nil)

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
