import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioTerminal

extension GhosttyActionRouterTests {
    @Test("commandFinished reaches ordered activity input before the ordinary runtime fact")
    func commandFinishedReachesOrderedInputBeforeRuntimeFact() async throws {
        var configuration = GhosttyActionRouterTestFixtureConfiguration()
        configuration.activityProjectionContext = TerminalActivityProjectionContext(
            isAttended: true,
            isAgentClassified: false,
            outputBurstThreshold: 30
        )

        try await withGhosttyActionRouterTestFixture(configuration: configuration) { fixture in
            #expect(
                await
                    (fixture.handler.host.applyExactFactOrControl(
                        precedingTitle: nil,
                        actionTag: GhosttyActionTag.commandFinished.rawValue,
                        payload: .commandFinished(exitCode: 0, duration: 42, sourceInstant: ContinuousClock.now),
                        surfaceID: fixture.surfaceID,
                        viewObjectID: fixture.surfaceViewObjectID,
                        accumulator: fixture.handler.localActionAccumulator
                    ) == .applied)
            )
            #expect(fixture.activityInputRecorder.runtimeWasEmptyAtInput == [true])
            let input = try #require(fixture.activityInputRecorder.inputs.first)
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
            #expect(recordedSurfaceID == fixture.surfaceID)
            #expect(recordedPaneID == fixture.paneUUID)
            #expect(precedingAggregate == nil)
            #expect((await fixture.runtime.eventsSince(seq: 0)).events.count == 1)
        }
    }

    @Test("failed title drain retains the publication without scheduling another claim")
    func failedTitleDrainDoesNotSelfReschedule() async throws {
        try await withGhosttyActionRouterTestFixture(
            configuration: .init(registerRuntime: false)
        ) { fixture in
            let accumulator = fixture.handler.localActionAccumulator
            #expect(accumulator.offer(.titleChanged("pending"), for: fixture.surfaceID) == .scheduled)
            fixture.handler.localActionDrainScheduler.cancel(for: fixture.surfaceID)

            await fixture.handler.host.drainLocalActions(
                for: fixture.surfaceID, lane: .title,
                accumulator: fixture.handler.localActionAccumulator
            )

            #expect(accumulator.beginDrain(for: fixture.surfaceID, lane: .title) == nil)
            #expect(accumulator.hasPendingActions(for: fixture.surfaceID))
            #expect(fixture.handler.localActionDrainScheduler.pendingDrainClaimCount == 0)
        }
    }

    @Test("successful title drain commits the applied projection without reading activity context")
    func successfulTitleDrainCommitsAppliedProjection() async throws {
        var activityContextReadCount = 0
        var configuration = GhosttyActionRouterTestFixtureConfiguration(runtimeTitle: "Committed title")
        configuration.activityContextRead = { _ in activityContextReadCount += 1 }

        try await withGhosttyActionRouterTestFixture(configuration: configuration) { fixture in
            let accumulator = fixture.handler.localActionAccumulator
            #expect(accumulator.offer(.titleChanged("A"), for: fixture.surfaceID) == .scheduled)
            fixture.handler.localActionDrainScheduler.cancel(for: fixture.surfaceID)

            await fixture.handler.host.drainLocalActions(
                for: fixture.surfaceID, lane: .title,
                accumulator: fixture.handler.localActionAccumulator
            )

            #expect(activityContextReadCount == 0)
            #expect(fixture.nativeView.title == "A")
            #expect(accumulator.offer(.titleChanged("A"), for: fixture.surfaceID) == .equalSuppressed)
            #expect(!accumulator.hasPendingActions(for: fixture.surfaceID))
        }
    }

    @Test("runtime-present drain preserves host runtime and activity delivery")
    func runtimePresentDrainPreservesExistingDelivery() async throws {
        let scrollbarState = ScrollbarState(top: 80, bottom: 120, total: 200)
        let projectionContext = TerminalActivityProjectionContext(
            isAttended: false,
            isAgentClassified: true,
            outputBurstThreshold: 10
        )
        var configuration = GhosttyActionRouterTestFixtureConfiguration()
        configuration.activityProjectionContext = projectionContext

        try await withGhosttyActionRouterTestFixture(configuration: configuration) { fixture in
            offerScrollbarState(scrollbarState, fixture: fixture)

            await fixture.handler.host.drainLocalActions(
                for: fixture.surfaceID, lane: .immediate,
                accumulator: fixture.handler.localActionAccumulator
            )

            #expect(fixture.nativeView.hostScrollbarState == scrollbarState)
            #expect(fixture.runtime.scrollbarState == scrollbarState)
            let input = try #require(fixture.activityInputRecorder.inputs.first)
            guard
                case .aggregate(let recordedSurfaceID, let recordedPaneID, let aggregateInput) = input
            else {
                Issue.record("Expected one terminal activity aggregate")
                return
            }
            #expect(recordedSurfaceID == fixture.surfaceID)
            #expect(recordedPaneID == fixture.paneUUID)
            #expect(aggregateInput.latestState == scrollbarState)
            #expect(aggregateInput.context == projectionContext)
            #expect(aggregateInput.aggregate.sampleCount == 1)
        }
    }

    @Test("no-runtime drain delivers host state and preserves a callback offered during delivery")
    func noRuntimeDrainDeliversHostStateAndFollowUp() async throws {
        let initialState = ScrollbarState(top: 80, bottom: 120, total: 200)
        let followUpState = ScrollbarState(top: 90, bottom: 130, total: 210)
        try await withGhosttyActionRouterTestFixture(
            configuration: .init(
                registerRuntime: false,
                activityProjectionContext: .init(
                    isAttended: false, isAgentClassified: false, outputBurstThreshold: 10
                )
            )
        ) { fixture in
            var didOfferFollowUp = false
            fixture.nativeView.onScrollbarStateChanged = { _ in
                guard !didOfferFollowUp else { return }
                didOfferFollowUp = true
                #expect(
                    Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
                        .scrollbarChanged(followUpState),
                        surfaceID: fixture.surfaceID,
                        accumulator: fixture.handler.localActionAccumulator
                    ) == .handledLocally
                )
                fixture.handler.localActionDrainScheduler.cancel(for: fixture.surfaceID)
            }
            offerScrollbarState(initialState, fixture: fixture)

            await fixture.handler.host.drainLocalActions(
                for: fixture.surfaceID, lane: .immediate,
                accumulator: fixture.handler.localActionAccumulator
            )
            fixture.handler.localActionDrainScheduler.cancel(for: fixture.surfaceID)

            #expect(fixture.nativeView.hostScrollbarState == initialState)
            #expect(fixture.handler.localActionAccumulator.hasPendingActions(for: fixture.surfaceID))

            await fixture.handler.host.drainLocalActions(
                for: fixture.surfaceID, lane: .immediate,
                accumulator: fixture.handler.localActionAccumulator
            )
            fixture.handler.localActionDrainScheduler.cancel(for: fixture.surfaceID)
            fixture.nativeView.onScrollbarStateChanged = nil

            #expect(fixture.nativeView.hostScrollbarState == followUpState)
            #expect(!fixture.handler.localActionAccumulator.hasPendingActions(for: fixture.surfaceID))
        }
    }

    @Test("no-runtime drain submits detached activity and records compact performance")
    func noRuntimeDrainSubmitsActivityAndRecordsPerformance() async throws {
        let traceFixture = makePerformanceTraceRuntime()
        let performanceRecorder = AgentStudioPerformanceTraceRecorder(traceRuntime: traceFixture.runtime)
        let scrollbarState = ScrollbarState(top: 80, bottom: 120, total: 200)
        let projectionContext = TerminalActivityProjectionContext(
            isAttended: false,
            isAgentClassified: true,
            outputBurstThreshold: 10
        )
        var configuration = GhosttyActionRouterTestFixtureConfiguration(registerRuntime: false)
        configuration.performanceTraceRecorder = performanceRecorder
        configuration.activityProjectionContext = projectionContext

        try await withGhosttyActionRouterTestFixture(configuration: configuration) { fixture in
            offerScrollbarState(scrollbarState, fixture: fixture)
            await fixture.handler.host.drainLocalActions(
                for: fixture.surfaceID, lane: .immediate,
                accumulator: fixture.handler.localActionAccumulator
            )
            try await performanceRecorder.drain()

            #expect(fixture.nativeView.hostScrollbarState == scrollbarState)
            let input = try #require(fixture.activityInputRecorder.inputs.first)
            guard case .aggregate(let recordedSurfaceID, let recordedPaneID, let aggregateInput) = input else {
                Issue.record("Expected one terminal activity aggregate")
                return
            }
            #expect(recordedSurfaceID == fixture.surfaceID)
            #expect(recordedPaneID == fixture.paneUUID)
            #expect(aggregateInput.latestState == scrollbarState)
            #expect(aggregateInput.context == projectionContext)

            let contents = try String(contentsOf: traceFixture.outputFileURL, encoding: .utf8)
            #expect(contents.contains("\"body\":\"performance.terminal.compact_apply\""))
            #expect(contents.contains("\"body\":\"performance.terminal.accumulator_drain\""))
            #expect(contents.contains("\"agentstudio.performance.terminal.equal_write_suppressed.count\":0"))
            #expect(contents.contains("\"agentstudio.performance.terminal.accumulator.mainactor_task.count\":1"))
        }
    }

    @Test("immediate drain does not publish title before the title lane")
    func immediateDrainDoesNotPublishTitleBeforeTitleLane() async throws {
        let scrollbarState = ScrollbarState(top: 80, bottom: 120, total: 200)
        try await withGhosttyActionRouterTestFixture(
            configuration: .init(runtimeTitle: "Local title drain")
        ) { fixture in
            let accumulator = fixture.handler.localActionAccumulator
            #expect(
                Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
                    .titleChanged("window"), surfaceID: fixture.surfaceID, accumulator: accumulator
                ) == .handledLocally
            )
            #expect(
                Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
                    .tabTitleChanged("tab"), surfaceID: fixture.surfaceID, accumulator: accumulator
                ) == .handledLocally
            )
            offerScrollbarState(scrollbarState, fixture: fixture)
            fixture.handler.localActionDrainScheduler.cancel(for: fixture.surfaceID)

            await fixture.handler.host.drainLocalActions(
                for: fixture.surfaceID, lane: .immediate,
                accumulator: fixture.handler.localActionAccumulator
            )

            #expect(fixture.nativeView.hostScrollbarState == scrollbarState)
            #expect(fixture.nativeView.title.isEmpty)
            #expect((await fixture.runtime.eventsSince(seq: 0)).events.isEmpty)

            await fixture.handler.host.drainLocalActions(
                for: fixture.surfaceID, lane: .title,
                accumulator: fixture.handler.localActionAccumulator
            )

            #expect(fixture.nativeView.title == "window")
            let titleEvents = await fixture.runtime.eventsSince(seq: 0).events.compactMap { envelope -> String? in
                guard case .pane(let paneEnvelope) = envelope else { return nil }
                guard case .terminal(.tabTitleChanged(let title)) = paneEnvelope.event else { return nil }
                return title
            }
            #expect(titleEvents == ["tab"])
        }
    }

    @Test("missing mounted surface retires pending local actions")
    func missingMountedSurfaceRetiresPendingLocalActions() async throws {
        try await assertInvalidMountedLifetimeRetiresPendingActions(
            configuration: .init(resolveMountedHost: false)
        )
    }

    @Test("replacement mounted surface retires pending local actions")
    func replacementMountedSurfaceRetiresPendingLocalActions() async throws {
        try await assertInvalidMountedLifetimeRetiresPendingActions(
            configuration: .init(nativeViewSurfaceID: UUIDv7.generate())
        )
    }

    @Test("missing pane mapping retires pending local actions")
    func missingPaneMappingRetiresPendingLocalActions() async throws {
        try await assertInvalidMountedLifetimeRetiresPendingActions(
            configuration: .init(resolveMountedPane: false)
        )
    }

    private func offerScrollbarState(
        _ state: ScrollbarState,
        fixture: GhosttyActionRouterTestFixture
    ) {
        #expect(
            Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
                .scrollbarChanged(state),
                surfaceID: fixture.surfaceID,
                accumulator: fixture.handler.localActionAccumulator
            ) == .handledLocally
        )
        fixture.handler.localActionDrainScheduler.cancel(for: fixture.surfaceID)
    }

    private func assertInvalidMountedLifetimeRetiresPendingActions(
        configuration: GhosttyActionRouterTestFixtureConfiguration
    ) async throws {
        try await withGhosttyActionRouterTestFixture(configuration: configuration) { fixture in
            offerScrollbarState(
                ScrollbarState(top: 80, bottom: 120, total: 200),
                fixture: fixture
            )
            await fixture.handler.host.drainLocalActions(
                for: fixture.surfaceID, lane: .immediate,
                accumulator: fixture.handler.localActionAccumulator
            )
            fixture.handler.localActionDrainScheduler.cancel(for: fixture.surfaceID)
            #expect(!fixture.handler.localActionAccumulator.hasPendingActions(for: fixture.surfaceID))
        }
    }

    private func makePerformanceTraceRuntime() -> (runtime: AgentStudioTraceRuntime, outputFileURL: URL) {
        let traceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstudio-local-action-drain-tests", isDirectory: true)
            .appendingPathComponent(UUIDv7.generate().uuidString, isDirectory: true)
        let traceRuntime = AgentStudioTraceRuntime(
            configuration: AgentStudioTraceConfiguration.from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
                "AGENTSTUDIO_TRACE_DIR": traceDirectory.path,
                "AGENTSTUDIO_TRACE_NAME": "no-runtime-local-drain",
                "AGENTSTUDIO_TRACE_TAGS": "performance",
            ]),
            processIdentifier: 932,
            timeUnixNano: { 123 }
        )
        return (
            runtime: traceRuntime,
            outputFileURL: traceDirectory.appendingPathComponent("agentstudio-no-runtime-local-drain-932.jsonl")
        )
    }
}
