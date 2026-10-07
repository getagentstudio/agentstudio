import AgentStudioTestHarness
import Testing

@testable import AgentStudioTestSupport

@Suite("Test push clock")
struct TestPushClockTests {
    @Test("a deadline waiter ignores a different sleep and resumes for its matching sleep")
    func pendingSleepWaiterMatchesOnlyItsDeadline() async throws {
        let facts = FactRecorder<TestPushClock.Instant, TestPushClock.PendingSleepFact>(
            vocabulary: FactVocabulary(
                describeScope: { String(describing: $0) },
                describeFact: { String(describing: $0) },
                isClosing: { _, fact in
                    if case .registrationSettled = fact { return true }
                    return false
                }
            ))
        let clock = TestPushClock(pendingSleepFactSink: { fact in
            facts.append(scope: fact.deadline, fact: fact)
        })
        let matchingDeadline = clock.now.advanced(by: .seconds(1))
        let differentDeadline = clock.now.advanced(by: .seconds(2))
        let waiterTask = Task {
            await clock.waitForPendingSleep(deadline: matchingDeadline)
        }
        // The owner announces insertion into its waiter list, before either sleep starts.
        await #expect(throws: Never.self) {
            try await facts.expectNext(in: matchingDeadline, .waiterRegistered(deadline: matchingDeadline))
        }
        let differentSleepOpening = await facts.mark(differentDeadline)
        let differentSleepTask = Task {
            try await clock.sleep(until: differentDeadline)
        }
        await #expect(throws: Never.self) {
            try await facts.expectNone(
                of: { fact in
                    guard case .registrationSettled(_, let resumedDeadlines) = fact else { return false }
                    return resumedDeadlines.contains(matchingDeadline)
                },
                "matching waiter resumed by a different deadline",
                from: differentSleepOpening,
                closedBy: { $0 == .registrationSettled(deadline: differentDeadline, resumedWaiterDeadlines: []) }
            )
        }

        let matchingSleepTask = Task {
            try await clock.sleep(until: matchingDeadline)
        }
        await #expect(throws: Never.self) {
            try await facts.expectNext(
                in: matchingDeadline,
                .registrationSettled(deadline: matchingDeadline, resumedWaiterDeadlines: [matchingDeadline])
            )
        }
        await waiterTask.value
        #expect(clock.pendingSleepDeadlines == [matchingDeadline, differentDeadline])
        clock.advance(to: differentDeadline)
        try await matchingSleepTask.value
        try await differentSleepTask.value
        #expect(clock.pendingSleepCount == 0)
        try await facts.finish()
    }

    @Test("a deadline waiter returns when its matching sleep is already pending")
    func pendingSleepWaiterAcceptsAlreadyRegisteredDeadline() async throws {
        let clock = TestPushClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        let sleepTask = Task {
            try await clock.sleep(until: deadline)
        }
        await clock.waitForPendingSleepCount(exactly: 1)

        await clock.waitForPendingSleep(deadline: deadline)

        #expect(clock.pendingSleepDeadlines.contains(deadline))
        clock.advance(to: deadline)
        try await sleepTask.value
    }

    @Test("advancing the next sleep atomically resumes only the earliest deadline")
    func advanceToNextPendingSleepResumesEarliestDeadline() async throws {
        let clock = TestPushClock()
        let start = clock.now
        let earlierTask = Task {
            try await clock.sleep(until: start.advanced(by: .seconds(1)))
        }
        let laterTask = Task {
            try await clock.sleep(until: start.advanced(by: .seconds(2)))
        }
        await clock.waitForPendingSleepCount(exactly: 2)

        #expect(clock.advanceToNextPendingSleep())
        try await earlierTask.value
        #expect(clock.pendingSleepCount == 1)
        #expect(clock.now == start.advanced(by: .seconds(1)))

        #expect(clock.advanceToNextPendingSleep())
        try await laterTask.value
        #expect(clock.pendingSleepCount == 0)
        #expect(clock.now == start.advanced(by: .seconds(2)))
        #expect(!clock.advanceToNextPendingSleep())
    }

    @Test("sleep entered after task cancellation terminates immediately")
    func cancelledBeforeSleepRegistrationTerminatesImmediately() async {
        let clock = TestPushClock()
        let sleepTask = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            try await clock.sleep(until: clock.now.advanced(by: .seconds(1)))
        }

        sleepTask.cancel()

        await #expect(throws: CancellationError.self) {
            try await sleepTask.value
        }
        #expect(clock.pendingSleepCount == 0)
    }
}
