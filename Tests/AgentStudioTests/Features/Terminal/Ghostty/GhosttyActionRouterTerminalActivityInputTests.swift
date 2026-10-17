import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioTerminal

@MainActor
@Suite("Terminal activity router readiness", .serialized)
struct GhosttyActivityInputBindingRestorePhaseTests {
    private func makeRouter(projector: TerminalActivityProjector = TerminalActivityProjector())
        -> TerminalActivityRouter
    {
        TerminalActivityRouter(
            bus: EventBus<RuntimeEnvelope>(), activityAtom: TerminalActivityAtom(),
            callbackHandlingAccess: { nil }, projector: projector,
            surfaceIDForPaneID: { _ in nil }, lastOutputLineReader: { _ in .surfaceStale })
    }

    @Test("awaitBound resumes only after start publishes readiness")
    func awaitBoundResumesOnlyAfterBind() async throws {
        let router = makeRouter()
        let source = LocalFactSource(vocabulary: waiterRegistrationFactVocabulary())
        let facts = try source.attach()
        var events: [String] = []
        let waiter = Task { @MainActor in
            defer { source.end() }
            await router.awaitSourceInputReady(onWaiterRegistered: { source.sink("router", .waiterRegistered) })
            events.append("resumed")
        }
        do {
            try await facts.expectNext(in: "router", .waiterRegistered)
            events.append("before-start")
            #expect(router.sourceInputContext(paneID: UUIDv7.generate()) == nil)
            await router.start()
            await waiter.value
            #expect(events == ["before-start", "resumed"])
            await router.stop()
            try await facts.finish()
        } catch {
            waiter.cancel()
            await waiter.value
            await router.stop()
            throw error
        }
    }

    @Test("an already-started router returns immediately without registering a waiter")
    func alreadyBoundReturnsImmediately() async {
        let router = makeRouter()
        await router.start()
        await router.awaitSourceInputReady(onWaiterRegistered: { Issue.record("ready router registered a waiter") })
        #expect(router.sourceInputContext(paneID: UUIDv7.generate()) != nil)
        await router.stop()
    }

    @Test("a cancelled wait resumes without ever starting the router")
    func cancelledWaitResumesWithoutBinding() async throws {
        let router = makeRouter()
        let source = LocalFactSource(vocabulary: waiterRegistrationFactVocabulary())
        let facts = try source.attach()
        let waiter = Task { @MainActor in
            defer { source.end() }
            await router.awaitSourceInputReady(onWaiterRegistered: { source.sink("router", .waiterRegistered) })
        }
        do {
            try await facts.expectNext(in: "router", .waiterRegistered)
            waiter.cancel()
            await waiter.value
            #expect(router.sourceInputContext(paneID: UUIDv7.generate()) == nil)
            try await facts.finish()
        } catch {
            waiter.cancel()
            await waiter.value
            throw error
        }
    }

    @Test("cancellation before registration returns projectorUnbound and never arms")
    func cancellationBeforeRegistrationDoesNotArm() async {
        let projector = TerminalActivityProjector()
        let router = makeRouter(projector: projector)
        let paneID = UUIDv7.generate()
        let task = Task { @MainActor in
            await router.armRestorePhase(paneID: paneID, restoreGeneration: .init(rawValue: 3))
        }
        task.cancel()
        #expect(await task.value == .projectorUnbound)
        #expect(await projector.restorePhaseGenerationsByPane[paneID] == nil)
    }
}

@MainActor
@Suite("Terminal activity router restore-phase arming", .serialized)
struct GhosttyActionRouterRestorePhaseArmingTests {
    @Test("arming an already-started router reaches its projector and returns armed")
    func armingAnAlreadyBoundRouterSubmitsAndAcknowledges() async {
        let projector = TerminalActivityProjector()
        let router = TerminalActivityRouter(
            bus: EventBus<RuntimeEnvelope>(), activityAtom: TerminalActivityAtom(),
            callbackHandlingAccess: { nil }, projector: projector,
            surfaceIDForPaneID: { _ in nil }, lastOutputLineReader: { _ in .surfaceStale })
        let paneID = UUIDv7.generate()
        let generation = RestoreGeneration(rawValue: 42)
        await router.start()
        let acknowledgment = await router.armRestorePhase(paneID: paneID, restoreGeneration: generation)
        #expect(acknowledgment == .armed)
        #expect(await projector.restorePhaseGenerationsByPane[paneID] == generation)
        await router.stop()
    }

    @Test("arming before readiness waits, then arms the same injected projector")
    func armingBeforeReadinessWaitsThenArms() async throws {
        let projector = TerminalActivityProjector()
        let router = TerminalActivityRouter(
            bus: EventBus<RuntimeEnvelope>(), activityAtom: TerminalActivityAtom(),
            callbackHandlingAccess: { nil }, projector: projector,
            surfaceIDForPaneID: { _ in nil }, lastOutputLineReader: { _ in .surfaceStale })
        let source = LocalFactSource(vocabulary: waiterRegistrationFactVocabulary())
        let facts = try source.attach()
        let paneID = UUIDv7.generate()
        let generation = RestoreGeneration(rawValue: 43)
        let arming = Task { @MainActor in
            defer { source.end() }
            return await router.armRestorePhase(
                paneID: paneID, restoreGeneration: generation,
                onWaiterRegistered: { source.sink("router", .waiterRegistered) })
        }
        do {
            try await facts.expectNext(in: "router", .waiterRegistered)
            #expect(await projector.restorePhaseGenerationsByPane[paneID] == nil)
            await router.start()
            #expect(await arming.value == .armed)
            #expect(await projector.restorePhaseGenerationsByPane[paneID] == generation)
            await router.stop()
            try await facts.finish()
        } catch {
            arming.cancel()
            _ = await arming.value
            await router.stop()
            throw error
        }
    }

    @Test("stopping before readiness releases arming with projectorUnbound")
    func stopBeforeReadinessDoesNotLeaveArmingPending() async throws {
        let projector = TerminalActivityProjector()
        let router = TerminalActivityRouter(
            bus: EventBus<RuntimeEnvelope>(), activityAtom: TerminalActivityAtom(),
            callbackHandlingAccess: { nil }, projector: projector,
            surfaceIDForPaneID: { _ in nil }, lastOutputLineReader: { _ in .surfaceStale })
        let source = LocalFactSource(vocabulary: waiterRegistrationFactVocabulary())
        let facts = try source.attach()
        let paneID = UUIDv7.generate()
        let arming = Task { @MainActor in
            defer { source.end() }
            return await router.armRestorePhase(
                paneID: paneID, restoreGeneration: .init(rawValue: 44),
                onWaiterRegistered: { source.sink("router", .waiterRegistered) })
        }
        do {
            try await facts.expectNext(in: "router", .waiterRegistered)
            await router.stop()
            #expect(await arming.value == .projectorUnbound)
            #expect(await projector.restorePhaseGenerationsByPane[paneID] == nil)
            try await facts.finish()
        } catch {
            arming.cancel()
            _ = await arming.value
            await router.stop()
            throw error
        }
    }

}

private enum WaiterRegistrationFact: Equatable, Sendable {
    case waiterRegistered
}

private func waiterRegistrationFactVocabulary() -> FactVocabulary<String, WaiterRegistrationFact> {
    FactVocabulary(describeScope: { $0 }, describeFact: { String(describing: $0) }, isClosing: { _, _ in true })
}
