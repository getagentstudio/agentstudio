import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Observation
import Synchronization

typealias TabBarMaterializedProjection = EagerDerivedAtom<
    TabBarProjectionRequest,
    TabBarProjectionGeneration,
    TabBarProjectionRequest,
    TabBarProjection,
    TabBarProjection
>

typealias TabBarMaterializedProjectionFamily = EagerDerivedAtomFamily<
    UUID,
    TabBarProjectionRequest,
    TabBarProjectionGeneration,
    TabBarProjectionRequest,
    TabBarProjection,
    TabBarProjection
>

private struct TabBarProjectionCapture {
    let request: TabBarProjectionRequest
}

/// Derives tab bar display state from keyed workspace observations.
/// Each tab projects off MainActor; the adapter publishes one coherent aggregate.
@MainActor
@Observable
final class TabBarAdapter {
    // MARK: - Materialized Projection

    var tabs: [TabBarItem] {
        publishedProjection?.items ?? []
    }

    var activeTabId: UUID? {
        publishedProjection?.activeTabID
    }

    /// Advances only when a semantically changed projection is published.
    private(set) var outputPublicationRevision: UInt64 = 0

    // MARK: - Overflow Detection

    var availableWidth: CGFloat = 0 {
        didSet {
            guard oldValue != availableWidth else { return }
            updateOverflow()
        }
    }
    private(set) var isOverflowing = false
    var contentWidth: CGFloat = 0 {
        didSet {
            guard oldValue != contentWidth else { return }
            updateOverflow()
        }
    }
    var viewportWidth: CGFloat = 0 {
        didSet {
            guard oldValue != viewportWidth else { return }
            updateOverflow()
        }
    }

    static let minTabWidth: CGFloat = 220
    static let tabSpacing: CGFloat = 4
    static let tabBarPadding: CGFloat = 16
    static let hysteresisBuffer: CGFloat = 50

    // MARK: - Management Layer

    private(set) var isManagementLayerActive = false

    // MARK: - Transient UI State

    var draggingTabId: UUID?
    var dropTargetIndex: Int?
    var dwellTabId: UUID?
    var dwellProgress: CGFloat = 0
    var tabFrames: [UUID: CGRect] = [:]

    // MARK: - Internals

    private let store: WorkspaceStore
    private let repoCache: RepoCacheAtom
    private let projectionTelemetry: TabBarProjectionTelemetry
    @ObservationIgnored private let onProjectionCompletion:
        @MainActor @Sendable (TabBarMaterializedProjection.ProjectionCompletion) -> Void
    @ObservationIgnored private var materializedProjectionFamily: TabBarMaterializedProjectionFamily!
    @ObservationIgnored private var tabObservationGenerationById: [UUID: UInt64] = [:]
    @ObservationIgnored private var orderedTabIds: [UUID] = []
    @ObservationIgnored private var requestedActiveTabId: UUID?
    @ObservationIgnored private var nextTabObservationGeneration: UInt64 = 0
    @ObservationIgnored private var projectionGeneration: UInt64 = 0
    @ObservationIgnored private var isObservingManagementLayer = false
    @ObservationIgnored private var isObservingTabCollection = false
    private var publishedProjection: TabBarProjection?
    @ObservationIgnored private var hasStopped = false

    var materializedProjections: [TabBarMaterializedProjection] {
        materializedProjectionFamily.atoms
    }

    func materializedProjection(for tabId: UUID) -> TabBarMaterializedProjection? {
        materializedProjectionFamily.atom(for: tabId)
    }

    init(
        store: WorkspaceStore,
        repoCache: RepoCacheAtom,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil,
        project: @escaping @Sendable (TabBarProjectionRequest) throws(CancellationError) -> TabBarProjection =
            { try TabBarProjector.project($0) },
        onProjectionCompletion:
            @escaping @MainActor @Sendable (
                TabBarMaterializedProjection.ProjectionCompletion
            ) -> Void = { _ in }
    ) {
        let projectionTelemetry = TabBarProjectionTelemetry(recorder: performanceTraceRecorder)
        let measuredProject: @Sendable (TabBarProjectionRequest) throws(CancellationError) -> TabBarProjection =
            { request in
                try projectionTelemetry.project(request, using: project)
            }
        self.store = store
        self.repoCache = repoCache
        self.projectionTelemetry = projectionTelemetry
        self.onProjectionCompletion = onProjectionCompletion
        self.materializedProjectionFamily = TabBarMaterializedProjectionFamily(
            intentIdentity: \.generation,
            combinePendingIntents: { _, latestRequest in latestRequest },
            prepare: { request, _ in .prepared(request) },
            project: measuredProject,
            classify: { candidate, currentValue in
                currentValue == candidate
                    ? .equalCurrent(candidate)
                    : .immediateAccepted(candidate)
            },
            onProjectionCompletion: { [weak self] tabId, completion in
                self?.handleProjectionCompletion(completion, for: tabId)
            }
        )
        observe()
    }

    func stop() {
        guard !hasStopped else { return }
        hasStopped = true
        projectionTelemetry.stop()
        materializedProjectionFamily.stop()
    }

    isolated deinit {
        stop()
    }

    func visibleProjectionDidRender() {
        projectionTelemetry.recordVisibleProjection()
    }

    // MARK: - Observation

    private func observe() {
        isManagementLayerActive = atom(\.managementLayer).isActive
        observeTabCollection()
        observeManagementLayer()
    }

    private func observeTabCollection() {
        guard !hasStopped, !isObservingTabCollection else { return }
        isObservingTabCollection = true
        let collection = withObservationTracking {
            (
                orderedTabIds: store.tabShellAtom.orderedTabIds,
                activeTabId: store.tabShellAtom.activeTabId
            )
        } onChange: { [weak self] in
            self?.projectionTelemetry.sourceDidInvalidate()
            Task { @MainActor [weak self] in
                guard let self, !self.hasStopped else { return }
                self.isObservingTabCollection = false
                self.observeTabCollection()
            }
        }
        reconcileTabObservers(
            orderedTabIds: collection.orderedTabIds,
            activeTabId: collection.activeTabId
        )
    }

    private func reconcileTabObservers(orderedTabIds: [UUID], activeTabId: UUID?) {
        self.orderedTabIds = orderedTabIds
        requestedActiveTabId = activeTabId

        let retainedTabIds = Set(orderedTabIds)
        for removedTabId in Array(tabObservationGenerationById.keys)
        where !retainedTabIds.contains(removedTabId) {
            materializedProjectionFamily.remove(for: removedTabId)
            tabObservationGenerationById.removeValue(forKey: removedTabId)
        }
        for tabId in orderedTabIds where materializedProjectionFamily.atom(for: tabId) == nil {
            _ = materializedProjectionFamily.materialize(for: tabId)
            observeTabItem(tabId)
        }
        publishProjectionIfReady()
    }

    private func observeTabItem(_ tabId: UUID) {
        guard !hasStopped, let materializedProjection = materializedProjectionFamily.atom(for: tabId)
        else {
            return
        }
        nextTabObservationGeneration &+= 1
        let observationGeneration = nextTabObservationGeneration
        tabObservationGenerationById[tabId] = observationGeneration

        projectionGeneration &+= 1
        let generation = TabBarProjectionGeneration(value: projectionGeneration)
        let projectionTelemetry = self.projectionTelemetry
        let captureStartedAt = projectionTelemetry.captureStartedAt()
        let capture = withObservationTracking {
            CoreTabBarProjectionRequest.capture(
                tabId: tabId,
                store: store,
                repoCache: repoCache
            ).map { coreRequest in
                TabBarProjectionCapture(
                    request: TabBarProjectionRequest(
                        generation: generation,
                        coreRequest: coreRequest,
                        inboxAttentionLane: nil
                    )
                )
            }
        } onChange: { [weak self, weak materializedProjection] in
            projectionTelemetry.sourceDidInvalidate()
            materializedProjection?.sourceDidInvalidate()
            Task { @MainActor [weak self] in
                guard let self,
                    !self.hasStopped,
                    self.tabObservationGenerationById[tabId] == observationGeneration
                else { return }
                self.observeTabItem(tabId)
            }
        }
        guard let capture else { return }
        projectionTelemetry.recordAdmission(capture, startedAt: captureStartedAt)
        materializedProjectionFamily.admit(capture.request, for: tabId)
    }

    private func handleProjectionCompletion(
        _ completion: TabBarMaterializedProjection.ProjectionCompletion,
        for tabId: UUID
    ) {
        projectionTelemetry.recordCompletion(completion)
        onProjectionCompletion(completion)
        switch completion {
        case .published, .equal:
            break
        case .rejected, .superseded, .cancelled:
            return
        }
        guard orderedTabIds.contains(tabId) else { return }
        publishProjectionIfReady()
    }

    private func publishProjectionIfReady() {
        let refreshStartedAt = projectionTelemetry.refreshStartedAt()
        var items: [TabBarItem] = []
        items.reserveCapacity(orderedTabIds.count)
        for tabId in orderedTabIds {
            guard let projection = materializedProjectionFamily.currentValue(for: tabId),
                projection.items.count == 1,
                let item = projection.items.first,
                item.id == tabId
            else {
                return
            }
            items.append(item)
        }
        let activeTabId =
            requestedActiveTabId.flatMap { requestedTabId in
                orderedTabIds.contains(requestedTabId) ? requestedTabId : nil
            } ?? orderedTabIds.last
        let candidate = TabBarProjection(items: items, activeTabID: activeTabId)
        guard publishedProjection != candidate else { return }
        let previousProjection = publishedProjection
        publishedProjection = candidate
        outputPublicationRevision &+= 1
        projectionTelemetry.recordCollectionPublicationAdmissionIfNeeded(
            current: candidate,
            startedAt: refreshStartedAt
        )
        projectionTelemetry.recordPublication(
            previous: previousProjection,
            current: candidate,
            refreshStartedAt: refreshStartedAt
        )
        updateOverflow()
    }

    private func observeManagementLayer() {
        guard !hasStopped, !isObservingManagementLayer else { return }
        isObservingManagementLayer = true
        withObservationTracking {
            _ = atom(\.managementLayer).isActive
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.hasStopped else { return }
                self.isObservingManagementLayer = false
                self.isManagementLayerActive = atom(\.managementLayer).isActive
                self.observeManagementLayer()
            }
        }
    }

    private func updateOverflow() {
        guard !tabs.isEmpty else {
            isOverflowing = false
            return
        }

        let effectiveViewport = viewportWidth > 0 ? viewportWidth : availableWidth
        guard effectiveViewport > 0 else { return }

        if contentWidth > 0 {
            if isOverflowing {
                isOverflowing = contentWidth > (effectiveViewport - Self.hysteresisBuffer)
            } else {
                isOverflowing = contentWidth > effectiveViewport
            }
            return
        }

        let tabCount = CGFloat(tabs.count)
        let totalMinWidth =
            tabCount * Self.minTabWidth
            + (tabCount - 1) * Self.tabSpacing
            + Self.tabBarPadding
        isOverflowing = totalMinWidth > effectiveViewport
    }
}

private final class TabBarProjectionTelemetry: Sendable {
    private struct Admission: Sendable {
        let sequence: UInt64
        let captureStartedAt: ContinuousClock.Instant
        let interactionStartedAt: ContinuousClock.Instant
        var tabCount: Int?
        var sourceTabCount: Int?
        var paneCount: Int?
        var activeTabPresent: Bool?
        var affectedItemCount: Int?
        var terminalMainActorStartedAt: ContinuousClock.Instant?
    }

    private struct State: Sendable {
        var admissionsBySequence: [UInt64: Admission] = [:]
        var nextCollectionSequence: UInt64 = 1 << 62
        var pendingInteractionStartedAt: ContinuousClock.Instant?
        var pendingPublicationAdmission: Admission?
        var pendingVisibleAdmission: Admission?
    }

    private let recorder: AgentStudioPerformanceTraceRecorder?
    private let clock = ContinuousClock()
    private let state = Mutex(State())

    init(recorder: AgentStudioPerformanceTraceRecorder?) {
        self.recorder = recorder
    }

    func captureStartedAt() -> ContinuousClock.Instant? {
        guard recorder?.isEnabled == true else { return nil }
        return clock.now
    }

    @MainActor
    func refreshStartedAt() -> ContinuousClock.Instant? {
        guard recorder?.isEnabled == true else { return nil }
        return clock.now
    }

    func sourceDidInvalidate() {
        guard recorder?.isEnabled == true else { return }
        let invalidatedAt = clock.now
        state.withLock { state in
            if state.pendingInteractionStartedAt == nil {
                state.pendingInteractionStartedAt = invalidatedAt
            }
        }
    }

    func recordAdmission(
        _ capture: TabBarProjectionCapture,
        startedAt: ContinuousClock.Instant?
    ) {
        guard let recorder, recorder.isEnabled, let startedAt else { return }
        let admission = state.withLock { state -> Admission in
            let admission = Admission(
                sequence: capture.request.generation.value,
                captureStartedAt: startedAt,
                interactionStartedAt: state.pendingInteractionStartedAt ?? startedAt,
                tabCount: nil,
                sourceTabCount: nil,
                paneCount: nil,
                activeTabPresent: nil,
                affectedItemCount: nil,
                terminalMainActorStartedAt: nil
            )
            state.pendingInteractionStartedAt = nil
            state.admissionsBySequence[admission.sequence] = admission
            return admission
        }
        let completedAt = clock.now
        recorder.recordDuration(
            .tabBarCapture,
            duration: admission.captureStartedAt.duration(to: completedAt),
            attributes: Self.attributes(for: admission).merging(
                Self.mainActorTimingAttributes(
                    interactionStartedAt: admission.interactionStartedAt,
                    mainActorStartedAt: admission.captureStartedAt,
                    mainActorCompletedAt: completedAt
                ),
                uniquingKeysWith: { _, timingValue in timingValue }
            )
        )
    }

    func project(
        _ request: TabBarProjectionRequest,
        using projector: @Sendable (TabBarProjectionRequest) throws(CancellationError) -> TabBarProjection
    ) throws(CancellationError) -> TabBarProjection {
        guard let recorder, recorder.isEnabled else {
            return try projector(request)
        }
        let startedAt = clock.now
        defer {
            if let admission = admission(for: request.generation.value) {
                recorder.recordDuration(
                    .tabBarWorker,
                    duration: startedAt.duration(to: clock.now),
                    attributes: Self.attributes(for: admission)
                )
            }
        }
        let projection = try projector(request)
        state.withLock { state in
            guard var admission = state.admissionsBySequence[request.generation.value] else { return }
            admission.tabCount = projection.items.count
            admission.paneCount = projection.items.reduce(into: 0) { count, item in
                count += item.activePaneCount
            }
            admission.activeTabPresent = projection.activeTabID != nil
            state.admissionsBySequence[request.generation.value] = admission
        }
        return projection
    }

    @MainActor
    func recordCompletion(_ completion: TabBarMaterializedProjection.ProjectionCompletion) {
        guard let recorder, recorder.isEnabled else { return }
        let mainActorStartedAt = clock.now
        let sequence: UInt64
        let outcome: String
        let didPublish: Bool
        switch completion {
        case .published(let generation):
            sequence = generation.value
            outcome = "published"
            didPublish = true
        case .equal(let generation):
            sequence = generation.value
            outcome = "equal"
            didPublish = false
        case .rejected(let generation):
            sequence = generation.value
            outcome = "rejected"
            didPublish = false
        case .superseded(let generation):
            sequence = generation.value
            outcome = "superseded"
            didPublish = false
        case .cancelled(let generation):
            sequence = generation.value
            outcome = "cancelled"
            didPublish = false
        }
        let admission = state.withLock { state -> Admission? in
            guard let admission = state.admissionsBySequence.removeValue(forKey: sequence) else {
                return nil
            }
            if didPublish {
                var admission = admission
                admission.terminalMainActorStartedAt = mainActorStartedAt
                state.pendingPublicationAdmission = admission
                return admission
            }
            return admission
        }
        guard let admission else { return }
        if !didPublish {
            recordTerminal(
                admission,
                outcome: outcome,
                mainActorStartedAt: mainActorStartedAt,
                recorder: recorder
            )
        }
    }

    @MainActor
    func recordCollectionPublicationAdmissionIfNeeded(
        current: TabBarProjection,
        startedAt: ContinuousClock.Instant?
    ) {
        guard let recorder, recorder.isEnabled, let startedAt else { return }
        let admission = state.withLock { state -> Admission? in
            guard state.pendingPublicationAdmission == nil,
                let interactionStartedAt = state.pendingInteractionStartedAt
            else { return nil }
            let admission = Admission(
                sequence: state.nextCollectionSequence,
                captureStartedAt: startedAt,
                interactionStartedAt: interactionStartedAt,
                tabCount: current.items.count,
                sourceTabCount: current.items.count,
                paneCount: current.items.reduce(into: 0) { count, item in
                    count += item.activePaneCount
                },
                activeTabPresent: current.activeTabID != nil,
                affectedItemCount: nil,
                terminalMainActorStartedAt: startedAt
            )
            state.nextCollectionSequence &+= 1
            state.pendingInteractionStartedAt = nil
            state.pendingPublicationAdmission = admission
            return admission
        }
        guard let admission else { return }
        let completedAt = clock.now
        recorder.recordDuration(
            .tabBarCapture,
            duration: admission.captureStartedAt.duration(to: completedAt),
            attributes: Self.attributes(for: admission).merging(
                Self.mainActorTimingAttributes(
                    interactionStartedAt: admission.interactionStartedAt,
                    mainActorStartedAt: admission.captureStartedAt,
                    mainActorCompletedAt: completedAt
                ),
                uniquingKeysWith: { _, timingValue in timingValue }
            )
        )
    }

    @MainActor
    func recordPublication(
        previous: TabBarProjection?,
        current: TabBarProjection,
        refreshStartedAt: ContinuousClock.Instant?
    ) {
        guard let recorder, recorder.isEnabled, let refreshStartedAt else { return }
        let admission = state.withLock { state -> Admission? in
            defer { state.pendingPublicationAdmission = nil }
            guard var admission = state.pendingPublicationAdmission else { return nil }
            admission.tabCount = current.items.count
            admission.sourceTabCount = current.items.count
            admission.paneCount = current.items.reduce(into: 0) { count, item in
                count += item.activePaneCount
            }
            admission.activeTabPresent = current.activeTabID != nil
            admission.affectedItemCount = Self.affectedItemCount(
                previous: previous?.items ?? [],
                current: current.items
            )
            state.pendingVisibleAdmission = admission
            return admission
        }
        guard let admission else { return }
        let completedAt = clock.now
        let timingAttributes = Self.mainActorTimingAttributes(
            interactionStartedAt: admission.interactionStartedAt,
            mainActorStartedAt: refreshStartedAt,
            mainActorCompletedAt: completedAt
        )
        let attributes = Self.attributes(for: admission).merging(
            timingAttributes,
            uniquingKeysWith: { _, timingValue in timingValue }
        )
        recorder.recordDuration(
            .tabBarRefresh,
            duration: refreshStartedAt.duration(to: completedAt),
            attributes: attributes
        )
        recorder.recordDuration(
            .tabBarCurrent,
            duration: admission.interactionStartedAt.duration(to: completedAt),
            attributes: attributes
        )
        recorder.recordDuration(
            .tabBarPublication,
            duration: refreshStartedAt.duration(to: completedAt),
            attributes: attributes
        )
        recordTerminal(
            admission,
            outcome: "published",
            mainActorStartedAt: admission.terminalMainActorStartedAt ?? refreshStartedAt,
            completedAt: completedAt,
            recorder: recorder
        )
    }

    @MainActor
    func recordVisibleProjection() {
        guard let recorder, recorder.isEnabled else { return }
        let admission = state.withLock { state in
            defer { state.pendingVisibleAdmission = nil }
            return state.pendingVisibleAdmission
        }
        guard let admission else { return }
        recorder.recordDuration(
            .tabBarVisible,
            duration: admission.interactionStartedAt.duration(to: clock.now),
            attributes: Self.attributes(for: admission)
        )
    }

    @MainActor
    func stop() {
        guard let recorder, recorder.isEnabled else {
            state.withLock { state in
                state.admissionsBySequence.removeAll()
                state.pendingInteractionStartedAt = nil
                state.pendingPublicationAdmission = nil
                state.pendingVisibleAdmission = nil
            }
            return
        }
        let unsettledAdmissions = state.withLock { state -> [Admission] in
            let admissions = state.admissionsBySequence.values.sorted { $0.sequence < $1.sequence }
            state.admissionsBySequence.removeAll()
            state.pendingInteractionStartedAt = nil
            state.pendingPublicationAdmission = nil
            state.pendingVisibleAdmission = nil
            return admissions
        }
        for admission in unsettledAdmissions {
            recordTerminal(
                admission,
                outcome: "cancelled",
                mainActorStartedAt: clock.now,
                recorder: recorder
            )
        }
    }

    private func recordTerminal(
        _ admission: Admission,
        outcome: String,
        mainActorStartedAt: ContinuousClock.Instant,
        completedAt: ContinuousClock.Instant? = nil,
        recorder: AgentStudioPerformanceTraceRecorder
    ) {
        let completedAt = completedAt ?? clock.now
        var attributes = Self.attributes(for: admission)
        attributes["agentstudio.performance.tabbar.terminal.outcome"] = .string(outcome)
        attributes.merge(
            Self.mainActorTimingAttributes(
                interactionStartedAt: admission.interactionStartedAt,
                mainActorStartedAt: mainActorStartedAt,
                mainActorCompletedAt: completedAt
            ),
            uniquingKeysWith: { _, timingValue in timingValue }
        )
        recorder.recordDuration(
            .tabBarTerminal,
            duration: admission.interactionStartedAt.duration(to: completedAt),
            attributes: attributes
        )
    }

    private static func mainActorTimingAttributes(
        interactionStartedAt: ContinuousClock.Instant,
        mainActorStartedAt: ContinuousClock.Instant,
        mainActorCompletedAt: ContinuousClock.Instant
    ) -> [String: AgentStudioTraceValue] {
        [
            "agentstudio.performance.tabbar.queue_wait_ms": .double(
                AgentStudioPerformanceTraceRecorder.milliseconds(
                    from: interactionStartedAt.duration(to: mainActorStartedAt))),
            "agentstudio.performance.tabbar.mainactor_held_ms": .double(
                AgentStudioPerformanceTraceRecorder.milliseconds(
                    from: mainActorStartedAt.duration(to: mainActorCompletedAt))),
        ]
    }

    private func admission(for sequence: UInt64) -> Admission? {
        state.withLock { state in
            state.admissionsBySequence[sequence]
        }
    }

    private static func attributes(
        for admission: Admission
    ) -> [String: AgentStudioTraceValue] {
        var attributes: [String: AgentStudioTraceValue] = [
            "agentstudio.performance.tabbar.sequence": .int(Int(clamping: admission.sequence))
        ]
        if let tabCount = admission.tabCount {
            attributes["agentstudio.performance.tabbar.tab.count"] = .int(tabCount)
        }
        if let sourceTabCount = admission.sourceTabCount {
            attributes["agentstudio.performance.tabbar.source_tab.count"] = .int(sourceTabCount)
        }
        if let paneCount = admission.paneCount {
            attributes["agentstudio.performance.tabbar.pane.count"] = .int(paneCount)
        }
        if let activeTabPresent = admission.activeTabPresent {
            attributes["agentstudio.performance.tabbar.active_tab.present"] = .bool(activeTabPresent)
        }
        if let affectedItemCount = admission.affectedItemCount {
            attributes["agentstudio.performance.tabbar.affected_item.count"] = .int(affectedItemCount)
        }
        return attributes
    }

    private static func affectedItemCount(
        previous: [TabBarItem],
        current: [TabBarItem]
    ) -> Int {
        let previousById = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let currentById = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let previousIndexById = Dictionary(
            uniqueKeysWithValues: previous.enumerated().map { ($0.element.id, $0.offset) }
        )
        let currentIndexById = Dictionary(
            uniqueKeysWithValues: current.enumerated().map { ($0.element.id, $0.offset) }
        )
        return Set(previousById.keys).union(currentById.keys).count { tabId in
            previousById[tabId] != currentById[tabId]
                || previousIndexById[tabId] != currentIndexById[tabId]
        }
    }
}
