import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Observation
import os.log

private let terminalActivityRouterLogger = Logger(
    subsystem: "com.agentstudio",
    category: "TerminalActivityRouter"
)

/// Adapts exact runtime facts and off-main terminal activity outcomes to MainActor state.
/// High-rate terminal samples are contracted before reaching this type.
@MainActor
package final class TerminalActivityRouter {
    private struct TraceRequest: Sendable {
        let tag: AgentStudioTraceTag
        let body: String
        let traceID: String?
        let parentSpanID: String?
        let attributes: [String: AgentStudioTraceValue]
    }

    private let bus: EventBus<RuntimeEnvelope>
    private let projector: TerminalActivityProjector
    private let projectorBindingID = UUIDv7.generate()
    private let activityAtom: TerminalActivityAtom
    private let attendedPane: AttendedPaneDerived?
    private let traceRuntime: AgentStudioTraceRuntime?
    private let startupTraceRecorder: AgentStudioStartupTraceRecorder?
    /// A6 (advisor review 2026-10-01; PD rev 21 item 5, Lead decision: push,
    /// not pull): notified from `consumeProjectionOutcome`'s existing
    /// `.firstRender` arm -- the same raw fact, already unconditional for
    /// warm/unverified panes (they never arm a restore phase, so
    /// `consumeAggregateState`'s `!isInRestorePhase` gate never blocks
    /// them). Composed in `AppDelegate.bootStartTerminalActivityRouter` to
    /// notify `WorkspaceSurfaceCoordinator.receivePostAttachFirstRender(paneID:)`.
    /// Both this router and the coordinator are `@MainActor`, so this adds
    /// no new actor hop -- typed `@MainActor @Sendable`, matching
    /// `recordSettledActivityStatus`'s own shape below, so the call at the
    /// `.firstRender` arm needs no `await`.
    private let onFirstRender: (@MainActor @Sendable (UUID) -> Void)?
    private let surfaceIDForPaneID: @MainActor (UUID) -> UUID?
    private let isPaneCurrentlyAttended: @MainActor (UUID) -> Bool
    private let isPaneAgentClassified: @MainActor (UUID, PaneContentType) -> Bool
    private let lastOutputLineReader: @MainActor (UUID) -> TerminalViewportTextReadResult
    private let recordSettledActivityStatus: @MainActor (UUID, String?) -> Void
    private let clearPaneActivityStatus: @MainActor (UUID) -> Void

    private var busTask: Task<Void, Never>?
    private var derivedActivityPostTask: Task<Void, Never>?
    private var traceContinuation: AsyncStream<TraceRequest>.Continuation?
    private var traceWorkerTask: Task<Void, Never>?
    private var lastAttendedPaneID: UUID?
    private var derivedActivitySequence: UInt64 = 0
    private var lifecycleOperationTask: Task<Void, Never>?
    private var lifecycleOperationSequence = 0
    private var attentionLifecycleEpoch = 0
    private var attentionObservationGeneration = 0
    private var attentionSettlementTask: Task<Void, Never>?
    private var attentionDeliveryTask: Task<Void, Never>?
    private var pendingAttentionControls: [AttentionControlDelivery] = []

    package init(
        bus: EventBus<RuntimeEnvelope>,
        activityAtom: TerminalActivityAtom,
        projector: TerminalActivityProjector? = nil,
        attendedPane: AttendedPaneDerived? = nil,
        traceRuntime: AgentStudioTraceRuntime? = nil,
        startupTraceRecorder: AgentStudioStartupTraceRecorder? = nil,
        onFirstRender: (@MainActor @Sendable (UUID) -> Void)? = nil,
        surfaceIDForPaneID: (@MainActor (UUID) -> UUID?)? = nil,
        isPaneCurrentlyAttended: (@MainActor (UUID) -> Bool)? = nil,
        isPaneAgentClassified: (@MainActor (UUID, PaneContentType) -> Bool)? = nil,
        lastOutputLineReader: (@MainActor (UUID) -> TerminalViewportTextReadResult)? = nil,
        recordSettledActivityStatus: (@MainActor (UUID, String?) -> Void)? = nil,
        clearPaneActivityStatus: (@MainActor (UUID) -> Void)? = nil,
        activityOccurrenceSink: (@Sendable (PaneActivityOccurrence) -> Void)? = nil,
        closeReadDurationSink: (@Sendable (Duration) -> Void)? = nil,
        unseenActivityDebounceDuration: Duration = AppPolicies.InboxNotification.terminalActivityQuietDebounceDuration,
        agentSettledQuietDuration: Duration = AppPolicies.InboxNotification.agentSettledQuietDuration,
        unseenActivityClock: (any Clock<Duration> & Sendable)? = nil,
        nowMilliseconds _: @escaping @Sendable () -> Int64 = {
            Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
        }
    ) {
        self.bus = bus
        self.projector =
            projector
            ?? TerminalActivityProjector(
                unseenQuietDuration: unseenActivityDebounceDuration,
                agentSettledQuietDuration: agentSettledQuietDuration,
                clock: unseenActivityClock,
                activitySink: activityOccurrenceSink,
                closeReadDurationSink: closeReadDurationSink
            )
        self.activityAtom = activityAtom
        self.attendedPane = attendedPane
        self.traceRuntime = traceRuntime
        self.startupTraceRecorder = startupTraceRecorder
        self.onFirstRender = onFirstRender
        self.surfaceIDForPaneID = surfaceIDForPaneID ?? { SurfaceManager.shared.surfaceId(forPaneId: $0) }
        self.isPaneCurrentlyAttended =
            isPaneCurrentlyAttended
            ?? { [attendedPane] paneID in
                attendedPane?.attendedPaneId == paneID
            }
        self.isPaneAgentClassified = isPaneAgentClassified ?? { _, paneKind in paneKind == .agent }
        self.lastOutputLineReader =
            lastOutputLineReader ?? { SurfaceManager.shared.readViewportTrailingText(forSurfaceID: $0) }
        self.recordSettledActivityStatus = recordSettledActivityStatus ?? { _, _ in }
        self.clearPaneActivityStatus = clearPaneActivityStatus ?? { _ in }
    }

    deinit {
        busTask?.cancel()
        attentionSettlementTask?.cancel()
        attentionDeliveryTask?.cancel()
        traceContinuation?.finish()
        traceWorkerTask?.cancel()
    }

    package func start() async {
        await enqueueLifecycleOperation(starting: true)
    }

    package func stop() async {
        await enqueueLifecycleOperation(starting: false)
    }

    private func enqueueLifecycleOperation(starting: Bool) async {
        lifecycleOperationSequence += 1
        let sequence = lifecycleOperationSequence
        let predecessor = lifecycleOperationTask
        let operation = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self else { return }
            if starting {
                await self.performStart()
            } else {
                await self.performStop()
            }
        }
        lifecycleOperationTask = operation
        await operation.value
        if lifecycleOperationSequence == sequence {
            lifecycleOperationTask = nil
        }
    }

    private func performStart() async {
        guard busTask == nil else { return }

        await projector.configure(
            lastOutputLineReader: { [weak self] surfaceID in
                self?.lastOutputLineReader(surfaceID) ?? .surfaceStale
            },
            outcomeSink: { [weak self] outcomes in
                self?.consumeProjectionOutcomes(outcomes)
            }
        )
        Ghostty.ActionRouter.bindTerminalActivityInput(
            id: projectorBindingID,
            context: { [weak self] paneID in
                self?.projectionContext(for: paneID)
                    ?? TerminalActivityProjectionContext(
                        isAttended: false,
                        isAgentClassified: false,
                        outputBurstThreshold: AppPolicies.InboxNotification.terminalActivityOutputBurstThresholdRows
                    )
            },
            sink: { [weak self] input in
                await self?.consumeTerminalActivityInput(input)
            }
        )
        let stream = await bus.subscribe(
            policy: .lossyNewest(BusSubscriberPolicy.standardLossyBufferLimit),
            subscriberName: "TerminalActivityRouter",
            factInterest: .matching([.paneTerminal])
        )
        busTask = Task { @MainActor [weak self] in
            for await envelope in stream {
                guard !Task.isCancelled, let self else { return }
                await consume(envelope)
            }
            if !Task.isCancelled {
                terminalActivityRouterLogger.warning(
                    "Runtime event stream ended while terminal activity router was active")
            }
        }
        attentionLifecycleEpoch += 1
        lastAttendedPaneID = attendedPane?.attendedPaneId
        observeAttendedPane()
    }

    private func performStop() async {
        Ghostty.ActionRouter.unbindTerminalActivityInput(id: projectorBindingID)
        let task = busTask
        task?.cancel()
        busTask = nil
        await stopAttentionDelivery()
        await task?.value
        await projector.reset()
        let derivedActivityPostTask = self.derivedActivityPostTask
        self.derivedActivityPostTask = nil
        await derivedActivityPostTask?.value
        await drainTraceRecords()
    }

    package func markUnseenActivityObserved(paneId: UUID) {
        guard let surfaceID = surfaceIDForPaneID(paneId) else { return }
        Task { @MainActor in
            await Ghostty.ActionRouter.applyOrderedActivityControl(
                surfaceID: surfaceID,
                paneID: paneId,
                control: .observed
            )
        }
    }

    /// Test-only seam: awaits any derived-activity bus post already enqueued by a prior
    /// `consumeTerminalActivityInput` call, without blocking ordinary production callers.
    package func waitForPendingDerivedActivityPosts() async {
        await derivedActivityPostTask?.value
    }

    func consumeTerminalActivityInput(_ input: TerminalActivitySourceInput) async {
        switch input {
        case .aggregate(let surfaceID, let paneID, let input):
            guard surfaceIDForPaneID(paneID) == surfaceID else { return }
            await projector.ingest(
                surfaceID: surfaceID,
                paneID: paneID,
                aggregate: input.aggregate,
                latestState: input.latestState,
                context: input.context
            )
        case .orderedControl(let surfaceID, let paneID, let precedingAggregate, let control):
            if control != .surfaceClosed {
                guard surfaceIDForPaneID(paneID) == surfaceID else { return }
            }
            await projector.applyOrderedControl(
                surfaceID: surfaceID,
                paneID: paneID,
                precedingAggregate: precedingAggregate,
                control: control
            )
        case .restorePhaseArmed(let paneID, let restoreGeneration):
            await projector.armRestorePhase(paneID: paneID, generation: restoreGeneration)
        case .restorePhaseEnded(let paneID, let restoreGeneration):
            await projector.endRestorePhase(paneID: paneID, generation: restoreGeneration)
        case .paneRetiredPermanently(let paneID):
            await projector.retirePanePermanently(paneID: paneID)
        }
    }

    private func consumeProjectionOutcomes(_ outcomes: [TerminalActivityProjectionOutcome]) {
        var derivedEnvelopes: [RuntimeEnvelope] = []
        for outcome in outcomes {
            consumeProjectionOutcome(outcome, derivedEnvelopes: &derivedEnvelopes)
        }
        enqueueDerivedActivityPosts(derivedEnvelopes)
    }

    private func consumeProjectionOutcome(
        _ outcome: TerminalActivityProjectionOutcome,
        derivedEnvelopes: inout [RuntimeEnvelope]
    ) {
        let surfaceID: UUID
        let paneID: UUID?
        switch outcome {
        case .compactStateChanged(let update):
            surfaceID = update.surfaceID
            paneID = update.paneID
        case .firstRender(let outcomeSurfaceID, let outcomePaneID),
            .paneObservationChanged(let outcomeSurfaceID, let outcomePaneID, _),
            .unseenActivitySettled(let outcomeSurfaceID, let outcomePaneID, _),
            .agentSettledActivityPromoted(let outcomeSurfaceID, let outcomePaneID, _),
            .agentSettledActivityRevoked(let outcomeSurfaceID, let outcomePaneID):
            surfaceID = outcomeSurfaceID
            paneID = outcomePaneID
        case .surfaceClosed(let outcomeSurfaceID, let outcomePaneID):
            surfaceID = outcomeSurfaceID
            paneID = outcomePaneID
        }

        if case .surfaceClosed = outcome {
            if let paneID, surfaceIDForPaneID(paneID) != nil { return }
        } else {
            guard let paneID, surfaceIDForPaneID(paneID) == surfaceID else { return }
        }

        switch outcome {
        case .compactStateChanged(let update):
            activityAtom.apply(update)
        case .firstRender(let surfaceID, let paneID):
            startupTraceRecorder?.recordFirstOutput(paneID: paneID, surfaceID: surfaceID)
            onFirstRender?(paneID)
        case .paneObservationChanged(_, let paneID, let isPinnedToBottom):
            derivedEnvelopes.append(
                derivedActivityEnvelope(
                    .paneObservationChanged(
                        TerminalPaneObservationState(isPinnedToBottom: isPinnedToBottom)
                    ),
                    paneID: paneID
                ))
        case .unseenActivitySettled(_, let paneID, let activity):
            // Written unconditionally, ahead of and independent of InboxNotificationRouter's
            // consumption of the derived envelope below, so a pane's own sidebar row always learns
            // its latest real output line even when InboxPromoter suppresses the notification for
            // small observed/attended bursts.
            recordSettledActivityStatus(paneID, activity.lastOutputLine)
            derivedEnvelopes.append(
                derivedActivityEnvelope(.unseenActivitySettled(activity), paneID: paneID))
        case .agentSettledActivityPromoted(_, let paneID, let activity):
            recordSettledActivityStatus(paneID, activity.lastOutputLine)
            derivedEnvelopes.append(
                derivedActivityEnvelope(.agentSettledActivityPromoted(activity), paneID: paneID))
        case .agentSettledActivityRevoked(_, let paneID):
            derivedEnvelopes.append(
                derivedActivityEnvelope(.agentSettledActivityRevoked, paneID: paneID))
        case .surfaceClosed(_, let paneID):
            if let paneID {
                activityAtom.clear(paneId: paneID)
                clearPaneActivityStatus(paneID)
            }
        }
    }

    private func projectionContext(for paneID: UUID) -> TerminalActivityProjectionContext {
        TerminalActivityProjectionContext(
            isAttended: isPaneCurrentlyAttended(paneID),
            isAgentClassified: isPaneAgentClassified(paneID, .terminal),
            outputBurstThreshold: activityAtom.outputBurstThreshold
        )
    }

    /// Internal for @testable owner-application proof; production calls it from busTask.
    func consume(_ envelope: RuntimeEnvelope) async {
        guard case .pane(let paneEnvelope) = envelope else { return }
        activityAtom.consume(paneEnvelope)
        if case .terminal(let event) = paneEnvelope.event,
            !RuntimeEnvelopeTraceSummary.isHighVolumeActivityOnly(.terminal(event)),
            let surfaceID = surfaceIDForPaneID(paneEnvelope.paneId.uuid)
        {
            if case .commandFinished = event {
                // Source delivery already applied the exact ordered settle before this ordinary
                // semantic fact entered the lossy bus. Other consumers retain the fact; this
                // projector must not settle it twice or depend on subscriber delivery.
            } else {
                await Ghostty.ActionRouter.applyOrderedActivityControl(
                    surfaceID: surfaceID,
                    paneID: paneEnvelope.paneId.uuid,
                    control: .semanticSignal
                )
            }
        }
        await traceTerminalActivity(paneEnvelope)
    }

    private func derivedActivityEnvelope(_ event: TerminalActivityEvent, paneID: UUID) -> RuntimeEnvelope {
        .pane(
            PaneEnvelope(
                source: .system(.builtin(.terminalActivityRouter)),
                seq: nextDerivedActivitySequence(),
                timestamp: ContinuousClock().now,
                paneId: PaneId(existingUUID: paneID),
                paneKind: .terminal,
                event: .terminalActivity(event)
            )
        )
    }

    private func enqueueDerivedActivityPosts(_ envelopes: [RuntimeEnvelope]) {
        guard !envelopes.isEmpty else { return }
        let predecessor = derivedActivityPostTask
        let bus = self.bus
        derivedActivityPostTask = Task {
            await predecessor?.value
            for envelope in envelopes {
                _ = await bus.post(envelope)
            }
        }
    }

    private func nextDerivedActivitySequence() -> UInt64 {
        if derivedActivitySequence == .max {
            terminalActivityRouterLogger.warning("Derived terminal activity sequence overflow; restarting at 1")
            derivedActivitySequence = 0
        }
        derivedActivitySequence += 1
        return derivedActivitySequence
    }

    private func traceTerminalActivity(_ envelope: PaneEnvelope) async {
        guard case .terminal(let event) = envelope.event else { return }
        guard !RuntimeEnvelopeTraceSummary.isHighVolumeActivityOnly(envelope.event) else { return }
        guard traceRuntime != nil else { return }
        ensureTraceWorkerStarted()
        traceEventBusDelivery(envelope)
        traceContinuation?.yield(
            .init(
                tag: .terminalActivity,
                body: "terminal.activity.observed",
                traceID: envelope.correlationId?.uuidString,
                parentSpanID: envelope.causationId?.uuidString,
                attributes: terminalTraceAttributes(for: envelope, event: event)
            )
        )
    }

    private func traceEventBusDelivery(_ envelope: PaneEnvelope) {
        var attributes = RuntimeEnvelopeTraceSummary(envelope).attributes(
            eventBusName: "paneRuntime",
            consumerName: "TerminalActivityRouter"
        )
        attributes["agentstudio.eventbus.delivery"] = .string("consumed")
        traceContinuation?.yield(
            .init(
                tag: .eventbus,
                body: "eventbus.deliver",
                traceID: envelope.correlationId?.uuidString,
                parentSpanID: envelope.causationId?.uuidString,
                attributes: attributes
            )
        )
    }

    private func ensureTraceWorkerStarted() {
        guard traceWorkerTask == nil, let traceRuntime else { return }
        let (stream, continuation) = AsyncStream.makeStream(
            of: TraceRequest.self,
            bufferingPolicy: .bufferingNewest(AppPolicies.Diagnostics.traceEventQueueBufferLimit)
        )
        traceContinuation = continuation
        // swiftlint:disable:next no_task_detached
        traceWorkerTask = Task.detached(priority: .utility) {
            for await request in stream {
                await traceRuntime.record(
                    tag: request.tag,
                    body: request.body,
                    traceID: request.traceID,
                    parentSpanID: request.parentSpanID,
                    attributes: request.attributes
                )
            }
        }
    }

    private func drainTraceRecords() async {
        traceContinuation?.finish()
        traceContinuation = nil
        let workerTask = traceWorkerTask
        traceWorkerTask = nil
        await workerTask?.value
        do {
            try await traceRuntime?.flush()
        } catch {
            let diagnostics = await traceRuntime?.diagnostics() ?? .empty
            terminalActivityRouterLogger.warning(
                "Terminal activity trace flush failed: \(error.localizedDescription); failedFlushCount=\(diagnostics.failedFlushCount); lastFlushError=\(diagnostics.lastFlushErrorDescription ?? "none")"
            )
        }
    }

    private func terminalTraceAttributes(
        for envelope: PaneEnvelope,
        event: GhosttyEvent
    ) -> [String: AgentStudioTraceValue] {
        var attributes: [String: AgentStudioTraceValue] = [
            "agentstudio.envelope.event_id": .string(envelope.eventId.uuidString),
            "agentstudio.envelope.seq": .int(Int(envelope.seq)),
            "agentstudio.pane.id": .string(envelope.paneId.uuidString),
            "agentstudio.pane.kind": .string(envelope.paneKind.traceName),
            "agentstudio.runtime.event": .string(event.traceEventName),
        ]
        if let commandId = envelope.commandId {
            attributes["agentstudio.command.id"] = .string(commandId.uuidString)
        }
        if let correlationId = envelope.correlationId {
            attributes["agentstudio.envelope.correlation_id"] = .string(correlationId.uuidString)
        }
        if let causationId = envelope.causationId {
            attributes["agentstudio.envelope.causation_id"] = .string(causationId.uuidString)
        }
        return attributes
    }
}

// MARK: - Settled attention capture and ordered delivery

extension TerminalActivityRouter {
    private struct AttentionControlDelivery {
        let paneID: UUID
        let surfaceID: UUID
        let before: TerminalActivityProjectionContext
        let after: TerminalActivityProjectionContext
    }

    private func observeAttendedPane() {
        guard let attendedPane, busTask != nil else { return }
        attentionObservationGeneration += 1
        let generation = attentionObservationGeneration
        let epoch = attentionLifecycleEpoch
        withObservationTracking {
            _ = attendedPane.attendedPaneId
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.busTask != nil,
                    self.attentionLifecycleEpoch == epoch,
                    self.attentionObservationGeneration == generation
                else { return }
                self.scheduleAttentionSettlement(epoch: epoch)
            }
        }
    }

    private func scheduleAttentionSettlement(epoch: Int) {
        guard attentionSettlementTask == nil else { return }
        attentionSettlementTask = Task { @MainActor [weak self] in
            guard let self, self.attentionLifecycleEpoch == epoch else { return }
            self.attentionSettlementTask = nil
            guard !Task.isCancelled, self.busTask != nil else { return }
            self.observeAttendedPane()
            self.captureSettledAttention(epoch: epoch)
        }
    }

    private func captureSettledAttention(epoch: Int) {
        let next = attendedPane?.attendedPaneId
        let previous = lastAttendedPaneID
        guard next != previous else { return }
        lastAttendedPaneID = next
        // This ordered list is one settled transition, not raw willSet mutations.
        for paneID in [previous, next].compactMap({ $0 }) {
            guard let surfaceID = surfaceIDForPaneID(paneID) else { continue }
            let context = projectionContext(for: paneID)
            pendingAttentionControls.append(
                AttentionControlDelivery(
                    paneID: paneID,
                    surfaceID: surfaceID,
                    before: TerminalActivityProjectionContext(
                        isAttended: paneID == previous,
                        isAgentClassified: context.isAgentClassified,
                        outputBurstThreshold: context.outputBurstThreshold
                    ),
                    after: TerminalActivityProjectionContext(
                        isAttended: paneID == next && context.isAttended,
                        isAgentClassified: context.isAgentClassified,
                        outputBurstThreshold: context.outputBurstThreshold
                    )
                )
            )
        }
        guard attentionDeliveryTask == nil, !pendingAttentionControls.isEmpty else { return }
        attentionDeliveryTask = Task { @MainActor [weak self] in
            await self?.deliverPendingAttention(epoch: epoch)
        }
    }

    private func deliverPendingAttention(epoch: Int) async {
        defer {
            if attentionLifecycleEpoch == epoch { attentionDeliveryTask = nil }
        }
        while !Task.isCancelled, attentionLifecycleEpoch == epoch, busTask != nil,
            !pendingAttentionControls.isEmpty
        {
            // Transfer the pending batch without shifting its remaining elements per control.
            // New settled transitions append to the next batch while this one is suspended.
            var deliveries: [AttentionControlDelivery] = []
            swap(&deliveries, &pendingAttentionControls)
            for delivery in deliveries {
                guard !Task.isCancelled, attentionLifecycleEpoch == epoch, busTask != nil else { return }
                guard surfaceIDForPaneID(delivery.paneID) == delivery.surfaceID else { continue }
                await Ghostty.ActionRouter.applyOrderedActivityControl(
                    surfaceID: delivery.surfaceID,
                    paneID: delivery.paneID,
                    control: .contextChanged(delivery.after),
                    contextBeforeControl: delivery.before,
                    contextAfterControl: delivery.after
                )
            }
        }
    }

    private func stopAttentionDelivery() async {
        attentionLifecycleEpoch += 1
        attentionObservationGeneration += 1
        let settlement = attentionSettlementTask
        let delivery = attentionDeliveryTask
        attentionSettlementTask = nil
        attentionDeliveryTask = nil
        pendingAttentionControls.removeAll()
        settlement?.cancel()
        delivery?.cancel()
        await settlement?.value
        await delivery?.value
    }

    /// Joins the current per-turn capture without waiting for potentially blocked delivery.
    package func waitForPendingAttentionSettlement() async {
        await attentionSettlementTask?.value
    }

    /// Joins work already requested by the caller's mutations.
    package func waitForPendingAttentionDelivery() async {
        await attentionSettlementTask?.value
        await attentionDeliveryTask?.value
    }
}
