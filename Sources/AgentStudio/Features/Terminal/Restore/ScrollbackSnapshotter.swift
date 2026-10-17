import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

/// One off-main cadence and one bounded fleet. Quit shares only the panes
/// in flight when it arrives, then refreshes the others through that same
/// pool. Retirement remains a per-pane write exclusion.
package actor ScrollbackSnapshotter {
    private struct CaptureMeasurement: Sendable {
        let disposition: ScrollbackSnapshotDisposition
        let capturedBytes: Int
        let writtenBytes: Int
    }

    private struct FleetResult: Sendable {
        let outcome: ScrollbackPassOutcome
        let paneCount: Int
        var paneIDs: Set<PaneId> = []
        var measurements: [PaneId: CaptureMeasurement] = [:]
    }

    private struct CaptureFleet {
        let id: UUID
        let owner: ScrollbackSnapshotterScope
        let task: Task<FleetResult, Never>
        var callers: Set<ScrollbackSnapshotterScope>
        var joinedPaneIDsByCaller: [ScrollbackSnapshotterScope: Set<PaneId>] = [:]
        var bindings: [ScrollbackPaneBinding]?
    }

    private struct CaptureAttempt {
        let id: UUID
        let task: Task<CaptureMeasurement, Never>
    }

    private struct CapturePass {
        let scope: ScrollbackSnapshotterScope
        let reason: ScrollbackPassReason
        let startedAt: Duration
        let task: Task<FleetResult, Never>?
        let joinedActiveFleet: Bool
        let sharedPaneIDs: Set<PaneId>
    }

    private enum QuitRaceResult: Sendable {
        case pass(ScrollbackPassOutcome)
        case deadline, cancelled
    }

    private let clock: ScrollbackSnapshotClock
    private let store: ScrollbackStore
    private let performanceRecorder: (any ScrollbackPerformanceRecording)?
    private let inventory: @Sendable () async -> ZmxSessionInventory
    private let paneBindings: @Sendable () async throws -> [ScrollbackPaneBinding]
    private let capture: @Sendable (ZmxSessionID) async -> ScrollbackCaptureResult
    private let captureInterval: Duration
    private let maximumConcurrentCaptures: Int
    private let factSink: (@Sendable (ScrollbackSnapshotterScope, ScrollbackSnapshotterFact) -> Void)?
    private var schedulerTask: Task<Void, Never>?
    private var fleet: CaptureFleet?
    private var attempts: [PaneId: CaptureAttempt] = [:]
    private var retiredPaneIDs: Set<PaneId> = []
    private var isQuitting = false
    private var isStopping = false
    private var didAnnounceStopped = false

    package init(
        clock: any Clock<Duration>, store: ScrollbackStore,
        performanceRecorder: (any ScrollbackPerformanceRecording)?,
        inventory: @escaping @Sendable () async -> ZmxSessionInventory,
        paneBindings: @escaping @Sendable () async throws -> [ScrollbackPaneBinding],
        capture: @escaping @Sendable (ZmxSessionID) async -> ScrollbackCaptureResult,
        maximumConcurrentCaptures: Int = AppPolicies.Restore.maximumConcurrentCaptures,
        captureInterval: Duration = AppPolicies.Restore.captureInterval,
        delay: AsyncDelay? = nil,
        factSink: (@Sendable (ScrollbackSnapshotterScope, ScrollbackSnapshotterFact) -> Void)? = nil
    ) {
        precondition(maximumConcurrentCaptures > 0 && captureInterval > .zero)
        self.clock = ScrollbackSnapshotClock(clock, delay: delay)
        self.store = store
        self.performanceRecorder = performanceRecorder
        self.inventory = inventory
        self.paneBindings = paneBindings
        self.capture = capture
        self.maximumConcurrentCaptures = maximumConcurrentCaptures
        self.captureInterval = captureInterval
        self.factSink = factSink
    }

    package func announceFirstFrameWait() {
        emit(.scheduler, .firstFrameGateWaiting)
    }

    package func startAfterFirstFrame() {
        emit(.scheduler, .firstFrameGatePassed)
        start()
    }

    package func start() {
        guard schedulerTask == nil, !isQuitting, !isStopping else { return }
        let clock = clock
        let interval = captureInterval
        let firstDeadline = clock.now + interval
        emit(.scheduler, .scheduled)
        schedulerTask = Task { [weak self] in
            var deadline = firstDeadline
            while !Task.isCancelled {
                do { try await clock.sleep(until: deadline) } catch { return }
                guard !Task.isCancelled, let self else { return }
                await self.runPeriodicPass()
                guard !Task.isCancelled else { return }
                deadline = clock.now + interval
            }
        }
    }

    private func runPeriodicPass() async {
        guard !isQuitting, !isStopping else { return }
        let pass = beginPass(scope: .pass(UUIDv7.generate()), reason: .periodic)
        _ = await completePass(pass)
    }

    package func captureForQuit(requestID: UUID, budget: Duration) async -> ScrollbackQuitOutcome {
        emit(.quit(requestID), .quitStarted)
        isQuitting = true
        schedulerTask?.cancel()
        let deadline = clock.now + max(.zero, budget)
        let clock = clock
        // Acquire the fleet and its in-flight pane set before suspension.
        // Completion between this request and the group's task cannot turn
        // an already-shared capture into a second quit attempt.
        let pass = beginPass(scope: .pass(requestID), reason: .quit)
        let outcome = await withTaskGroup(of: QuitRaceResult.self, returning: ScrollbackQuitOutcome.self) { group in
            group.addTask { [self] in
                let result = await completePass(pass)
                return .pass(result.outcome)
            }
            group.addTask {
                do { try await clock.sleep(until: deadline) } catch { return .cancelled }
                return .deadline
            }
            let first = await group.next() ?? .cancelled
            let outcome: ScrollbackQuitOutcome
            switch first {
            case .pass(let passOutcome):
                outcome = Task.isCancelled || passOutcome == .cancelled ? .cancelled : .completed
            case .deadline:
                outcome = .deadlineExceeded
                cancelFleet()
            case .cancelled:
                outcome = .cancelled
                cancelFleet()
            }
            group.cancelAll()
            // Cancellation never detaches an inventory probe, capture or
            // prepared file write from its owning pass.
            for await _ in group {}
            return outcome
        }
        emit(.quit(requestID), .quitFinished(outcome))
        return outcome
    }

    private func beginPass(scope: ScrollbackSnapshotterScope, reason: ScrollbackPassReason) -> CapturePass {
        let startedAt = clock.now
        emit(scope, .passStarted(reason))
        performanceRecorder?.recordScrollbackPassObservation(.started(reason))
        guard !isStopping, !Task.isCancelled else {
            return .init(
                scope: scope, reason: reason, startedAt: startedAt, task: nil,
                joinedActiveFleet: false, sharedPaneIDs: [])
        }
        let joinedActiveFleet = fleet != nil
        let sharedPaneIDs = reason == .quit ? Set(attempts.keys) : []
        let task = acquireFleet(
            scope: scope, joiningPaneIDs: reason == .quit && joinedActiveFleet ? sharedPaneIDs : nil)
        return .init(
            scope: scope, reason: reason, startedAt: startedAt, task: task,
            joinedActiveFleet: joinedActiveFleet, sharedPaneIDs: sharedPaneIDs)
    }

    private func completePass(_ pass: CapturePass) async -> FleetResult {
        var result: FleetResult
        if let task = pass.task {
            result = await task.value
        } else {
            result = .init(outcome: .cancelled, paneCount: 0)
        }
        if pass.reason == .quit, pass.joinedActiveFleet {
            // A periodic result completed before the request did not serve
            // this quit. Even cancelled passes account only for their joins.
            let sharedPaneIDs = result.paneIDs.intersection(pass.sharedPaneIDs)
            let sharedMeasurements = result.measurements.filter { pass.sharedPaneIDs.contains($0.key) }
            result = .init(
                outcome: result.outcome, paneCount: sharedPaneIDs.count,
                paneIDs: sharedPaneIDs, measurements: sharedMeasurements)
            if result.outcome == .completed, !Task.isCancelled, !isStopping {
                // The initial fleet has joined, so refreshing A cannot
                // overlap B or create a second pool, even with queued panes.
                let additional = await acquireFleet(scope: pass.scope, excluding: pass.sharedPaneIDs).value
                let paneIDs = sharedPaneIDs.union(additional.paneIDs)
                result = .init(
                    outcome: additional.outcome, paneCount: paneIDs.count, paneIDs: paneIDs,
                    measurements: sharedMeasurements.merging(additional.measurements) { _, newest in newest })
            }
        }
        recordPassEnd(pass, result: result)
        emit(pass.scope, .passFinished(outcome: result.outcome, capturedPaneCount: result.paneCount))
        return result
    }

    private func recordPassEnd(_ pass: CapturePass, result: FleetResult) {
        guard let performanceRecorder else { return }
        var capturedBytes = 0
        var writtenBytes = 0
        var outcomeCounts: [ScrollbackSnapshotDisposition: Int] = [:]
        for measurement in result.measurements.values {
            capturedBytes += measurement.capturedBytes
            writtenBytes += measurement.writtenBytes
            outcomeCounts[measurement.disposition, default: 0] += 1
        }
        performanceRecorder.recordScrollbackPassObservation(
            .finished(
                .init(
                    reason: pass.reason, paneCount: result.paneCount,
                    capturedBytes: capturedBytes, writtenBytes: writtenBytes, outcomeCounts: outcomeCounts,
                    duration: max(.zero, clock.now - pass.startedAt))))
    }

    private func acquireFleet(
        scope: ScrollbackSnapshotterScope, excluding paneIDs: Set<PaneId> = [], joiningPaneIDs: Set<PaneId>? = nil
    ) -> Task<FleetResult, Never> {
        let task: Task<FleetResult, Never>
        if var current = fleet {
            current.callers.insert(scope)
            if let joiningPaneIDs { current.joinedPaneIDsByCaller[scope] = joiningPaneIDs }
            if let bindings = current.bindings {
                for binding in bindings where joiningPaneIDs?.contains(binding.paneID) ?? true {
                    emit(scope, .captureJoined(binding))
                }
            }
            fleet = current
            task = current.task
        } else {
            let id = UUIDv7.generate()
            task = Task { [self] in await captureFleet(id: id, excluding: paneIDs) }
            fleet = CaptureFleet(id: id, owner: scope, task: task, callers: [scope], bindings: nil)
        }
        return task
    }

    private func captureFleet(id: UUID, excluding paneIDs: Set<PaneId>) async -> FleetResult {
        defer { if fleet?.id == id { fleet = nil } }
        let inventory = await inventory()
        guard !Task.isCancelled else { return .init(outcome: .cancelled, paneCount: 0) }
        guard case .complete(let entries) = inventory else {
            return .init(outcome: .inventoryUnavailable, paneCount: 0)
        }
        let bindings: [ScrollbackPaneBinding]
        do { bindings = try await paneBindings() } catch {
            return .init(outcome: Task.isCancelled ? .cancelled : .bindingsUnavailable, paneCount: 0)
        }
        var seenPaneIDs: Set<PaneId> = []
        let targets = bindings.filter { binding in
            guard case .alive? = entries[binding.sessionID], !retiredPaneIDs.contains(binding.paneID),
                !paneIDs.contains(binding.paneID)
            else { return false }
            return seenPaneIDs.insert(binding.paneID).inserted
        }
        guard !Task.isCancelled, var current = fleet, current.id == id else {
            return .init(outcome: .cancelled, paneCount: 0)
        }
        current.bindings = targets
        fleet = current
        for caller in current.callers {
            for binding in targets {
                if caller == current.owner {
                    emit(caller, .captureAdmitted(binding))
                } else if current.joinedPaneIDsByCaller[caller]?.contains(binding.paneID) ?? true {
                    emit(caller, .captureJoined(binding))
                }
            }
        }
        let measurements = await withTaskGroup(
            of: (PaneId, CaptureMeasurement).self, returning: [PaneId: CaptureMeasurement].self
        ) { group in
            var remaining = targets.makeIterator()
            var measurements: [PaneId: CaptureMeasurement] = [:]
            for _ in 0..<maximumConcurrentCaptures {
                guard let binding = remaining.next() else { break }
                group.addTask { [self] in (binding.paneID, await captureTarget(binding)) }
            }
            while let (paneID, measurement) = await group.next() {
                measurements[paneID] = measurement
                guard !Task.isCancelled, let binding = remaining.next() else { continue }
                group.addTask { [self] in (binding.paneID, await captureTarget(binding)) }
            }
            return measurements
        }
        return .init(
            outcome: Task.isCancelled ? .cancelled : .completed, paneCount: targets.count,
            paneIDs: Set(targets.map(\.paneID)), measurements: measurements)
    }

    private func captureTarget(_ binding: ScrollbackPaneBinding) async -> CaptureMeasurement {
        guard !Task.isCancelled else { return .init(disposition: .cancelled, capturedBytes: 0, writtenBytes: 0) }
        let id = UUIDv7.generate()
        let task = Task { [self] in await captureAndStore(binding, attemptID: id) }
        attempts[binding.paneID] = .init(id: id, task: task)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func captureAndStore(_ binding: ScrollbackPaneBinding, attemptID: UUID) async -> CaptureMeasurement {
        let scope = ScrollbackSnapshotterScope.capture(paneID: binding.paneID, attemptID: attemptID)
        emit(scope, .captureStarted(binding))
        let measurement: CaptureMeasurement
        if retiredPaneIDs.contains(binding.paneID) {
            measurement = .init(disposition: .retired, capturedBytes: 0, writtenBytes: 0)
        } else if Task.isCancelled || isStopping {
            measurement = .init(disposition: .cancelled, capturedBytes: 0, writtenBytes: 0)
        } else {
            let result = await capture(binding.sessionID)
            let capturedBytes: Int
            if case .accepted(let bytes) = result { capturedBytes = bytes.count } else { capturedBytes = 0 }
            if retiredPaneIDs.contains(binding.paneID) {
                measurement = .init(disposition: .retired, capturedBytes: capturedBytes, writtenBytes: 0)
            } else if Task.isCancelled || isStopping {
                measurement = .init(disposition: .cancelled, capturedBytes: capturedBytes, writtenBytes: 0)
            } else {
                measurement = await persist(result, for: binding.paneID)
            }
        }
        // Closing the attempt and its fact are one actor step. A quit
        // arriving after captureFinished sees this pane as completed.
        if attempts[binding.paneID]?.id == attemptID { attempts.removeValue(forKey: binding.paneID) }
        emit(scope, .captureFinished(measurement.disposition))
        return measurement
    }

    private func persist(_ result: ScrollbackCaptureResult, for paneID: PaneId) async -> CaptureMeasurement {
        let disposition: ScrollbackSnapshotDisposition
        switch result {
        case .accepted(let data):
            do {
                let write = try await store.storeWithMeasurement(paneId: paneID, capture: data)
                let disposition: ScrollbackSnapshotDisposition
                switch write.result {
                case .written: disposition = .written
                case .invalidUTF8: disposition = .invalidUTF8
                case .keepPrevious: disposition = .keepPrevious
                case .unchanged: disposition = .unchanged
                case .retired: disposition = .retired
                }
                return .init(disposition: disposition, capturedBytes: data.count, writtenBytes: write.writtenBytes)
            } catch {
                let failed: ScrollbackSnapshotDisposition =
                    retiredPaneIDs.contains(paneID)
                    ? .retired : (Task.isCancelled ? .cancelled : .writeFailed)
                return .init(disposition: failed, capturedBytes: data.count, writtenBytes: 0)
            }
        case .empty: disposition = .empty
        case .deadlineExceeded: disposition = .deadlineExceeded
        case .exceededCeiling: disposition = .exceededCeiling
        case .launchFailed(let errno): disposition = .launchFailed(errno: errno)
        case .readFailed: disposition = .readFailed
        case .exitedNonZero(let status): disposition = .exitedNonZero(status)
        }
        return .init(disposition: disposition, capturedBytes: 0, writtenBytes: 0)
    }

    /// Thin App forward passes UUIDs unchanged; conversion stays off-main.
    package func retire(operationID: UUID, paneUUIDs: Set<UUID>) async throws {
        try await retire(operationID: operationID, paneIDs: Set(paneUUIDs.map { PaneId(existingUUID: $0) }))
    }

    package func retire(operationID: UUID, paneIDs: Set<PaneId>) async throws {
        retiredPaneIDs.formUnion(paneIDs)
        emit(.retirement(operationID), .retirementStarted(paneIDs))
        var deletionError: (any Error)?
        do { try await store.retire(paneIds: paneIDs) } catch { deletionError = error }
        let retiring = paneIDs.compactMap { attempts[$0]?.task }
        for task in retiring { task.cancel() }
        for task in retiring { _ = await task.value }
        emit(.retirement(operationID), .retirementFinished)
        if let deletionError { throw deletionError }
    }

    private func cancelFleet() {
        fleet?.task.cancel()
        for attempt in attempts.values { attempt.task.cancel() }
    }

    package func shutdown() async {
        isStopping = true
        let scheduler = schedulerTask
        let activeFleet = fleet?.task
        let activeAttempts = attempts.values.map(\.task)
        scheduler?.cancel()
        cancelFleet()
        for attempt in activeAttempts { _ = await attempt.value }
        _ = await activeFleet?.value
        await scheduler?.value
        schedulerTask = nil
        if !didAnnounceStopped {
            didAnnounceStopped = true
            emit(.scheduler, .stopped)
        }
    }

    private func emit(_ scope: ScrollbackSnapshotterScope, _ fact: ScrollbackSnapshotterFact) {
        factSink?(scope, fact)
    }
}

/// Durations from an origin preserve absolute deadlines with an existential
/// production or test clock, without erasing its cancellation semantics.
private struct ScrollbackSnapshotClock: Sendable {
    private let nowValue: @Sendable () -> Duration
    private let sleepValue: @Sendable (Duration) async throws -> Void

    init<SourceClock: Clock>(_ clock: SourceClock, delay: AsyncDelay?) where SourceClock.Duration == Duration {
        let origin = clock.now
        nowValue = { origin.duration(to: clock.now) }
        sleepValue = { deadline in
            if let delay {
                // Production uses the existing nanosecond sleep seam to
                // avoid the macOS generic-clock deallocation crash. The
                // monotonic clock still owns the absolute deadline.
                try await delay.wait(max(.zero, deadline - origin.duration(to: clock.now)))
            } else {
                try await clock.sleep(until: origin.advanced(by: deadline), tolerance: nil)
            }
        }
    }

    var now: Duration { nowValue() }
    func sleep(until deadline: Duration) async throws { try await sleepValue(deadline) }
}
