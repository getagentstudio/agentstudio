import AgentStudioTestHarness
import Foundation
import Testing

@Suite("HeldStep")
struct HeldStepTests {
    @Test("a release made before any arrival is kept and later arrivals pass")
    func releaseBeforeArrivalIsKept() async throws {
        // Arrange
        let step = HeldStep<Int>("release-before-arrival")
        step.release()

        // Act
        try await step.arrive(1)
        try await step.arrive(2)

        // Assert
        #expect(try await step.firstArrival() == 1)
        #expect(step.recordedArrivals == [1, 2])
    }

    @Test("an arrival is held until release, and first arrival reports its value")
    func arrivalIsHeldUntilRelease() async throws {
        // Arrange
        let step = HeldStep<Int>("release-after-arrival")
        let arriving = Task { try await step.arrive(7) }

        // Act
        let firstArrival = try await step.firstArrival()
        step.release()

        // Assert
        #expect(firstArrival == 7)
        try await arriving.value
    }

    @Test("release resumes every current and later arrival")
    func releaseResumesEveryArrival() async throws {
        // Arrange
        let step = HeldStep<String>("many-arrivals")
        let first = Task { try await step.arrive("first") }
        let second = Task { try await step.arrive("second") }
        _ = try await step.firstArrival()

        // Act
        step.release()
        try await step.arrive("after-release")

        // Assert
        try await first.value
        try await second.value
        #expect(Set(step.recordedArrivals) == ["first", "second", "after-release"])
    }

    @Test("fail makes current and later arrivals throw the given error")
    func failThrowsTheGivenError() async throws {
        // Arrange
        let step = HeldStep<Int>("fail")
        let arriving = Task { try await step.arrive(1) }
        _ = try await step.firstArrival()

        // Act
        step.fail(HeldStepTestFailure.injected)

        // Assert
        await #expect(throws: HeldStepTestFailure.injected) { try await arriving.value }
        await #expect(throws: HeldStepTestFailure.injected) { try await step.arrive(2) }
    }

    @Test("retire resumes current and later arrivals as cancelled")
    func retireResumesAsCancelled() async throws {
        // Arrange
        let step = HeldStep<Int>("retire")
        let arriving = Task { try await step.arrive(1) }
        _ = try await step.firstArrival()

        // Act
        step.retire()

        // Assert
        await #expect(throws: CancellationError.self) { try await arriving.value }
        await #expect(throws: CancellationError.self) { try await step.arrive(2) }
    }

    @Test("the first terminal call wins and later terminal calls change nothing")
    func firstTerminalCallWins() async throws {
        // Arrange
        let releasedFirst = HeldStep<Int>("released-first")
        let failedFirst = HeldStep<Int>("failed-first")

        // Act
        releasedFirst.release()
        releasedFirst.fail(HeldStepTestFailure.injected)
        releasedFirst.retire()
        failedFirst.fail(HeldStepTestFailure.injected)
        failedFirst.release()
        failedFirst.retire()

        // Assert
        try await releasedFirst.arrive(1)
        await #expect(throws: HeldStepTestFailure.injected) { try await failedFirst.arrive(1) }
    }

    @Test("cancelling a held arrival resumes only that arrival, as cancelled")
    func cancellingAnArrivalResumesOnlyIt() async throws {
        // Arrange
        let step = HeldStep<String>("cancellation")
        let cancelled = Task { try await step.arrive("cancelled") }
        _ = try await step.firstArrival()
        let stillHeld = Task { try await step.arrive("still-held") }

        // Act
        cancelled.cancel()

        // Assert
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await step.cancellationObserved()
        step.release()
        try await stillHeld.value
    }

    @Test("a hold-through-cancellation step keeps a cancelled arrival held and reports the cancellation")
    func holdThroughCancellationKeepsTheArrivalHeld() async throws {
        // Arrange
        let step = HeldStep<Int>("hold-through-cancellation", cancellation: .holdThroughCancellation)
        let cancelled = Task { try await step.arrive(5) }
        _ = try await step.firstArrival()

        // Act
        cancelled.cancel()
        try await step.cancellationObserved()
        let arrivalsWhileHeld = step.recordedArrivals
        step.release()

        // Assert
        #expect(arrivalsWhileHeld == [5])
        try await cancelled.value
    }

    @Test("a blocking arrival from inside a task is rejected, naming the step, and does not park")
    func blockingArrivalInsideATaskIsRejected() async throws {
        // Arrange
        let step = HeldStep<Int>("blocking-inside-task")

        // Act
        let rejection = #expect(throws: HeldStepBlockingArrivalInsideTask.self) {
            try step.arriveBlocking(6)
        }

        // Assert
        #expect(rejection?.stepName == "blocking-inside-task")
        #expect(step.recordedArrivals.isEmpty)
        await #expect(throws: HeldStepBlockingArrivalInsideTask.self) { try await step.firstArrival() }
    }

    @Test("a blocking arrival parks a real thread until release")
    func blockingArrivalParksARealThreadUntilRelease() async throws {
        // Arrange
        let step = HeldStep<Int>("blocking-release")
        async let blockingArrival: Void = valueFromDedicatedThread { try step.arriveBlocking(3) }

        // Act
        let firstArrival = try await step.firstArrival()
        step.release()

        // Assert
        #expect(firstArrival == 3)
        try await blockingArrival
    }

    @Test("a blocking arrival throws the failure error")
    func blockingArrivalThrowsTheFailure() async throws {
        // Arrange
        let step = HeldStep<Int>("blocking-fail")
        let blockingArrival = Task { try await valueFromDedicatedThread { try step.arriveBlocking(4) } }
        _ = try await step.firstArrival()

        // Act
        step.fail(HeldStepTestFailure.injected)

        // Assert
        await #expect(throws: HeldStepTestFailure.injected) { try await blockingArrival.value }
    }

    @Test("waiting for a step that is never reached ends only by cancellation, naming the step")
    func neverReachedStepIsNamedOnCancellation() async throws {
        // Arrange
        let step = HeldStep<Int>("never-reached")
        let waiting = Task { try await step.firstArrival() }

        // Act
        waiting.cancel()

        // Assert
        let error = await #expect(throws: HeldStepNeverReached.self) { try await waiting.value }
        #expect(error?.stepName == "never-reached")
    }

    @Test("the event log records a wait with its test, and only the first arrival")
    func eventLogRecordsWaitingAndFirstArrival() async throws {
        // Arrange
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("held-step-log-\(ProcessInfo.processInfo.globallyUniqueString).log")
        defer { try? FileManager.default.removeItem(at: logURL) }
        let step = HeldStep<Int>("logged step", eventLog: HeldStepEventLog(path: logURL.path))
        let waiting = Task { try await step.firstArrival() }
        waiting.cancel()
        await #expect(throws: HeldStepNeverReached.self) { try await waiting.value }

        // Act
        step.release()
        try await step.arrive(1)
        try await step.arrive(2)

        // Assert
        let lines = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        let payloads = lines.filter { !$0.hasPrefix("wait_settled\t") }.map {
            $0.split(separator: "\t", omittingEmptySubsequences: false).dropLast().joined(separator: "\t")
        }
        #expect(
            payloads == [
                "waiting\t\(step.instanceID)\tlogged step\tAgentStudioTestHarnessTests/HeldStepTests.swift "
                    + "eventLogRecordsWaitingAndFirstArrival()",
                "arrived\t\(step.instanceID)\tlogged step",
            ]
        )
    }

    @Test("same-named steps log distinct instance ids, so one's arrival cannot answer the other's wait")
    func sameNamedStepsLogDistinctInstances() async throws {
        // Arrange
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("held-step-log-\(ProcessInfo.processInfo.globallyUniqueString).log")
        defer { try? FileManager.default.removeItem(at: logURL) }
        let eventLog = HeldStepEventLog(path: logURL.path)
        let arrivedFirst = HeldStep<Int>("shared name", eventLog: eventLog)
        let neverReached = HeldStep<Int>("shared name", eventLog: eventLog)

        // Act: one instance arrives before anyone waits; the other is waited on and never reached.
        arrivedFirst.release()
        try await arrivedFirst.arrive(1)
        let waiting = Task { try await neverReached.firstArrival() }
        waiting.cancel()
        await #expect(throws: HeldStepNeverReached.self) { try await waiting.value }

        // Assert
        let lines = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        let payloads = lines.filter { !$0.hasPrefix("wait_settled\t") }.map {
            $0.split(separator: "\t", omittingEmptySubsequences: false).dropLast().joined(separator: "\t")
        }
        #expect(arrivedFirst.instanceID != neverReached.instanceID)
        #expect(
            payloads == [
                "arrived\t\(arrivedFirst.instanceID)\tshared name",
                "waiting\t\(neverReached.instanceID)\tshared name\tAgentStudioTestHarnessTests/HeldStepTests.swift "
                    + "sameNamedStepsLogDistinctInstances()",
            ]
        )
    }
}

private enum HeldStepTestFailure: Error {
    case injected
}
