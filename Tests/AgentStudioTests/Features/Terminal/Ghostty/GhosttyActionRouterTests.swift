import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudioTerminal

@MainActor
@Suite(.serialized)
struct GhosttyActionRouterTests {
    final class FakeActionRoutingLookup: GhosttyActionRoutingLookup {
        private let surfaceIdsByViewObjectId: [ObjectIdentifier: UUID]
        private let paneIdsBySurfaceId: [UUID: UUID]

        init(
            surfaceIdsByViewObjectId: [ObjectIdentifier: UUID] = [:],
            paneIdsBySurfaceId: [UUID: UUID] = [:]
        ) {
            self.surfaceIdsByViewObjectId = surfaceIdsByViewObjectId
            self.paneIdsBySurfaceId = paneIdsBySurfaceId
        }

        func surfaceId(forViewObjectId viewObjectId: ObjectIdentifier) -> UUID? {
            surfaceIdsByViewObjectId[viewObjectId]
        }

        func paneId(for surfaceId: UUID) -> UUID? {
            paneIdsBySurfaceId[surfaceId]
        }
    }

    @Test(
        "routing with resolved surface object identifier returns false when surface is unknown"
    )
    func routeWithResolvedSurfaceView_unknownSurface() {
        let unknownSurfaceViewId = ObjectIdentifier(NSView(frame: .zero))
        let lookup = FakeActionRoutingLookup()

        let routed = Ghostty.ActionRouter.routeActionToTerminalRuntimeOnMainActor(
            actionTag: UInt32(GHOSTTY_ACTION_NEW_TAB.rawValue),
            payload: .noPayload,
            surfaceViewObjectId: unknownSurfaceViewId,
            routingLookup: lookup
        )

        #expect(!routed)
    }

    @Test("deferred tags are fully retired after explicit terminal event promotion")
    func deferredTags_areRetired() {
        #expect(Ghostty.ActionRouter.deferredTags.isEmpty)
        #expect(Ghostty.ActionRouter.interceptedTags.contains(.render))
    }

    @Test("Ghostty trace signal classes are pinned by semantic bucket")
    func traceSignalClassesArePinnedBySemanticBucket() {
        #expect(Ghostty.ActionRouter.signalClass(for: .desktopNotification) == .semantic)
        #expect(Ghostty.ActionRouter.signalClass(for: .commandFinished) == .semantic)
        #expect(Ghostty.ActionRouter.signalClass(for: .scrollbar) == .inferred)
        #expect(Ghostty.ActionRouter.signalClass(for: .setTitle) == .context)
        #expect(Ghostty.ActionRouter.signalClass(for: .newWindow) == .deferred)
        #expect(Ghostty.ActionRouter.signalClass(for: .render) == .deferred)
        #expect(
            Ghostty.ActionRouter.signalClass(for: .unhandled(tag: UInt32.max), fallbackActionTag: UInt32.max)
                == .unhandled)
    }

    @Test("Ghostty payload trace names use stable case names")
    func payloadTraceNamesUseStableCaseNames() {
        #expect(
            Ghostty.ActionRouter.payloadTraceName(
                .desktopNotification(title: "Build", body: "Complete")
            ) == "desktopNotification"
        )
        #expect(
            Ghostty.ActionRouter.payloadTraceName(
                .commandFinished(exitCode: 0, duration: 12, sourceInstant: ContinuousClock.now)
            )
                == "commandFinished"
        )
        #expect(
            Ghostty.ActionRouter.payloadTraceName(
                .openURL(url: "https://example.com/private/token", kindRawValue: 1)
            ) == "openURL"
        )
        #expect(Ghostty.ActionRouter.payloadTraceName(.noPayload) == "noPayload")
    }

    @Test("routing returns false when surface has no pane mapping")
    func routeWithResolvedSurfaceView_missingPaneMapping() {
        let surfaceViewObjectId = ObjectIdentifier(NSView(frame: .zero))
        let surfaceId = UUID()
        let lookup = FakeActionRoutingLookup(
            surfaceIdsByViewObjectId: [surfaceViewObjectId: surfaceId]
        )

        let routed = Ghostty.ActionRouter.routeActionToTerminalRuntimeOnMainActor(
            actionTag: UInt32(GHOSTTY_ACTION_NEW_TAB.rawValue),
            payload: .noPayload,
            surfaceViewObjectId: surfaceViewObjectId,
            routingLookup: lookup
        )

        #expect(!routed)
    }

    @Test("routing returns false when mapped pane id is not UUID v7")
    func routeWithResolvedSurfaceView_nonV7PaneId() {
        let surfaceViewObjectId = ObjectIdentifier(NSView(frame: .zero))
        let surfaceId = UUID()
        let lookup = FakeActionRoutingLookup(
            surfaceIdsByViewObjectId: [surfaceViewObjectId: surfaceId],
            paneIdsBySurfaceId: [surfaceId: UUID()]
        )

        let routed = Ghostty.ActionRouter.routeActionToTerminalRuntimeOnMainActor(
            actionTag: UInt32(GHOSTTY_ACTION_NEW_TAB.rawValue),
            payload: .noPayload,
            surfaceViewObjectId: surfaceViewObjectId,
            routingLookup: lookup
        )

        #expect(!routed)
    }

    @Test("routing returns false when pane has no registered runtime")
    func routeWithResolvedSurfaceView_missingRuntime() {
        let surfaceViewObjectId = ObjectIdentifier(NSView(frame: .zero))
        let surfaceId = UUID()
        let paneUUID = UUIDv7.generate()
        let originalRegistry = Ghostty.ActionRouter.runtimeRegistryForActionRouting
        let runtimeRegistry = RuntimeRegistry()
        let lookup = FakeActionRoutingLookup(
            surfaceIdsByViewObjectId: [surfaceViewObjectId: surfaceId],
            paneIdsBySurfaceId: [surfaceId: paneUUID]
        )

        Ghostty.ActionRouter.setRuntimeRegistry(runtimeRegistry)
        defer {
            Ghostty.ActionRouter.setRuntimeRegistry(originalRegistry)
        }

        let routed = Ghostty.ActionRouter.routeActionToTerminalRuntimeOnMainActor(
            actionTag: UInt32(GHOSTTY_ACTION_NEW_TAB.rawValue),
            payload: .noPayload,
            surfaceViewObjectId: surfaceViewObjectId,
            routingLookup: lookup
        )

        #expect(!routed)
    }

    @Test("registered surface reaches terminal runtime end to end")
    func actionRouter_endToEnd_registeredSurfaceReachesTerminalRuntime() {
        let surfaceViewObjectId = ObjectIdentifier(NSView(frame: .zero))
        let surfaceId = UUID()
        let paneUUID = UUIDv7.generate()
        let paneId = PaneId(existingUUID: paneUUID)
        let runtime = TerminalRuntime(
            paneId: paneId,
            metadata: PaneMetadata(
                paneId: paneId,
                title: "Runtime"
            )
        )
        let runtimeRegistry = RuntimeRegistry()
        _ = runtimeRegistry.register(runtime)
        let lookup = FakeActionRoutingLookup(
            surfaceIdsByViewObjectId: [surfaceViewObjectId: surfaceId],
            paneIdsBySurfaceId: [surfaceId: paneUUID]
        )

        let originalRegistry = Ghostty.ActionRouter.runtimeRegistryForActionRouting
        Ghostty.ActionRouter.setRuntimeRegistry(runtimeRegistry)
        defer {
            Ghostty.ActionRouter.setRuntimeRegistry(originalRegistry)
        }

        let routed = Ghostty.ActionRouter.routeActionToTerminalRuntimeOnMainActor(
            actionTag: UInt32(GHOSTTY_ACTION_SET_TITLE.rawValue),
            payload: .titleChanged("test"),
            surfaceViewObjectId: surfaceViewObjectId,
            routingLookup: lookup
        )

        #expect(routed)
        #expect(runtime.metadata.title == "test")
    }

    @Test("contracted tab title retains its runtime event kind and replay route")
    func contractedTabTitleRetainsRuntimeRoute() async throws {
        let surfaceViewObjectId = ObjectIdentifier(NSView(frame: .zero))
        let surfaceId = UUIDv7.generate()
        let paneUUID = UUIDv7.generate()
        let paneId = PaneId(existingUUID: paneUUID)
        let runtime = TerminalRuntime(
            paneId: paneId,
            metadata: PaneMetadata(paneId: paneId, title: "Before")
        )
        let runtimeRegistry = RuntimeRegistry()
        _ = runtimeRegistry.register(runtime)
        let lookup = FakeActionRoutingLookup(
            surfaceIdsByViewObjectId: [surfaceViewObjectId: surfaceId],
            paneIdsBySurfaceId: [surfaceId: paneUUID]
        )
        let originalRegistry = Ghostty.ActionRouter.runtimeRegistryForActionRouting
        Ghostty.ActionRouter.setRuntimeRegistry(runtimeRegistry)
        defer {
            Ghostty.ActionRouter.setRuntimeRegistry(originalRegistry)
        }

        Ghostty.ActionRouter.routeContractedTitleMetadata(
            .tabTitleChanged("After"),
            surfaceViewObjectID: surfaceViewObjectId,
            routingLookup: lookup
        )

        #expect(runtime.metadata.title == "After")
        let replay = await runtime.eventsSince(seq: 0)
        #expect(replay.events.count == 1)
        let envelope = try #require(replay.events.first)
        guard case .pane(let paneEnvelope) = envelope else {
            Issue.record("expected pane runtime envelope")
            return
        }
        guard case .terminal(.tabTitleChanged(let title)) = paneEnvelope.event else {
            Issue.record("expected contracted tab-title runtime event")
            return
        }
        #expect(title == "After")
    }

    @Test("equal contracted first title still records startup readiness")
    func equalContractedFirstTitleRecordsStartupReadiness() async throws {
        let surfaceViewObjectId = ObjectIdentifier(NSView(frame: .zero))
        let surfaceId = UUIDv7.generate()
        let paneUUID = UUIDv7.generate()
        let paneId = PaneId(existingUUID: paneUUID)
        let runtime = TerminalRuntime(
            paneId: paneId,
            metadata: PaneMetadata(paneId: paneId, title: "Same")
        )
        let runtimeRegistry = RuntimeRegistry()
        _ = runtimeRegistry.register(runtime)
        let lookup = FakeActionRoutingLookup(
            surfaceIdsByViewObjectId: [surfaceViewObjectId: surfaceId],
            paneIdsBySurfaceId: [surfaceId: paneUUID]
        )
        let traceFixture = makeTraceRuntime(
            traceName: "equal-title-startup",
            traceTags: "terminal.startup",
            processIdentifier: 255,
            flushMode: "immediate"
        )
        let traceRuntime = traceFixture.runtime
        let startupRecorder = AgentStudioStartupTraceRecorder(traceRuntime: traceRuntime)
        let originalRegistry = Ghostty.ActionRouter.runtimeRegistryForActionRouting
        Ghostty.ActionRouter.setRuntimeRegistry(runtimeRegistry)
        Ghostty.ActionRouter.bindStartupTraceRecorder(startupRecorder)
        defer {
            Ghostty.ActionRouter.setRuntimeRegistry(originalRegistry)
            Ghostty.ActionRouter.bindStartupTraceRecorder(nil)
        }

        Ghostty.ActionRouter.routeContractedTitleMetadata(
            .titleChanged("Same"),
            surfaceViewObjectID: surfaceViewObjectId,
            routingLookup: lookup
        )
        try await startupRecorder.drain()

        #expect((await runtime.eventsSince(seq: 0)).events.isEmpty)
        let outputFileURL = traceFixture.outputFileURL
        let contents = try String(contentsOf: outputFileURL, encoding: .utf8)
        #expect(contents.contains("terminal.startup.title_ready"))
    }

    @Test("exact routing seals an earlier title before a later title arrives")
    func exactRoutingSealsEarlierTitleBeforeLaterTitle() async throws {
        let fixture = ExactBarrierFixture()
        let originalRegistry = Ghostty.ActionRouter.runtimeRegistryForActionRouting
        Ghostty.ActionRouter.setRuntimeRegistry(fixture.runtimeRegistry)
        defer { Ghostty.ActionRouter.setRuntimeRegistry(originalRegistry) }

        #expect(
            Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
                .titleChanged("A"),
                surfaceID: fixture.surfaceID,
                accumulator: fixture.accumulator
            ) == .handledLocally
        )
        let exactAdmission = Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
            .commandFinished(exitCode: 7, duration: 42),
            surfaceID: fixture.surfaceID,
            accumulator: fixture.accumulator
        )

        // The exact MainActor task is intentionally gated here while a later title arrives.
        #expect(
            Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
                .titleChanged("C"),
                surfaceID: fixture.surfaceID,
                accumulator: fixture.accumulator
            ) == .handledLocally
        )

        guard case .routeExactFactOrControl(let precedingTitle) = exactAdmission else {
            Issue.record("expected exact routing admission")
            return
        }
        let sealedTitle = try #require(precedingTitle)
        #expect(sealedTitle.metadata.runtimeTitle == .titleChanged("A"))

        #expect(
            await Ghostty.ActionRouter.routeExactFactOrControlOnMainActor(
                precedingTitle: sealedTitle,
                actionTag: UInt32(GHOSTTY_ACTION_COMMAND_FINISHED.rawValue),
                payload: .commandFinished(exitCode: 7, duration: 42, sourceInstant: ContinuousClock.now),
                surfaceViewObjectID: fixture.surfaceViewObjectID,
                expectedSurfaceID: fixture.surfaceID,
                routingLookup: fixture.routingLookup,
                accumulator: fixture.accumulator
            )
        )
        let laterBatch = try #require(fixture.accumulator.beginDrain(for: fixture.surfaceID, lane: .title))
        let laterTitle = try #require(laterBatch.titleMetadata?.runtimeTitle)
        Ghostty.ActionRouter.routeContractedTitleMetadata(
            laterTitle,
            surfaceViewObjectID: fixture.surfaceViewObjectID,
            routingLookup: fixture.routingLookup
        )
        #expect(fixture.accumulator.finishDrain(for: fixture.surfaceID, lane: .title) == .idle)

        let replay = await fixture.runtime.eventsSince(seq: 0)
        #expect(terminalEventNames(from: replay.events) == ["title:A", "command:7", "title:C"])
    }

    @Test("an exact fact admitted before a title has no preceding title barrier")
    func exactFirstLeavesLaterTitleAfterBarrier() async throws {
        let fixture = ExactBarrierFixture()
        let originalRegistry = Ghostty.ActionRouter.runtimeRegistryForActionRouting
        Ghostty.ActionRouter.setRuntimeRegistry(fixture.runtimeRegistry)
        defer { Ghostty.ActionRouter.setRuntimeRegistry(originalRegistry) }

        let exactAdmission = Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
            .commandFinished(exitCode: 3, duration: 9),
            surfaceID: fixture.surfaceID,
            accumulator: fixture.accumulator
        )
        guard case .routeExactFactOrControl(let precedingTitle) = exactAdmission else {
            Issue.record("expected exact routing admission")
            return
        }
        #expect(precedingTitle == nil)
        #expect(
            await Ghostty.ActionRouter.routeExactFactOrControlOnMainActor(
                precedingTitle: precedingTitle,
                actionTag: UInt32(GHOSTTY_ACTION_COMMAND_FINISHED.rawValue),
                payload: .commandFinished(exitCode: 3, duration: 9, sourceInstant: ContinuousClock.now),
                surfaceViewObjectID: fixture.surfaceViewObjectID,
                expectedSurfaceID: fixture.surfaceID,
                routingLookup: fixture.routingLookup,
                accumulator: fixture.accumulator
            )
        )

        #expect(
            Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
                .titleChanged("later"),
                surfaceID: fixture.surfaceID,
                accumulator: fixture.accumulator
            ) == .handledLocally
        )
        let laterBatch = try #require(fixture.accumulator.beginDrain(for: fixture.surfaceID, lane: .title))
        let laterTitle = try #require(laterBatch.titleMetadata?.runtimeTitle)
        Ghostty.ActionRouter.routeContractedTitleMetadata(
            laterTitle,
            surfaceViewObjectID: fixture.surfaceViewObjectID,
            routingLookup: fixture.routingLookup
        )
        #expect(fixture.accumulator.finishDrain(for: fixture.surfaceID, lane: .title) == .idle)

        let replay = await fixture.runtime.eventsSince(seq: 0)
        #expect(terminalEventNames(from: replay.events) == ["command:3", "title:later"])
    }

    @Test("exact CWD publication suppresses committed equality before MainActor admission")
    func exactCWDPublicationSuppressesCommittedEqualityBeforeMainActorAdmission() async throws {
        let fixture = ExactBarrierFixture()
        let originalRegistry = Ghostty.ActionRouter.runtimeRegistryForActionRouting
        Ghostty.ActionRouter.setRuntimeRegistry(fixture.runtimeRegistry)
        defer { Ghostty.ActionRouter.setRuntimeRegistry(originalRegistry) }

        let firstAdmission = Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
            .cwdChanged("/tmp/project"),
            surfaceID: fixture.surfaceID,
            accumulator: fixture.accumulator
        )
        guard case .routeExactFactOrControl(let precedingTitle) = firstAdmission else {
            Issue.record("Expected first CWD to enter exact routing")
            return
        }
        #expect(
            await Ghostty.ActionRouter.routeExactFactOrControlOnMainActor(
                precedingTitle: precedingTitle,
                actionTag: UInt32(GHOSTTY_ACTION_PWD.rawValue),
                payload: .cwdChanged("/tmp/project"),
                surfaceViewObjectID: fixture.surfaceViewObjectID,
                expectedSurfaceID: fixture.surfaceID,
                routingLookup: fixture.routingLookup,
                accumulator: fixture.accumulator
            )
        )

        #expect(
            Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
                .cwdChanged("/tmp/./project"),
                surfaceID: fixture.surfaceID,
                accumulator: fixture.accumulator
            ) == .handledLocally
        )
        #expect(
            Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
                .titleChanged("before-cwd"),
                surfaceID: fixture.surfaceID,
                accumulator: fixture.accumulator
            ) == .handledLocally
        )
        let changedAdmission = Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
            .cwdChanged("/tmp/other"),
            surfaceID: fixture.surfaceID,
            accumulator: fixture.accumulator
        )
        guard case .routeExactFactOrControl(let changedPrecedingTitle) = changedAdmission else {
            Issue.record("Expected changed CWD to enter exact routing")
            return
        }
        #expect(
            await Ghostty.ActionRouter.routeExactFactOrControlOnMainActor(
                precedingTitle: changedPrecedingTitle,
                actionTag: UInt32(GHOSTTY_ACTION_PWD.rawValue),
                payload: .cwdChanged("/tmp/other"),
                surfaceViewObjectID: fixture.surfaceViewObjectID,
                expectedSurfaceID: fixture.surfaceID,
                routingLookup: fixture.routingLookup,
                accumulator: fixture.accumulator
            )
        )

        let replay = await fixture.runtime.eventsSince(seq: 0)
        #expect(
            terminalEventNames(from: replay.events)
                == ["cwd:/tmp/project", "title:before-cwd", "cwd:/tmp/other"]
        )
    }

    @Test("deferred exact routing rejects a replacement surface at the same view address")
    func exactRoutingRejectsReplacementSurfaceLifetime() async throws {
        let originalSurfaceID = UUIDv7.generate()
        let replacementSurfaceID = UUIDv7.generate()
        let replacementPaneUUID = UUIDv7.generate()
        let surfaceViewObjectID = ObjectIdentifier(NSView(frame: .zero))
        let replacementPaneID = PaneId(existingUUID: replacementPaneUUID)
        let replacementRuntime = TerminalRuntime(
            paneId: replacementPaneID,
            metadata: PaneMetadata(paneId: replacementPaneID, title: "Replacement")
        )
        let runtimeRegistry = RuntimeRegistry()
        _ = runtimeRegistry.register(replacementRuntime)
        let replacementLookup = FakeActionRoutingLookup(
            surfaceIdsByViewObjectId: [surfaceViewObjectID: replacementSurfaceID],
            paneIdsBySurfaceId: [replacementSurfaceID: replacementPaneUUID]
        )
        let accumulator = TerminalLocalActionAccumulator { _, _ in }
        let originalRegistry = Ghostty.ActionRouter.runtimeRegistryForActionRouting
        Ghostty.ActionRouter.setRuntimeRegistry(runtimeRegistry)
        defer { Ghostty.ActionRouter.setRuntimeRegistry(originalRegistry) }

        #expect(accumulator.offer(.titleChanged("Retired"), for: originalSurfaceID) == .scheduled)
        let sealedTitle = try #require(
            accumulator.detachTitleBeforeExactBarrier(for: originalSurfaceID)
        )

        let routed = await Ghostty.ActionRouter.routeExactFactOrControlOnMainActor(
            precedingTitle: sealedTitle,
            actionTag: UInt32(GHOSTTY_ACTION_COMMAND_FINISHED.rawValue),
            payload: .commandFinished(exitCode: 9, duration: 12, sourceInstant: ContinuousClock.now),
            surfaceViewObjectID: surfaceViewObjectID,
            expectedSurfaceID: originalSurfaceID,
            routingLookup: replacementLookup
        )

        #expect(!routed)
        #expect((await replacementRuntime.eventsSince(seq: 0)).events.isEmpty)
    }

    @Test("retired surface lifetime is not current after routing removal")
    func retiredSurfaceLifetimeIsNotCurrent() {
        let retainedView = NSView(frame: .zero)

        #expect(
            !Ghostty.ActionRouter.isCurrentSurfaceLifetime(
                expectedSurfaceID: UUIDv7.generate(),
                surfaceViewObjectID: ObjectIdentifier(retainedView),
                routingLookup: FakeActionRoutingLookup()
            )
        )
    }

    @Test("queued close does not retire a same-pane undo remount")
    func queuedCloseRejectsSamePaneUndoRemount() {
        let paneID = UUIDv7.generate()

        #expect(
            !Ghostty.ActionRouter.shouldSubmitSurfaceClose(
                currentPaneID: paneID,
                closingPaneID: paneID
            )
        )
        #expect(
            Ghostty.ActionRouter.shouldSubmitSurfaceClose(
                currentPaneID: nil,
                closingPaneID: paneID
            )
        )
    }

    @Test("registered surface routes observed terminal intelligence payloads through runtime envelopes")
    func actionRouter_endToEnd_observedTerminalIntelligencePayloadsReachRuntime() async {
        let surfaceViewObjectId = ObjectIdentifier(NSView(frame: .zero))
        let surfaceId = UUID()
        let paneUUID = UUIDv7.generate()
        let paneId = PaneId(existingUUID: paneUUID)
        let runtime = TerminalRuntime(
            paneId: paneId,
            metadata: PaneMetadata(
                paneId: paneId,
                title: "Runtime"
            )
        )
        let runtimeRegistry = RuntimeRegistry()
        _ = runtimeRegistry.register(runtime)
        let lookup = FakeActionRoutingLookup(
            surfaceIdsByViewObjectId: [surfaceViewObjectId: surfaceId],
            paneIdsBySurfaceId: [surfaceId: paneUUID]
        )

        let originalRegistry = Ghostty.ActionRouter.runtimeRegistryForActionRouting
        Ghostty.ActionRouter.setRuntimeRegistry(runtimeRegistry)
        defer {
            Ghostty.ActionRouter.setRuntimeRegistry(originalRegistry)
        }

        let routedDesktopNotification =
            Ghostty.ActionRouter.routeActionToTerminalRuntimeOnMainActor(
                actionTag: UInt32(GHOSTTY_ACTION_DESKTOP_NOTIFICATION.rawValue),
                payload: .desktopNotification(title: "Build", body: "Complete"),
                surfaceViewObjectId: surfaceViewObjectId,
                routingLookup: lookup
            )
        #expect(routedDesktopNotification)
        #expect(
            Ghostty.ActionRouter.routeActionToTerminalRuntimeOnMainActor(
                actionTag: UInt32(GHOSTTY_ACTION_PROGRESS_REPORT.rawValue),
                payload: .progressReport(
                    stateRawValue: UInt32(GHOSTTY_PROGRESS_STATE_ERROR.rawValue),
                    progress: 80
                ),
                surfaceViewObjectId: surfaceViewObjectId,
                routingLookup: lookup
            )
        )
        #expect(
            Ghostty.ActionRouter.routeActionToTerminalRuntimeOnMainActor(
                actionTag: UInt32(GHOSTTY_ACTION_RENDERER_HEALTH.rawValue),
                payload: .rendererHealth(rawValue: UInt32(GHOSTTY_RENDERER_HEALTH_UNHEALTHY.rawValue)),
                surfaceViewObjectId: surfaceViewObjectId,
                routingLookup: lookup
            )
        )
        #expect(
            Ghostty.ActionRouter.routeActionToTerminalRuntimeOnMainActor(
                actionTag: UInt32(GHOSTTY_ACTION_SCROLLBAR.rawValue),
                payload: .scrollbar(total: 1000, offset: 900, length: 40),
                surfaceViewObjectId: surfaceViewObjectId,
                routingLookup: lookup
            )
        )
        #expect(
            Ghostty.ActionRouter.routeActionToTerminalRuntimeOnMainActor(
                actionTag: UInt32(GHOSTTY_ACTION_PWD.rawValue),
                payload: .cwdChanged("/tmp/project"),
                surfaceViewObjectId: surfaceViewObjectId,
                routingLookup: lookup
            )
        )

        let replay = await runtime.eventsSince(seq: 0)
        let events = replay.events.compactMap { envelope -> PaneRuntimeEvent? in
            guard case .pane(let paneEnvelope) = envelope else { return nil }
            return paneEnvelope.event
        }

        #expect(
            events.contains {
                guard case .terminal(.progressReportUpdated(ProgressState(kind: .error, percent: 80))) = $0
                else { return false }
                return true
            }
        )
        #expect(
            events.contains {
                guard case .terminal(.rendererHealthChanged(false)) = $0 else { return false }
                return true
            }
        )
        #expect(
            events.contains {
                guard case .terminal(.scrollbarChanged) = $0 else { return false }
                return true
            } == false
        )
        #expect(
            events.contains {
                guard case .terminal(.cwdChanged("/tmp/project")) = $0 else { return false }
                return true
            }
        )
    }

    @Test("registered surface writes Ghostty action translation trace records")
    func actionRouterTrace_registeredSurfaceWritesTranslationRecord() async throws {
        let surfaceViewObjectId = ObjectIdentifier(NSView(frame: .zero))
        let surfaceId = UUID()
        let paneUUID = UUIDv7.generate()
        let paneId = PaneId(existingUUID: paneUUID)
        let runtime = TerminalRuntime(
            paneId: paneId,
            metadata: PaneMetadata(
                paneId: paneId,
                title: "Runtime"
            )
        )
        let runtimeRegistry = RuntimeRegistry()
        _ = runtimeRegistry.register(runtime)
        let lookup = FakeActionRoutingLookup(
            surfaceIdsByViewObjectId: [surfaceViewObjectId: surfaceId],
            paneIdsBySurfaceId: [surfaceId: paneUUID]
        )
        let traceFixture = makeTraceRuntime(
            traceName: "ghostty-action-router",
            traceTags: "terminal.signal",
            processIdentifier: 251,
            flushMode: "immediate"
        )
        let traceRuntime = traceFixture.runtime

        let originalRegistry = Ghostty.ActionRouter.runtimeRegistryForActionRouting
        Ghostty.ActionRouter.setRuntimeRegistry(runtimeRegistry)
        Ghostty.ActionRouter.bindTraceRuntime(traceRuntime)
        defer {
            Ghostty.ActionRouter.setRuntimeRegistry(originalRegistry)
            Ghostty.ActionRouter.bindTraceRuntime(nil)
        }

        #expect(
            Ghostty.ActionRouter.routeActionToTerminalRuntimeOnMainActor(
                actionTag: UInt32(GHOSTTY_ACTION_DESKTOP_NOTIFICATION.rawValue),
                payload: .desktopNotification(title: "Build", body: "Complete"),
                surfaceViewObjectId: surfaceViewObjectId,
                routingLookup: lookup
            )
        )
        await Ghostty.ActionRouter.drainTraceRuntimeForActionRouting()

        await Ghostty.ActionRouter.drainTraceRuntimeForActionRouting()
        let outputFileURL = traceFixture.outputFileURL
        let contents = try String(contentsOf: outputFileURL, encoding: .utf8)
        #expect(contents.contains("\"body\":\"ghostty.action.translated\""))
        #expect(contents.contains("\"agentstudio.ghostty.action.name\":\"desktopNotification\""))
        #expect(contents.contains("\"agentstudio.ghostty.action.payload\":\"desktopNotification\""))
        #expect(contents.contains("\"agentstudio.ghostty.route.result\":true"))
        #expect(contents.contains("\"agentstudio.ghostty.signal.class\":\"semantic\""))
        #expect(contents.contains("\"agentstudio.pane.id\":\"\(paneUUID.uuidString)\""))
        #expect(contents.contains("\"agentstudio.runtime.event\":\"terminal.desktopNotificationRequested\""))
        #expect(contents.contains("\"agentstudio.surface.id\":\"\(surfaceId.uuidString)\""))
    }

    @Test("terminal activity tag alone does not write Ghostty action translation trace records")
    func actionRouterTrace_terminalActivityAloneDoesNotWriteTranslationRecord() async throws {
        let surfaceViewObjectId = ObjectIdentifier(NSView(frame: .zero))
        let surfaceId = UUID()
        let paneUUID = UUIDv7.generate()
        let paneId = PaneId(existingUUID: paneUUID)
        let runtime = TerminalRuntime(
            paneId: paneId,
            metadata: PaneMetadata(
                paneId: paneId,
                title: "Runtime"
            )
        )
        let runtimeRegistry = RuntimeRegistry()
        _ = runtimeRegistry.register(runtime)
        let lookup = FakeActionRoutingLookup(
            surfaceIdsByViewObjectId: [surfaceViewObjectId: surfaceId],
            paneIdsBySurfaceId: [surfaceId: paneUUID]
        )
        let traceFixture = makeTraceRuntime(
            traceName: "ghostty-action-router-activity-only",
            traceTags: "terminal.activity",
            processIdentifier: 253,
            flushMode: "immediate"
        )
        let traceRuntime = traceFixture.runtime

        let originalRegistry = Ghostty.ActionRouter.runtimeRegistryForActionRouting
        Ghostty.ActionRouter.setRuntimeRegistry(runtimeRegistry)
        Ghostty.ActionRouter.bindTraceRuntime(traceRuntime)
        defer {
            Ghostty.ActionRouter.setRuntimeRegistry(originalRegistry)
            Ghostty.ActionRouter.bindTraceRuntime(nil)
        }

        #expect(
            Ghostty.ActionRouter.routeActionToTerminalRuntimeOnMainActor(
                actionTag: UInt32(GHOSTTY_ACTION_DESKTOP_NOTIFICATION.rawValue),
                payload: .desktopNotification(title: "Build", body: "Complete"),
                surfaceViewObjectId: surfaceViewObjectId,
                routingLookup: lookup
            )
        )
        await Ghostty.ActionRouter.drainTraceRuntimeForActionRouting()

        let outputFileURL = traceFixture.outputFileURL
        #expect(FileManager.default.fileExists(atPath: outputFileURL.path) == false)
    }

    @Test("high-volume callbacks do not write per-callback Ghostty action trace records")
    func actionRouterTrace_highVolumeCallbacksDoNotWritePerCallbackRecords() async throws {
        let surfaceViewObjectId = ObjectIdentifier(NSView(frame: .zero))
        let surfaceId = UUID()
        let paneUUID = UUIDv7.generate()
        let paneId = PaneId(existingUUID: paneUUID)
        let runtime = TerminalRuntime(
            paneId: paneId,
            metadata: PaneMetadata(
                paneId: paneId,
                title: "Runtime"
            )
        )
        let runtimeRegistry = RuntimeRegistry()
        _ = runtimeRegistry.register(runtime)
        let lookup = FakeActionRoutingLookup(
            surfaceIdsByViewObjectId: [surfaceViewObjectId: surfaceId],
            paneIdsBySurfaceId: [surfaceId: paneUUID]
        )
        let traceFixture = makeTraceRuntime(
            traceName: "ghostty-action-router-scrollbar",
            traceTags: "terminal.signal",
            processIdentifier: 254,
            flushMode: "immediate"
        )
        let traceRuntime = traceFixture.runtime

        let originalRegistry = Ghostty.ActionRouter.runtimeRegistryForActionRouting
        Ghostty.ActionRouter.setRuntimeRegistry(runtimeRegistry)
        Ghostty.ActionRouter.bindTraceRuntime(traceRuntime)
        defer {
            Ghostty.ActionRouter.setRuntimeRegistry(originalRegistry)
            Ghostty.ActionRouter.bindTraceRuntime(nil)
        }

        #expect(
            Ghostty.ActionRouter.routeActionToTerminalRuntimeOnMainActor(
                actionTag: UInt32(GHOSTTY_ACTION_SCROLLBAR.rawValue),
                payload: .scrollbar(total: 1000, offset: 900, length: 40),
                surfaceViewObjectId: surfaceViewObjectId,
                routingLookup: lookup
            )
        )
        #expect(
            Ghostty.ActionRouter.routeActionToTerminalRuntimeOnMainActor(
                actionTag: UInt32(GHOSTTY_ACTION_KEY_SEQUENCE.rawValue),
                payload: .keySequence(active: true, triggerTag: 0, key: 112, mods: 0),
                surfaceViewObjectId: surfaceViewObjectId,
                routingLookup: lookup
            )
        )
        await Ghostty.ActionRouter.drainTraceRuntimeForActionRouting()

        let outputFileURL = traceFixture.outputFileURL
        #expect(FileManager.default.fileExists(atPath: outputFileURL.path) == false)
    }

    private func temporaryTraceDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstudio-ghostty-action-router-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeTraceRuntime(
        traceName: String,
        traceTags: String,
        processIdentifier: Int32,
        flushMode: String? = nil
    ) -> (runtime: AgentStudioTraceRuntime, outputFileURL: URL) {
        let traceDirectory = temporaryTraceDirectoryURL()
        var environment = [
            "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
            "AGENTSTUDIO_TRACE_DIR": traceDirectory.path,
            "AGENTSTUDIO_TRACE_NAME": traceName,
            "AGENTSTUDIO_TRACE_TAGS": traceTags,
        ]
        environment["AGENTSTUDIO_TRACE_FLUSH"] = flushMode
        return (
            runtime: AgentStudioTraceRuntime.fromEnvironment(
                environment,
                processIdentifier: processIdentifier
            ),
            outputFileURL: traceDirectory.appendingPathComponent(
                "agentstudio-\(traceName)-\(processIdentifier).jsonl"
            )
        )
    }

    private func terminalEventNames(from envelopes: [RuntimeEnvelope]) -> [String] {
        envelopes.compactMap { envelope in
            guard case .pane(let paneEnvelope) = envelope else { return nil }
            switch paneEnvelope.event {
            case .terminal(.titleChanged(let title)):
                return "title:\(title)"
            case .terminal(.commandFinished(let exitCode, _)):
                return "command:\(exitCode)"
            case .terminal(.cwdChanged(let cwdPath)):
                return "cwd:\(cwdPath)"
            default:
                return nil
            }
        }
    }

}

@MainActor
private struct ExactBarrierFixture {
    let surfaceViewObjectID = ObjectIdentifier(NSView(frame: .zero))
    let surfaceID = UUIDv7.generate()
    let paneUUID = UUIDv7.generate()
    let runtime: TerminalRuntime
    let runtimeRegistry: RuntimeRegistry
    let routingLookup: GhosttyActionRouterTests.FakeActionRoutingLookup
    let accumulator = TerminalLocalActionAccumulator { _, _ in }

    init() {
        let paneID = PaneId(existingUUID: paneUUID)
        runtime = TerminalRuntime(
            paneId: paneID,
            metadata: PaneMetadata(paneId: paneID, title: "Before")
        )
        runtimeRegistry = RuntimeRegistry()
        _ = runtimeRegistry.register(runtime)
        routingLookup = GhosttyActionRouterTests.FakeActionRoutingLookup(
            surfaceIdsByViewObjectId: [surfaceViewObjectID: surfaceID],
            paneIdsBySurfaceId: [surfaceID: paneUUID]
        )
    }
}

extension GhosttyActionRouterTests {
    @Test("known unsupported actions retain diagnostics without resolving a surface")
    func unsupportedActionsRetainDiagnostics() async throws {
        let fixture = makeTraceRuntime(
            traceName: "unsupported-actions", traceTags: "terminal.signal",
            processIdentifier: 253, flushMode: "immediate"
        )
        Ghostty.ActionRouter.bindTraceRuntime(fixture.runtime)
        defer { Ghostty.ActionRouter.bindTraceRuntime(nil) }
        let appHandle = try #require(UnsafeMutableRawPointer(bitPattern: 1))
        for tag in Ghostty.ActionRouter.unsupportedTags {
            let handled = Ghostty.ActionRouter.handleAction(
                appHandle,
                target: ghostty_target_s(tag: GHOSTTY_TARGET_APP, target: ghostty_target_u(surface: nil)),
                action: ghostty_action_s(tag: ghostty_action_tag_e(rawValue: tag.rawValue), action: ghostty_action_u()),
                routingLookupProvider: {
                    Issue.record("Unsupported action must not resolve a surface")
                    return SurfaceManager.shared
                },
                metadataActionRouter: { _, _, _, _ in
                    Issue.record("Unsupported action must not publish metadata")
                    return true
                }
            )
            #expect(!handled)
        }
        await Ghostty.ActionRouter.drainTraceRuntimeForActionRouting()
        let contents = try String(contentsOf: fixture.outputFileURL, encoding: .utf8)
        for tag in Ghostty.ActionRouter.unsupportedTags {
            #expect(contents.contains("\"agentstudio.ghostty.action.name\":\"\(tag)\""))
        }
        #expect(contents.contains("\"agentstudio.ghostty.route.reason\":\"unsupported_action\""))
        #expect(contents.contains("\"agentstudio.ghostty.route.result\":false"))
    }

}
