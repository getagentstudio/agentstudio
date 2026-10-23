import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import AppKit
import Foundation
import Synchronization
import Testing

@testable import AgentStudioTerminal

@MainActor
@Suite("Ghostty resumed start ordered phase end", .serialized)
struct GhosttyRouterResumedSessionStartEndTests {
    @Test(
        "a matched start alone and racing person input follow the held restore drain",
        arguments: ResumedStartInputOrder.allCases)
    func matchedStartFollowsInFlightRestoreDrain(inputOrder: ResumedStartInputOrder) async throws {
        let source = LocalFactSource<UUID, ResumedStartDrainFact>(
            vocabulary: .init(
                describeScope: { $0.uuidString }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in fact == .drainsJoined }))
        let facts = try source.attach()
        let hold = HeldStep<Void>("restore aggregate at the actual host's projector submission")
        let projector = TerminalActivityProjector(clock: TestPushClock())
        let forwarder = ResumedStartDrainForwarder(projector: projector, hold: hold, source: source)
        var configuration = GhosttyActionRouterTestFixtureConfiguration()
        configuration.registerRuntime = false
        configuration.activityProjectionContext = .init(
            isAttended: false, isAgentClassified: false, outputBurstThreshold: 30)
        configuration.activityInputObserved = { [weak forwarder] input in await forwarder?.consume(input) }
        try await withGhosttyActionRouterTestFixture(configuration: configuration) { fixture in
            let lookups = Mutex(0)
            let router = TerminalActivityRouter(
                bus: EventBus<RuntimeEnvelope>(), activityAtom: TerminalActivityAtom(),
                callbackHandlingAccess: { [weak fixture] in fixture?.handler }, projector: projector,
                surfaceIDForPaneID: { pane in
                    lookups.withLock { $0 += 1 }
                    return pane == fixture.paneUUID ? fixture.surfaceID : nil
                }, lastOutputLineReader: { _ in .surfaceStale })
            let generation = RestoreGeneration(rawValue: 21)
            let session = UUIDv7.generate().uuidString
            let invocation = ResumeInvocation(provider: .codex, sessionId: try .init(rawValue: session))
            forwarder.router = router
            await router.start()
            _ = await router.armRestorePhase(
                paneID: fixture.paneUUID, restoreGeneration: generation, resumeInvocation: invocation)
            fixture.handler.localActionAccumulator.offer(
                .scrollbar(.init(top: 0, bottom: 100, total: 100), observedAtMilliseconds: 1000),
                for: fixture.surfaceID)
            // Own the first drain's handle. The cancelled automatic claim is
            // never allowed to race this forced, real host suspension point.
            fixture.handler.localActionDrainScheduler.cancel(for: fixture.surfaceID)
            let firstDrain = Task { @MainActor in
                await fixture.handler.host.drainLocalActions(
                    for: fixture.surfaceID, lane: .immediate, accumulator: fixture.handler.localActionAccumulator)
            }
            let completion = Task { @MainActor in
                defer {
                    source.end()
                    hold.retire()
                }
                await firstDrain.value
                // finishDrain schedules its real follow-up before returning.
                // Close ingress, join every admitted drain, then announce the
                // producer end even when the required follow-up was missing.
                let snapshot = fixture.handler.taskOwner.closeAdmissionAndSnapshot()
                await snapshot.joinAdmittedTasks()
                source.sink(fixture.paneUUID, .drainsJoined)
            }
            do {
                _ = try await hold.firstArrival()
                let surface = Ghostty.SurfaceView(
                    managedSurfaceID: fixture.surfaceID, appCommandDispatcher: ResumedStartCommandDispatcher(),
                    callbackHandling: fixture.handler)
                surface.restorePhaseLatch = generation
                if inputOrder == .personFirst { surface.paste(nil) }
                let sink = router.resumedSessionStartSink
                await sink(fixture.paneUUID, "codex", session)
                await sink(fixture.paneUUID, "codex", session)
                if inputOrder == .startFirst { surface.paste(nil) }
                if inputOrder != .startOnly { #expect(surface.restorePhaseLatch == nil) }
                #expect(lookups.withLock { $0 } == 1)
                #expect(await projector.isRestorePhaseActive(paneID: fixture.paneUUID))
                hold.release()
                try await facts.expectNext(in: fixture.paneUUID, .aggregateApplied(whileRestoring: true))
                try await facts.expectNext(in: fixture.paneUUID, .phaseEnded(generation))
                try await facts.expectNext(in: fixture.paneUUID, .drainsJoined)
                await completion.value
                #expect(!(await projector.isRestorePhaseActive(paneID: fixture.paneUUID)))
                #expect(await projector.scheduledTimerCount == 0)
                try await facts.finish()
                await router.stop()
                await projector.reset()
            } catch {
                hold.retire()
                await firstDrain.value
                await completion.value
                await router.stop()
                await projector.reset()
                throw error
            }
            forwarder.router = nil
        }
    }
    @Test(
        "key release, modifier-only changes and composing text keep the cold phase",
        arguments: NonCommittingRestoreInput.allCases)
    func nonCommittingInputPreservesRestorePhase(input: NonCommittingRestoreInput) async throws {
        let source = LocalFactSource<UUID, ResumedStartDrainFact>(
            vocabulary: .init(
                describeScope: { $0.uuidString }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in fact == .drainsJoined }))
        let facts = try source.attach()
        let projector = TerminalActivityProjector(clock: TestPushClock())
        let forwarder = ResumedStartDrainForwarder(projector: projector, hold: nil, source: source)
        var configuration = GhosttyActionRouterTestFixtureConfiguration()
        configuration.registerRuntime = false
        configuration.activityInputObserved = { [weak forwarder] value in await forwarder?.consume(value) }
        try await withGhosttyActionRouterTestFixture(configuration: configuration) { fixture in
            let router = TerminalActivityRouter(
                bus: EventBus<RuntimeEnvelope>(), activityAtom: TerminalActivityAtom(),
                callbackHandlingAccess: { [weak fixture] in fixture?.handler }, projector: projector,
                surfaceIDForPaneID: { _ in fixture.surfaceID }, lastOutputLineReader: { _ in .surfaceStale })
            forwarder.router = router
            await router.start()
            let generation = RestoreGeneration(rawValue: 31)
            _ = await router.armRestorePhase(paneID: fixture.paneUUID, restoreGeneration: generation)
            let surface = Ghostty.SurfaceView(
                managedSurfaceID: fixture.surfaceID, appCommandDispatcher: ResumedStartCommandDispatcher(),
                callbackHandling: fixture.handler)
            surface.restorePhaseLatch = generation
            do {
                let opening = await facts.mark(fixture.paneUUID)
                switch input {
                case .keyRelease:
                    let event = try #require(
                        NSEvent.keyEvent(
                            with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false,
                            keyCode: 0))
                    surface.keyUp(with: event)
                case .modifierOnly:
                    let modifierEvent = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0x37, keyDown: true))
                    modifierEvent.type = .flagsChanged
                    modifierEvent.flags = .maskCommand
                    surface.flagsChanged(with: try #require(NSEvent(cgEvent: modifierEvent)))
                case .composingText:
                    surface.setMarkedText(
                        "composing", selectedRange: .init(location: 0, length: 0),
                        replacementRange: .init(location: NSNotFound, length: 0))
                }
                #expect(surface.restorePhaseLatch == generation)
                let completed = fixture.handler.taskOwner.closeAdmissionAndSnapshot()
                await completed.joinAdmittedTasks()
                source.sink(fixture.paneUUID, .drainsJoined)
                source.end()
                try await facts.expectNone(
                    of: { if case .phaseEnded = $0 { true } else { false } }, "phase end from non-committing input",
                    from: opening, closedBy: { $0 == .drainsJoined })
                #expect(await projector.isRestorePhaseActive(paneID: fixture.paneUUID))
                #expect(await projector.scheduledTimerCount == 0)
                try await facts.finish()
                await router.stop()
                await projector.reset()
            } catch {
                source.end()
                await router.stop()
                await projector.reset()
                throw error
            }
            forwarder.router = nil
        }
    }
    @Test("a match retained across rearm cannot consume the next phase's first input")
    func staleMatchedEndCannotMaskNextGenerationInput() async throws {
        let source = LocalFactSource<UUID, ResumedStartDrainFact>(
            vocabulary: .init(
                describeScope: { $0.uuidString }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in fact == .drainsJoined }))
        let facts = try source.attach()
        let projector = TerminalActivityProjector(clock: TestPushClock())
        let forwarder = ResumedStartDrainForwarder(projector: projector, hold: nil, source: source)
        var configuration = GhosttyActionRouterTestFixtureConfiguration()
        configuration.registerRuntime = false
        configuration.activityInputObserved = { [weak forwarder] value in await forwarder?.consume(value) }
        try await withGhosttyActionRouterTestFixture(configuration: configuration) { fixture in
            let router = TerminalActivityRouter(
                bus: EventBus<RuntimeEnvelope>(), activityAtom: TerminalActivityAtom(),
                callbackHandlingAccess: { [weak fixture] in fixture?.handler }, projector: projector,
                surfaceIDForPaneID: { _ in fixture.surfaceID }, lastOutputLineReader: { _ in .surfaceStale })
            let session = UUIDv7.generate().uuidString
            let invocation = ResumeInvocation(provider: .codex, sessionId: try .init(rawValue: session))
            forwarder.router = router
            await router.start()
            do {
                _ = await router.armRestorePhase(
                    paneID: fixture.paneUUID, restoreGeneration: .init(rawValue: 1), resumeInvocation: invocation)
                let matched = try #require(
                    await projector.claimMatchingResumeRestoreGeneration(
                        paneID: fixture.paneUUID, providerIdentifier: "codex", providerSessionID: session))
                // Retain the actual match as an actor-to-MainActor message,
                // then advance the owner before delivering that old message.
                let current = RestoreGeneration(rawValue: 2)
                _ = await router.armRestorePhase(paneID: fixture.paneUUID, restoreGeneration: current)
                let surface = Ghostty.SurfaceView(
                    managedSurfaceID: fixture.surfaceID, appCommandDispatcher: ResumedStartCommandDispatcher(),
                    callbackHandling: fixture.handler)
                surface.restorePhaseLatch = current
                let opening = await facts.mark(fixture.paneUUID)
                _ = matched.withCurrentGeneration { generation in
                    fixture.handler.localActionAccumulator.markRestorePhaseEnded(
                        surfaceID: fixture.surfaceID, generation: generation,
                        contextBeforeControl: configuration.activityProjectionContext)
                }
                surface.paste(nil)
                #expect(surface.restorePhaseLatch == nil)
                let completed = fixture.handler.taskOwner.closeAdmissionAndSnapshot()
                await completed.joinAdmittedTasks()
                source.sink(fixture.paneUUID, .drainsJoined)
                source.end()
                #expect(!(await projector.isRestorePhaseActive(paneID: fixture.paneUUID)))
                try await facts.expectNone(
                    of: { $0 == .phaseEnded(.init(rawValue: 1)) }, "old matched end after rearm",
                    from: opening, closedBy: { $0 == .drainsJoined })
                try await facts.finish()
                await router.stop()
                await projector.reset()
            } catch {
                source.end()
                await router.stop()
                await projector.reset()
                throw error
            }
            forwarder.router = nil
        }
    }

}

private enum ResumedStartDrainFact: Equatable, Sendable {
    case aggregateApplied(whileRestoring: Bool)
    case phaseEnded(RestoreGeneration)
    case drainsJoined
}

@MainActor
private final class ResumedStartDrainForwarder {
    let projector: TerminalActivityProjector
    let hold: HeldStep<Void>?
    let source: LocalFactSource<UUID, ResumedStartDrainFact>
    var router: TerminalActivityRouter?

    init(
        projector: TerminalActivityProjector, hold: HeldStep<Void>?,
        source: LocalFactSource<UUID, ResumedStartDrainFact>
    ) {
        self.projector = projector
        self.hold = hold
        self.source = source
    }

    func consume(_ input: TerminalActivitySourceInput) async {
        switch input {
        case .aggregate(_, let pane, _):
            if let hold {
                do { try await hold.arrive(()) } catch { return }
            }
            let suppressed = await projector.isRestorePhaseActive(paneID: pane)
            await router?.consumeSourceInputIfAccepting(input)
            source.sink(pane, .aggregateApplied(whileRestoring: suppressed))
        case .orderedControl(_, let pane, _, .restorePhaseEnded(let generation)):
            await router?.consumeSourceInputIfAccepting(input)
            source.sink(pane, .phaseEnded(generation))
        default: await router?.consumeSourceInputIfAccepting(input)
        }
    }
}

@MainActor
private final class ResumedStartCommandDispatcher: AppCommandDispatching {
    func dispatchKeyboardShortcut(_: AppShortcut) {}
    func dispatchExtractPaneToTab(tabId _: UUID, paneId _: UUID, targetTabInsertionIndex _: Int?) {}
    func dispatch(_: AppCommand) -> Bool { false }
    func dispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) {}
    func canDispatch(_: AppCommand) -> Bool { false }
    func canDispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool { false }
    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? { nil }
    func dispatchMovePaneToTab(sourcePaneId _: UUID, sourceTabId _: UUID?, targetTabId _: UUID) {}
}

enum ResumedStartInputOrder: CaseIterable, Sendable { case startOnly, personFirst, startFirst }

enum NonCommittingRestoreInput: CaseIterable, Sendable { case keyRelease, modifierOnly, composingText }
