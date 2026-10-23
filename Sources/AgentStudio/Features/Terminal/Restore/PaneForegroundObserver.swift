import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

/// Latest-state demand and future deadlines live here, off MainActor. A look
/// never absorbs a later trigger, and exit facts can only request fresh looks.
package actor PaneForegroundObserver<ObserverClock: Clock> where ObserverClock.Duration == Duration {
    private var didNoteRelaunch = false
    private var didNoteQuit = false
    private var quitEnumerationFinished = false

    package func noteLifecycle(_ trigger: ForegroundLookTrigger) async {
        guard !stopped else { return }
        switch trigger {
        case .relaunched:
            guard !didNoteRelaunch, !didNoteQuit else { return }
            didNoteRelaunch = true
        case .appQuitting:
            guard !didNoteQuit else { return }
            didNoteQuit = true
        default: return
        }
        let eligible = (try? await repository.eligiblePanes()) ?? []
        guard !stopped else { return }
        if case .relaunched = trigger, didNoteQuit { return }
        for binding in eligible { await note(trigger, pane: binding.paneId) }
        if case .appQuitting = trigger {
            quitEnumerationFinished = true
            resolveQuitWaitersIfSettled()
        }
    }

    private struct Demand {
        var dueAt: ObserverClock.Instant
        let maxAt: ObserverClock.Instant
        var requiredIdentity: Data?
        var quitting: Bool
    }
    private struct RunningLook {
        let operation: LookOperation
        let sequence: UInt64
        let taskId: UUID
        let requiredIdentity: Data?
        let quitting: Bool
    }
    private struct OwnedWatch {
        let value: CurrentExitWatch
        let identity: Data
        let cancel: @Sendable () -> Void
        let listenerId: UUID
    }
    private struct PaneState {
        var outputActive: UUID?
        var pending: Demand?
        var followUp: Demand?
        var running: RunningLook?
        var watch: OwnedWatch?
        var quitDeadline: ObserverClock.Instant?
        var settled = false
    }
    private let clock: ObserverClock
    private let policy: ForegroundObserverPolicy
    private let repository: any PaneForegroundEvidenceRepository
    private let probe: any TerminalForegroundProbing
    private let exitWatcher: any ProcessExitWatching
    private let observerLaunchId: UUID
    private let factSink: (@Sendable (ForegroundObserverFactScope, ForegroundObserverFact) -> Void)?
    private var panes: [UUID: PaneState] = [:]
    private var retiredPanes: Set<UUID> = []
    private var handoffs: Set<UUID> = []
    private var capturedPreRestorePanes: Set<UUID> = []
    private struct RestoreCandidate {
        var observation: PaneForegroundLook
        var incarnationReplaced = false
    }
    private var preRestoreObservations: [UUID: RestoreCandidate] = [:]
    // Serialize admission and one-shot handoff across repository suspensions.
    // Probing and other panes remain independent; these waiters own no tasks.
    private var observationOperations: Set<UUID> = []
    private struct ObservationWaiter {
        let continuation: CheckedContinuation<Bool, Never>
        let allowsStopped: Bool
    }
    private var observationWaiters: [UUID: [ObservationWaiter]] = [:]
    private var quitWaiters: [AsyncStream<Void>.Continuation] = []
    private var sequence: UInt64 = 0
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var deadlineTaskId: UUID?
    private var stopped = false

    package init(
        clock: ObserverClock,
        policy: ForegroundObserverPolicy,
        repository: any PaneForegroundEvidenceRepository,
        probe: any TerminalForegroundProbing,
        exitWatcher: any ProcessExitWatching,
        observerLaunchId: UUID,
        factSink: (@Sendable (ForegroundObserverFactScope, ForegroundObserverFact) -> Void)? = nil
    ) {
        self.clock = clock
        self.policy = policy
        self.repository = repository
        self.probe = probe
        self.exitWatcher = exitWatcher
        self.observerLaunchId = observerLaunchId
        self.factSink = factSink
    }

    package func note(_ trigger: ForegroundLookTrigger, pane: UUID) async {
        guard !stopped, !retiredPanes.contains(pane) else { return }
        if case .bindingChanged = trigger {
            try? await repository.clearReportedEvidenceForChangedBinding(paneId: pane)
        }
        guard !stopped, !retiredPanes.contains(pane), panes[pane]?.settled != true else { return }
        var state = panes[pane] ?? PaneState()
        let now = clock.now
        let due: ObserverClock.Instant
        switch trigger {
        case .outputBegan(let identifier):
            state.outputActive = identifier
            due = now.advanced(by: policy.lookMaxDelay)
        case .outputSettled(let identifier):
            guard state.outputActive == identifier else { return }
            state.outputActive = nil
            due = now.advanced(by: policy.lookSettleDelay)
        case .agentMessage: due = now.advanced(by: policy.lookSettleDelay)
        case .appQuitting:
            state.quitDeadline = now.advanced(by: policy.quitLookDeadline)
            due = now
        case .bindingChanged, .relaunched: due = now
        }
        let quitting = state.quitDeadline != nil
        mergeDemand(into: &state, due: due, identity: nil, quitting: quitting)
        panes[pane] = state
        if let factSink {
            let scope = ForegroundObserverFactScope(paneId: pane, operationId: UUIDv7.generate())
            factSink(scope, .scheduled)
            factSink(scope, .closed(.scheduled))
        }
        rescheduleDeadline()

    }

    private func mergeDemand(
        into state: inout PaneState, due: ObserverClock.Instant, identity: Data?, quitting: Bool
    ) {
        var demand = state.running == nil ? state.pending : state.followUp
        if var existing = demand {
            // Immediate triggers pull forward; settle triggers debounce within
            // the max fixed when this demand was first armed.
            existing.dueAt = due <= clock.now ? due : min(due, existing.maxAt)
            existing.requiredIdentity = identity
            existing.quitting = existing.quitting || quitting
            demand = existing
        } else {
            demand = Demand(
                dueAt: due, maxAt: clock.now.advanced(by: policy.lookMaxDelay),
                requiredIdentity: identity, quitting: quitting)
        }
        if state.running == nil { state.pending = demand } else { state.followUp = demand }
    }

    /// One sleep covers all pending looks and quit deadlines. Old sleeper ids
    /// are invalidated before cancellation, so a delivered wake stays inert.
    private func rescheduleDeadline() {
        if let old = deadlineTaskId { tasks[old]?.cancel() }
        deadlineTaskId = nil
        guard !stopped else { return }
        let deadline = panes.values.filter { !$0.settled }.flatMap { state in
            [state.pending?.dueAt, state.quitDeadline].compactMap { $0 }
        }.min()
        guard let deadline else { return }
        let identifier = UUIDv7.generate()
        deadlineTaskId = identifier
        let clock = clock
        tasks[identifier] = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline, tolerance: nil)
                await self?.deadlineReached(identifier)
            } catch {}
            await self?.taskFinished(identifier)
        }
    }

    private func deadlineReached(_ identifier: UUID) {
        guard deadlineTaskId == identifier, !stopped else { return }
        deadlineTaskId = nil
        let now = clock.now
        for pane in Array(panes.keys) {
            if let deadline = panes[pane]?.quitDeadline, deadline <= now { settleQuitDeadline(pane) }
        }
        var looks: [UUID: RunningLook] = [:]
        let taskId = UUIDv7.generate()
        for pane in Array(panes.keys) {
            guard var state = panes[pane], !state.settled, state.running == nil,
                let demand = state.pending, demand.dueAt <= now
            else { continue }
            sequence += 1
            let look = RunningLook(
                operation: newOperation(pane), sequence: sequence, taskId: taskId,
                requiredIdentity: demand.requiredIdentity, quitting: demand.quitting)
            state.pending = nil
            state.running = look
            panes[pane] = state
            looks[pane] = look
            recordFact(look.operation, .snapshotStarted(sequence: look.sequence))
        }
        if !looks.isEmpty {
            let captured = looks
            tasks[taskId] = Task { [weak self] in
                await self?.executeLooks(captured)
                await self?.taskFinished(taskId)
            }
        }
        rescheduleDeadline()

    }

    private func executeLooks(_ looks: [UUID: RunningLook]) async {
        do {
            // Persisted membership may trail a flush: removed sessions yield nothing; added panes join the next look.
            let bindings = try await repository.eligiblePanes().filter { looks[$0.paneId] != nil }
            try Task.checkCancellation()
            let snapshots = try await probe.probeForeground(of: bindings.map(\.sessionId))
            for (paneId, look) in looks {
                guard let binding = bindings.first(where: { $0.paneId == paneId }),
                    let snapshot = snapshots[binding.sessionId]
                else {
                    completeLook(paneId, look: look)
                    continue
                }
                await admitSnapshot(snapshot, binding: binding, look: look)
            }
        } catch {
            for (paneId, look) in looks { completeLook(paneId, look: look) }
        }
    }

    private func isCurrent(_ look: RunningLook) -> Bool {
        !stopped && !retiredPanes.contains(look.operation.paneId)
            && panes[look.operation.paneId]?.settled != true
            && panes[look.operation.paneId]?.running?.operation == look.operation
    }

    private func admitSnapshot(_ snapshot: ForegroundSnapshot, binding: ForegroundPaneBinding, look: RunningLook) async
    {
        guard await acquireObservationOperation(binding.paneId) else { return }
        defer { releaseObservationOperation(binding.paneId) }
        guard isCurrent(look), !Task.isCancelled else { return }
        if let identity = look.requiredIdentity, identity != snapshot.sessionIdentity {
            completeLook(binding.paneId, look: look)
            return
        }
        let observation = PaneForegroundLook(
            paneId: binding.paneId, zmxSessionId: binding.sessionId, sessionIdentity: snapshot.sessionIdentity,
            bindingGenerationId: binding.bindingGenerationId, program: snapshot.program,
            observerLaunchId: observerLaunchId, sequence: look.sequence, observedAt: Date())
        do {
            if !handoffs.contains(binding.paneId), !capturedPreRestorePanes.contains(binding.paneId) {
                let previous = try await repository.load(paneId: binding.paneId)
                if let previous, previous.observerLaunchId != observerLaunchId,
                    !stopped, !retiredPanes.contains(binding.paneId), !handoffs.contains(binding.paneId),
                    capturedPreRestorePanes.insert(binding.paneId).inserted
                {
                    preRestoreObservations[binding.paneId] = RestoreCandidate(observation: previous)
                }
            }
            guard isCurrent(look), !Task.isCancelled else { return }
            let admission = try await repository.admit(observation)
            // An admitted look matters even if its scheduling scope expired
            // during the write. Never let that hide a same-incarnation exit.
            if admission == .admitted, !stopped, !retiredPanes.contains(binding.paneId),
                !handoffs.contains(binding.paneId)
            {
                updateRestoreCandidate(observation)
            }
            guard isCurrent(look) else { return }
            recordFact(look.operation, .observation(admission))
            if admission == .admitted {
                // The repository remains authoritative after any suspension.
                let latest = try await repository.load(paneId: binding.paneId)
                guard isCurrent(look) else { return }
                if latest?.observerLaunchId == observerLaunchId, latest?.sequence == look.sequence {
                    replaceWatch(snapshot: snapshot, binding: binding, look: look)
                }
            }
        } catch {}
        completeLook(binding.paneId, look: look)
    }

    private func replaceWatch(snapshot: ForegroundSnapshot, binding: ForegroundPaneBinding, look: RunningLook) {
        removeWatch(binding.paneId)
        guard !look.quitting, snapshot.program == .claudeCode || snapshot.program == .codex,
            let process = snapshot.foregroundProcess, isCurrent(look)
        else { return }
        let watchId = UUIDv7.generate()
        let listenerId = UUIDv7.generate()
        let watch = exitWatcher.watchExit(of: process, watchId: watchId)
        panes[binding.paneId]?.watch = OwnedWatch(
            value: .init(watchId: watchId, incarnation: process, bindingGenerationId: binding.bindingGenerationId),
            identity: snapshot.sessionIdentity, cancel: watch.cancel, listenerId: listenerId)
        recordFact(look.operation, .watchRegistered(watchId: watchId))
        tasks[listenerId] = Task { [weak self] in
            for await event in watch.events { await self?.watchEvent(event, paneId: binding.paneId) }
            await self?.taskFinished(listenerId)
        }
    }

    private func watchEvent(_ event: ProcessExitWatchEvent, paneId: UUID) {
        let watchId: UUID
        switch event {
        case .exited(let identifier), .alreadyGone(let identifier), .unavailable(let identifier, _):
            watchId = identifier
        }
        let scope = LookOperation(paneId: paneId, operationId: watchId)
        guard !stopped, !retiredPanes.contains(paneId), let watch = panes[paneId]?.watch,
            watch.value.watchId == watchId
        else {
            recordFact(scope, .staleWatchDropped(watchId: watchId))
            recordFact(scope, .closed(.looked))
            return
        }
        // Clear the guard before cancellation: an already-read old callback
        // can still arrive, but cannot request another look or touch a record.
        removeWatch(paneId)
        guard var state = panes[paneId], !state.settled else { return }
        switch event {
        case .unavailable(_, let failure):
            recordFact(scope, .watchUnavailable(failure))
            mergeDemand(into: &state, due: clock.now.advanced(by: policy.lookMaxDelay), identity: nil, quitting: false)
        case .exited, .alreadyGone:
            mergeDemand(into: &state, due: clock.now, identity: watch.identity, quitting: false)
        }
        panes[paneId] = state
        recordFact(scope, .closed(.looked))
        rescheduleDeadline()
    }

    private func removeWatch(_ paneId: UUID) {
        guard let watch = panes[paneId]?.watch else { return }
        panes[paneId]?.watch = nil
        watch.cancel()
        tasks[watch.listenerId]?.cancel()
    }

    private func completeLook(_ paneId: UUID, look: RunningLook) {
        guard isCurrent(look), var state = panes[paneId] else { return }
        state.running = nil
        if look.quitting {
            removeWatch(paneId)
            state.watch = nil
            state.settled = true
            state.pending = nil
            state.followUp = nil
            state.quitDeadline = nil
        } else if let followUp = state.followUp {
            state.pending = followUp
            state.followUp = nil
        } else if state.outputActive != nil {
            let due = clock.now.advanced(by: policy.lookMaxDelay)
            state.pending = Demand(dueAt: due, maxAt: due, requiredIdentity: nil, quitting: false)
        }
        panes[paneId] = state
        recordFact(look.operation, .closed(look.quitting ? .quit : .looked))
        resolveQuitWaitersIfSettled()
        rescheduleDeadline()
    }

    private func settleQuitDeadline(_ paneId: UUID) {
        guard var state = panes[paneId], !state.settled else { return }
        removeWatch(paneId)
        state.watch = nil
        let scope = state.running?.operation
        let taskId = state.running?.taskId
        state.running = nil
        state.pending = nil
        state.followUp = nil
        state.quitDeadline = nil
        state.settled = true
        panes[paneId] = state
        cancelLookIfUnused(taskId)
        recordClosingFact(scope, paneId: paneId, .quitDeadline)
        resolveQuitWaitersIfSettled()
    }

    package func retire(paneId: UUID) async {
        guard retiredPanes.insert(paneId).inserted else { return }
        removeWatch(paneId)
        let scope = panes[paneId]?.running?.operation
        let taskId = panes[paneId]?.running?.taskId
        panes[paneId] = nil
        preRestoreObservations[paneId] = nil
        capturedPreRestorePanes.remove(paneId)
        resolveQuitWaitersIfSettled()
        cancelLookIfUnused(taskId)
        try? await repository.retire(paneId: paneId)
        recordClosingFact(scope, paneId: paneId, .retired)
        rescheduleDeadline()
    }

    package func takePreRestoreLook(paneId: UUID) async throws -> PaneForegroundLook? {
        // Stopping ends live observation, not access to durable restore evidence.
        guard await acquireObservationOperation(paneId, allowsStopped: true) else { return nil }
        defer { releaseObservationOperation(paneId) }
        guard !retiredPanes.contains(paneId), handoffs.insert(paneId).inserted else { return nil }
        if capturedPreRestorePanes.contains(paneId) {
            return preRestoreObservations.removeValue(forKey: paneId)?.observation
        }
        let observation = try await repository.load(paneId: paneId)
        return !retiredPanes.contains(paneId) ? observation : nil
    }

    private func updateRestoreCandidate(_ observation: PaneForegroundLook) {
        let paneId = observation.paneId
        if var candidate = preRestoreObservations[paneId] {
            guard !candidate.incarnationReplaced else { return }
            if candidate.observation.zmxSessionId == observation.zmxSessionId,
                candidate.observation.sessionIdentity == observation.sessionIdentity
            {
                candidate.observation = observation
            } else {
                // Admission validated the identity: this is a proven replacement.
                candidate.incarnationReplaced = true
            }
            preRestoreObservations[paneId] = candidate
        } else {
            capturedPreRestorePanes.insert(paneId)
            preRestoreObservations[paneId] = RestoreCandidate(observation: observation)
        }
    }

    private func acquireObservationOperation(_ paneId: UUID, allowsStopped: Bool = false) async -> Bool {
        guard !stopped || allowsStopped else { return false }
        if observationOperations.insert(paneId).inserted { return true }
        // Continuations survive caller cancellation until ownership is passed;
        // a cancelled look then releases immediately instead of stranding a pane.
        return await withCheckedContinuation { continuation in
            observationWaiters[paneId, default: []].append(
                ObservationWaiter(continuation: continuation, allowsStopped: allowsStopped))
        }
    }

    private func releaseObservationOperation(_ paneId: UUID) {
        if var waiters = observationWaiters[paneId], !waiters.isEmpty {
            let next = waiters.removeFirst()
            observationWaiters[paneId] = waiters.isEmpty ? nil : waiters
            next.continuation.resume(returning: !stopped || next.allowsStopped)
        } else {
            observationOperations.remove(paneId)
        }
    }

    /// The quit deadline is owned here, so App can join the bounded final look
    /// concurrently with its other flushes without chaining their budgets.
    package func finishQuitLooks() async {
        await noteLifecycle(.appQuitting)
        guard !stopped,
            !quitEnumerationFinished || panes.values.contains(where: { !$0.settled && $0.quitDeadline != nil })
        else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        quitWaiters.append(continuation)
        for await _ in stream { break }
    }

    private func resolveQuitWaitersIfSettled() {
        guard
            stopped
                || (quitEnumerationFinished && !panes.values.contains(where: { !$0.settled && $0.quitDeadline != nil }))
        else { return }
        let waiters = quitWaiters
        quitWaiters.removeAll()
        for waiter in waiters {
            waiter.yield(())
            waiter.finish()
        }
    }

    package func currentWatch(paneId: UUID) -> CurrentExitWatch? { panes[paneId]?.watch?.value }

    package func shutdown() async {
        guard !stopped else {
            for task in Array(tasks.values) { await task.value }
            return
        }
        stopped = true
        // Admission waiters stop now; handoffs retain FIFO ownership and drain
        // after the in-flight owner releases, including after shutdown returns.
        for paneId in Array(observationWaiters.keys) {
            let waiting = observationWaiters[paneId] ?? []
            let handoffWaiters = waiting.filter(\.allowsStopped)
            observationWaiters[paneId] = handoffWaiters.isEmpty ? nil : handoffWaiters
            for waiter in waiting where !waiter.allowsStopped { waiter.continuation.resume(returning: false) }
        }
        resolveQuitWaitersIfSettled()
        preRestoreObservations.removeAll()
        capturedPreRestorePanes.removeAll()
        deadlineTaskId = nil
        for pane in Array(panes.keys) {
            removeWatch(pane)
            if let look = panes[pane]?.running { recordFact(look.operation, .closed(.quit)) }
        }
        panes.removeAll()
        let owned = Array(tasks.values)
        for task in owned { task.cancel() }
        for task in owned { await task.value }
        tasks.removeAll()
    }

    private func cancelLookIfUnused(_ identifier: UUID?) {
        guard let identifier, !panes.values.contains(where: { $0.running?.taskId == identifier }) else { return }
        tasks[identifier]?.cancel()
    }

    private func taskFinished(_ identifier: UUID) { tasks[identifier] = nil }
    /// Runtime operation identity participates in stale-result admission independently of observation.
    private struct LookOperation: Equatable, Sendable {
        let paneId: UUID
        let operationId: UUID
    }

    private func recordFact(_ operation: LookOperation, _ fact: ForegroundObserverFact) {
        guard let factSink else { return }
        factSink(.init(paneId: operation.paneId, operationId: operation.operationId), fact)
    }

    private func recordClosingFact(_ operation: LookOperation?, paneId: UUID, _ close: ForegroundObserverClose) {
        guard let factSink else { return }
        factSink(.init(paneId: paneId, operationId: operation?.operationId ?? UUIDv7.generate()), .closed(close))
    }

    private func newOperation(_ paneId: UUID) -> LookOperation {
        .init(paneId: paneId, operationId: UUIDv7.generate())
    }
}
