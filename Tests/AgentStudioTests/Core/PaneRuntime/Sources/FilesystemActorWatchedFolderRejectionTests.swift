import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

extension FilesystemActorWatchedFolderTests {
    @Test("a rejected eligible folder cannot strand another folder in the same pacing drain")
    func rejectedFolderDoesNotStrandOtherEligibleFolders() async throws {
        let fixture = try await WatchedFolderActorFixture(watchedFolderCount: 2)
        defer { fixture.removeTemporaryRoot() }
        var refresh: Task<WatchedFolderRefreshSummary, Never>?
        do {
            let initial = Task { await fixture.actor.refreshWatchedFolders(fixture.watchedPaths) }
            refresh = initial
            for _ in fixture.watchedPaths { try await fixture.finishNextScanWithEmptyResult() }
            _ = await initial.value
            fixture.submissionLog.reset()
            let registrations = await fixture.actor.watchedFolderScanState.registrationsBySourceID.values.sorted {
                $0.registeredRoot.sourceID.rootID.uuidString < $1.registeredRoot.sourceID.rootID.uuidString
            }
            let first = try #require(registrations.first)
            let second = try #require(registrations.last)
            // Real scheduler rejection models retirement reaching it before the actor observes retirement.
            _ = await fixture.scheduler.retireRegistration(first.registeredRoot)
            for registration in registrations {
                await fixture.actor.handleWatchedFolderFSEvent(
                    .init(
                        worktreeId: registration.legacyCallbackRoutingID,
                        paths: [registration.watchedPath.path.appending(path: ".git/HEAD").path]))
            }
            _ = try await fixture.advancePacingDeadline()
            let callbacks = fixture.submissionLog.entries.filter { $0.request.cause == .callback }
            try #require(
                callbacks.count == 2, "each eligible folder gets one submission attempt, without rejection spin")
            #expect(
                callbacks.map { $0.request.sourceID } == [
                    first.registeredRoot.sourceID, second.registeredRoot.sourceID,
                ])
            #expect(callbacks.allSatisfy { $0.submittedAt == .seconds(2) })
            let start = try await fixture.scanner.nextStart(for: second.registeredRoot.sourceID)
            #expect(start.request.sourceID == second.registeredRoot.sourceID)
            let sequence = await fixture.actor.nextEnvelopeSequence + 1
            await fixture.scanner.finish(start, with: completeResult(entries: []))
            _ = try await fixture.consumeTopologyObservation(sequence: sequence)
            #expect(
                await fixture.actor.watchedFolderScanState.pacing.obligationsBySourceID[first.registeredRoot.sourceID]
                    != nil)
            #expect(
                await fixture.actor.watchedFolderScanState.pacing.obligationsBySourceID[second.registeredRoot.sourceID]
                    == nil)
        } catch {
            await fixture.shutdown()
            _ = await refresh?.value
            throw error
        }
        await fixture.shutdown()
    }
}
