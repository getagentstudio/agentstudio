import Dispatch
import Synchronization

/// One named point in the work under test where that work stops until the test
/// decides how the step ends.
///
/// A fake dependency calls ``arrive(_:)`` (async seam) or ``arriveBlocking(_:)``
/// (synchronous seam reached from a dedicated thread) at the point it stands in
/// for. The test awaits ``firstArrival()`` — which completes because the work got
/// there, never because time passed — then ends the step with ``release()``,
/// ``fail(_:)`` or ``retire()``. The first terminal call wins and is sticky:
/// every parked arrival resumes with it, and every later arrival passes (or
/// throws the same error) immediately. A terminal call made before any arrival is
/// kept, so an early `release()` cannot be lost.
///
/// This is a class over a `Mutex`, not an actor, so a synchronous production
/// seam can arrive without an `await`. State changes happen under the lock;
/// continuations and semaphores are resumed after it is released, and no
/// detached task relays a resume. An arrival that immediately arrives again
/// therefore sees the terminal state.
package final class HeldStep<Arrival: Sendable>: Sendable {
    /// Names the step in every failure the harness reports for it, so a step
    /// that is never reached, or is reached the wrong way, is identifiable.
    package let name: String
    /// Unique among the steps of this process, in creation order. A process-local
    /// counter rather than a UUIDv7: the harness depends on nothing beyond the
    /// standard library, Foundation and Synchronization. The event log pairs a
    /// wait with an arrival by this id, never by name.
    package let instanceID: UInt64
    private let cancellationPolicy: HeldStepCancellationPolicy
    private let eventLog: HeldStepEventLog
    private let logIdentity: TestEventLogIdentity?
    private let test: String
    private let state = Mutex(HeldStepState<Arrival>())

    /// - Parameters:
    ///   - eventLog: defaults to the log the lane names in
    ///     `AGENTSTUDIO_HELD_STEP_LOG`, or none.
    ///   - fileID, function: identify the test in the event log; they default to
    ///     the place that created the step.
    package init(
        _ name: String,
        cancellation cancellationPolicy: HeldStepCancellationPolicy = .resumeOnCancellation,
        eventLog: HeldStepEventLog = .environment,
        fileID: String = #fileID,
        function: String = #function
    ) {
        self.name = name
        self.instanceID = heldStepInstanceCounter.wrappingAdd(1, ordering: .relaxed).newValue
        self.cancellationPolicy = cancellationPolicy
        self.eventLog = eventLog
        self.logIdentity = eventLog.path == nil ? nil : TestEventLogIdentity.current
        self.test = "\(fileID) \(function)"
    }

    /// Records an arrival and suspends until the step is released, failed or
    /// retired. Throws the failure error on `fail` and `CancellationError` on
    /// `retire`. When the arriving task is cancelled first, the cancellation
    /// policy decides: resume it as cancelled, or keep it held until a terminal
    /// call. Either way ``cancellationObserved()`` completes.
    package func arrive(_ arrival: Arrival) async throws {
        let admission = admitArrival(arrival, parking: .async)
        if let terminal = admission.terminal {
            try terminal.resolveArrival()
            return
        }
        let parkingID = admission.parkingID
        let resumesOnCancellation = cancellationPolicy == .resumeOnCancellation
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let terminal = state.withLock { state -> HeldStepTerminal? in
                    if let terminal = state.terminal {
                        return terminal
                    }
                    if Task.isCancelled, resumesOnCancellation {
                        return .retired
                    }
                    state.parkedAsyncArrivals[parkingID] = continuation
                    return nil
                }
                terminal?.resume(continuation)
            }
        } onCancel: {
            let cancellation = state.withLock {
                $0.observeCancellation(of: parkingID, resumingArrival: resumesOnCancellation)
            }
            cancellation.cancelledArrival?.resume(throwing: CancellationError())
            for observer in cancellation.cancellationObservers {
                observer.resume()
            }
        }
    }

    /// Records an arrival and parks the calling thread until the step ends.
    ///
    /// For a synchronous seam reached from a thread that may block: a socket
    /// listener's accept queue, or a thread from ``valueFromDedicatedThread(_:)``.
    /// The block lands on a semaphore this harness owns for this one arrival.
    /// Called from inside a task — the cooperative pool or an actor — it would
    /// park a thread other work needs, so it does not park: it throws
    /// ``HeldStepBlockingArrivalInsideTask`` and makes every ``firstArrival()``
    /// throw the same failure, naming the step.
    package func arriveBlocking(_ arrival: Arrival) throws {
        guard !Self.isRunningInsideTask else {
            let misuse = HeldStepBlockingArrivalInsideTask(stepName: name)
            let firstArrivalWaiters = state.withLock { $0.rejectBlockingArrival(misuse) }
            for waiter in firstArrivalWaiters {
                waiter.resume(throwing: misuse)
            }
            throw misuse
        }
        let parkingSemaphore = DispatchSemaphore(value: 0)
        let admission = admitArrival(arrival, parking: .blocking(parkingSemaphore))
        if let terminal = admission.terminal {
            try terminal.resolveArrival()
            return
        }
        parkingSemaphore.wait()
        let terminal = state.withLock { $0.terminal }
        guard let terminal else {
            preconditionFailure("HeldStep '\(name)' woke a blocking arrival before reaching a terminal state")
        }
        try terminal.resolveArrival()
    }

    /// The first arrival's value, once the work reaches the step.
    ///
    /// Has no deadline. When the step is never reached, the runner's hang bound
    /// cancels the waiting test and this throws ``HeldStepNeverReached`` naming
    /// the step.
    package func firstArrival() async throws -> Arrival {
        let (waiterID, hasArrival) = state.withLock { ($0.allocateID(), !$0.arrivals.isEmpty) }
        if !hasArrival {
            eventLog.recordWaiting(instanceID: instanceID, waiterID: waiterID, stepName: name, test: test)
        }
        do {
            let arrival = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Arrival, any Error>) in
                    let outcome = state.withLock { state -> Result<Arrival, any Error>? in
                        if let misuse = state.blockingArrivalMisuse {
                            return .failure(misuse)
                        }
                        if let firstArrival = state.arrivals.first {
                            return .success(firstArrival)
                        }
                        if Task.isCancelled {
                            return .failure(HeldStepNeverReached(stepName: name))
                        }
                        state.firstArrivalWaiters[waiterID] = continuation
                        return nil
                    }
                    if let outcome {
                        continuation.resume(with: outcome)
                    }
                }
            } onCancel: {
                let waiter = state.withLock { $0.firstArrivalWaiters.removeValue(forKey: waiterID) }
                waiter?.resume(throwing: HeldStepNeverReached(stepName: name))
            }
            eventLog.recordWaitSettled(instanceID: instanceID, waiterID: waiterID, outcome: .arrived)
            return arrival
        } catch {
            let wasCancelled = error is CancellationError || (error is HeldStepNeverReached && Task.isCancelled)
            eventLog.recordWaitSettled(
                instanceID: instanceID, waiterID: waiterID, outcome: wasCancelled ? .cancelled : .threw
            )
            throw error
        }
    }

    /// Returns once an arriving task has been cancelled while at the step.
    ///
    /// The event a `.holdThroughCancellation` interleaving waits on. Has no
    /// deadline; when no cancellation happens, the runner's hang bound cancels
    /// the waiting test and this throws ``HeldStepNeverReached`` naming the step.
    package func cancellationObserved() async throws {
        let observerID = state.withLock { $0.allocateID() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome = state.withLock { state -> Result<Void, any Error>? in
                    if state.hasObservedCancellation {
                        return .success(())
                    }
                    if Task.isCancelled {
                        return .failure(HeldStepNeverReached(stepName: name))
                    }
                    state.cancellationObservers[observerID] = continuation
                    return nil
                }
                if let outcome {
                    continuation.resume(with: outcome)
                }
            }
        } onCancel: {
            let observer = state.withLock { $0.cancellationObservers.removeValue(forKey: observerID) }
            observer?.resume(throwing: HeldStepNeverReached(stepName: name))
        }
    }

    /// Every arrival recorded so far, in arrival order. A synchronous read for
    /// asserting once, after the test has awaited whatever makes the count
    /// final.
    package var recordedArrivals: [Arrival] {
        state.withLock { $0.arrivals }
    }

    /// Whether an arriving task has been cancelled while at the step. A
    /// synchronous read for asserting once that no cancellation happened, after
    /// the test has awaited whatever could have caused one.
    package var hasObservedCancellation: Bool {
        state.withLock { $0.hasObservedCancellation }
    }

    /// Resumes every current and later arrival normally.
    package func release() {
        settle(.released)
    }

    /// Makes every current and later arrival throw `error`.
    package func fail(_ error: any Error) {
        settle(.failed(error))
    }

    /// Resumes every current and later arrival as cancelled.
    package func retire() {
        settle(.retired)
    }

    private static var isRunningInsideTask: Bool {
        withUnsafeCurrentTask { $0 != nil }
    }

    private func admitArrival(_ arrival: Arrival, parking: HeldStepParking) -> HeldStepAdmission<Arrival> {
        let admission = state.withLock { $0.admit(arrival, parking: parking) }
        if admission.isFirstArrival {
            eventLog.recordArrived(instanceID: instanceID, stepName: name, identity: logIdentity)
        }
        for waiter in admission.firstArrivalWaiters {
            waiter.resume(returning: arrival)
        }
        return admission
    }

    private func settle(_ terminal: HeldStepTerminal) {
        let settlement = state.withLock { $0.settle(terminal) }
        for continuation in settlement.parkedAsyncArrivals {
            terminal.resume(continuation)
        }
        for semaphore in settlement.parkedBlockingArrivals {
            semaphore.signal()
        }
    }
}

private let heldStepInstanceCounter = Atomic<UInt64>(0)

/// What a held async arrival does when its task is cancelled before the step
/// ends.
package enum HeldStepCancellationPolicy: Sendable {
    /// The arrival resumes at once, throwing `CancellationError`.
    case resumeOnCancellation
    /// The arrival stays held until `release`, `fail` or `retire`, the way a
    /// dependency that ignores cancellation behaves. The test observes the
    /// cancellation through ``HeldStep/cancellationObserved()``.
    case holdThroughCancellation
}

/// Thrown by ``HeldStep/firstArrival()`` and ``HeldStep/cancellationObserved()``
/// when the waiting task is cancelled before the awaited event — in practice,
/// the runner's hang bound.
package struct HeldStepNeverReached: Error, CustomStringConvertible {
    package let stepName: String

    package var description: String {
        "HeldStep '\(stepName)' was never reached"
    }
}

/// A blocking arrival made from inside a task, which would have parked a
/// cooperative-pool or actor thread. The step reports it instead of parking.
package struct HeldStepBlockingArrivalInsideTask: Error, CustomStringConvertible {
    package let stepName: String

    package var description: String {
        "HeldStep '\(stepName)' was reached by a blocking arrival from inside a task; "
            + "reach it from a dedicated thread or use arrive(_:)"
    }
}

private enum HeldStepTerminal: Sendable {
    case released
    case failed(any Error)
    case retired

    func resolveArrival() throws {
        switch self {
        case .released:
            return
        case .failed(let error):
            throw error
        case .retired:
            throw CancellationError()
        }
    }

    func resume(_ continuation: CheckedContinuation<Void, any Error>) {
        switch self {
        case .released:
            continuation.resume()
        case .failed(let error):
            continuation.resume(throwing: error)
        case .retired:
            continuation.resume(throwing: CancellationError())
        }
    }
}

private enum HeldStepParking {
    case async
    case blocking(DispatchSemaphore)
}

private struct HeldStepAdmission<Arrival: Sendable> {
    let isFirstArrival: Bool
    let parkingID: UInt64
    let terminal: HeldStepTerminal?
    let firstArrivalWaiters: [CheckedContinuation<Arrival, any Error>]
}

/// The arrivals a terminal transition must resume, taken out of the state
/// under the lock and resumed after it is released.
private struct HeldStepSettlement {
    var parkedAsyncArrivals: [CheckedContinuation<Void, any Error>] = []
    var parkedBlockingArrivals: [DispatchSemaphore] = []
}

/// What an arriving task's cancellation must resume once the lock is released.
private struct HeldStepCancellation {
    let cancelledArrival: CheckedContinuation<Void, any Error>?
    let cancellationObservers: [CheckedContinuation<Void, any Error>]
}

private struct HeldStepState<Arrival: Sendable> {
    var arrivals: [Arrival] = []
    var terminal: HeldStepTerminal?
    var blockingArrivalMisuse: HeldStepBlockingArrivalInsideTask?
    var hasObservedCancellation = false
    var parkedAsyncArrivals: [UInt64: CheckedContinuation<Void, any Error>] = [:]
    var parkedBlockingArrivals: [UInt64: DispatchSemaphore] = [:]
    var firstArrivalWaiters: [UInt64: CheckedContinuation<Arrival, any Error>] = [:]
    var cancellationObservers: [UInt64: CheckedContinuation<Void, any Error>] = [:]
    private var nextID: UInt64 = 1

    mutating func allocateID() -> UInt64 {
        defer { nextID += 1 }
        return nextID
    }

    /// Records the arrival. The first one takes every waiting `firstArrival`
    /// caller with it; a terminal state lets the arrival pass at once.
    mutating func admit(_ arrival: Arrival, parking: HeldStepParking) -> HeldStepAdmission<Arrival> {
        arrivals.append(arrival)
        var waiters: [CheckedContinuation<Arrival, any Error>] = []
        if arrivals.count == 1 {
            waiters = Array(firstArrivalWaiters.values)
            firstArrivalWaiters.removeAll()
        }
        if let terminal {
            return HeldStepAdmission(
                isFirstArrival: arrivals.count == 1,
                parkingID: 0,
                terminal: terminal,
                firstArrivalWaiters: waiters
            )
        }
        let parkingID = allocateID()
        if case .blocking(let semaphore) = parking {
            parkedBlockingArrivals[parkingID] = semaphore
        }
        return HeldStepAdmission(
            isFirstArrival: arrivals.count == 1,
            parkingID: parkingID,
            terminal: nil,
            firstArrivalWaiters: waiters
        )
    }

    /// Records a blocking arrival made from inside a task and hands back every
    /// waiting `firstArrival` caller, which must fail with it.
    mutating func rejectBlockingArrival(
        _ misuse: HeldStepBlockingArrivalInsideTask
    ) -> [CheckedContinuation<Arrival, any Error>] {
        blockingArrivalMisuse = blockingArrivalMisuse ?? misuse
        let waiters = Array(firstArrivalWaiters.values)
        firstArrivalWaiters.removeAll()
        return waiters
    }

    /// Records that an arriving task was cancelled. Under the resume policy the
    /// parked arrival leaves the state; under the hold policy it stays parked.
    mutating func observeCancellation(of parkingID: UInt64, resumingArrival: Bool) -> HeldStepCancellation {
        hasObservedCancellation = true
        let observers = Array(cancellationObservers.values)
        cancellationObservers.removeAll()
        let cancelledArrival = resumingArrival ? parkedAsyncArrivals.removeValue(forKey: parkingID) : nil
        return HeldStepCancellation(cancelledArrival: cancelledArrival, cancellationObservers: observers)
    }

    /// Records the first terminal state and hands back every parked arrival.
    /// A later terminal call changes nothing and resumes nothing.
    mutating func settle(_ newTerminal: HeldStepTerminal) -> HeldStepSettlement {
        guard terminal == nil else {
            return HeldStepSettlement()
        }
        terminal = newTerminal
        let settlement = HeldStepSettlement(
            parkedAsyncArrivals: Array(parkedAsyncArrivals.values),
            parkedBlockingArrivals: Array(parkedBlockingArrivals.values)
        )
        parkedAsyncArrivals.removeAll()
        parkedBlockingArrivals.removeAll()
        return settlement
    }
}
