import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

/// Owns demanded detail work. Views copy canonical facts and apply its prepared outcomes.
actor PaneContextPopoverRefreshOwner<SourceClock: Clock> where SourceClock.Duration == Duration {
    typealias Capture =
        @Sendable (
            PaneContextPopoverConsumerKey, UInt64, UInt64, Set<PaneId>
        ) async -> PopoverSourceCapture

    typealias Execution = PaneContextPopoverExecution
    typealias Opening = PaneContextPopoverOpening
    struct SourceObservation {
        let sources: Set<PaneId>
        let serviceEpoch: UUID
        let task: Task<Void, Never>
    }
    struct Retirement {
        let opening: UInt64
        let id: UUID
        let task: Task<Void, Never>
    }
    struct Consumer {
        let opening: UInt64
        let demand: PaneContextPopoverDemand
        let projection: PaneContextPopoverProjectionPort
        var capture: PopoverSourceCapture?
        var inputGeneration: UInt64 = 0
        var requestGeneration: UInt64 = 0
        var ageGeneration: UInt64 = 0
        var pageGeneration: UInt64 = 0
        var sources: Set<PaneId>
        var sourceObservation: SourceObservation?
        var sourceEnded = false
        var execution: Execution?
        var latestExecution: Execution?
        var pending: PaneContextPopoverOwnerFact.ExecutionKind?
        var inputOperation: UUID?
        var acceptedState: PaneContextPopoverSnapshot.State?
        var retained: PaneContextPopoverSnapshot.Loaded? {
            switch acceptedState {
            case .ready(let value)?, .unavailable(_, let value?)?: value
            case .unavailable(_, nil)?, .paneGone?, nil: nil
            }
        }
        var loadedPages: Set<PaneContextPopoverPageScope> = []
        var pendingPages: [PaneContextPopoverPageScope: Set<UUID>] = [:]
        var nextAgeBoundary: Date?
        var lastAdmission: SourceClock.Instant?
        var frozenWidth: Double?
        var shellExecutablePath: String?
        var liveSession: SessionSummary?
        var actionFeedback: String?
        var latestPersonCommand: UUID?
        var pendingPersonRefreshes: Set<UUID> = []
    }

    let clock: SourceClock
    let wallNow: @Sendable () -> Date
    let captureValues: Capture
    let observe: PaneContextPopoverOwnerObserver
    var inputCompletions: [UUID: InputCompletion] = [:]
    var service: PaneContextPopoverServicePorts?
    var serviceEpoch: UUID
    var consumers: [PaneContextPopoverConsumerKey: Consumer] = [:]
    var retirements: [PaneContextPopoverConsumerKey: Retirement] = [:]
    // Only generations whose invalidation has dirtied every affected consumer belong here.
    var fannedOutSourceGenerations: [PaneId: UInt64] = [:]
    var personTasks: [UUID: Task<PaneContextPopoverPersonCompletion, Never>] = [:]
    var pageWaiters: [UUID: CheckedContinuation<PaneContextPopoverOwnerFact.PageFinish, Never>] = [:]
    var openingSequence: UInt64 = 0
    var deadlineSequence: UInt64 = 0
    var scheduledDeadline: SourceClock.Instant?
    var deadlineTask: Task<Void, Never>?
    var stopping = false

    init(
        clock: SourceClock, wallNow: @escaping @Sendable () -> Date,
        service: PaneContextPopoverServicePorts?, capture: @escaping Capture,
        observe: @escaping PaneContextPopoverOwnerObserver = { _, _ in }
    ) {
        self.clock = clock
        self.wallNow = wallNow
        self.service = service
        serviceEpoch = service?.epoch ?? UUIDv7.generate()
        captureValues = capture
        self.observe = observe
    }

    @discardableResult
    func open(
        _ key: PaneContextPopoverConsumerKey, demand: PaneContextPopoverDemand,
        projection: PaneContextPopoverProjectionPort
    ) async -> Opening? {
        guard !stopping, !Task.isCancelled else { return nil }
        await awaitRetirement(key)
        if consumers[key] != nil { await close(key) }
        guard !stopping, !Task.isCancelled else { return nil }
        openingSequence &+= 1
        let opening = openingSequence
        consumers[key] = Consumer(
            opening: opening, demand: demand, projection: projection, sources: [key.paneId])
        observe(.consumer(key, opening: opening), .observed)
        enqueue(key, kind: .opening)
        rescheduleDeadline()
        guard let initial = consumers[key]?.execution else {
            await close(key)
            return nil
        }
        return .init(
            epoch: opening, initialExecution: initial,
            loadingWidth: preferredWidth(for: demand, state: .unavailable(.databaseUnavailable, retained: nil)))
    }

    /// Concrete producer handles let native consumers end waits when their work ends.
    func latestExecution(for key: PaneContextPopoverConsumerKey) -> Execution? {
        consumers[key]?.latestExecution
    }

    func scheduledWake() -> (sequence: UInt64, deadline: SourceClock.Instant, task: Task<Void, Never>)? {
        guard let scheduledDeadline, let deadlineTask else { return nil }
        return (deadlineSequence, scheduledDeadline, deadlineTask)
    }

    func scheduledWakeProducer() -> PaneContextPopoverWakeProducer? {
        guard scheduledDeadline != nil, let deadlineTask else { return nil }
        return .init(sequence: deadlineSequence, task: deadlineTask)
    }

    func refreshImmediately(_ key: PaneContextPopoverConsumerKey, opening: UInt64) {
        guard consumers[key]?.opening == opening else { return }
        enqueue(key, kind: .action)
        rescheduleDeadline()
    }

    @discardableResult
    func requestPage(
        _ scope: PaneContextPopoverPageScope, for key: PaneContextPopoverConsumerKey, opening: UInt64
    ) -> UUID {
        let request = UUIDv7.generate()
        queuePage(scope, request: request, for: key, opening: opening)
        return request
    }

    func loadPage(
        _ scope: PaneContextPopoverPageScope, for key: PaneContextPopoverConsumerKey, opening: UInt64
    ) async -> PaneContextPopoverOwnerFact.PageFinish {
        await withCheckedContinuation { continuation in
            let request = UUIDv7.generate()
            pageWaiters[request] = continuation
            queuePage(scope, request: request, for: key, opening: opening)
        }
    }

    func queuePage(
        _ scope: PaneContextPopoverPageScope, request: UUID, for key: PaneContextPopoverConsumerKey, opening: UInt64
    ) {
        guard !stopping, var consumer = consumers[key], consumer.opening == opening else {
            finishPage(request, outcome: .cancelled)
            return
        }
        consumer.pendingPages[scope, default: []].insert(request)
        consumer.pageGeneration &+= 1
        consumers[key] = consumer
        observe(.page(request), .observed)
        enqueue(key, kind: .page)
        rescheduleDeadline()
    }

    func finishPage(_ request: UUID, outcome: PaneContextPopoverOwnerFact.PageFinish) {
        observe(.page(request), .pageFinished(outcome))
        pageWaiters.removeValue(forKey: request)?.resume(returning: outcome)
    }

    func replaceService(_ next: PaneContextPopoverServicePorts?) async {
        guard !stopping, service?.epoch != next?.epoch else { return }
        service = next
        serviceEpoch = next?.epoch ?? UUIDv7.generate()
        let replacingEpoch = serviceEpoch
        fannedOutSourceGenerations.removeAll()
        var retiring: [Task<Void, Never>] = []
        for key in Array(consumers.keys) {
            guard !stopping, serviceEpoch == replacingEpoch, var consumer = consumers[key] else { break }
            if let observation = consumer.sourceObservation {
                observation.task.cancel()
                retiring.append(observation.task)
            }
            consumer.sourceObservation = nil
            consumer.sourceEnded = false
            consumer.nextAgeBoundary = nil
            if consumer.demand.content != .card { consumer.acceptedState = nil }
            consumer.shellExecutablePath = nil
            consumer.liveSession = nil
            consumer.actionFeedback = nil
            consumer.latestPersonCommand = nil
            consumer.pendingPersonRefreshes.removeAll()
            consumer.loadedPages.removeAll()
            for requests in consumer.pendingPages.values {
                for request in requests { finishPage(request, outcome: .restartedOnRevision) }
            }
            consumer.pendingPages.removeAll()
            consumer.pageGeneration &+= 1
            consumers[key] = consumer
            guard let input = beginInput(key, opening: consumer.opening, kind: .action, cause: .serviceReplacement)
            else { continue }
            let capture = await captureValues(key, consumer.opening, input.generation, consumer.sources)
            await applyInput(capture, context: input)
        }
        rescheduleDeadline()
        for task in retiring { await task.value }
    }

    func close(_ key: PaneContextPopoverConsumerKey, opening expectedOpening: UInt64? = nil) async {
        if let expectedOpening {
            if let current = consumers[key], current.opening != expectedOpening { return }
            if let retiring = retirements[key], retiring.opening != expectedOpening { return }
        }
        if retirements[key] != nil {
            await awaitRetirement(key)
            return
        }
        guard let consumer = consumers.removeValue(forKey: key) else { return }
        retireInputCompletions(for: key, opening: consumer.opening)
        consumer.projection.invalidate()
        consumer.execution?.task.cancel()
        consumer.sourceObservation?.task.cancel()
        rescheduleDeadline()
        let retiringTimer = scheduledDeadline == nil ? deadlineTask : nil
        let id = UUIDv7.generate()
        let observe = observe
        let task = Task {
            await consumer.projection.retire()
            await consumer.execution?.task.value
            await consumer.sourceObservation?.task.value
            await retiringTimer?.value
            for requests in consumer.pendingPages.values {
                for request in requests { self.finishPage(request, outcome: .cancelled) }
            }
            observe(.consumer(key, opening: consumer.opening), .retired)
        }
        retirements[key] = .init(opening: consumer.opening, id: id, task: task)
        await awaitRetirement(key)
    }

    func awaitRetirement(_ key: PaneContextPopoverConsumerKey) async {
        guard let retiring = retirements[key] else { return }
        await retiring.task.value
        if retirements[key]?.id == retiring.id { retirements.removeValue(forKey: key) }
    }

    func stop() async {
        guard !stopping else { return }
        stopping = true
        let timer = deadlineTask
        deadlineTask = nil
        scheduledDeadline = nil
        timer?.cancel()
        for key in Array(consumers.keys) { await close(key) }
        for key in Array(retirements.keys) { await awaitRetirement(key) }
        await timer?.value
        for task in Array(personTasks.values) { _ = await task.value }
        for request in Array(pageWaiters.keys) { finishPage(request, outcome: .cancelled) }
    }

    func enqueue(_ key: PaneContextPopoverConsumerKey, kind: PaneContextPopoverOwnerFact.ExecutionKind) {
        let previous = reserveRequest(key, kind: kind)
        previous?.task.cancel()
        startIfEligible(key)
    }

    @discardableResult
    func reserveRequest(_ key: PaneContextPopoverConsumerKey, kind: PaneContextPopoverOwnerFact.ExecutionKind)
        -> Execution?
    {
        guard !stopping, var consumer = consumers[key] else { return nil }
        let previous = consumer.execution
        consumer.requestGeneration &+= 1
        consumer.projection.invalidate()
        let pageKind = consumer.pendingPages.isEmpty ? kind : combine(.page, kind)
        let required = consumer.pendingPersonRefreshes.isEmpty ? pageKind : combine(.action, pageKind)
        consumer.pending = combine(consumer.pending, required)
        consumers[key] = consumer
        return previous
    }

    func combine(
        _ old: PaneContextPopoverOwnerFact.ExecutionKind?, _ next: PaneContextPopoverOwnerFact.ExecutionKind
    ) -> PaneContextPopoverOwnerFact.ExecutionKind {
        switch (old, next) {
        case (.opening?, _): .opening
        case (_, .opening): .opening
        case (.action?, _): .action
        case (_, .action): .action
        case (.page?, _): .page
        case (_, .page): .page
        case (.background?, _): .background
        case (_, .background): .background
        case (.age?, .age), (nil, .age): .age
        }
    }

    func startIfEligible(_ key: PaneContextPopoverConsumerKey) {
        guard !stopping, var consumer = consumers[key], consumer.execution == nil, consumer.inputOperation == nil,
            let kind = consumer.pending
        else {
            return
        }
        if kind == .background || kind == .age, let last = consumer.lastAdmission,
            clock.now < last.advanced(by: AppPolicies.PaneContext.backgroundRefreshMinimumSpacing)
        {
            observe(.consumer(key, opening: consumer.opening), .deferred)
            return
        }
        let id = UUIDv7.generate()
        let opening = consumer.opening
        let epoch = serviceEpoch
        let generation = consumer.requestGeneration
        consumer.pending = nil
        consumer.lastAdmission = clock.now
        if kind == .age { consumer.ageGeneration &+= 1 }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.execute(key, id: id, opening: opening, epoch: epoch, generation: generation, kind: kind)
        }
        consumer.execution = .init(
            id: id, opening: opening, serviceEpoch: epoch, generation: generation, kind: kind, task: task)
        consumer.latestExecution = consumer.execution
        consumers[key] = consumer
        observe(.execution(key, id), .admitted(kind))
    }

    func isCurrent(_ key: PaneContextPopoverConsumerKey, opening: UInt64, epoch: UUID, generation: UInt64) -> Bool {
        guard !stopping, !Task.isCancelled, let current = consumers[key] else { return false }
        return current.opening == opening && serviceEpoch == epoch && current.requestGeneration == generation
    }

    func finishExecution(
        _ key: PaneContextPopoverConsumerKey, id: UUID, outcome: PaneContextPopoverOwnerFact.Finish
    ) {
        observe(.execution(key, id), .finished(outcome))
        guard var consumer = consumers[key], consumer.execution?.id == id else { return }
        consumer.execution = nil
        if consumer.pending == nil, outcome != .published, outcome != .equal {
            let abandoned = consumer.pendingPages.values.flatMap { $0 }
            consumer.pendingPages.removeAll()
            for request in abandoned { finishPage(request, outcome: .cancelled) }
        }
        consumers[key] = consumer
        startIfEligible(key)
        rescheduleDeadline()
    }
}

extension PaneContextPopoverRefreshOwner: PaneContextPopoverRefreshing {}
