import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Pane context owner-local commit invalidations")
struct PaneContextInvalidationTests {
    @Test("D52 register-token-read sees committed notices without a presentation lane")
    func committedNoticeAdvancesRuntimeGeneration() async throws {
        try await withPaneContextService { fixture, service in
            let stream = await service.invalidations(for: [fixture.paneId])
            #expect(await service.invalidationGenerations(for: [fixture.paneId]) == [fixture.paneId: 0])
            let message = fixture.message()
            try await fixture.sendCreated(message, to: service)
            #expect(await service.invalidationGenerations(for: [fixture.paneId]) == [fixture.paneId: 1])
            #expect(try await fixture.detail(service).messages.first?.id == message.messageId)
            await service.stop()
            var observed: [PaneContextSourceInvalidation] = []
            for await change in stream { observed.append(change) }
            #expect(observed == [.init(sourcePaneId: fixture.paneId, generation: 1)])
        }
    }

    @Test("D52 idempotent epoch claims and duplicate notices do not invalidate detail")
    func noOpMutationsDoNotAdvanceGeneration() async throws {
        try await withPaneContextService { fixture, service in
            let claim = UUIDv7.generate()
            _ = try await fixture.epoch(service, claimId: claim)
            let before = await service.invalidationGenerations(for: [fixture.paneId])
            let stream = await service.invalidations(for: [fixture.paneId])
            _ = try await fixture.epoch(service, claimId: claim)
            #expect(await service.invalidationGenerations(for: [fixture.paneId]) == before)
            let notice = fixture.message()
            try await fixture.sendCreated(notice, to: service)
            let after = await service.invalidationGenerations(for: [fixture.paneId])
            #expect(after[fixture.paneId] == (before[fixture.paneId] ?? 0) + 1)
            #expect(await service.send(notice) == .existing(notice.messageId))
            #expect(await service.invalidationGenerations(for: [fixture.paneId]) == after)
            await service.stop()
            var observed: [PaneContextSourceInvalidation] = []
            for await change in stream { observed.append(change) }
            #expect(observed == [.init(sourcePaneId: fixture.paneId, generation: (before[fixture.paneId] ?? 0) + 1)])
        }
    }

    private enum Fact: Equatable, Sendable {
        case downstreamEntered
        case sendEnded(PaneMessageSendResult)
    }

    @Test("D52 commit invalidation precedes a held downstream open-ask sink")
    func invalidationPrecedesDownstreamEffects() async throws {
        let fixture = try await PaneContextServiceFixture.make()
        let held = HeldStep<Void>("committed ask's downstream summary")
        let facts = FactRecorder<Int, Fact>(
            vocabulary: .init(
                describeScope: { "send \($0)" }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in if case .sendEnded = fact { true } else { false } }))
        let service = fixture.makeService(openAskSink: { _ in
            facts.append(scope: 0, fact: .downstreamEntered)
            try? await held.arrive(())
        })
        let stream = await service.invalidations(for: [fixture.paneId])
        let request = fixture.ask()
        let task = Task {
            let result = await service.send(request)
            facts.append(scope: 0, fact: .sendEnded(result))
            return result
        }
        do {
            try await facts.expectNext(in: 0, .downstreamEntered)
            #expect(await service.invalidationGenerations(for: [fixture.paneId]) == [fixture.paneId: 1])
            // Shutdown closes the real source even if a broken subject never emitted.
            await service.stop()
            var observed: [PaneContextSourceInvalidation] = []
            for await change in stream { observed.append(change) }
            #expect(observed == [.init(sourcePaneId: fixture.paneId, generation: 1)])
            held.release()
            #expect(await task.value == .created(request.messageId))
            try await facts.expectNext(in: 0, .sendEnded(.created(request.messageId)))
            try await facts.finish()
            try await fixture.removeFiles()
        } catch {
            held.retire()
            _ = await task.value
            await service.stop()
            try? await facts.finish()
            try? await fixture.removeFiles()
            throw error
        }
    }
}
