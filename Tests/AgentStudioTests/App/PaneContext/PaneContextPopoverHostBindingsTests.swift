import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

@MainActor
@Suite("Popover host lifetime and canonical wiring", .serialized)
struct PaneContextPopoverHostBindingsTests {
    @Test("S4 a real equal-paint rebind automatically reaches only its demanded family slot")
    func realBindingFlowsThroughAutomaticCaptureAndFamily() async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let status = SessionStatusAtom()
        let bridge = PopoverOwnerFactBridge()
        let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
        let time = PaneContextTestTime(clock: clock)
        let adapter = PaneContextUIAdapter(service: fixture.composition.paneContextService)
        let bindings = PaneContextPopoverHostBindings(
            clock: clock, wallNow: { time.now },
            readSource: { pane in
                .init(
                    structuralFacts: nil, title: "Owner", note: nil,
                    session: status.value(for: pane), display: fixture.presentationAtom.value(for: pane), activity: nil)
            },
            serviceProvider: { adapter }, observe: bridge.observe)
        let ownKey = key(fixture.ownerId)
        let otherKey = key(fixture.drawerId)
        do {
            let first = try await fixture.bind(paneId: fixture.ownerId)
            let mailbox = await fixture.composition.ingestion.statusPublicationMailbox
            status.apply(mailbox.takeBatch())
            let before = try #require(status.value(for: fixture.ownerId))
            let own = try #require(await bindings.beginOpen(ownKey, demand: demand).value)
            try await consume(own, bridge: bridge)
            let other = try #require(await bindings.beginOpen(otherKey, demand: demand).value)
            try await consume(other, bridge: bridge)
            let originalValue = try #require(own.atom.value)
            let untouched = await bridge.facts.mark(.init(channel: .lifetime(otherKey, other.opening.epoch)))
            let ended = try await fixture.composition.ingestion.submitHook(
                .init(
                    paneId: fixture.ownerId.uuid, providerIdentifier: first.providerIdentifier,
                    providerVersion: ClaudeCodeProviderIdentity.supportedExactVersion,
                    sessionId: first.providerConversationId, eventName: .sessionEnd, turnId: nil,
                    signal: .sessionEnd, recordId: UUIDv7.generate(), admittedAt: fixture.now,
                    chain: TestMainAgentChain.observation))
            guard case .committed(let end) = ended, end.binding.status == .ended else {
                throw ProofFailure.bindingNotEnded
            }
            let nextBinding = try await fixture.bind(paneId: fixture.ownerId)
            try #require(nextBinding.bindingGenerationId != first.bindingGenerationId)
            status.apply(mailbox.takeBatch())
            let after = try #require(status.value(for: fixture.ownerId))
            try #require(before.status == after.status && before.evidence == after.evidence)
            try #require(
                before.compactPrompt == after.compactPrompt && before.promptListRevision == after.promptListRevision)
            #expect(after.currentBindingId == nextBinding.bindingGenerationId)
            let forwarding = bindings.inputs.forwardingTasks(for: ownKey, opening: own.opening.epoch)
            try #require(!forwarding.isEmpty, "The real binding publication did not wake its registered capture")
            for producer in forwarding { await producer.value }
            let wake = try #require(await bindings.owner.scheduledWakeProducer())
            let scope = PopoverOwnerProofScope(channel: .owner(.deadline(wake.sequence)))
            try await bridge.facts.expectNext(in: scope, .owner(.deadlineArmed))
            try await bridge.facts.expectNext(in: scope, .clockRegistered(clock.now.advanced(by: .seconds(10))))
            clock.advance(by: .seconds(10))
            await wake.task.value
            let refreshed = try #require(await bindings.owner.latestExecution(for: ownKey))
            try #require(refreshed.id != own.opening.initialExecution.id)
            await refreshed.task.value
            #expect(own.atom.value === originalValue)
            #expect(own.atom.latestAcceptedValue?.shape?.revision != originalValue.shape?.revision)
            #expect(await bindings.owner.latestExecution(for: otherKey)?.id == other.opening.initialExecution.id)
            await bindings.beginClose(otherKey).value
            try await bridge.facts.expectNone(
                of: { fact in if case .admitted? = fact.ownerFact { true } else { false } },
                "work for the unrelated demanded drawer", from: untouched, closedBy: { $0 == .owner(.retired) })
            await bindings.stop()
            #expect(clock.pendingSleepCount == 0)
            bridge.facts.receive(.ended)
            try await bridge.facts.finish()
            try await fixture.close()
        } catch {
            await bindings.stop()
            bridge.facts.receive(.ended)
            try? await bridge.facts.finish()
            try? await fixture.close()
            throw error
        }
    }

    @Test("S4 rapid open-close-open joins the old lifetime before reusing its host key")
    func setupAndCloseChainsPreserveTheNewestOpening() async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let clock = TestPushClock()
        let time = PaneContextTestTime(clock: clock)
        let adapter = PaneContextUIAdapter(service: fixture.composition.paneContextService)
        let bindings = PaneContextPopoverHostBindings(
            clock: clock, wallNow: { time.now },
            readSource: { _ in
                .init(structuralFacts: nil, title: "Owner", note: nil, session: nil, display: nil, activity: nil)
            },
            serviceProvider: { adapter })
        let key = key(fixture.ownerId)
        do {
            let obsolete = bindings.beginOpen(key, demand: demand)
            let second = bindings.beginOpen(key, demand: demand)
            #expect(await obsolete.value == nil)
            let old = try #require(await second.value)
            await old.opening.initialExecution.task.value
            let replacement = try #require(await bindings.beginOpen(key, demand: demand).value)
            await replacement.opening.initialExecution.task.value
            #expect(replacement.atom !== old.atom)
            #expect(old.atom.freshness == .stopped)
            #expect(replacement.atom.freshness != .stopped)
            #expect(replacement.atom.value != nil)
            let closing = bindings.beginClose(key)
            let opening = bindings.beginOpen(key, demand: demand)
            let current = try #require(await opening.value)
            await closing.value
            await current.opening.initialExecution.task.value
            #expect(current.opening.epoch != replacement.opening.epoch)
            #expect(current.atom !== replacement.atom)
            #expect(replacement.atom.freshness == .stopped)
            #expect(current.atom.value != nil)
            #expect(current.atom.freshness != .stopped)
            await bindings.beginClose(key).value
            #expect(current.atom.freshness == .stopped)
            await bindings.stop()
            #expect(clock.pendingSleepCount == 0)
            try await fixture.close()
        } catch {
            await bindings.stop()
            try? await fixture.close()
            throw error
        }
    }

    @Test("S4 a compact card age tick reuses its live identity and performs no detail read")
    func compactCardAgeReusesIdentityRead() async throws {
        let pane = PaneId.generateUUIDv7()
        let ports = PaneContextPopoverTestPorts(PaneContextPopoverShapingTests.detail(paneId: pane))
        let invalidations = PopoverOwnerInvalidationPorts()
        let reads = IdentityReads()
        let adapter = PaneContextUIAdapter(
            reader: ports, person: ports, invalidations: invalidations,
            readLiveSession: { pane in
                await reads.read(pane)
                return nil
            })
        let bridge = PopoverOwnerFactBridge()
        let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
        let time = PaneContextTestTime(clock: clock)
        let activity = PaneActivityTime(orderingInstant: ContinuousClock.now, wallTime: time.now, source: .terminal)
        let bindings = PaneContextPopoverHostBindings(
            clock: clock, wallNow: { time.now },
            readSource: { _ in
                .init(structuralFacts: nil, title: "Owner", note: nil, session: nil, display: nil, activity: activity)
            },
            serviceProvider: { adapter }, observe: bridge.observe)
        let key = key(pane)
        do {
            let handle = try #require(
                await bindings.beginOpen(
                    key,
                    demand: .init(
                        content: .card, location: .card, includingDrawers: true, screenVisibleWidth: 1400)
                ).value)
            await handle.opening.initialExecution.task.value
            #expect(handle.atom.value?.card?.activityText == "Now")
            #expect(await reads.panes == [pane])
            let wake = try #require(await bindings.owner.scheduledWakeProducer())
            let scope = PopoverOwnerProofScope(channel: .owner(.deadline(wake.sequence)))
            try await bridge.facts.expectNext(in: scope, .owner(.deadlineArmed))
            try await bridge.facts.expectNext(in: scope, .clockRegistered(clock.now.advanced(by: .seconds(60))))
            clock.advance(by: .seconds(60))
            await wake.task.value
            let tick = try #require(await bindings.owner.latestExecution(for: key))
            try #require(tick.id != handle.opening.initialExecution.id)
            await tick.task.value
            #expect(handle.atom.value?.card?.activityText == "1 min ago")
            #expect(await reads.panes == [pane])
            #expect(await ports.requests.isEmpty)
            await bindings.stop()
            await invalidations.finish()
            try await ports.finish()
            bridge.facts.receive(.ended)
            try await bridge.facts.finish()
        } catch {
            await bindings.stop()
            await invalidations.finish()
            try? await ports.finish()
            bridge.facts.receive(.ended)
            try? await bridge.facts.finish()
            throw error
        }
    }

    @Test("S4 services resolve only at consumer and explicit service boundaries")
    func serviceResolutionIsLazyAndNotRepeatedByCapture() async throws {
        let pane = PaneId.generateUUIDv7()
        let ports = PaneContextPopoverTestPorts(PaneContextPopoverShapingTests.detail(paneId: pane))
        let invalidations = PopoverOwnerInvalidationPorts()
        let adapter = PaneContextUIAdapter(reader: ports, person: ports, invalidations: invalidations)
        let clock = TestPushClock()
        let time = PaneContextTestTime(clock: clock)
        var resolutions = 0
        let bindings = PaneContextPopoverHostBindings(
            clock: clock, wallNow: { time.now },
            readSource: { _ in
                .init(structuralFacts: nil, title: "Owner", note: nil, session: nil, display: nil, activity: nil)
            },
            serviceProvider: {
                resolutions += 1
                return adapter
            })
        let key = key(pane)
        do {
            #expect(resolutions == 0)
            let handle = try #require(await bindings.beginOpen(key, demand: demand).value)
            await handle.opening.initialExecution.task.value
            #expect(resolutions == 1)
            await bindings.owner.refreshImmediately(key, opening: handle.opening.epoch)
            let refresh = try #require(await bindings.owner.latestExecution(for: key))
            try #require(refresh.id != handle.opening.initialExecution.id)
            await refresh.task.value
            #expect(resolutions == 1)
            await bindings.serviceDidChange().value
            #expect(resolutions == 2)
            _ = await bindings.performPerson(.dismissAllNotices, handle: handle)
            #expect(resolutions == 3)
            await bindings.stop()
            await invalidations.finish()
            try await ports.finish()
        } catch {
            await bindings.stop()
            await invalidations.finish()
            try? await ports.finish()
            throw error
        }
    }

    private actor IdentityReads {
        private(set) var panes: [PaneId] = []
        func read(_ pane: PaneId) { panes.append(pane) }
    }

    private func consume(_ handle: PaneContextPopoverConsumerHandle, bridge: PopoverOwnerFactBridge) async throws {
        let execution = handle.opening.initialExecution
        await execution.task.value
        try #require(
            bridge.didFinish(.execution(handle.key, execution.id)),
            "The initial producer ended without its terminal fact")
        let scope = PopoverOwnerProofScope(channel: .owner(.execution(handle.key, execution.id)))
        while true {
            let fact = try await bridge.facts.expectNext(
                in: scope, where: { _ in true }, "the initial producer's terminal fact")
            if case .owner(.finished(let outcome)) = fact {
                try #require(
                    outcome == .published || outcome == .equal,
                    "The actual initial producer must publish or confirm its current family value")
                try await bridge.acknowledgeLifetime(execution, key: handle.key)
                return
            }
        }
    }

    private func key(_ pane: PaneId) -> PaneContextPopoverConsumerKey {
        .init(hostId: UUIDv7.generate(), surface: .paneMessages, paneId: pane)
    }
    private var demand: PaneContextPopoverDemand {
        .init(content: .messages(.top), location: .pane, includingDrawers: true, screenVisibleWidth: 1400)
    }
    private enum ProofFailure: Error { case bindingNotEnded }
}
