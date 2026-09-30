import Foundation

package enum TerminalAccumulatorDrainClass: String, Equatable, Sendable {
    case immediate
    case titleDeadline = "title_deadline"
    case exactBarrier = "exact_barrier"
}

package enum TerminalPerformancePublicationKind: String, Equatable, Sendable {
    case activity
    case cwd
    case title
}

package enum TerminalAccumulatorApplyOutcome: String, Equatable, Sendable {
    case equal
    case changed
}

package enum PaneAssociationOutcome: String, Equatable, Sendable {
    case stampedKnown = "stamped_known"
    case resolvedChanged = "resolved_changed"
    case resolvedEqual = "resolved_equal"
    case clearedNoMatch = "cleared_no_match"
    case topologyRemoved = "topology_removed"
    case deferredUncertain = "deferred_uncertain"
    case freeNil = "free_nil"
}

package struct PaneAssociationBootReconciliationSummary: Equatable, Sendable {
    package let paneCount: UInt64
    package let retainedKnownCount: UInt64
    package let backfilledCount: UInt64
    package let danglingClearedCount: UInt64
    package let freeNilCount: UInt64
    package let changedCount: UInt64

    package init(
        paneCount: UInt64,
        retainedKnownCount: UInt64,
        backfilledCount: UInt64,
        danglingClearedCount: UInt64,
        freeNilCount: UInt64,
        changedCount: UInt64
    ) {
        self.paneCount = paneCount
        self.retainedKnownCount = retainedKnownCount
        self.backfilledCount = backfilledCount
        self.danglingClearedCount = danglingClearedCount
        self.freeNilCount = freeNilCount
        self.changedCount = changedCount
    }
}

package struct TerminalAccumulatorDrainPerformanceSnapshot: Equatable, Sendable {
    let drainClass: TerminalAccumulatorDrainClass
    let offeredCount: UInt64
    let replacedCount: UInt64
    let equalSuppressedCount: UInt64
    let scheduledDrainCount: UInt64
    let followUpDrainCount: UInt64
    let mainActorTaskCount: UInt64
    let activityAggregateCount: UInt64
    let outputAdvancementCount: UInt64
    let retainedEntryCount: UInt64
    let retainedSizeBytes: UInt64

    package init(
        drainClass: TerminalAccumulatorDrainClass,
        offeredCount: UInt64,
        replacedCount: UInt64,
        equalSuppressedCount: UInt64,
        scheduledDrainCount: UInt64,
        followUpDrainCount: UInt64,
        mainActorTaskCount: UInt64,
        activityAggregateCount: UInt64,
        outputAdvancementCount: UInt64 = 0,
        retainedEntryCount: UInt64,
        retainedSizeBytes: UInt64
    ) {
        self.drainClass = drainClass
        self.offeredCount = offeredCount
        self.replacedCount = replacedCount
        self.equalSuppressedCount = equalSuppressedCount
        self.scheduledDrainCount = scheduledDrainCount
        self.followUpDrainCount = followUpDrainCount
        self.mainActorTaskCount = mainActorTaskCount
        self.activityAggregateCount = activityAggregateCount
        self.outputAdvancementCount = outputAdvancementCount
        self.retainedEntryCount = retainedEntryCount
        self.retainedSizeBytes = retainedSizeBytes
    }
}

package struct TerminalCompactApplyPerformanceSnapshot: Equatable, Sendable {
    let equalWriteSuppressedCount: UInt64
    let activityProjectionRoundTrip: TerminalActivityProjectionRoundTripPerformance

    package init(
        equalWriteSuppressedCount: UInt64,
        activityProjectionRoundTrip: TerminalActivityProjectionRoundTripPerformance
    ) {
        self.equalWriteSuppressedCount = equalWriteSuppressedCount
        self.activityProjectionRoundTrip = activityProjectionRoundTrip
    }
}

package enum TerminalActivityProjectionRoundTripPerformance: Equatable, Sendable {
    case notSubmitted
    case completed(Duration)
}

package struct SidebarPerformanceTerminalWorkloadSnapshot: Equatable, Sendable {
    package let terminalInputCount: UInt64
    package let terminalOutputAdvancementCount: UInt64
    package let orderedCommandCount: UInt64

    package init(
        terminalInputCount: UInt64,
        terminalOutputAdvancementCount: UInt64,
        orderedCommandCount: UInt64
    ) {
        self.terminalInputCount = terminalInputCount
        self.terminalOutputAdvancementCount = terminalOutputAdvancementCount
        self.orderedCommandCount = orderedCommandCount
    }
}

package struct FilesystemEffectPerformanceSnapshot: Equatable, Sendable {
    let fullReconciliationRequestCount: UInt64
    let affectedKeyRequestCount: UInt64

    package init(
        fullReconciliationRequestCount: UInt64,
        affectedKeyRequestCount: UInt64
    ) {
        self.fullReconciliationRequestCount = fullReconciliationRequestCount
        self.affectedKeyRequestCount = affectedKeyRequestCount
    }
}

package struct TraceIdentityPerformanceSnapshot: Equatable, Sendable {
    let refreshRequestCount: UInt64
    let coalescedRequestCount: UInt64
    let fleetCaptureCount: UInt64
    let equalSnapshotSuppressedCount: UInt64

    package init(
        refreshRequestCount: UInt64,
        coalescedRequestCount: UInt64,
        fleetCaptureCount: UInt64,
        equalSnapshotSuppressedCount: UInt64
    ) {
        self.refreshRequestCount = refreshRequestCount
        self.coalescedRequestCount = coalescedRequestCount
        self.fleetCaptureCount = fleetCaptureCount
        self.equalSnapshotSuppressedCount = equalSnapshotSuppressedCount
    }
}

package enum AgentStudioFocusResponderChangeReason: String, Sendable {
    case userClick = "user_click"
    case restoreTail = "restore_tail"
    case restoreTailSkippedUserFocus = "restore_tail_skipped_user_focus"
    case parkedReplay = "parked_replay"
    case parkedCleared = "parked_cleared"
}

package final class AgentStudioPerformanceTraceRecorder: @unchecked Sendable {
    package typealias PeriodicSnapshotReporter = @MainActor @Sendable () -> Void

    package struct TopologyLookupFact: Hashable, Sendable {
        let normalizedCWD: String
        let worktreePathIndexGeneration: UInt64
        let repoId: UUID?
        let worktreeId: UUID?

        package init(
            normalizedCWD: String,
            worktreePathIndexGeneration: UInt64,
            repoId: UUID?,
            worktreeId: UUID?
        ) {
            self.normalizedCWD = normalizedCWD
            self.worktreePathIndexGeneration = worktreePathIndexGeneration
            self.repoId = repoId
            self.worktreeId = worktreeId
        }
    }

    package enum Event: String, Sendable {
        case atomDerived = "performance.atom.derived"
        case atomMutation = "performance.atom.mutation"
        case atomRead = "performance.atom.read"
        case applyGovernorDrain = "performance.apply_governor.drain"
        case bridgeGitReadScheduler = "performance.bridge.git_read_scheduler"
        case bridgeWorktreeProductConstruction = "performance.bridge.worktree_product_construction"
        case commandBarFilter = "performance.commandbar.filter"
        case commandBarItems = "performance.commandbar.items"
        case commandBarCache = "performance.commandbar.cache"
        case commandBarSearch = "performance.commandbar.search"
        case coordinatorWrite = "performance.coordinator.write"
        case filesystemEffectSnapshot = "performance.filesystem.effect_snapshot"
        case filesystemIngressSnapshot = "performance.filesystem.ingress_snapshot"
        case filesystemStageOutcome = "performance.filesystem.stage_outcome"
        case filesystemLogicalDebt = "performance.filesystem.logical_debt"
        case focusResponderChange = "performance.focus.responder_change"
        case forgeRefresh = "performance.forge.refresh"
        case gitAdmission = "performance.git.admission"
        case gitAggregate = "performance.git.aggregate"
        case gitBackoff = "performance.git.backoff"
        case gitEventPosted = "performance.git.event_posted"
        case gitPathQuarantine = "performance.git.path_quarantine"
        case gitLogicalDebt = "performance.git.logical_debt"
        case gitSnapshotDedup = "performance.git.snapshot_dedup"
        case gitStatusComputed = "performance.git.status"
        case gitStatusUnavailable = "performance.git.status_unavailable"
        case gitSuppressedInputSkipped = "performance.git.suppressed_input_skipped"
        case gitTick = "performance.git.tick"
        case interactionLatency = "performance.interaction.latency"
        case ipcAgentAuthorization = "performance.ipc.agent_authorization"
        case ipcAgentAuthorizationMainActorHeld = "performance.ipc.agent_authorization.main_actor_held"
        case managementLayerAppKitState = "performance.management_layer.appkit_state"
        case managementLayerCommand = "performance.management_layer.command"
        case paneAssociation = "performance.pane.association"
        case paneAssociationBootReconciliation = "performance.pane.association_boot_reconciliation"
        case paneActionExecution = "performance.pane_action.execution"
        case paneTabLayout = "performance.pane_tab.layout"
        case paneViewRestore = "performance.pane_view.restore"
        case paneViewRestoreVisible = "performance.pane_view.restore_visible"
        case repoExplorerCommandPresentation = "performance.repo_explorer.command_presentation"
        case repoExplorerKeyedWake = "performance.repo_explorer.keyed_wake"
        case repoExplorerNativeTablePilot = "performance.repo_explorer.native_table_pilot"
        case repoExplorerStageSnapshot = "performance.repo_explorer.stage_snapshot"
        case repoExplorerOutlineApplyProxy = "performance.repo_explorer.outline_apply_proxy"
        case repositoryFactDemand = "performance.repository_fact_demand"
        case repositoryFactUpdate = "performance.repository_fact_update"
        case repositoryLifecyclePreparation = "performance.repository_lifecycle.preparation"
        case repositoryLifecyclePublication = "performance.repository_lifecycle.publication"
        case repositoryRetentionPreparation = "performance.repository_retention.preparation"
        case repositoryRetentionCommit = "performance.repository_retention.commit"
        case remoteReferenceRefresh = "performance.remote_reference.refresh"
        case repoExplorerRowBodyEvaluation = "performance.repo_explorer.row_body_evaluation"
        case repoExplorerScrollFrameGap = "performance.repo_explorer.scroll_frame_gap"
        case repoAndWorktreeLookup = "performance.topology.repo_and_worktree"
        case processMallocZone = "performance.process.malloc_zone"
        case rendererLifecycle = "performance.renderer.lifecycle"
        case runtimeDeliverySnapshot = "performance.runtime_delivery.snapshot"
        case sidebarFilterInput = "performance.sidebar.filter_input"
        case sidebarProofWorkloadChanged = "performance.sidebar.proof_workload_changed"
        case sidebarProjection = "performance.sidebar.projection"
        case sidebarRowIndex = "performance.sidebar.row_index"
        case sidebarResize = "performance.sidebar.resize"
        case sidebarToggle = "performance.sidebar.toggle"
        case startupUsable = "performance.startup.usable"
        case startupDeferral = "performance.startup.deferral"
        case tabBarCurrent = "performance.tabbar.current"
        case tabBarCapture = "performance.tabbar.capture"
        case tabBarContextMenu = "performance.tabbar.context_menu"
        case tabBarPaneDrop = "performance.tabbar.pane_drop"
        case tabBarPublication = "performance.tabbar.publication"
        case tabBarRefresh = "performance.tabbar.refresh"
        case tabBarTerminal = "performance.tabbar.terminal"
        case tabBarVisible = "performance.tabbar.visible"
        case tabBarWorker = "performance.tabbar.worker"
        case terminalAccumulatorDrain = "performance.terminal.accumulator_drain"
        case terminalCompactApply = "performance.terminal.compact_apply"
        case terminalActivityCloseRead = "performance.terminal.activity_projection.close_read"
        case terminalEqualSuppressed = "performance.terminal.equal_suppressed"
        case terminalForceGeometrySync = "performance.terminal.force_geometry_sync"
        case terminalGeometrySync = "performance.terminal.geometry_sync"
        case terminalMountLayout = "performance.terminal.mount_layout"
        case terminalSurfaceSizeDidChange = "performance.terminal.surface_size"
        case traceIdentitySnapshot = "performance.trace_identity.snapshot"
    }

    private let traceRuntime: AgentStudioTraceRuntime?
    private let eventQueue: AgentStudioTraceEventQueue?
    private let lock = NSLock()
    private var topologyLookupAdmission = TopologyLookupTraceAdmission()
    private var paneAssociationAdmission = PaneAssociationTraceAdmission()
    private var sidebarPerformanceTerminalWorkload = SidebarPerformanceTerminalWorkloadSnapshot(
        terminalInputCount: 0,
        terminalOutputAdvancementCount: 0,
        orderedCommandCount: 0
    )
    private var sidebarPerformanceProofWorkloadBaseline: SidebarPerformanceTerminalWorkloadSnapshot?
    private var didRecordSidebarPerformanceProofWorkloadChange = false
    private var rendererLifecycleState = RendererLifecyclePerformanceState()
    private let processMemorySampler: AgentStudioProcessMemorySampler?
    private let runtimeDeliveryPerformanceReporter: RuntimeDeliveryPerformanceReporter?
    private let periodicSnapshotReporterRegistry: PeriodicSnapshotReporterRegistry
    private var recordedStartupLaunchInstant: ContinuousClock.Instant

    package init(
        traceRuntime: AgentStudioTraceRuntime?,
        runtimeDeliveryPerformanceReporter: RuntimeDeliveryPerformanceReporter? = nil,
        processMemorySampleWait: @escaping AgentStudioProcessMemorySampler.WaitForNextSample =
            AgentStudioProcessMemorySampler.waitOneSecond
    ) {
        self.recordedStartupLaunchInstant = ContinuousClock.now
        let periodicSnapshotReporterRegistry = PeriodicSnapshotReporterRegistry()
        self.periodicSnapshotReporterRegistry = periodicSnapshotReporterRegistry
        self.traceRuntime = traceRuntime
        if let traceRuntime, traceRuntime.isEnabled(.performance) {
            runtimeDeliveryPerformanceReporter?.enable()
            self.runtimeDeliveryPerformanceReporter = runtimeDeliveryPerformanceReporter
            let eventQueue = AgentStudioTraceEventQueue(traceRuntime: traceRuntime)
            self.eventQueue = eventQueue
            let processMemorySampler = AgentStudioProcessMemorySampler(
                waitForNextSample: processMemorySampleWait
            ) { snapshot in
                eventQueue.record(
                    tag: .performance,
                    body: Event.processMallocZone.rawValue,
                    eventTimeUnixNano: traceRuntime.timestampUnixNano(),
                    attributes: snapshot.traceAttributes
                )
                if let runtimeDeliverySnapshot = runtimeDeliveryPerformanceReporter?.snapshot() {
                    eventQueue.record(
                        tag: .performance,
                        body: Event.runtimeDeliverySnapshot.rawValue,
                        eventTimeUnixNano: traceRuntime.timestampUnixNano(),
                        attributes: runtimeDeliverySnapshot.traceAttributes
                    )
                }
                Task { @MainActor in
                    for reporter in periodicSnapshotReporterRegistry.snapshot() {
                        reporter()
                    }
                }
            }
            self.processMemorySampler = processMemorySampler
            processMemorySampler.start()
        } else {
            self.eventQueue = nil
            self.processMemorySampler = nil
            self.runtimeDeliveryPerformanceReporter = nil
        }
    }

    deinit {
        processMemorySampler?.cancel()
        runtimeDeliveryPerformanceReporter?.disable()
    }

    package var isEnabled: Bool {
        eventQueue != nil
    }

    package var startupLaunchInstant: ContinuousClock.Instant {
        lock.withLock { recordedStartupLaunchInstant }
    }

    package func markStartupLaunchStarted() {
        lock.withLock {
            recordedStartupLaunchInstant = ContinuousClock.now
        }
    }

    package func recordSidebarPerformanceTerminalInput() {
        let changedSnapshot = lock.withLock { () -> SidebarPerformanceTerminalWorkloadSnapshot? in
            sidebarPerformanceTerminalWorkload = SidebarPerformanceTerminalWorkloadSnapshot(
                terminalInputCount: sidebarPerformanceTerminalWorkload.terminalInputCount &+ 1,
                terminalOutputAdvancementCount: sidebarPerformanceTerminalWorkload
                    .terminalOutputAdvancementCount,
                orderedCommandCount: sidebarPerformanceTerminalWorkload.orderedCommandCount
            )
            return claimSidebarPerformanceProofWorkloadChangeIfNeeded()
        }
        recordSidebarPerformanceProofWorkloadChange(changedSnapshot, kind: "terminal_input")
    }

    package func recordSidebarPerformanceTerminalOutputAdvancements(_ count: UInt64) {
        guard count > 0 else { return }
        let changedSnapshot = lock.withLock { () -> SidebarPerformanceTerminalWorkloadSnapshot? in
            sidebarPerformanceTerminalWorkload = SidebarPerformanceTerminalWorkloadSnapshot(
                terminalInputCount: sidebarPerformanceTerminalWorkload.terminalInputCount,
                terminalOutputAdvancementCount: sidebarPerformanceTerminalWorkload
                    .terminalOutputAdvancementCount &+ count,
                orderedCommandCount: sidebarPerformanceTerminalWorkload.orderedCommandCount
            )
            return claimSidebarPerformanceProofWorkloadChangeIfNeeded()
        }
        recordSidebarPerformanceProofWorkloadChange(changedSnapshot, kind: "terminal_output")
    }

    package func recordSidebarPerformanceOrderedCommand() {
        let changedSnapshot = lock.withLock { () -> SidebarPerformanceTerminalWorkloadSnapshot? in
            sidebarPerformanceTerminalWorkload = SidebarPerformanceTerminalWorkloadSnapshot(
                terminalInputCount: sidebarPerformanceTerminalWorkload.terminalInputCount,
                terminalOutputAdvancementCount: sidebarPerformanceTerminalWorkload
                    .terminalOutputAdvancementCount,
                orderedCommandCount: sidebarPerformanceTerminalWorkload.orderedCommandCount &+ 1
            )
            return claimSidebarPerformanceProofWorkloadChangeIfNeeded()
        }
        recordSidebarPerformanceProofWorkloadChange(changedSnapshot, kind: "ordered_command")
    }

    package func sidebarPerformanceTerminalWorkloadSnapshot()
        -> SidebarPerformanceTerminalWorkloadSnapshot
    {
        lock.withLock { sidebarPerformanceTerminalWorkload }
    }

    package func beginSidebarPerformanceWorkloadProof()
        -> SidebarPerformanceTerminalWorkloadSnapshot
    {
        lock.withLock {
            sidebarPerformanceProofWorkloadBaseline = sidebarPerformanceTerminalWorkload
            didRecordSidebarPerformanceProofWorkloadChange = false
            return sidebarPerformanceTerminalWorkload
        }
    }

    package func completeSidebarPerformanceWorkloadProof()
        -> SidebarPerformanceTerminalWorkloadSnapshot
    {
        lock.withLock {
            sidebarPerformanceProofWorkloadBaseline = nil
            return sidebarPerformanceTerminalWorkload
        }
    }

    private func claimSidebarPerformanceProofWorkloadChangeIfNeeded()
        -> SidebarPerformanceTerminalWorkloadSnapshot?
    {
        guard let baseline = sidebarPerformanceProofWorkloadBaseline,
            sidebarPerformanceTerminalWorkload != baseline,
            !didRecordSidebarPerformanceProofWorkloadChange
        else { return nil }
        didRecordSidebarPerformanceProofWorkloadChange = true
        return sidebarPerformanceTerminalWorkload
    }

    private func recordSidebarPerformanceProofWorkloadChange(
        _ snapshot: SidebarPerformanceTerminalWorkloadSnapshot?,
        kind: String
    ) {
        guard let snapshot else { return }
        record(
            .sidebarProofWorkloadChanged,
            attributes: [
                "agentstudio.performance.sidebar.proof.workload.kind": .string(kind),
                "agentstudio.performance.sidebar.proof.terminal_input.count": Self.traceInteger(
                    snapshot.terminalInputCount),
                "agentstudio.performance.sidebar.proof.terminal_output.count": Self.traceInteger(
                    snapshot.terminalOutputAdvancementCount),
                "agentstudio.performance.sidebar.proof.ordered_command.count": Self.traceInteger(
                    snapshot.orderedCommandCount),
            ]
        )
    }

    package func record(
        _ event: Event,
        attributes: @autoclosure () -> [String: AgentStudioTraceValue] = [:]
    ) {
        guard let traceRuntime, traceRuntime.isEnabled(.performance), let eventQueue else { return }
        eventQueue.record(
            tag: .performance,
            body: event.rawValue,
            eventTimeUnixNano: traceRuntime.timestampUnixNano(),
            attributes: attributes()
        )
    }

    @discardableResult
    package func registerPeriodicSnapshotReporter(
        _ reporter: @escaping PeriodicSnapshotReporter
    ) -> UUID {
        periodicSnapshotReporterRegistry.register(reporter)
    }

    package func unregisterPeriodicSnapshotReporter(_ token: UUID) {
        periodicSnapshotReporterRegistry.unregister(token)
    }

    package func recordDuration(
        _ event: Event,
        duration: Duration,
        attributes: @autoclosure () -> [String: AgentStudioTraceValue] = [:]
    ) {
        guard isEnabled else { return }
        var mergedAttributes = attributes()
        mergedAttributes["agentstudio.performance.elapsed_ms"] = .double(Self.milliseconds(from: duration))
        record(event, attributes: mergedAttributes)
    }

    package func recordInteractionLatency(
        kind: AgentStudioInteractionKind,
        duration: Duration
    ) {
        recordDuration(
            .interactionLatency,
            duration: duration,
            attributes: [
                "agentstudio.performance.interaction.kind": .string(kind.rawValue)
            ]
        )
    }

    package func recordStartupUsable(
        launchToUsable: Duration,
        layoutSettleToUsable: Duration,
        source: String
    ) {
        recordDuration(
            .startupUsable,
            duration: launchToUsable,
            attributes: [
                "agentstudio.performance.startup.layout_settle_to_usable_elapsed_ms": .double(
                    Self.milliseconds(from: layoutSettleToUsable)
                ),
                "agentstudio.performance.startup.source": .string(source),
            ]
        )
    }

    package func recordStartupDeferral(
        gate: String,
        outcome: StartupDeferralOutcome
    ) {
        record(
            .startupDeferral,
            attributes: [
                "agentstudio.performance.startup.deferral.gate": .string(gate),
                "agentstudio.performance.startup.deferral.outcome": .string(outcome.rawValue),
            ]
        )
    }

    package func recordFocusResponderChange(reason: AgentStudioFocusResponderChangeReason) {
        record(
            .focusResponderChange,
            attributes: [
                "agentstudio.performance.focus.responder_change.reason": .string(reason.rawValue)
            ]
        )
    }

    package func recordRepoAndWorktreeLookup(
        duration: Duration,
        indexCount: Int,
        hasMatch: Bool,
        fact: TopologyLookupFact
    ) {
        guard shouldRecordTopologyLookup(fact) else { return }
        recordDuration(
            .repoAndWorktreeLookup,
            duration: duration,
            attributes: [
                "agentstudio.performance.topology.index.count": .int(indexCount),
                "agentstudio.performance.topology.has_match": .bool(hasMatch),
            ]
        )
    }

    package func recordPaneAssociationOutcome(_ outcome: PaneAssociationOutcome) {
        guard shouldRecordPaneAssociationOutcome() else { return }
        record(
            .paneAssociation,
            attributes: [
                "agentstudio.performance.pane.association_outcome": .string(outcome.rawValue)
            ]
        )
    }

    package func recordPaneAssociationBootReconciliation(
        _ summary: PaneAssociationBootReconciliationSummary
    ) {
        record(
            .paneAssociationBootReconciliation,
            attributes: [
                "agentstudio.performance.pane.association_boot.pane.count": Self.traceInteger(
                    summary.paneCount
                ),
                "agentstudio.performance.pane.association_boot.retained_known.count": Self.traceInteger(
                    summary.retainedKnownCount
                ),
                "agentstudio.performance.pane.association_boot.backfilled.count": Self.traceInteger(
                    summary.backfilledCount
                ),
                "agentstudio.performance.pane.association_boot.dangling_cleared.count": Self.traceInteger(
                    summary.danglingClearedCount
                ),
                "agentstudio.performance.pane.association_boot.free_nil.count": Self.traceInteger(
                    summary.freeNilCount
                ),
                "agentstudio.performance.pane.association_boot.changed.count": Self.traceInteger(
                    summary.changedCount
                ),
            ]
        )
    }

    package func recordTerminalAccumulatorDrain(
        _ snapshot: TerminalAccumulatorDrainPerformanceSnapshot,
        queueAge: Duration,
        applyOutcome: TerminalAccumulatorApplyOutcome?
    ) {
        recordSidebarPerformanceTerminalOutputAdvancements(snapshot.outputAdvancementCount)
        var attributes: [String: AgentStudioTraceValue] = [
            "agentstudio.performance.terminal.accumulator.drain.class": .string(
                snapshot.drainClass.rawValue
            ),
            "agentstudio.performance.terminal.accumulator.offered.count": Self.traceInteger(
                snapshot.offeredCount),
            "agentstudio.performance.terminal.accumulator.replaced.count": Self.traceInteger(
                snapshot.replacedCount),
            "agentstudio.performance.terminal.accumulator.equal_suppressed.count": Self.traceInteger(
                snapshot.equalSuppressedCount),
            "agentstudio.performance.terminal.accumulator.scheduled_drain.count": Self.traceInteger(
                snapshot.scheduledDrainCount),
            "agentstudio.performance.terminal.accumulator.follow_up_drain.count": Self.traceInteger(
                snapshot.followUpDrainCount),
            "agentstudio.performance.terminal.accumulator.mainactor_task.count": Self.traceInteger(
                snapshot.mainActorTaskCount),
            "agentstudio.performance.terminal.activity_aggregate.count": Self.traceInteger(
                snapshot.activityAggregateCount),
            "agentstudio.performance.terminal.output_advancement.count": Self.traceInteger(
                snapshot.outputAdvancementCount),
            "agentstudio.performance.terminal.accumulator.retained_entry.count": Self.traceInteger(
                snapshot.retainedEntryCount),
            "agentstudio.performance.terminal.accumulator.retained_size_bytes": Self.traceInteger(
                snapshot.retainedSizeBytes),
        ]
        if let applyOutcome {
            attributes["agentstudio.performance.terminal.accumulator.apply.outcome"] = .string(
                applyOutcome.rawValue
            )
        }
        recordDuration(
            .terminalAccumulatorDrain,
            duration: queueAge,
            attributes: attributes
        )
    }

    package func recordTerminalEqualSuppressed(
        publicationKind: TerminalPerformancePublicationKind
    ) {
        record(
            .terminalEqualSuppressed,
            attributes: [
                "agentstudio.performance.terminal.publication.kind": .string(
                    publicationKind.rawValue
                ),
                "agentstudio.performance.terminal.equal_suppressed.count": .int(1),
            ]
        )
    }

    package func recordTerminalCompactApply(
        _ snapshot: TerminalCompactApplyPerformanceSnapshot,
        serviceTime: Duration
    ) {
        var attributes: [String: AgentStudioTraceValue] = [
            "agentstudio.performance.terminal.equal_write_suppressed.count": Self.traceInteger(
                snapshot.equalWriteSuppressedCount)
        ]
        switch snapshot.activityProjectionRoundTrip {
        case .notSubmitted:
            attributes["agentstudio.performance.terminal.activity_projection.submitted"] = .bool(false)
        case .completed(let duration):
            attributes["agentstudio.performance.terminal.activity_projection.submitted"] = .bool(true)
            attributes["agentstudio.performance.terminal.activity_projection.round_trip_ms"] = .double(
                Self.milliseconds(from: duration)
            )
        }
        recordDuration(
            .terminalCompactApply,
            duration: serviceTime,
            attributes: attributes
        )
    }

    package func recordTerminalActivityCloseRead(_ duration: Duration) {
        record(
            .terminalActivityCloseRead,
            attributes: [
                "agentstudio.performance.terminal.activity_projection.close_read_ms": .double(
                    Self.milliseconds(from: duration)
                )
            ]
        )
    }

    package func recordFilesystemEffectSnapshot(_ snapshot: FilesystemEffectPerformanceSnapshot) {
        record(
            .filesystemEffectSnapshot,
            attributes: [
                "agentstudio.performance.filesystem.full_reconciliation_request.count": Self.traceInteger(
                    snapshot.fullReconciliationRequestCount),
                "agentstudio.performance.filesystem.affected_key_request.count": Self.traceInteger(
                    snapshot.affectedKeyRequestCount),
            ]
        )
    }

    package func recordTraceIdentitySnapshot(_ snapshot: TraceIdentityPerformanceSnapshot) {
        record(
            .traceIdentitySnapshot,
            attributes: [
                "agentstudio.performance.trace_identity.refresh_request.count": Self.traceInteger(
                    snapshot.refreshRequestCount),
                "agentstudio.performance.trace_identity.coalesced_request.count": Self.traceInteger(
                    snapshot.coalescedRequestCount),
                "agentstudio.performance.trace_identity.fleet_capture.count": Self.traceInteger(
                    snapshot.fleetCaptureCount),
                "agentstudio.performance.trace_identity.equal_snapshot_suppressed.count": Self.traceInteger(
                    snapshot.equalSnapshotSuppressedCount),
            ]
        )
    }

    /// Serialized access to the renderer lifecycle counters for
    /// `AgentStudioPerformanceTraceRecorder+RendererLifecycle.swift`; keeps `lock` and the state private
    /// to this file.
    func withRendererLifecycleState<T>(_ body: (inout RendererLifecyclePerformanceState) -> T) -> T {
        lock.withLock { body(&rendererLifecycleState) }
    }

    func measure<T>(
        _ event: Event,
        attributes: @autoclosure () -> [String: AgentStudioTraceValue] = [:],
        operation: () throws -> T
    ) rethrows -> T {
        guard isEnabled else {
            return try operation()
        }

        let clock = ContinuousClock()
        let start = clock.now
        let result = try operation()
        recordDuration(
            event,
            duration: start.duration(to: clock.now),
            attributes: attributes()
        )
        return result
    }

    package func drain() async throws {
        await processMemorySampler?.stop()
        runtimeDeliveryPerformanceReporter?.disable()
        try await eventQueue?.drain()
        if eventQueue == nil {
            try await traceRuntime?.flush()
        }
    }

    package func flush() async throws {
        if let eventQueue {
            try await eventQueue.flush()
        } else {
            try await traceRuntime?.flush()
        }
    }

    package static func milliseconds(from duration: Duration) -> Double {
        let components = duration.components
        let secondsMilliseconds = Double(components.seconds) * 1000
        let attosecondsMilliseconds = Double(components.attoseconds) / 1_000_000_000_000_000
        return secondsMilliseconds + attosecondsMilliseconds
    }

    private func shouldRecordTopologyLookup(_ fact: TopologyLookupFact) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return topologyLookupAdmission.admit(
            fact,
            now: ContinuousClock().now,
            window: AppPolicies.Diagnostics.topologyLookupTraceAdmissionWindow,
            limit: AppPolicies.Diagnostics.topologyLookupTraceAdmissionLimit
        )
    }

    private func shouldRecordPaneAssociationOutcome() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paneAssociationAdmission.admit(
            now: ContinuousClock().now,
            window: AppPolicies.Diagnostics.paneAssociationTraceAdmissionWindow,
            limit: AppPolicies.Diagnostics.paneAssociationTraceAdmissionLimit
        )
    }

    private static func traceInteger(_ value: UInt64) -> AgentStudioTraceValue {
        .int(Int(clamping: value))
    }
}

private struct PaneAssociationTraceAdmission {
    private var windowStart: ContinuousClock.Instant?
    private var admittedInWindow = 0

    mutating func admit(
        now: ContinuousClock.Instant,
        window: Duration,
        limit: Int
    ) -> Bool {
        resetWindowIfNeeded(now: now, window: window)
        guard admittedInWindow < limit else { return false }
        admittedInWindow += 1
        return true
    }

    private mutating func resetWindowIfNeeded(now: ContinuousClock.Instant, window: Duration) {
        guard let windowStart else {
            self.windowStart = now
            admittedInWindow = 0
            return
        }
        guard windowStart.duration(to: now) >= window else { return }
        self.windowStart = now
        admittedInWindow = 0
    }
}

private struct TopologyLookupTraceAdmission {
    private var windowStart: ContinuousClock.Instant?
    private var admittedInWindow = 0
    private var emittedFactGeneration: UInt64?
    private var emittedFacts: Set<AgentStudioPerformanceTraceRecorder.TopologyLookupFact> = []

    mutating func admit(
        _ fact: AgentStudioPerformanceTraceRecorder.TopologyLookupFact,
        now: ContinuousClock.Instant,
        window: Duration,
        limit: Int
    ) -> Bool {
        resetDeduplicationIfNeeded(for: fact)
        guard !emittedFacts.contains(fact) else { return false }
        resetWindowIfNeeded(now: now, window: window)
        guard admittedInWindow < limit else { return false }
        admittedInWindow += 1
        emittedFacts.insert(fact)
        return true
    }

    private mutating func resetDeduplicationIfNeeded(
        for fact: AgentStudioPerformanceTraceRecorder.TopologyLookupFact
    ) {
        guard emittedFactGeneration != fact.worktreePathIndexGeneration else { return }
        emittedFactGeneration = fact.worktreePathIndexGeneration
        emittedFacts.removeAll(keepingCapacity: true)
    }

    private mutating func resetWindowIfNeeded(now: ContinuousClock.Instant, window: Duration) {
        guard let windowStart else {
            self.windowStart = now
            admittedInWindow = 0
            return
        }
        guard windowStart.duration(to: now) >= window else { return }
        self.windowStart = now
        admittedInWindow = 0
    }
}
