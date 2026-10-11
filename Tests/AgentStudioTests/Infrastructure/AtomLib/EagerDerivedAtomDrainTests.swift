import Testing

@testable import AgentStudioInfrastructure

@MainActor
@Suite("Eager derived atom drain", .serialized)
struct EagerDerivedAtomDrainTests {
    @Test("stop and drain clears a released cancelled projection")
    func stopAndDrainClearsReleasedCancelledProjection() async {
        var gate: EagerDerivedAtomProjectionGate? = EagerDerivedAtomProjectionGate()
        weak let retainedGate = gate
        let cancellationSignal = EagerDerivedAtomTestSignal()
        let completionRecorder = EagerDerivedAtomCompletionRecorder()
        let atom = makeEagerDerivedAtomTestNode(completionRecorder: completionRecorder)

        atom.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 1,
                outputContent: 1,
                gate: gate,
                projectionCount: EagerDerivedAtomTestCounter(),
                observesCancellation: true,
                cancellationSignal: cancellationSignal
            ))
        _ = await requireEagerDerivedAtomTestEvent("projection start") {
            await retainedGate?.waitUntilStarted() == true
        }
        gate = nil

        atom.stop()
        #expect(atom.freshness == .stopped)
        #expect(atom.hasUnsettledProjectionTasks)

        async let drain: Void = atom.stopAndDrain()
        #expect(retainedGate != nil)
        retainedGate?.release()
        await drain

        #expect(!atom.hasUnsettledProjectionTasks)
        #expect(atom.value == nil)
        #expect(retainedGate == nil)
        _ = await requireEagerDerivedAtomTestEvent("cancelled completion") {
            await completionRecorder.wait(for: .cancelled(1))
        }
        _ = await requireEagerDerivedAtomTestEvent("projection cancellation") {
            await cancellationSignal.wait()
        }
    }

    @Test("stop and drain cancels active and pending intent without starting successor")
    func stopAndDrainCancelsActiveAndPendingWithoutStartingSuccessor() async {
        let gate = EagerDerivedAtomProjectionGate()
        let projectionCount = EagerDerivedAtomTestCounter()
        let completionRecorder = EagerDerivedAtomCompletionRecorder()
        let atom = makeEagerDerivedAtomTestNode(completionRecorder: completionRecorder)
        atom.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 1,
                outputContent: 1,
                gate: gate,
                projectionCount: projectionCount
            ))
        _ = await requireEagerDerivedAtomTestEvent("active projection start") {
            await gate.waitUntilStarted()
        }
        atom.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 2,
                outputContent: 2,
                projectionCount: projectionCount
            ))

        atom.stop()
        #expect(atom.freshness == .stopped)
        gate.release()
        await atom.stopAndDrain()

        #expect(projectionCount.count == 1)
        #expect(atom.freshness == .stopped)
        #expect(atom.value == nil)
        _ = await requireEagerDerivedAtomTestEvent("active cancellation") {
            await completionRecorder.wait(for: .cancelled(1))
        }
        _ = await requireEagerDerivedAtomTestEvent("pending cancellation") {
            await completionRecorder.wait(for: .cancelled(2))
        }
    }

    @Test("concurrent and repeated drains resume exactly once")
    func concurrentAndRepeatedDrainsResumeExactlyOnce() async {
        let gate = EagerDerivedAtomProjectionGate()
        let atom = makeEagerDerivedAtomTestNode()
        atom.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 1,
                outputContent: 1,
                gate: gate,
                projectionCount: EagerDerivedAtomTestCounter()
            ))
        _ = await requireEagerDerivedAtomTestEvent("projection start") {
            await gate.waitUntilStarted()
        }

        atom.stop()
        async let firstDrain: Void = atom.stopAndDrain()
        async let secondDrain: Void = atom.stopAndDrain()
        async let thirdDrain: Void = atom.stopAndDrain()
        gate.release()
        _ = await (firstDrain, secondDrain, thirdDrain)

        await atom.stopAndDrain()
        #expect(atom.freshness == .stopped)
        #expect(!atom.hasUnsettledProjectionTasks)
    }

    @Test("stop and drain rejects an awaiting owner candidate")
    func stopAndDrainRejectsAwaitingOwnerCandidate() async {
        let awaitingOwner = EagerDerivedAtomTestSignal()
        var retainedToken: EagerDerivedAtomTestNode.CandidateToken?
        let atom = EagerDerivedAtomTestNode(
            intentIdentity: \EagerDerivedAtomTestRequest.identity,
            combinePendingIntents: { _, latestRequest in latestRequest },
            prepare: { request, _ in .prepared(request) },
            project: projectEagerDerivedAtomTestRequest,
            classify: { candidate, _ in .changedAwaitingOwner(candidate) },
            onAwaitingOwner: { token, _, _ in
                retainedToken = token
                awaitingOwner.signal()
            }
        )

        atom.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 1,
                outputContent: 1,
                projectionCount: EagerDerivedAtomTestCounter()
            ))
        _ = await requireEagerDerivedAtomTestEvent("awaiting-owner candidate") {
            await awaitingOwner.wait()
        }

        await atom.stopAndDrain()

        #expect(atom.freshness == .stopped)
        #expect(!atom.hasUnsettledProjectionTasks)
        #expect(retainedToken.map { atom.settle($0, .accepted(EagerDerivedAtomTestValue(content: 1))) } == false)
        #expect(atom.value == nil)
    }
}
