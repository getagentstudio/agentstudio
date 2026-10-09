import AgentStudioCore
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal

@MainActor
@Suite("Fixture-owned Ghostty callback routing", .serialized)
struct GhosttyCallbackFixtureOwnershipTests {
    @Test("two handlers publish only their own title barrier and exact fact")
    func twoFixturesKeepTitleBarriersAndExactFactsSeparate() async throws {
        let first = OwnedGhosttyCallbackFixture()
        let second = OwnedGhosttyCallbackFixture()
        do {
            first.offerTitleAndBell("First fixture")
            second.offerTitleAndBell("Second fixture")
            await first.handler.retire()
            await second.handler.retire()

            let firstEvents = await first.events()
            let secondEvents = await second.events()
            let firstEvent = try #require(firstEvents.first)
            #expect(firstEvent == .title("First fixture"))
            #expect(firstEvents == [.title("First fixture"), .bell])
            #expect(secondEvents == [.title("Second fixture"), .bell])
            #expect(first.host.title == "First fixture")
            #expect(second.host.title == "Second fixture")
        } catch {
            await first.closeAndJoin()
            await second.closeAndJoin()
            throw error
        }
        await first.closeAndJoin()
        await second.closeAndJoin()
    }

    @Test("a missing selected runtime cannot route to another fixture's registry")
    func missingSelectedRuntimeDoesNotRouteToAnotherFixture() async {
        let sharedPaneID = PaneId.generateUUIDv7()
        let missing = OwnedGhosttyCallbackFixture(paneID: sharedPaneID)
        let available = OwnedGhosttyCallbackFixture(paneID: sharedPaneID)
        missing.registry.unregister(sharedPaneID)

        #expect(missing.handler.accept(missing.bellWork))
        await missing.handler.retire()
        #expect(await missing.events().isEmpty)
        #expect(await available.events().isEmpty)

        #expect(available.handler.accept(available.bellWork))
        await available.handler.retire()
        #expect(await available.events() == [.bell])
        await missing.closeAndJoin()
        await available.closeAndJoin()
    }

    @Test("an owned exact offer racing retirement is either delivered and joined or rejected")
    func exactOfferRacingRetirementIsDeliveredOrRejected() async throws {
        let fixture = OwnedGhosttyCallbackFixture()
        let handler = fixture.handler
        let work = fixture.bellWork
        let offerReady = HeldStep<Void>("owned callback offer reaches retirement race")
        let retireReady = HeldStep<Void>("handler retirement reaches offer race")
        do {
            let accepted = try await withThrowingTaskGroup(of: OwnedCallbackRaceResult.self) { group in
                group.addTask {
                    try await offerReady.arrive(())
                    return .offered(handler.accept(work))
                }
                group.addTask {
                    try await retireReady.arrive(())
                    await handler.retire()
                    return .retired
                }
                do {
                    _ = try await offerReady.firstArrival()
                    _ = try await retireReady.firstArrival()
                    offerReady.release()
                    retireReady.release()
                } catch {
                    offerReady.retire()
                    retireReady.retire()
                    throw error
                }
                var wasAccepted = false
                for try await result in group {
                    if case .offered(let accepted) = result { wasAccepted = accepted }
                }
                return wasAccepted
            }
            #expect(await fixture.events() == (accepted ? [.bell] : []))
            #expect(handler.taskOwner.pendingTaskCount == 0)
            #expect(!handler.accept(work))
        } catch {
            offerReady.retire()
            retireReady.retire()
            await fixture.closeAndJoin()
            throw error
        }
        offerReady.retire()
        retireReady.retire()
        await fixture.closeAndJoin()
    }

    @Test("retirement rejects later owned work and repeated retirement remains complete")
    func retirementRejectsLaterOwnedWork() async {
        let fixture = OwnedGhosttyCallbackFixture()
        #expect(fixture.handler.accept(fixture.bellWork))
        await fixture.handler.retire()
        let beforeLateWork = await fixture.events()

        #expect(!fixture.handler.accept(fixture.bellWork))
        await fixture.handler.retire()
        #expect(await fixture.events() == beforeLateWork)
        #expect(beforeLateWork == [.bell])
        await fixture.closeAndJoin()
    }
}

@MainActor
private final class OwnedGhosttyCallbackFixture {
    let registry: RuntimeRegistry
    let host: OwnedGhosttyDrainHost
    let runtime: TerminalRuntime
    let handler: Ghostty.ActionRouter
    private let reporter: RuntimeDeliveryPerformanceReporter

    init(paneID: PaneId = .generateUUIDv7()) {
        let registry = RuntimeRegistry()
        let host = OwnedGhosttyDrainHost()
        let lookup = OwnedGhosttyRoutingLookup(host: host, paneID: paneID.uuid)
        let reporter = RuntimeDeliveryPerformanceReporter()
        reporter.enable()
        let bus = EventBus<RuntimeEnvelope>(performanceReporter: reporter)
        let runtime = TerminalRuntime(
            paneId: paneID,
            metadata: PaneMetadata(paneId: paneID, contentType: .terminal, title: "Fixture"),
            paneEventBus: bus,
            performanceReporter: reporter,
            surfaceCommandDispatcher: OwnedGhosttySurfaceCommands(),
            openExternalURL: { _ in }
        )
        runtime.transitionToReady()
        registry.register(runtime)
        let routingHost = GhosttyActionRoutingHost(
            dependencies: .init(
                runtimeRegistry: registry,
                routingLookup: lookup,
                mountedHostResolver: .init(
                    surfaceForID: { id in id == host.managedSurfaceID ? host : nil },
                    paneIDForSurfaceID: { id in id == host.managedSurfaceID ? paneID.uuid : nil }
                ),
                applyNativeView: { surfaceID, viewID, _ in
                    guard surfaceID == host.managedSurfaceID, viewID == ObjectIdentifier(host) else {
                        return .dropped(.staleSurface)
                    }
                    return .applied
                },
                activityContext: { _ in nil },
                submitActivityInput: { _ in },
                startupTraceRecorder: nil,
                traceRuntime: nil
            )
        )
        self.registry = registry
        self.host = host
        self.runtime = runtime
        self.reporter = reporter
        self.handler = Ghostty.ActionRouter(host: routingHost)
    }

    var bellWork: GhosttyOwnedCallbackWork {
        .action(
            target: .surface(surfaceID: host.managedSurfaceID, viewObjectID: ObjectIdentifier(host)),
            tag: GhosttyActionTag.ringBell.rawValue,
            payload: .noPayload
        )
    }

    func offerTitleAndBell(_ title: String) {
        #expect(
            handler.accept(
                .action(
                    target: .surface(surfaceID: host.managedSurfaceID, viewObjectID: ObjectIdentifier(host)),
                    tag: GhosttyActionTag.setTitle.rawValue,
                    payload: .titleChanged(title)
                )
            )
        )
        #expect(handler.accept(bellWork))
    }

    func events() async -> [OwnedGhosttyObservedEvent] {
        let replay = await runtime.eventsSince(seq: 0)
        return RuntimeEnvelopeHarness.paneEvents(from: replay.events).map { envelope in
            switch envelope.event {
            case .terminal(.titleChanged(let title)): .title(title)
            case .terminal(.bellRang): .bell
            default: .unexpected
            }
        }
    }

    func closeAndJoin() async {
        await handler.retire()
        _ = await runtime.shutdown(timeout: .seconds(1))
        await runtime.finishAndJoinOutboundDelivery()
        #expect(reporter.snapshot().runtimeChannelOutboundPendingCount == 0)
    }
}

@MainActor
private final class OwnedGhosttyDrainHost: TerminalLocalActionDrainHost {
    let managedSurfaceID = UUIDv7.generate()
    var hostScrollbarState: ScrollbarState?
    var title = ""
    let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil

    func updateHostScrollbarState(_ state: ScrollbarState) {
        hostScrollbarState = state
    }

    func titleDidChange(_ title: String) {
        self.title = title
    }
}

@MainActor
private final class OwnedGhosttyRoutingLookup: GhosttyActionRoutingLookup {
    private let host: OwnedGhosttyDrainHost
    private let paneID: UUID

    init(host: OwnedGhosttyDrainHost, paneID: UUID) {
        self.host = host
        self.paneID = paneID
    }

    func surfaceId(forViewObjectId viewObjectId: ObjectIdentifier) -> UUID? {
        viewObjectId == ObjectIdentifier(host) ? host.managedSurfaceID : nil
    }

    func paneId(for surfaceId: UUID) -> UUID? {
        surfaceId == host.managedSurfaceID ? paneID : nil
    }
}

@MainActor
private final class OwnedGhosttySurfaceCommands: TerminalSurfaceCommandDispatching {
    func sendInput(_: String, toPaneId _: UUID) -> Result<Void, SurfaceError> { .success(()) }
    func clearScrollback(forPaneId _: UUID) -> Result<Void, SurfaceError> { .success(()) }
    func scrollToBottom(forPaneId _: UUID) -> Result<Void, SurfaceError> { .success(()) }
    func scrollPageFractional(fraction _: Double, forPaneId _: UUID) -> Result<Void, SurfaceError> { .success(()) }
    func jumpToPrompt(delta _: Int, forPaneId _: UUID) -> Result<Void, SurfaceError> { .success(()) }
}

private enum OwnedGhosttyObservedEvent: Sendable, Equatable {
    case title(String)
    case bell
    case unexpected
}

private enum OwnedCallbackRaceResult: Sendable {
    case offered(Bool)
    case retired
}
