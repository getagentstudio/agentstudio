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
    @Test(
        "routing with resolved surface object identifier returns false when surface is unknown"
    )
    func routeWithResolvedSurfaceView_unknownSurface() async throws {
        try await withGhosttyActionRouterTestFixture { fixture in
            let unknownSurfaceViewID = ObjectIdentifier(NSView(frame: .zero))
            #expect(!fixture.route(.newTab, .noPayload, surfaceViewObjectID: unknownSurfaceViewID))
        }
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
    func routeWithResolvedSurfaceView_missingPaneMapping() async throws {
        try await withGhosttyActionRouterTestFixture { fixture in
            fixture.routingLookup.mapPane(nil, for: fixture.surfaceID)
            #expect(!fixture.route(.newTab, .noPayload))
        }
    }

    @Test("routing returns false when mapped pane id is not UUID v7")
    func routeWithResolvedSurfaceView_nonV7PaneId() async throws {
        try await withGhosttyActionRouterTestFixture { fixture in
            fixture.routingLookup.mapPane(UUID(), for: fixture.surfaceID)
            #expect(!fixture.route(.newTab, .noPayload))
        }
    }

    @Test("routing returns false when pane has no registered runtime")
    func routeWithResolvedSurfaceView_missingRuntime() async throws {
        try await withGhosttyActionRouterTestFixture(
            configuration: .init(registerRuntime: false)
        ) { fixture in
            #expect(!fixture.route(.newTab, .noPayload))
        }
    }

    @Test("registered surface reaches terminal runtime end to end")
    func actionRouter_endToEnd_registeredSurfaceReachesTerminalRuntime() async throws {
        try await withGhosttyActionRouterTestFixture { fixture in
            #expect(fixture.route(.setTitle, .titleChanged("test")))
            #expect(fixture.runtime.metadata.title == "test")
        }
    }

    @Test("contracted tab title retains its runtime event kind and replay route")
    func contractedTabTitleRetainsRuntimeRoute() async throws {
        try await withGhosttyActionRouterTestFixture(
            configuration: .init(runtimeTitle: "Before")
        ) { fixture in
            #expect(
                fixture.handler.routeContractedTitleMetadata(
                    .tabTitleChanged("After"),
                    surfaceViewObjectID: fixture.surfaceViewObjectID
                )
            )

            #expect(fixture.runtime.metadata.title == "After")
            let replay = await fixture.runtime.eventsSince(seq: 0)
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
    }

    @Test("equal contracted first title still records startup readiness")
    func equalContractedFirstTitleRecordsStartupReadiness() async throws {
        let traceFixture = makeTraceRuntime(
            traceName: "equal-title-startup",
            traceTags: "terminal.startup",
            processIdentifier: 255,
            flushMode: "immediate"
        )
        let traceRuntime = traceFixture.runtime
        let startupRecorder = AgentStudioStartupTraceRecorder(traceRuntime: traceRuntime)
        try await withGhosttyActionRouterTestFixture(
            configuration: .init(
                runtimeTitle: "Same",
                traceRuntime: traceRuntime,
                startupTraceRecorder: startupRecorder
            )
        ) { fixture in
            #expect(
                fixture.handler.routeContractedTitleMetadata(
                    .titleChanged("Same"),
                    surfaceViewObjectID: fixture.surfaceViewObjectID
                )
            )
            try await startupRecorder.drain()

            #expect((await fixture.runtime.eventsSince(seq: 0)).events.isEmpty)
            let contents = try String(contentsOf: traceFixture.outputFileURL, encoding: .utf8)
            #expect(contents.contains("terminal.startup.title_ready"))
        }
    }

    @Test("exact routing seals an earlier title before a later title arrives")
    func exactRoutingSealsEarlierTitleBeforeLaterTitle() async throws {
        try await withGhosttyActionRouterTestFixture { fixture in
            let accumulator = fixture.handler.localActionAccumulator
            #expect(
                Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
                    .titleChanged("A"), surfaceID: fixture.surfaceID, accumulator: accumulator
                ) == .handledLocally
            )
            let exactAdmission = Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
                .commandFinished(exitCode: 7, duration: 42),
                surfaceID: fixture.surfaceID,
                accumulator: accumulator
            )
            #expect(
                Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
                    .titleChanged("C"), surfaceID: fixture.surfaceID, accumulator: accumulator
                ) == .handledLocally
            )
            fixture.handler.localActionDrainScheduler.cancel(for: fixture.surfaceID)

            guard case .routeExactFactOrControl(let precedingTitle) = exactAdmission else {
                Issue.record("expected exact routing admission")
                return
            }
            let sealedTitle = try #require(precedingTitle)
            #expect(sealedTitle.metadata.runtimeTitle == .titleChanged("A"))

            #expect(
                await fixture.handler.routeExactFactOrControlOnMainActor(
                    precedingTitle: sealedTitle,
                    actionTag: GhosttyActionTag.commandFinished.rawValue,
                    payload: .commandFinished(exitCode: 7, duration: 42, sourceInstant: ContinuousClock.now),
                    surfaceViewObjectID: fixture.surfaceViewObjectID,
                    expectedSurfaceID: fixture.surfaceID
                )
            )
            let laterBatch = try #require(accumulator.beginDrain(for: fixture.surfaceID, lane: .title))
            let laterTitle = try #require(laterBatch.titleMetadata?.runtimeTitle)
            #expect(
                fixture.handler.routeContractedTitleMetadata(
                    laterTitle, surfaceViewObjectID: fixture.surfaceViewObjectID
                )
            )
            #expect(accumulator.finishDrain(for: fixture.surfaceID, lane: .title) == .idle)

            let replay = await fixture.runtime.eventsSince(seq: 0)
            #expect(terminalEventNames(from: replay.events) == ["title:A", "command:7", "title:C"])
        }
    }

    @Test("an exact fact admitted before a title has no preceding title barrier")
    func exactFirstLeavesLaterTitleAfterBarrier() async throws {
        try await withGhosttyActionRouterTestFixture { fixture in
            let accumulator = fixture.handler.localActionAccumulator
            let exactAdmission = Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
                .commandFinished(exitCode: 3, duration: 9),
                surfaceID: fixture.surfaceID,
                accumulator: accumulator
            )
            guard case .routeExactFactOrControl(let precedingTitle) = exactAdmission else {
                Issue.record("expected exact routing admission")
                return
            }
            #expect(precedingTitle == nil)
            fixture.handler.localActionDrainScheduler.cancel(for: fixture.surfaceID)
            #expect(
                await fixture.handler.routeExactFactOrControlOnMainActor(
                    precedingTitle: precedingTitle,
                    actionTag: GhosttyActionTag.commandFinished.rawValue,
                    payload: .commandFinished(exitCode: 3, duration: 9, sourceInstant: ContinuousClock.now),
                    surfaceViewObjectID: fixture.surfaceViewObjectID,
                    expectedSurfaceID: fixture.surfaceID
                )
            )

            #expect(
                Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
                    .titleChanged("later"), surfaceID: fixture.surfaceID, accumulator: accumulator
                ) == .handledLocally
            )
            fixture.handler.localActionDrainScheduler.cancel(for: fixture.surfaceID)
            let laterBatch = try #require(accumulator.beginDrain(for: fixture.surfaceID, lane: .title))
            let laterTitle = try #require(laterBatch.titleMetadata?.runtimeTitle)
            #expect(
                fixture.handler.routeContractedTitleMetadata(
                    laterTitle, surfaceViewObjectID: fixture.surfaceViewObjectID
                )
            )
            #expect(accumulator.finishDrain(for: fixture.surfaceID, lane: .title) == .idle)

            let replay = await fixture.runtime.eventsSince(seq: 0)
            #expect(terminalEventNames(from: replay.events) == ["command:3", "title:later"])
        }
    }

    @Test("exact CWD publication suppresses committed equality before MainActor admission")
    func exactCWDPublicationSuppressesCommittedEqualityBeforeMainActorAdmission() async throws {
        try await withGhosttyActionRouterTestFixture { fixture in
            let accumulator = fixture.handler.localActionAccumulator
            let firstAdmission = Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
                .cwdChanged("/tmp/project"), surfaceID: fixture.surfaceID, accumulator: accumulator
            )
            guard case .routeExactFactOrControl(let precedingTitle) = firstAdmission else {
                Issue.record("Expected first CWD to enter exact routing")
                return
            }
            #expect(
                await fixture.handler.routeExactFactOrControlOnMainActor(
                    precedingTitle: precedingTitle,
                    actionTag: GhosttyActionTag.pwd.rawValue,
                    payload: .cwdChanged("/tmp/project"),
                    surfaceViewObjectID: fixture.surfaceViewObjectID,
                    expectedSurfaceID: fixture.surfaceID
                )
            )

            #expect(
                Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
                    .cwdChanged("/tmp/./project"), surfaceID: fixture.surfaceID, accumulator: accumulator
                ) == .handledLocally
            )
            #expect(
                Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
                    .titleChanged("before-cwd"), surfaceID: fixture.surfaceID, accumulator: accumulator
                ) == .handledLocally
            )
            let changedAdmission = Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
                .cwdChanged("/tmp/other"), surfaceID: fixture.surfaceID, accumulator: accumulator
            )
            guard case .routeExactFactOrControl(let changedPrecedingTitle) = changedAdmission else {
                Issue.record("Expected changed CWD to enter exact routing")
                return
            }
            fixture.handler.localActionDrainScheduler.cancel(for: fixture.surfaceID)
            #expect(
                await fixture.handler.routeExactFactOrControlOnMainActor(
                    precedingTitle: changedPrecedingTitle,
                    actionTag: GhosttyActionTag.pwd.rawValue,
                    payload: .cwdChanged("/tmp/other"),
                    surfaceViewObjectID: fixture.surfaceViewObjectID,
                    expectedSurfaceID: fixture.surfaceID
                )
            )

            let replay = await fixture.runtime.eventsSince(seq: 0)
            #expect(
                terminalEventNames(from: replay.events)
                    == ["cwd:/tmp/project", "title:before-cwd", "cwd:/tmp/other"]
            )
        }
    }

    @Test("deferred exact routing rejects a replacement surface at the same view address")
    func exactRoutingRejectsReplacementSurfaceLifetime() async throws {
        try await withGhosttyActionRouterTestFixture { fixture in
            let replacementSurfaceID = UUIDv7.generate()
            let replacementPaneUUID = UUIDv7.generate()
            let replacementPaneID = PaneId(existingUUID: replacementPaneUUID)
            let replacementRuntime = TerminalRuntime(
                paneId: replacementPaneID,
                metadata: PaneMetadata(paneId: replacementPaneID, title: "Replacement"),
                surfaceCommandDispatcher: TerminalFixtureSurfaceCommands()
            )
            _ = fixture.runtimeRegistry.register(replacementRuntime)
            fixture.routingLookup.mapSurface(replacementSurfaceID, for: fixture.surfaceViewObjectID)
            fixture.routingLookup.mapPane(replacementPaneUUID, for: replacementSurfaceID)

            let accumulator = fixture.handler.localActionAccumulator
            #expect(accumulator.offer(.titleChanged("Retired"), for: fixture.surfaceID) == .scheduled)
            let sealedTitle = try #require(accumulator.detachTitleBeforeExactBarrier(for: fixture.surfaceID))
            fixture.handler.localActionDrainScheduler.cancel(for: fixture.surfaceID)

            let routed = await fixture.handler.routeExactFactOrControlOnMainActor(
                precedingTitle: sealedTitle,
                actionTag: GhosttyActionTag.commandFinished.rawValue,
                payload: .commandFinished(exitCode: 9, duration: 12, sourceInstant: ContinuousClock.now),
                surfaceViewObjectID: fixture.surfaceViewObjectID,
                expectedSurfaceID: fixture.surfaceID
            )

            #expect(!routed)
            #expect((await replacementRuntime.eventsSince(seq: 0)).events.isEmpty)
        }
    }

    @Test("retired surface lifetime is not current after routing removal")
    func retiredSurfaceLifetimeIsNotCurrent() async throws {
        try await withGhosttyActionRouterTestFixture { fixture in
            let retainedView = NSView(frame: .zero)
            #expect(
                !Ghostty.ActionRouter.isCurrentSurfaceLifetime(
                    expectedSurfaceID: UUIDv7.generate(),
                    surfaceViewObjectID: ObjectIdentifier(retainedView),
                    routingLookup: fixture.routingLookup
                )
            )
        }
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
    func actionRouter_endToEnd_observedTerminalIntelligencePayloadsReachRuntime() async throws {
        try await withGhosttyActionRouterTestFixture { fixture in
            #expect(fixture.route(.desktopNotification, .desktopNotification(title: "Build", body: "Complete")))
            #expect(
                fixture.route(
                    .progressReport,
                    .progressReport(stateRawValue: UInt32(GHOSTTY_PROGRESS_STATE_ERROR.rawValue), progress: 80)
                )
            )
            #expect(
                fixture.route(
                    .rendererHealth,
                    .rendererHealth(rawValue: UInt32(GHOSTTY_RENDERER_HEALTH_UNHEALTHY.rawValue))
                )
            )
            #expect(fixture.route(.scrollbar, .scrollbar(total: 1000, offset: 900, length: 40)))
            #expect(fixture.route(.pwd, .cwdChanged("/tmp/project")))

            let replay = await fixture.runtime.eventsSince(seq: 0)
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
    }

    @Test("registered surface writes Ghostty action translation trace records")
    func actionRouterTrace_registeredSurfaceWritesTranslationRecord() async throws {
        let traceFixture = makeTraceRuntime(
            traceName: "ghostty-action-router",
            traceTags: "terminal.signal",
            processIdentifier: 251,
            flushMode: "immediate"
        )
        try await withGhosttyActionRouterTestFixture(
            configuration: .init(traceRuntime: traceFixture.runtime)
        ) { fixture in
            #expect(fixture.route(.desktopNotification, .desktopNotification(title: "Build", body: "Complete")))
            await fixture.handler.retire()

            let contents = try String(contentsOf: traceFixture.outputFileURL, encoding: .utf8)
            #expect(contents.contains("\"body\":\"ghostty.action.translated\""))
            #expect(contents.contains("\"agentstudio.ghostty.action.name\":\"desktopNotification\""))
            #expect(contents.contains("\"agentstudio.ghostty.action.payload\":\"desktopNotification\""))
            #expect(contents.contains("\"agentstudio.ghostty.route.result\":true"))
            #expect(contents.contains("\"agentstudio.ghostty.signal.class\":\"semantic\""))
            #expect(contents.contains("\"agentstudio.pane.id\":\"\(fixture.paneUUID.uuidString)\""))
            #expect(contents.contains("\"agentstudio.runtime.event\":\"terminal.desktopNotificationRequested\""))
            #expect(contents.contains("\"agentstudio.surface.id\":\"\(fixture.surfaceID.uuidString)\""))
        }
    }

    @Test("terminal activity tag alone does not write Ghostty action translation trace records")
    func actionRouterTrace_terminalActivityAloneDoesNotWriteTranslationRecord() async throws {
        let traceFixture = makeTraceRuntime(
            traceName: "ghostty-action-router-activity-only",
            traceTags: "terminal.activity",
            processIdentifier: 253,
            flushMode: "immediate"
        )
        try await withGhosttyActionRouterTestFixture(
            configuration: .init(traceRuntime: traceFixture.runtime)
        ) { fixture in
            #expect(fixture.route(.desktopNotification, .desktopNotification(title: "Build", body: "Complete")))
            await fixture.handler.retire()
            #expect(FileManager.default.fileExists(atPath: traceFixture.outputFileURL.path) == false)
        }
    }

    @Test("high-volume callbacks do not write per-callback Ghostty action trace records")
    func actionRouterTrace_highVolumeCallbacksDoNotWritePerCallbackRecords() async throws {
        let traceFixture = makeTraceRuntime(
            traceName: "ghostty-action-router-scrollbar",
            traceTags: "terminal.signal",
            processIdentifier: 254,
            flushMode: "immediate"
        )
        try await withGhosttyActionRouterTestFixture(
            configuration: .init(traceRuntime: traceFixture.runtime)
        ) { fixture in
            #expect(fixture.route(.scrollbar, .scrollbar(total: 1000, offset: 900, length: 40)))
            #expect(
                fixture.route(
                    .keySequence,
                    .keySequence(active: true, triggerTag: 0, key: 112, mods: 0)
                )
            )
            await fixture.handler.retire()
            #expect(FileManager.default.fileExists(atPath: traceFixture.outputFileURL.path) == false)
        }
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

extension GhosttyActionRouterTests {
    @Test("known unsupported actions retain diagnostics without resolving a surface")
    func unsupportedActionsRetainDiagnostics() async throws {
        let fixture = makeTraceRuntime(
            traceName: "unsupported-actions", traceTags: "terminal.signal",
            processIdentifier: 253, flushMode: "immediate"
        )
        try await withGhosttyActionRouterTestFixture(
            configuration: .init(traceRuntime: fixture.runtime)
        ) { testFixture in
            testFixture.routingLookup.onSurfaceLookup = { _ in
                Issue.record("Unsupported action must not resolve a surface")
            }
            let appTarget = ghostty_target_s(
                tag: GHOSTTY_TARGET_APP,
                target: ghostty_target_u(surface: nil)
            )
            for tag in Ghostty.ActionRouter.unsupportedTags {
                let handled = testFixture.handler.handleAction(
                    target: appTarget,
                    action: ghostty_action_s(
                        tag: ghostty_action_tag_e(rawValue: tag.rawValue),
                        action: ghostty_action_u()
                    )
                )
                #expect(!handled)
            }
            await testFixture.handler.retire()
            let contents = try String(contentsOf: fixture.outputFileURL, encoding: .utf8)
            for tag in Ghostty.ActionRouter.unsupportedTags {
                #expect(contents.contains("\"agentstudio.ghostty.action.name\":\"\(tag)\""))
            }
            #expect(contents.contains("\"agentstudio.ghostty.route.reason\":\"unsupported_action\""))
            #expect(contents.contains("\"agentstudio.ghostty.route.result\":false"))
        }
    }

}
