import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSharedComponents
import AgentStudioTestHarness
import Foundation
import Observation
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

@MainActor
@Suite("Binding-only popover input invalidation", .serialized)
struct PaneContextPopoverBindingRefreshTests {
    @Test("D53 real binding publication survives atom equality and changes its demanded owner capture")
    func bindingOnlyRebindReachesDemandedOwner() async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let status = SessionStatusAtom()
        let service = fixture.composition.paneContextService
        let harness = PopoverOwnerHarness(
            detail: PaneContextPopoverShapingTests.detail(paneId: fixture.ownerId),
            service: .init(epoch: UUIDv7.generate(), reader: service, invalidations: service, person: service))
        do {
            let first = try await fixture.bind(paneId: fixture.ownerId)
            let mailbox = await fixture.composition.ingestion.statusPublicationMailbox
            status.apply(mailbox.takeBatch())
            let before = try #require(status.value(for: fixture.ownerId))
            #expect(before.currentBindingId == first.bindingGenerationId)
            harness.capture.setSource(source(before), for: fixture.ownerId)
            let own = try await harness.open()
            _ = try await harness.completed(own.initialExecution)
            let otherKey = PaneContextPopoverConsumerKey(
                hostId: UUIDv7.generate(), surface: .paneMessages, paneId: fixture.drawerId)
            let other = try await harness.open(otherKey)
            _ = try await harness.completed(other.initialExecution, for: otherKey)
            let untouched = await harness.bridge.facts.mark(.init(channel: .lifetime(otherKey, other.epoch)))
            let changes = Mutex(0)
            withObservationTracking {
                _ = status.value(for: fixture.ownerId)
            } onChange: {
                changes.withLock { $0 += 1 }
            }
            let ended = try await fixture.composition.ingestion.submitHook(
                .init(
                    paneId: fixture.ownerId.uuid, providerIdentifier: first.providerIdentifier,
                    providerVersion: ClaudeCodeProviderIdentity.supportedExactVersion,
                    sessionId: first.providerConversationId, eventName: .sessionEnd, turnId: nil,
                    signal: .sessionEnd, recordId: UUIDv7.generate(), admittedAt: fixture.now,
                    chain: TestMainAgentChain.observation))
            guard case .committed(let endedCommit) = ended, endedCommit.binding.status == .ended else {
                Issue.record("The real old binding did not end: \(ended)")
                throw BindingProofFailure.oldBindingNotEnded
            }
            let rebound = try await fixture.bind(paneId: fixture.ownerId)
            try #require(rebound.bindingGenerationId != first.bindingGenerationId)
            status.apply(mailbox.takeBatch())
            let after = try #require(status.value(for: fixture.ownerId))
            try #require(before.status == after.status && before.evidence == after.evidence)
            try #require(
                before.compactPrompt == after.compactPrompt && before.promptListRevision == after.promptListRevision)
            #expect(changes.withLock { $0 } == 1, "Equal paint must not suppress a binding-only source change")
            #expect(after.currentBindingId == rebound.bindingGenerationId)
            harness.capture.setSource(source(after), for: fixture.ownerId)
            await harness.owner.receive(
                harness.capture.snapshot(for: [fixture.ownerId]), for: harness.key, opening: own.epoch)
            let timer = try await harness.timer()
            try #require(timer.deadline == harness.clock.now.advanced(by: .seconds(10)))
            harness.clock.advance(by: .seconds(10))
            await timer.task.value
            let refreshed = try #require(await harness.owner.latestExecution(for: harness.key))
            try #require(refreshed.id != own.initialExecution.id)
            _ = try await harness.completed(refreshed)
            #expect(await harness.owner.latestExecution(for: otherKey)?.id == other.initialExecution.id)
            let admitted = try #require(await harness.projections.requests.last)
            #expect(admitted.capture.sources[fixture.ownerId]?.session?.currentBindingId == rebound.bindingGenerationId)
            await harness.owner.close(otherKey)
            try await harness.bridge.facts.expectNone(
                of: { fact in if case .owner(.admitted) = fact { true } else { false } },
                "work for the unaffected drawer consumer", from: untouched, closedBy: { $0 == .owner(.retired) })
            try await harness.finish()
            try await fixture.close()
        } catch {
            try? await harness.finish()
            try? await fixture.close()
            throw error
        }
    }

    private func source(_ status: PaneAgentStatusPresentation) -> PopoverSourceCapture.Source {
        .init(structuralFacts: nil, title: "Owner", note: nil, session: status, display: nil, activity: nil)
    }
}

private enum BindingProofFailure: Error { case oldBindingNotEnded }
