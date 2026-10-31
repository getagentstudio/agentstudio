import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation

/// One host's demand, independent from other surfaces that happen to display the same pane.
struct PaneContextPopoverConsumerKey: Hashable, Sendable {
    enum Surface: Hashable, Sendable {
        case sidebarMessages, paneMessages, agentLine, managementCard, toolbar
    }
    let hostId: UUID
    let surface: Surface
    let paneId: PaneId
}

struct PaneContextPopoverDemand: Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case messages(PaneContextMessagesTarget)
        case agentLine
        case card
        case toolbar
    }
    let content: Content
    let location: PaneContextPopoverLocation
    let includingDrawers: Bool
    let screenVisibleWidth: Double
}

/// Canonical values copied from keyed owners. Equality and scope derivation run in the actor.
struct PopoverSourceCapture: Equatable, Sendable {
    struct Source: Equatable, Sendable {
        let structuralFacts: PaneStructuralFacts?
        let title: String?
        let note: String?
        let session: PaneAgentStatusPresentation?
        let display: PaneContextDisplay?
        let activity: PaneActivityTime?
    }
    let observationGeneration: UInt64
    let serviceEpoch: UUID?
    let sources: [PaneId: Source]
}

struct PaneContextPopoverServicePorts: Sendable {
    let epoch: UUID
    let reader: any PaneContextDetailReading
    let invalidations: any PaneContextInvalidationReading
    let person: any PaneContextPersonActing
    let readLiveSession: @Sendable (PaneId) async -> SessionSummary?

    init(
        epoch: UUID, reader: any PaneContextDetailReading, invalidations: any PaneContextInvalidationReading,
        person: any PaneContextPersonActing,
        readLiveSession: @escaping @Sendable (PaneId) async -> SessionSummary? = { _ in nil }
    ) {
        self.epoch = epoch
        self.reader = reader
        self.invalidations = invalidations
        self.person = person
        self.readLiveSession = readLiveSession
    }
}

struct PaneContextPopoverRequestIdentity: Hashable, Sendable {
    enum ValidationPhase: Hashable, Sendable { case pending, resolved }
    let key: PaneContextPopoverConsumerKey
    let openingEpoch: UInt64
    let serviceEpoch: UUID
    let requestGeneration: UInt64
    let inputGeneration: UInt64
    let ageGeneration: UInt64
    let pageGeneration: UInt64
    let validationPhase: ValidationPhase
    let layoutGeneration: UInt64
    let producer: PaneContextPopoverProducer

    init(
        key: PaneContextPopoverConsumerKey, openingEpoch: UInt64, serviceEpoch: UUID,
        requestGeneration: UInt64, inputGeneration: UInt64, ageGeneration: UInt64, pageGeneration: UInt64,
        producer: PaneContextPopoverProducer, validationPhase: ValidationPhase = .resolved,
        layoutGeneration: UInt64 = 0
    ) {
        self.key = key
        self.openingEpoch = openingEpoch
        self.serviceEpoch = serviceEpoch
        self.requestGeneration = requestGeneration
        self.inputGeneration = inputGeneration
        self.ageGeneration = ageGeneration
        self.pageGeneration = pageGeneration
        self.validationPhase = validationPhase
        self.layoutGeneration = layoutGeneration
        self.producer = producer
    }
}

struct PaneContextPopoverSnapshot: Sendable {
    enum Loaded: Sendable {
        case compact
        case detail(PaneContextDetail)
    }
    enum State: Sendable {
        case ready(Loaded)
        case unavailable(StorageFailureSummary, retained: Loaded?)
        case paneGone
    }
    let identity: PaneContextPopoverRequestIdentity
    let demand: PaneContextPopoverDemand
    let capture: PopoverSourceCapture
    let state: State
    let wallNow: Date
    let frozenWidth: Double?
    let shellExecutablePath: String?
    let liveSession: SessionSummary?
    let actionFeedback: String?
    let bodyGeometry: [PaneContextTextBodyKey: PaneContextMessageBodyGeometry]

    init(
        identity: PaneContextPopoverRequestIdentity, demand: PaneContextPopoverDemand,
        capture: PopoverSourceCapture, state: State, wallNow: Date, frozenWidth: Double?,
        shellExecutablePath: String? = nil, liveSession: SessionSummary? = nil, actionFeedback: String? = nil,
        bodyGeometry: [PaneContextTextBodyKey: PaneContextMessageBodyGeometry] = [:]
    ) {
        self.identity = identity
        self.demand = demand
        self.capture = capture
        self.state = state
        self.wallNow = wallNow
        self.frozenWidth = frozenWidth
        self.shellExecutablePath = shellExecutablePath
        self.liveSession = liveSession
        self.actionFeedback = actionFeedback
        self.bodyGeometry = bodyGeometry
    }
}

enum PaneContextPopoverProjectionOutcome: Sendable {
    struct Accepted: Sendable {
        let nextAgeBoundary: Date?
        let openingWidth: Double
    }
    case published(Accepted)
    case equal(Accepted)
    case superseded
    case cancelled
}

/// Hashable page demand preserves independent cursors before an assembled snapshot exists.
enum PaneContextPopoverPageScope: Hashable, Sendable {
    case messages(source: PaneId, rank: Int, position: UInt64)
    case sources(after: PaneId)

    nonisolated var readPage: PaneContextReadPage {
        switch self {
        case .messages(let source, let rank, let position):
            .more(source: source, after: .init(rank: rank, position: position))
        case .sources(let source): .moreSources(after: source)
        }
    }
}

enum PaneContextPopoverOwnerScope: Hashable, Sendable {
    case consumer(PaneContextPopoverConsumerKey, opening: UInt64)
    case execution(PaneContextPopoverConsumerKey, UUID)
    case deadline(UInt64)
    case input(UUID)
    case page(UUID)
}

enum PaneContextPopoverOwnerFact: Equatable, Sendable {
    enum Read: Equatable, Sendable {
        case detail(PaneContextReadPage)
        case message(PaneContextMessageKey)
        case liveSession(PaneId)
    }
    enum ExecutionKind: Equatable, Sendable { case opening, background, age, action, page }
    enum Finish: Equatable, Sendable { case published, equal, superseded, cancelled, failed }
    enum PageFinish: Equatable, Sendable {
        case loaded, restartedOnRevision, sourceRemoved, cancelled, paneGone
        case unavailable(StorageFailureSummary)
    }
    case observed
    case coalesced
    case deferred
    case admitted(ExecutionKind)
    case readStarted(Read)
    case readCompleted(Read)
    case readFailed(StorageFailureSummary)
    case projected
    case published
    case equal
    case superseded
    case cancelled
    case finished(Finish)
    case deadlineArmed
    case deadlineEnded(cancelled: Bool)
    case inputFinished
    case pageFinished(PageFinish)
    case retired
}

typealias PaneContextPopoverOwnerObserver =
    @Sendable (PaneContextPopoverOwnerScope, PaneContextPopoverOwnerFact) -> Void

/// The existing family supplies these capabilities after materializing this consumer's slot.
struct PaneContextPopoverProjectionPort: Sendable {
    let admit: @Sendable (PaneContextPopoverSnapshot) async -> PaneContextPopoverProjectionOutcome
    let invalidate: @Sendable () -> Void
    let retire: @Sendable () async -> Void
}

/// Concrete producers stay inspectable after erasing only the injected clock type.
struct PaneContextPopoverExecution: Sendable {
    let id: UUID
    let opening: UInt64
    let serviceEpoch: UUID
    let generation: UInt64
    let kind: PaneContextPopoverOwnerFact.ExecutionKind
    let task: Task<Void, Never>
}
struct PaneContextPopoverOpening: Sendable {
    let epoch: UInt64
    let initialExecution: PaneContextPopoverExecution
    let loadingWidth: Double
}

struct PaneContextPopoverWakeProducer: Sendable {
    let sequence: UInt64
    let task: Task<Void, Never>
}

/// Source ordering travels with the value; actor arrival order cannot establish capture currentness.
struct PaneContextPopoverBodyGeometryCapture: Sendable {
    let sequence: UInt64
    let geometry: PaneContextMessageBodyGeometry
}

protocol PaneContextPopoverRefreshing: Actor {
    func receiveBodyGeometry(
        _ capture: PaneContextPopoverBodyGeometryCapture, row: PaneContextTextBodyKey,
        for key: PaneContextPopoverConsumerKey, opening: UInt64, operation: UUID
    ) async
    func open(
        _ key: PaneContextPopoverConsumerKey, demand: PaneContextPopoverDemand,
        projection: PaneContextPopoverProjectionPort
    ) async -> PaneContextPopoverOpening?
    func close(_ key: PaneContextPopoverConsumerKey, opening: UInt64?) async
    func refreshImmediately(_ key: PaneContextPopoverConsumerKey, opening: UInt64) async
    func requestPage(_ scope: PaneContextPopoverPageScope, for key: PaneContextPopoverConsumerKey, opening: UInt64)
        async -> UUID
    func loadPage(
        _ scope: PaneContextPopoverPageScope, for key: PaneContextPopoverConsumerKey, opening: UInt64
    ) async -> PaneContextPopoverOwnerFact.PageFinish
    func replaceService(_ next: PaneContextPopoverServicePorts?) async
    func latestExecution(for key: PaneContextPopoverConsumerKey) async -> PaneContextPopoverExecution?
    func scheduledWakeProducer() async -> PaneContextPopoverWakeProducer?
    func performPerson(
        _ intent: PaneContextPopoverPersonIntent, for key: PaneContextPopoverConsumerKey, opening: UInt64
    ) async -> PaneContextPopoverPersonCompletion
    func stop() async
}
