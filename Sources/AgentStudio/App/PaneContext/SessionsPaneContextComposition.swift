import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
import Foundation

/// App joins the existing owners; each owner retains its own decisions and state.
struct SessionsPaneContextComposition: Sendable {
    struct Inputs: Sendable {
        let datastore: WorkspaceSQLiteDatastoreActor
        let directory: PaneContextMembershipDirectory
        let workspaceId: UUID
        let clock: any Clock<Duration> & Sendable
        let wallNow: @Sendable () -> Date
        let limits: SessionsIngestionLimits
        let paneViewedMailbox: SessionsPaneViewedMailbox
        let presentationAtom: PaneContextPresentationAtom
        var presentationApplyMeasurement: PaneContextPresentationApplyMeasurement = .init()
        var presentationApplyProbe: @Sendable (PaneContextPresentationApplySnapshot) -> Void = { _ in }
        var performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?
        var ingestionProbe: SessionsIngestionProbe = { _ in }
        var statusSink: (@MainActor @Sendable ([PaneId: SessionStatusPublication]) async -> Void)?
        var statusApplyMeasurement: SessionStatusApplyMeasurement = .init()
        var statusApplyProbe: @Sendable (SessionStatusApplySnapshot) -> Void = { _ in }
        var activityClock: PaneActivityClock?
    }

    let ingestion: SessionsIngestion
    let paneContextService: PaneContextService
    let liveSessionsAdapter: AgentStudioIPCSessionsAdapter
    let paneContextIPCAdapter: AgentStudioIPCPaneContextAdapter
    let presentationLane: PaneContextPublicationLane
    private let bridge: PaneContextSessionsBridge

    static func make(inputs: Inputs) -> Self {
        let directory = inputs.directory
        let presentationLane = makePresentationLane(inputs: inputs)
        let bridge = PaneContextSessionsBridge()
        let ingestion = SessionsIngestion(
            repository: SessionsRepository(sqliteAccess: WorkspaceSessionsSQLiteAccess(datastore: inputs.datastore)),
            limits: inputs.limits, probe: inputs.ingestionProbe, paneViewedMailbox: inputs.paneViewedMailbox,
            statusSink: inputs.statusSink, openAskSource: bridge,
            sessionEnded: { generation in await bridge.sessionEnded(bindingGenerationId: generation) },
            statusApplyMeasurement: inputs.statusApplyMeasurement, statusApplyProbe: inputs.statusApplyProbe)
        let service = PaneContextService(
            sqliteAccess: WorkspacePaneContextSQLiteAccess(datastore: inputs.datastore), clock: inputs.clock,
            wallNow: inputs.wallNow, membership: inputs.directory,
            currentBindingGeneration: PaneContextSessionsBridge.currentBindingGeneration,
            sessionSummary: { paneId in try await bridge.sessionSummary(paneId: paneId) },
            openAskSink: { update in await bridge.receiveOpenAskSummary(update) },
            agentLineSink: { work, generation in
                await bridge.receiveAgentLine(work: work, bindingGenerationId: generation)
            },
            presentationLane: presentationLane)
        let ownerPaneLookup: @Sendable (PaneId) -> PaneId? = { directory.ownerPaneId(for: $0) }
        let composition = Self(
            ingestion: ingestion, paneContextService: service,
            liveSessionsAdapter: AgentStudioIPCSessionsAdapter(
                ingestion: ingestion, now: inputs.wallNow,
                activityClock: inputs.activityClock, ownerPaneLookup: ownerPaneLookup,
                performanceTraceRecorder: inputs.performanceTraceRecorder),
            paneContextIPCAdapter: AgentStudioIPCPaneContextAdapter(
                service: service, ingestion: ingestion, performanceTraceRecorder: inputs.performanceTraceRecorder),
            presentationLane: presentationLane, bridge: bridge)
        composition.connect()
        return composition
    }

    private func connect() {
        bridge.connect(service: paneContextService, ingestion: ingestion)
    }

    private static func makePresentationLane(inputs: Inputs) -> PaneContextPublicationLane {
        let directory = inputs.directory
        let workspaceId = inputs.workspaceId
        let mailbox = PaneContextPublicationMailbox(
            isPresent: { directory.contains(paneID: $0.uuid, inWorkspace: workspaceId) })
        let atom = inputs.presentationAtom
        let measurement = inputs.presentationApplyMeasurement
        return PaneContextPublicationLane(
            mailbox: mailbox,
            sink: { batch in
                let began = ContinuousClock.now
                atom.apply(batch)
                measurement.recordHeldDuration(began.duration(to: ContinuousClock.now))
            },
            measurement: measurement,
            probe: { snapshot in
                inputs.performanceTraceRecorder?.recordDuration(
                    .paneContextPresentationApply, duration: snapshot.heldDuration,
                    attributes: [
                        "agentstudio.pane_context.computed_count": .int(snapshot.counts.computed),
                        "agentstudio.pane_context.equal_suppressed_count": .int(snapshot.counts.suppressed),
                        "agentstudio.pane_context.coalesced_count": .int(snapshot.counts.coalesced),
                        "agentstudio.pane_context.batch_size": .int(snapshot.batchSize),
                        "agentstudio.pane_context.main_actor_total_ms": .double(
                            AgentStudioPerformanceTraceRecorder.milliseconds(from: snapshot.totalHeldDuration)),
                        "agentstudio.pane_context.main_actor_max_ms": .double(
                            AgentStudioPerformanceTraceRecorder.milliseconds(from: snapshot.maximumHeldDuration)),
                    ])
                inputs.presentationApplyProbe(snapshot)
            })
    }

    /// The caller joins spool and socket handlers before stopping this assembly.
    func shutdown() async {
        await paneContextService.stop()
        await ingestion.finish()
    }
}
