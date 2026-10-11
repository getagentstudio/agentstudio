import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product admission gate")
struct BridgeProductAdmissionGateTests {
    @Test("close invalidates an admitted token and rejects new acquisition")
    func closeInvalidatesPriorAndFutureAdmission() throws {
        // Arrange
        let gate = BridgeProductAdmissionGate()
        let admission = try #require(gate.acquire())
        var mutationRan = false

        // Act
        gate.close()
        let result = admission.withValidAdmission {
            mutationRan = true
            return true
        }

        // Assert
        #expect(result == nil)
        #expect(!mutationRan)
        #expect(gate.acquire() == nil)
    }

    @Test("terminal close advances the epoch exactly once")
    func closeIsIdempotent() {
        // Arrange
        let gate = BridgeProductAdmissionGate()
        let openSnapshot = gate.diagnosticSnapshot

        // Act
        gate.close()
        let firstClosedSnapshot = gate.diagnosticSnapshot
        gate.close()
        let secondClosedSnapshot = gate.diagnosticSnapshot

        // Assert
        #expect(openSnapshot == .init(isOpen: true, epoch: 0))
        #expect(firstClosedSnapshot == .init(isOpen: false, epoch: 1))
        #expect(secondClosedSnapshot == firstClosedSnapshot)
    }

    @Test("admission contexts never match across pane gates")
    func foreignGateContextDoesNotMatch() throws {
        // Arrange
        let originalGate = BridgeProductAdmissionGate()
        let foreignGate = BridgeProductAdmissionGate()
        let originalAdmission = try #require(originalGate.acquire())
        let foreignAdmission = try #require(foreignGate.acquire())

        // Act
        let matches = originalAdmission.matches(foreignAdmission)

        // Assert
        #expect(!matches)
    }

    @Test("close linearizes between completed and suppressed mutations")
    func closeLinearizesVisibleMutation() throws {
        // Arrange
        let gate = BridgeProductAdmissionGate()
        let admission = try #require(gate.acquire())
        var publicationCount = 0

        // Act
        let beforeClose = admission.withValidAdmission {
            publicationCount += 1
            return publicationCount
        }
        gate.close()
        let afterClose = admission.withValidAdmission {
            publicationCount += 1
            return publicationCount
        }

        // Assert
        #expect(beforeClose == 1)
        #expect(afterClose == nil)
        #expect(publicationCount == 1)
    }

    @Test("racing close returns after the admitted mutation completes")
    func racingCloseLinearizesAfterAdmittedMutation() async throws {
        // Arrange
        let gate = BridgeProductAdmissionGate()
        let admission = try #require(gate.acquire())
        let (mutationEntryEvents, mutationEntryContinuation) = AsyncStream<Void>.makeStream()
        let (closeInvocationEvents, closeInvocationContinuation) = AsyncStream<Void>.makeStream()
        let mutationRelease = DispatchSemaphore(value: 0)
        let eventRecorder = BridgeProductAdmissionGateTestEventRecorder()
        // Both halves of this race block a thread on purpose: the mutation parks
        // in `wait()` while holding the gate, and `close()` parks on the gate's
        // lock behind it. Left on the cooperative executor they would occupy two
        // of its threads, which is how this test helped deadlock a three-core CI
        // lane. `withoutBlockingCooperativePool` keeps the race intact and moves
        // the parked threads to libdispatch.
        let mutationTask = Task {
            await withoutBlockingCooperativePool {
                admission.withValidAdmission {
                    mutationEntryContinuation.yield()
                    mutationEntryContinuation.finish()
                    mutationRelease.wait()
                    eventRecorder.append(.mutationCompleted)
                    return true
                }
            }
        }
        var mutationEntryIterator = mutationEntryEvents.makeAsyncIterator()
        _ = await mutationEntryIterator.next()
        let closeTask = Task {
            closeInvocationContinuation.yield()
            closeInvocationContinuation.finish()
            await withoutBlockingCooperativePool { gate.close() }
            eventRecorder.append(.closeReturned)
        }
        var closeInvocationIterator = closeInvocationEvents.makeAsyncIterator()
        _ = await closeInvocationIterator.next()

        // Act
        mutationRelease.signal()
        let admittedMutationResult = await mutationTask.value
        await closeTask.value
        let lateMutationResult = admission.withValidAdmission {
            eventRecorder.append(.lateMutationEntered)
            return true
        }

        // Assert
        #expect(admittedMutationResult == true)
        #expect(lateMutationResult == nil)
        #expect(eventRecorder.events == [.mutationCompleted, .closeReturned])
    }

    @Test("async suspension carrying a token does not hold the gate lock")
    func suspendedOperationDoesNotBlockClose() async throws {
        // Arrange
        let gate = BridgeProductAdmissionGate()
        let admission = try #require(gate.acquire())
        let suspension = BridgeProductAdmissionGateTestSuspension()
        let eventRecorder = BridgeProductAdmissionGateTestEventRecorder()
        let suspendedOperation = Task {
            await suspension.suspend()
            return admission.withValidAdmission {
                eventRecorder.append(.lateMutationEntered)
                return true
            }
        }
        await suspension.waitUntilSuspended()

        // Act
        gate.close()
        let closedSnapshot = gate.diagnosticSnapshot
        await suspension.resume()
        let mutationResult = await suspendedOperation.value

        // Assert
        #expect(closedSnapshot == .init(isOpen: false, epoch: 1))
        #expect(mutationResult == nil)
        #expect(eventRecorder.events.isEmpty)
    }
}

private final class BridgeProductAdmissionGateTestEventRecorder: @unchecked Sendable {
    enum Event: Equatable, Sendable {
        case mutationCompleted
        case closeReturned
        case lateMutationEntered
    }

    private let lock = NSLock()
    private var storedEvents: [Event] = []

    var events: [Event] {
        lock.withLock { storedEvents }
    }

    func append(_ event: Event) {
        lock.withLock { storedEvents.append(event) }
    }
}

private actor BridgeProductAdmissionGateTestSuspension {
    private var isSuspended = false
    private var suspensionContinuation: CheckedContinuation<Void, Never>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        await withCheckedContinuation { continuation in
            isSuspended = true
            suspensionContinuation = continuation
            let waiters = suspensionWaiters
            suspensionWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitUntilSuspended() async {
        if isSuspended { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resume() {
        isSuspended = false
        suspensionContinuation?.resume()
        suspensionContinuation = nil
    }
}
