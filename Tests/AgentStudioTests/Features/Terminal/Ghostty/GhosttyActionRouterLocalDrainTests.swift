import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudioTerminal

@MainActor
private final class FakeTerminalLocalActionDrainHost: TerminalLocalActionDrainHost {
    let managedSurfaceID: UUID
    private(set) var hostScrollbarState: ScrollbarState?
    private(set) var title = ""
    var performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?
    var onScrollbarStateChanged: (@MainActor (ScrollbarState) -> Void)?

    init(managedSurfaceID: UUID) {
        self.managedSurfaceID = managedSurfaceID
    }

    func updateHostScrollbarState(_ state: ScrollbarState) {
        hostScrollbarState = state
        onScrollbarStateChanged?(state)
    }

    func titleDidChange(_ title: String) {
        self.title = title
    }
}

@MainActor
private final class TerminalActivityInputRecorder {
    private(set) var inputs: [TerminalActivitySourceInput] = []

    func record(_ input: TerminalActivitySourceInput) {
        inputs.append(input)
    }
}

@MainActor
private final class ExactControlOrderRecorder {
    private(set) var inputs: [TerminalActivitySourceInput] = []
    private(set) var runtimeWasEmptyAtInput = false

    func record(_ input: TerminalActivitySourceInput, runtimeWasEmpty: Bool) {
        inputs.append(input)
        runtimeWasEmptyAtInput = runtimeWasEmpty
    }
}

@MainActor
private final class LocalDrainRoutingLookup: GhosttyActionRoutingLookup {
    private let surfaceIDsByViewObjectID: [ObjectIdentifier: UUID]
    private let paneIDsBySurfaceID: [UUID: UUID]

    init(
        surfaceIDsByViewObjectID: [ObjectIdentifier: UUID],
        paneIDsBySurfaceID: [UUID: UUID]
    ) {
        self.surfaceIDsByViewObjectID = surfaceIDsByViewObjectID
        self.paneIDsBySurfaceID = paneIDsBySurfaceID
    }

    func surfaceId(forViewObjectId viewObjectId: ObjectIdentifier) -> UUID? {
        surfaceIDsByViewObjectID[viewObjectId]
    }

    func paneId(for surfaceId: UUID) -> UUID? {
        paneIDsBySurfaceID[surfaceId]
    }
}

extension GhosttyActionRouterTests {
    @Test("commandFinished reaches ordered activity input before the ordinary runtime fact")
    func commandFinishedReachesOrderedInputBeforeRuntimeFact() async throws {
        let surfaceID = UUIDv7.generate()
        let paneUUID = UUIDv7.generate()
        let paneID = PaneId(existingUUID: paneUUID)
        let surfaceViewObjectID = ObjectIdentifier(NSView(frame: .zero))
        let runtime = TerminalRuntime(
            paneId: paneID,
            metadata: PaneMetadata(paneId: paneID, title: "Ordered command finish")
        )
        let runtimeRegistry = RuntimeRegistry()
        _ = runtimeRegistry.register(runtime)
        let routingLookup = LocalDrainRoutingLookup(
            surfaceIDsByViewObjectID: [surfaceViewObjectID: surfaceID],
            paneIDsBySurfaceID: [surfaceID: paneUUID]
        )
        let accumulator = TerminalLocalActionAccumulator { _, _ in }
        let recorder = ExactControlOrderRecorder()
        let bindingID = UUIDv7.generate()
        let originalRegistry = Ghostty.ActionRouter.runtimeRegistryForActionRouting
        Ghostty.ActionRouter.setRuntimeRegistry(runtimeRegistry)
        Ghostty.ActionRouter.bindTerminalActivityInput(
            id: bindingID,
            context: { _ in
                TerminalActivityProjectionContext(
                    isAttended: true,
                    isAgentClassified: false,
                    outputBurstThreshold: 30
                )
            },
            sink: { input in
                let runtimeWasEmpty = (await runtime.eventsSince(seq: 0)).events.isEmpty
                recorder.record(input, runtimeWasEmpty: runtimeWasEmpty)
            }
        )
        defer {
            Ghostty.ActionRouter.unbindTerminalActivityInput(id: bindingID)
            Ghostty.ActionRouter.setRuntimeRegistry(originalRegistry)
        }

        let routed = await Ghostty.ActionRouter.routeExactFactOrControlOnMainActor(
            precedingTitle: nil,
            actionTag: UInt32(GHOSTTY_ACTION_COMMAND_FINISHED.rawValue),
            payload: .commandFinished(exitCode: 0, duration: 42, sourceInstant: ContinuousClock.now),
            surfaceViewObjectID: surfaceViewObjectID,
            expectedSurfaceID: surfaceID,
            routingLookup: routingLookup,
            accumulator: accumulator
        )

        #expect(routed)
        #expect(recorder.runtimeWasEmptyAtInput)
        let input = try #require(recorder.inputs.first)
        guard
            case .orderedControl(
                let recordedSurfaceID,
                let recordedPaneID,
                let precedingAggregate,
                .commandFinished
            ) = input
        else {
            Issue.record("Expected one ordered commandFinished input")
            return
        }
        #expect(recordedSurfaceID == surfaceID)
        #expect(recordedPaneID == paneUUID)
        #expect(precedingAggregate == nil)

        let replay = await runtime.eventsSince(seq: 0)
        #expect(replay.events.count == 1)
    }

    @Test("mounted surface without apply target does not self-reschedule failed title")
    func mountedSurfaceWithoutApplyTargetDoesNotSelfRescheduleFailedTitle() async {
        let surfaceID = UUIDv7.generate()
        let paneUUID = UUIDv7.generate()
        let host = FakeTerminalLocalActionDrainHost(managedSurfaceID: surfaceID)
        let dependencies = TerminalLocalActionDrainDependencies(
            mountedHostResolver: TerminalLocalActionMountedHostResolver(
                surfaceForID: { requestedID in requestedID == surfaceID ? host : nil },
                paneIDForSurfaceID: { requestedID in requestedID == surfaceID ? paneUUID : nil }
            ),
            runtimeRegistry: RuntimeRegistry(),
            fallbackRuntimeRegistry: nil,
            activityContext: { _ in nil },
            submitActivityInput: { _ in }
        )
        defer {
            Ghostty.ActionRouter.localActionDrainScheduler.cancel(for: surfaceID)
            Ghostty.ActionRouter.localActionAccumulator.removeSurface(surfaceID)
        }

        #expect(
            Ghostty.ActionRouter.localActionAccumulator.offer(.titleChanged("pending"), for: surfaceID)
                == .scheduled
        )
        Ghostty.ActionRouter.localActionDrainScheduler.cancel(for: surfaceID)

        await Ghostty.ActionRouter.drainLocalActions(
            for: surfaceID,
            lane: .title,
            dependencies: dependencies
        )

        #expect(Ghostty.ActionRouter.localActionAccumulator.beginDrain(for: surfaceID, lane: .title) == nil)
        #expect(Ghostty.ActionRouter.localActionAccumulator.hasPendingActions(for: surfaceID))
    }

    @Test("successful title drain commits the applied projection without reading activity context")
    func successfulTitleDrainCommitsAppliedProjection() async {
        let surfaceID = UUIDv7.generate()
        let paneUUID = UUIDv7.generate()
        let paneID = PaneId(existingUUID: paneUUID)
        let host = FakeTerminalLocalActionDrainHost(managedSurfaceID: surfaceID)
        let runtimeRegistry = RuntimeRegistry()
        _ = runtimeRegistry.register(
            TerminalRuntime(
                paneId: paneID,
                metadata: PaneMetadata(paneId: paneID, title: "Committed title")
            )
        )
        let routingLookup = LocalDrainRoutingLookup(
            surfaceIDsByViewObjectID: [ObjectIdentifier(host): surfaceID],
            paneIDsBySurfaceID: [surfaceID: paneUUID]
        )
        let originalRuntimeRegistry = Ghostty.ActionRouter.runtimeRegistryForActionRouting
        Ghostty.ActionRouter.setRuntimeRegistry(runtimeRegistry)
        defer {
            Ghostty.ActionRouter.setRuntimeRegistry(originalRuntimeRegistry)
            Ghostty.ActionRouter.localActionDrainScheduler.cancel(for: surfaceID)
            Ghostty.ActionRouter.localActionAccumulator.removeSurface(surfaceID)
        }

        #expect(
            Ghostty.ActionRouter.localActionAccumulator.offer(
                .titleChanged("A"),
                for: surfaceID
            ) == .scheduled
        )
        Ghostty.ActionRouter.localActionDrainScheduler.cancel(for: surfaceID)

        var activityContextReadCount = 0
        await Ghostty.ActionRouter.drainLocalActions(
            for: surfaceID,
            lane: .title,
            dependencies: TerminalLocalActionDrainDependencies(
                mountedHostResolver: TerminalLocalActionMountedHostResolver(
                    surfaceForID: { requestedID in requestedID == surfaceID ? host : nil },
                    paneIDForSurfaceID: { requestedID in requestedID == surfaceID ? paneUUID : nil }
                ),
                runtimeRegistry: runtimeRegistry,
                fallbackRuntimeRegistry: nil,
                routingLookup: routingLookup,
                activityContext: { _ in
                    activityContextReadCount += 1
                    return nil
                },
                submitActivityInput: { _ in }
            )
        )

        #expect(activityContextReadCount == 0)
        #expect(host.title == "A")
        #expect(
            Ghostty.ActionRouter.localActionAccumulator.offer(
                .titleChanged("A"),
                for: surfaceID
            ) == .equalSuppressed
        )
        #expect(!Ghostty.ActionRouter.localActionAccumulator.hasPendingActions(for: surfaceID))
    }

    private func offerScrollbarState(
        _ state: ScrollbarState,
        surfaceID: UUID
    ) {
        #expect(
            Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
                .scrollbarChanged(state),
                surfaceID: surfaceID,
                accumulator: Ghostty.ActionRouter.localActionAccumulator
            ) == .handledLocally
        )
        Ghostty.ActionRouter.localActionDrainScheduler.cancel(for: surfaceID)
    }

    private func assertInvalidMountedLifetimeRetiresPendingActions(
        surfaceID: UUID,
        mountedHostResolver: TerminalLocalActionMountedHostResolver
    ) async {
        offerScrollbarState(
            ScrollbarState(top: 80, bottom: 120, total: 200),
            surfaceID: surfaceID
        )

        await Ghostty.ActionRouter.drainLocalActions(
            for: surfaceID,
            lane: .immediate,
            dependencies: TerminalLocalActionDrainDependencies(
                mountedHostResolver: mountedHostResolver,
                runtimeRegistry: RuntimeRegistry(),
                fallbackRuntimeRegistry: nil,
                activityContext: { _ in nil },
                submitActivityInput: { _ in }
            )
        )

        Ghostty.ActionRouter.localActionDrainScheduler.cancel(for: surfaceID)
        #expect(!Ghostty.ActionRouter.localActionAccumulator.hasPendingActions(for: surfaceID))
    }

    @Test("runtime-present drain preserves host runtime and activity delivery")
    func runtimePresentDrainPreservesExistingDelivery() async throws {
        let surfaceID = UUIDv7.generate()
        let paneUUID = UUIDv7.generate()
        let paneID = PaneId(existingUUID: paneUUID)
        let scrollbarState = ScrollbarState(top: 80, bottom: 120, total: 200)
        let projectionContext = TerminalActivityProjectionContext(
            isAttended: false,
            isAgentClassified: true,
            outputBurstThreshold: 10
        )
        let host = FakeTerminalLocalActionDrainHost(managedSurfaceID: surfaceID)
        let mountedHostResolver = TerminalLocalActionMountedHostResolver(
            surfaceForID: { requestedID in
                requestedID == surfaceID ? host : nil
            },
            paneIDForSurfaceID: { requestedID in
                requestedID == surfaceID ? paneUUID : nil
            }
        )
        let runtime = TerminalRuntime(
            paneId: paneID,
            metadata: PaneMetadata(paneId: paneID, title: "Local drain")
        )
        let runtimeRegistry = RuntimeRegistry()
        _ = runtimeRegistry.register(runtime)
        let activityRecorder = TerminalActivityInputRecorder()

        #expect(RuntimeRegistry.shared.runtime(for: paneID) == nil)
        defer {
            Ghostty.ActionRouter.localActionDrainScheduler.cancel(for: surfaceID)
            Ghostty.ActionRouter.localActionAccumulator.removeSurface(surfaceID)
        }

        #expect(
            Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
                .scrollbarChanged(scrollbarState),
                surfaceID: surfaceID,
                accumulator: Ghostty.ActionRouter.localActionAccumulator
            ) == .handledLocally
        )
        Ghostty.ActionRouter.localActionDrainScheduler.cancel(for: surfaceID)

        await Ghostty.ActionRouter.drainLocalActions(
            for: surfaceID,
            lane: .immediate,
            dependencies: TerminalLocalActionDrainDependencies(
                mountedHostResolver: mountedHostResolver,
                runtimeRegistry: runtimeRegistry,
                fallbackRuntimeRegistry: nil,
                activityContext: { requestedPaneID in
                    #expect(requestedPaneID == paneUUID)
                    return projectionContext
                },
                submitActivityInput: { input in
                    activityRecorder.record(input)
                }
            )
        )

        #expect(host.hostScrollbarState == scrollbarState)
        #expect(runtime.scrollbarState == scrollbarState)
        let input = try #require(activityRecorder.inputs.first)
        guard
            case .aggregate(
                let recordedSurfaceID,
                let recordedPaneID,
                let aggregateInput
            ) = input
        else {
            Issue.record("Expected one terminal activity aggregate")
            return
        }
        #expect(recordedSurfaceID == surfaceID)
        #expect(recordedPaneID == paneUUID)
        #expect(aggregateInput.latestState == scrollbarState)
        #expect(aggregateInput.context == projectionContext)
        #expect(aggregateInput.aggregate.sampleCount == 1)
    }

    @Test("no-runtime drain delivers host state and preserves a callback offered during delivery")
    func noRuntimeDrainDeliversHostStateAndFollowUp() async {
        let surfaceID = UUIDv7.generate()
        let paneUUID = UUIDv7.generate()
        let paneID = PaneId(existingUUID: paneUUID)
        let initialState = ScrollbarState(top: 80, bottom: 120, total: 200)
        let followUpState = ScrollbarState(top: 90, bottom: 130, total: 210)
        let projectionContext = TerminalActivityProjectionContext(
            isAttended: false,
            isAgentClassified: false,
            outputBurstThreshold: 10
        )
        let host = FakeTerminalLocalActionDrainHost(managedSurfaceID: surfaceID)
        let mountedHostResolver = TerminalLocalActionMountedHostResolver(
            surfaceForID: { requestedID in
                requestedID == surfaceID ? host : nil
            },
            paneIDForSurfaceID: { requestedID in
                requestedID == surfaceID ? paneUUID : nil
            }
        )
        defer {
            Ghostty.ActionRouter.localActionDrainScheduler.cancel(for: surfaceID)
            Ghostty.ActionRouter.localActionAccumulator.removeSurface(surfaceID)
        }
        #expect(RuntimeRegistry.shared.runtime(for: paneID) == nil)

        var didOfferFollowUp = false
        host.onScrollbarStateChanged = { _ in
            guard !didOfferFollowUp else { return }
            didOfferFollowUp = true
            _ = Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
                .scrollbarChanged(followUpState),
                surfaceID: surfaceID,
                accumulator: Ghostty.ActionRouter.localActionAccumulator
            )
        }
        offerScrollbarState(initialState, surfaceID: surfaceID)

        await Ghostty.ActionRouter.drainLocalActions(
            for: surfaceID,
            lane: .immediate,
            dependencies: TerminalLocalActionDrainDependencies(
                mountedHostResolver: mountedHostResolver,
                runtimeRegistry: RuntimeRegistry(),
                fallbackRuntimeRegistry: nil,
                activityContext: { _ in projectionContext },
                submitActivityInput: { _ in }
            )
        )
        Ghostty.ActionRouter.localActionDrainScheduler.cancel(for: surfaceID)

        #expect(host.hostScrollbarState == initialState)
        #expect(Ghostty.ActionRouter.localActionAccumulator.hasPendingActions(for: surfaceID))

        await Ghostty.ActionRouter.drainLocalActions(
            for: surfaceID,
            lane: .immediate,
            dependencies: TerminalLocalActionDrainDependencies(
                mountedHostResolver: mountedHostResolver,
                runtimeRegistry: RuntimeRegistry(),
                fallbackRuntimeRegistry: nil,
                activityContext: { _ in projectionContext },
                submitActivityInput: { _ in }
            )
        )
        Ghostty.ActionRouter.localActionDrainScheduler.cancel(for: surfaceID)

        #expect(host.hostScrollbarState == followUpState)
        #expect(!Ghostty.ActionRouter.localActionAccumulator.hasPendingActions(for: surfaceID))
    }

    @Test("no-runtime drain submits detached activity and records compact performance")
    func noRuntimeDrainSubmitsActivityAndRecordsPerformance() async throws {
        let surfaceID = UUIDv7.generate()
        let paneUUID = UUIDv7.generate()
        let paneID = PaneId(existingUUID: paneUUID)
        let scrollbarState = ScrollbarState(top: 80, bottom: 120, total: 200)
        let projectionContext = TerminalActivityProjectionContext(
            isAttended: false,
            isAgentClassified: true,
            outputBurstThreshold: 10
        )
        let traceRuntime = AgentStudioTraceRuntime(
            configuration: AgentStudioTraceConfiguration.from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
                "AGENTSTUDIO_TRACE_DIR": temporaryTraceDirectoryURL().path,
                "AGENTSTUDIO_TRACE_NAME": "no-runtime-local-drain",
                "AGENTSTUDIO_TRACE_TAGS": "performance",
            ]),
            processIdentifier: 932,
            timeUnixNano: { 123 }
        )
        let performanceRecorder = AgentStudioPerformanceTraceRecorder(traceRuntime: traceRuntime)
        let host = FakeTerminalLocalActionDrainHost(managedSurfaceID: surfaceID)
        host.performanceTraceRecorder = performanceRecorder
        let mountedHostResolver = TerminalLocalActionMountedHostResolver(
            surfaceForID: { requestedID in
                requestedID == surfaceID ? host : nil
            },
            paneIDForSurfaceID: { requestedID in
                requestedID == surfaceID ? paneUUID : nil
            }
        )
        let activityRecorder = TerminalActivityInputRecorder()
        defer {
            Ghostty.ActionRouter.localActionDrainScheduler.cancel(for: surfaceID)
            Ghostty.ActionRouter.localActionAccumulator.removeSurface(surfaceID)
        }
        #expect(RuntimeRegistry.shared.runtime(for: paneID) == nil)
        offerScrollbarState(scrollbarState, surfaceID: surfaceID)

        await Ghostty.ActionRouter.drainLocalActions(
            for: surfaceID,
            lane: .immediate,
            dependencies: TerminalLocalActionDrainDependencies(
                mountedHostResolver: mountedHostResolver,
                runtimeRegistry: RuntimeRegistry(),
                fallbackRuntimeRegistry: nil,
                activityContext: { requestedPaneID in
                    #expect(requestedPaneID == paneUUID)
                    return projectionContext
                },
                submitActivityInput: { input in
                    activityRecorder.record(input)
                }
            )
        )
        Ghostty.ActionRouter.localActionDrainScheduler.cancel(for: surfaceID)
        try await performanceRecorder.drain()

        #expect(host.hostScrollbarState == scrollbarState)
        let input = try #require(activityRecorder.inputs.first)
        guard case .aggregate(let recordedSurfaceID, let recordedPaneID, let aggregateInput) = input else {
            Issue.record("Expected one terminal activity aggregate")
            return
        }
        #expect(recordedSurfaceID == surfaceID)
        #expect(recordedPaneID == paneUUID)
        #expect(aggregateInput.latestState == scrollbarState)
        #expect(aggregateInput.context == projectionContext)

        let outputFileURL = try #require(traceRuntime.outputFileURL)
        let contents = try String(contentsOf: outputFileURL, encoding: .utf8)
        #expect(contents.contains("\"body\":\"performance.terminal.compact_apply\""))
        #expect(contents.contains("\"body\":\"performance.terminal.accumulator_drain\""))
        #expect(contents.contains("\"agentstudio.performance.terminal.equal_write_suppressed.count\":0"))
        #expect(contents.contains("\"agentstudio.performance.terminal.accumulator.mainactor_task.count\":1"))
    }

    @Test("immediate drain does not publish title before the title lane")
    func immediateDrainDoesNotPublishTitleBeforeTitleLane() async throws {
        let surfaceID = UUIDv7.generate()
        let paneUUID = UUIDv7.generate()
        let paneID = PaneId(existingUUID: paneUUID)
        let scrollbarState = ScrollbarState(top: 80, bottom: 120, total: 200)
        let host = FakeTerminalLocalActionDrainHost(managedSurfaceID: surfaceID)
        let runtime = TerminalRuntime(
            paneId: paneID,
            metadata: PaneMetadata(paneId: paneID, title: "Local title drain")
        )
        let runtimeRegistry = RuntimeRegistry()
        _ = runtimeRegistry.register(runtime)
        let originalRuntimeRegistry = Ghostty.ActionRouter.runtimeRegistryForActionRouting
        Ghostty.ActionRouter.setRuntimeRegistry(runtimeRegistry)
        let routingLookup = LocalDrainRoutingLookup(
            surfaceIDsByViewObjectID: [ObjectIdentifier(host): surfaceID],
            paneIDsBySurfaceID: [surfaceID: paneUUID]
        )
        let dependencies = TerminalLocalActionDrainDependencies(
            mountedHostResolver: TerminalLocalActionMountedHostResolver(
                surfaceForID: { requestedID in requestedID == surfaceID ? host : nil },
                paneIDForSurfaceID: { requestedID in requestedID == surfaceID ? paneUUID : nil }
            ),
            runtimeRegistry: runtimeRegistry,
            fallbackRuntimeRegistry: nil,
            routingLookup: routingLookup,
            activityContext: { _ in nil },
            submitActivityInput: { _ in }
        )
        defer {
            Ghostty.ActionRouter.setRuntimeRegistry(originalRuntimeRegistry)
            Ghostty.ActionRouter.localActionDrainScheduler.cancel(for: surfaceID)
            Ghostty.ActionRouter.localActionAccumulator.removeSurface(surfaceID)
        }

        #expect(
            Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
                .titleChanged("window"),
                surfaceID: surfaceID,
                accumulator: Ghostty.ActionRouter.localActionAccumulator
            ) == .handledLocally
        )
        #expect(
            Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
                .tabTitleChanged("tab"),
                surfaceID: surfaceID,
                accumulator: Ghostty.ActionRouter.localActionAccumulator
            ) == .handledLocally
        )
        #expect(
            Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
                .scrollbarChanged(scrollbarState),
                surfaceID: surfaceID,
                accumulator: Ghostty.ActionRouter.localActionAccumulator
            ) == .handledLocally
        )
        Ghostty.ActionRouter.localActionDrainScheduler.cancel(for: surfaceID)

        await Ghostty.ActionRouter.drainLocalActions(
            for: surfaceID,
            lane: .immediate,
            dependencies: dependencies
        )

        #expect(host.hostScrollbarState == scrollbarState)
        #expect(host.title.isEmpty)
        #expect((await runtime.eventsSince(seq: 0)).events.isEmpty)

        await Ghostty.ActionRouter.drainLocalActions(
            for: surfaceID,
            lane: .title,
            dependencies: dependencies
        )

        #expect(host.title == "window")
        let titleEvents = await runtime.eventsSince(seq: 0).events.compactMap { envelope -> String? in
            guard case .pane(let paneEnvelope) = envelope else { return nil }
            guard case .terminal(.tabTitleChanged(let title)) = paneEnvelope.event else { return nil }
            return title
        }
        #expect(titleEvents == ["tab"])
    }

    @Test("missing mounted surface retires pending local actions")
    func missingMountedSurfaceRetiresPendingLocalActions() async {
        let surfaceID = UUIDv7.generate()
        defer {
            Ghostty.ActionRouter.localActionDrainScheduler.cancel(for: surfaceID)
            Ghostty.ActionRouter.localActionAccumulator.removeSurface(surfaceID)
        }

        await assertInvalidMountedLifetimeRetiresPendingActions(
            surfaceID: surfaceID,
            mountedHostResolver: TerminalLocalActionMountedHostResolver(
                surfaceForID: { _ in nil },
                paneIDForSurfaceID: { _ in UUIDv7.generate() }
            )
        )
    }

    @Test("replacement mounted surface retires pending local actions")
    func replacementMountedSurfaceRetiresPendingLocalActions() async {
        let surfaceID = UUIDv7.generate()
        let replacementHost = FakeTerminalLocalActionDrainHost(managedSurfaceID: UUIDv7.generate())
        defer {
            Ghostty.ActionRouter.localActionDrainScheduler.cancel(for: surfaceID)
            Ghostty.ActionRouter.localActionAccumulator.removeSurface(surfaceID)
        }

        await assertInvalidMountedLifetimeRetiresPendingActions(
            surfaceID: surfaceID,
            mountedHostResolver: TerminalLocalActionMountedHostResolver(
                surfaceForID: { _ in replacementHost },
                paneIDForSurfaceID: { _ in UUIDv7.generate() }
            )
        )
    }

    @Test("missing pane mapping retires pending local actions")
    func missingPaneMappingRetiresPendingLocalActions() async {
        let surfaceID = UUIDv7.generate()
        let host = FakeTerminalLocalActionDrainHost(managedSurfaceID: surfaceID)
        defer {
            Ghostty.ActionRouter.localActionDrainScheduler.cancel(for: surfaceID)
            Ghostty.ActionRouter.localActionAccumulator.removeSurface(surfaceID)
        }

        await assertInvalidMountedLifetimeRetiresPendingActions(
            surfaceID: surfaceID,
            mountedHostResolver: TerminalLocalActionMountedHostResolver(
                surfaceForID: { _ in host },
                paneIDForSurfaceID: { _ in nil }
            )
        )
    }

    private func temporaryTraceDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstudio-local-action-drain-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
