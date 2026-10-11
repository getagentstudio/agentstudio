import Testing

@testable import AgentStudioInfrastructure

@Suite(.serialized)
@MainActor
struct EagerDerivedAtomTests {
    @Test
    func initialPublicationStoresValueAndKeepsRevisionZero() async {
        let gate = EagerDerivedAtomProjectionGate()
        defer { gate.release() }
        let projectionCount = EagerDerivedAtomTestCounter()
        let atom = makeEagerDerivedAtomTestNode()
        let valueChanged = EagerDerivedAtomTestSignal()

        atom.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 1,
                outputContent: 10,
                gate: gate,
                projectionCount: projectionCount
            ))
        guard
            await requireEagerDerivedAtomTestEvent(
                "initial projection start",
                wait: { await gate.waitUntilStarted() }
            )
        else { return }
        #expect(atom.freshness == .running(1))
        observeEagerDerivedAtomValue(atom) {
            valueChanged.signal()
        }

        gate.release()
        guard
            await requireEagerDerivedAtomTestEvent(
                "initial value publication",
                wait: { await valueChanged.wait() }
            )
        else { return }

        #expect(atom.value?.content == 10)
        #expect(atom.freshness == .current(1))
        #expect(atom.revision == 0)
        #expect(projectionCount.count == 1)
    }

    @Test
    func equalCurrentRequestIsANoOp() async {
        let gate = EagerDerivedAtomProjectionGate()
        defer { gate.release() }
        let projectionCount = EagerDerivedAtomTestCounter()
        let atom = makeEagerDerivedAtomTestNode()
        let request = makeEagerDerivedAtomTestRequest(
            identity: 1,
            outputContent: 10,
            gate: gate,
            projectionCount: projectionCount
        )

        atom.admit(request)
        guard
            await requireEagerDerivedAtomTestEvent(
                "equal request projection start",
                wait: { await gate.waitUntilStarted() }
            )
        else { return }
        atom.admit(request)

        #expect(atom.freshness == .running(1))
        #expect(projectionCount.count == 1)

        let valueChanged = EagerDerivedAtomTestSignal()
        observeEagerDerivedAtomValue(atom) {
            valueChanged.signal()
        }
        gate.release()
        guard
            await requireEagerDerivedAtomTestEvent(
                "equal request initial publication",
                wait: { await valueChanged.wait() }
            )
        else { return }

        atom.admit(request)
        #expect(atom.freshness == .current(1))
        #expect(projectionCount.count == 1)
    }

    @Test
    func successorCancelsRetainedPredecessor() async {
        let firstGate = EagerDerivedAtomProjectionGate()
        let secondGate = EagerDerivedAtomProjectionGate()
        defer {
            firstGate.release()
            secondGate.release()
        }
        let cancellationSignal = EagerDerivedAtomTestSignal()
        let projectionCount = EagerDerivedAtomTestCounter()
        let atom = makeEagerDerivedAtomTestNode()

        atom.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 1,
                outputContent: 10,
                gate: firstGate,
                projectionCount: projectionCount,
                observesCancellation: true,
                cancellationSignal: cancellationSignal
            ))
        guard
            await requireEagerDerivedAtomTestEvent(
                "predecessor projection start",
                wait: { await firstGate.waitUntilStarted() }
            )
        else { return }

        atom.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 2,
                outputContent: 20,
                gate: secondGate,
                projectionCount: projectionCount
            ))
        firstGate.release()
        guard
            await requireEagerDerivedAtomTestEvent(
                "predecessor cancellation",
                wait: { await cancellationSignal.wait() }
            ),
            await requireEagerDerivedAtomTestEvent(
                "successor projection start",
                wait: { await secondGate.waitUntilStarted() }
            )
        else { return }

        let valueChanged = EagerDerivedAtomTestSignal()
        observeEagerDerivedAtomValue(atom) {
            valueChanged.signal()
        }
        secondGate.release()
        guard
            await requireEagerDerivedAtomTestEvent(
                "successor publication",
                wait: { await valueChanged.wait() }
            )
        else { return }

        #expect(atom.value?.content == 20)
        #expect(atom.freshness == .current(2))
        #expect(projectionCount.count == 2)
    }

    @Test
    func rapidAdmissionsExecuteOnlyTheLatestPendingRequest() async {
        let predecessorGate = EagerDerivedAtomProjectionGate()
        let skippedPendingGate = EagerDerivedAtomProjectionGate()
        let latestPendingGate = EagerDerivedAtomProjectionGate()
        defer {
            predecessorGate.release()
            skippedPendingGate.release()
            latestPendingGate.release()
        }
        let projectionCount = EagerDerivedAtomTestCounter()
        let completionRecorder = EagerDerivedAtomCompletionRecorder()
        let atom = makeEagerDerivedAtomTestNode(
            completionRecorder: completionRecorder,
            combinePendingRequests: { accumulatedRequest, latestRequest in
                EagerDerivedAtomTestRequest(
                    identity: latestRequest.identity,
                    outputContent: accumulatedRequest.outputContent + latestRequest.outputContent,
                    gate: latestRequest.gate,
                    projectionCount: latestRequest.projectionCount,
                    concurrencyTracker: latestRequest.concurrencyTracker,
                    observesCancellation: latestRequest.observesCancellation,
                    cancellationSignal: latestRequest.cancellationSignal
                )
            }
        )

        atom.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 1,
                outputContent: 1,
                gate: predecessorGate,
                projectionCount: projectionCount
            ))
        _ = await requireEagerDerivedAtomTestEvent("predecessor projection start") {
            await predecessorGate.waitUntilStarted()
        }

        atom.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 2,
                outputContent: 10,
                gate: skippedPendingGate,
                projectionCount: projectionCount
            ))
        atom.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 3,
                outputContent: 100,
                gate: latestPendingGate,
                projectionCount: projectionCount
            ))
        predecessorGate.release()

        _ = await requireEagerDerivedAtomTestEvent("first pending projection supersession") {
            await completionRecorder.wait(for: .superseded(1))
        }
        _ = await requireEagerDerivedAtomTestEvent("second pending projection supersession") {
            await completionRecorder.wait(for: .superseded(2))
        }
        _ = await requireEagerDerivedAtomTestEvent("latest pending projection start") {
            await latestPendingGate.waitUntilStarted()
        }
        #expect(projectionCount.count == 2)
        #expect(atom.freshness == .running(3))

        latestPendingGate.release()
        _ = await requireEagerDerivedAtomTestEvent("latest projection publication") {
            await completionRecorder.wait(for: .published(3))
        }
        #expect(atom.value?.content == 111)
        #expect(atom.freshness == .current(3))
    }

    @Test
    func successorStartsOnlyAfterCancelledPredecessorTerminates() async {
        let predecessorGate = EagerDerivedAtomProjectionGate()
        let successorGate = EagerDerivedAtomProjectionGate()
        defer {
            predecessorGate.release()
            successorGate.release()
        }
        let concurrencyTracker = EagerDerivedAtomConcurrencyTracker()
        let projectionCount = EagerDerivedAtomTestCounter()
        let completionRecorder = EagerDerivedAtomCompletionRecorder()
        let atom = makeEagerDerivedAtomTestNode(completionRecorder: completionRecorder)

        atom.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 1,
                outputContent: 10,
                gate: predecessorGate,
                projectionCount: projectionCount,
                concurrencyTracker: concurrencyTracker
            ))
        guard
            await requireEagerDerivedAtomTestEvent(
                "single-flight predecessor start",
                wait: { await predecessorGate.waitUntilStarted() }
            )
        else { return }

        atom.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 2,
                outputContent: 20,
                gate: successorGate,
                projectionCount: projectionCount,
                concurrencyTracker: concurrencyTracker
            ))
        predecessorGate.release()
        guard
            await requireEagerDerivedAtomTestEvent(
                "single-flight predecessor settlement",
                wait: { await completionRecorder.wait(for: .superseded(1)) }
            ),
            await requireEagerDerivedAtomTestEvent(
                "single-flight successor start",
                wait: { await successorGate.waitUntilStarted() }
            )
        else { return }

        #expect(concurrencyTracker.maximumConcurrentProjectionCount == 1)

        successorGate.release()
        guard
            await requireEagerDerivedAtomTestEvent(
                "single-flight successor publication",
                wait: { await completionRecorder.wait(for: .published(2)) }
            )
        else { return }
        #expect(atom.value?.content == 20)
        #expect(projectionCount.count == 2)
    }

    @Test
    func staleCompletionThatIgnoresCancellationCannotPublish() async {
        let firstGate = EagerDerivedAtomProjectionGate()
        let secondGate = EagerDerivedAtomProjectionGate()
        defer {
            firstGate.release()
            secondGate.release()
        }
        let completionRecorder = EagerDerivedAtomCompletionRecorder()
        let projectionCount = EagerDerivedAtomTestCounter()
        let atom = makeEagerDerivedAtomTestNode(completionRecorder: completionRecorder)

        atom.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 1,
                outputContent: 10,
                gate: firstGate,
                projectionCount: projectionCount
            ))
        guard
            await requireEagerDerivedAtomTestEvent(
                "stale projection start",
                wait: { await firstGate.waitUntilStarted() }
            )
        else { return }
        atom.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 2,
                outputContent: 20,
                gate: secondGate,
                projectionCount: projectionCount
            ))
        firstGate.release()
        guard
            await requireEagerDerivedAtomTestEvent(
                "stale completion admission decision",
                wait: { await completionRecorder.wait(for: .superseded(1)) }
            ),
            await requireEagerDerivedAtomTestEvent(
                "replacement projection start",
                wait: { await secondGate.waitUntilStarted() }
            )
        else { return }

        #expect(atom.value == nil)
        #expect(atom.freshness == .running(2))
        #expect(atom.revision == 0)

        let valueChanged = EagerDerivedAtomTestSignal()
        observeEagerDerivedAtomValue(atom) {
            valueChanged.signal()
        }
        secondGate.release()
        guard
            await requireEagerDerivedAtomTestEvent(
                "replacement publication",
                wait: { await valueChanged.wait() }
            )
        else { return }

        #expect(atom.value?.content == 20)
        #expect(atom.freshness == .current(2))
    }

    @Test
    func equalCurrentCompletionPreservesValueRevisionAndOutputObservation() async {
        let firstGate = EagerDerivedAtomProjectionGate()
        let secondGate = EagerDerivedAtomProjectionGate()
        defer {
            firstGate.release()
            secondGate.release()
        }
        let projectionCount = EagerDerivedAtomTestCounter()
        let atom = makeEagerDerivedAtomTestNode()

        atom.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 1,
                outputContent: 10,
                gate: firstGate,
                projectionCount: projectionCount
            ))
        guard
            await requireEagerDerivedAtomTestEvent(
                "first equal-output projection start",
                wait: { await firstGate.waitUntilStarted() }
            )
        else { return }
        let firstValueChanged = EagerDerivedAtomTestSignal()
        observeEagerDerivedAtomValue(atom) {
            firstValueChanged.signal()
        }
        firstGate.release()
        guard
            await requireEagerDerivedAtomTestEvent(
                "first equal-output publication",
                wait: { await firstValueChanged.wait() }
            )
        else { return }
        let firstValue = atom.value

        let outputObservationCount = EagerDerivedAtomTestCounter()
        observeEagerDerivedAtomValue(atom) {
            outputObservationCount.increment()
        }
        atom.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 2,
                outputContent: 10,
                gate: secondGate,
                projectionCount: projectionCount
            ))
        guard
            await requireEagerDerivedAtomTestEvent(
                "second equal-output projection start",
                wait: { await secondGate.waitUntilStarted() }
            )
        else { return }
        #expect(outputObservationCount.isEmpty)

        let freshnessChanged = EagerDerivedAtomTestSignal()
        observeEagerDerivedAtomFreshness(atom) {
            freshnessChanged.signal()
        }
        secondGate.release()
        guard
            await requireEagerDerivedAtomTestEvent(
                "equal-output freshness publication",
                wait: { await freshnessChanged.wait() }
            )
        else { return }

        #expect(atom.value === firstValue)
        #expect(atom.freshness == .current(2))
        #expect(atom.revision == 0)
        #expect(outputObservationCount.isEmpty)
    }

    @Test
    func sourceInvalidationSynchronouslyRevokesWorkBeforeSuccessorAdmission() async {
        let firstGate = EagerDerivedAtomProjectionGate()
        let successorGate = EagerDerivedAtomProjectionGate()
        defer {
            firstGate.release()
            successorGate.release()
        }
        let completionRecorder = EagerDerivedAtomCompletionRecorder()
        let projectionCount = EagerDerivedAtomTestCounter()
        let atom = makeEagerDerivedAtomTestNode(completionRecorder: completionRecorder)

        atom.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 1,
                outputContent: 10,
                gate: firstGate,
                projectionCount: projectionCount
            ))
        guard
            await requireEagerDerivedAtomTestEvent(
                "invalidated projection start",
                wait: { await firstGate.waitUntilStarted() }
            )
        else { return }

        atom.sourceDidInvalidate()
        firstGate.release()
        guard
            await requireEagerDerivedAtomTestEvent(
                "invalidated completion admission decision",
                wait: { await completionRecorder.wait(for: .superseded(1)) }
            )
        else { return }

        #expect(atom.value == nil)
        #expect(atom.freshness != .current(1))

        atom.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 1,
                outputContent: 11,
                gate: successorGate,
                projectionCount: projectionCount
            ))
        guard
            await requireEagerDerivedAtomTestEvent(
                "post-invalidation successor start",
                wait: { await successorGate.waitUntilStarted() }
            )
        else { return }
        let valueChanged = EagerDerivedAtomTestSignal()
        observeEagerDerivedAtomValue(atom) {
            valueChanged.signal()
        }
        successorGate.release()
        guard
            await requireEagerDerivedAtomTestEvent(
                "post-invalidation successor publication",
                wait: { await valueChanged.wait() }
            )
        else { return }

        #expect(atom.value?.content == 11)
        #expect(atom.freshness == .current(1))
        #expect(projectionCount.count == 2)
    }

    @Test
    func queuedSourceInvalidationPreservesSynchronouslyAdmittedNewEpochSuccessor() async {
        let predecessorGate = EagerDerivedAtomProjectionGate()
        let successorGate = EagerDerivedAtomProjectionGate()
        defer {
            predecessorGate.release()
            successorGate.release()
        }
        let completionRecorder = EagerDerivedAtomCompletionRecorder()
        let projectionCount = EagerDerivedAtomTestCounter()
        let atom = makeEagerDerivedAtomTestNode(completionRecorder: completionRecorder)

        atom.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 1,
                outputContent: 10,
                gate: predecessorGate,
                projectionCount: projectionCount
            ))
        guard
            await requireEagerDerivedAtomTestEvent(
                "pre-invalidation projection start",
                wait: { await predecessorGate.waitUntilStarted() }
            )
        else { return }

        atom.sourceDidInvalidate()
        atom.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 1,
                outputContent: 11,
                gate: successorGate,
                projectionCount: projectionCount
            ))
        #expect(atom.freshness == .running(1))

        predecessorGate.release()
        guard
            await requireEagerDerivedAtomTestEvent(
                "pre-invalidation projection revocation",
                wait: { await completionRecorder.wait(for: .superseded(1)) }
            ),
            await requireEagerDerivedAtomTestEvent(
                "new-epoch successor start",
                wait: { await successorGate.waitUntilStarted() }
            )
        else { return }

        successorGate.release()
        guard
            await requireEagerDerivedAtomTestEvent(
                "new-epoch successor publication",
                wait: { await completionRecorder.wait(for: .published(1)) }
            )
        else { return }

        #expect(atom.value?.content == 11)
        #expect(atom.freshness == .current(1))
        #expect(projectionCount.count == 2)
        #expect(!atom.hasUnsettledProjectionTasks)
    }

    @Test
    func repeatedInvalidationKeepsOnlyTheStillStaleAdmissionInvalidated() async {
        let firstGate = EagerDerivedAtomProjectionGate()
        let successorGate = EagerDerivedAtomProjectionGate()
        defer {
            firstGate.release()
            successorGate.release()
        }
        let projectionCount = EagerDerivedAtomTestCounter()
        let atom = makeEagerDerivedAtomTestNode()

        atom.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 1,
                outputContent: 10,
                gate: firstGate,
                projectionCount: projectionCount
            ))
        guard
            await requireEagerDerivedAtomTestEvent(
                "repeated-invalidation initial projection start",
                wait: { await firstGate.waitUntilStarted() }
            )
        else { return }
        let firstValueChanged = EagerDerivedAtomTestSignal()
        observeEagerDerivedAtomValue(atom) {
            firstValueChanged.signal()
        }
        firstGate.release()
        guard
            await requireEagerDerivedAtomTestEvent(
                "repeated-invalidation initial publication",
                wait: { await firstValueChanged.wait() }
            )
        else { return }

        let invalidated = EagerDerivedAtomTestSignal()
        observeEagerDerivedAtomFreshness(atom) {
            invalidated.signal()
        }
        atom.sourceDidInvalidate()
        atom.sourceDidInvalidate()
        guard
            await requireEagerDerivedAtomTestEvent(
                "repeated invalidation freshness",
                wait: { await invalidated.wait() }
            )
        else { return }
        #expect(atom.freshness == .invalidated(1))

        atom.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 1,
                outputContent: 11,
                gate: successorGate,
                projectionCount: projectionCount
            ))
        guard
            await requireEagerDerivedAtomTestEvent(
                "repeated-invalidation successor start",
                wait: { await successorGate.waitUntilStarted() }
            )
        else { return }
        #expect(atom.freshness == .running(1))

        let successorValueChanged = EagerDerivedAtomTestSignal()
        observeEagerDerivedAtomValue(atom) {
            successorValueChanged.signal()
        }
        successorGate.release()
        guard
            await requireEagerDerivedAtomTestEvent(
                "repeated-invalidation successor publication",
                wait: { await successorValueChanged.wait() }
            )
        else { return }

        #expect(atom.value?.content == 11)
        #expect(atom.freshness == .current(1))
        #expect(atom.revision == 1)
    }

    @Test
    func stopBeforeCompletionPreventsPublication() async {
        let gate = EagerDerivedAtomProjectionGate()
        defer { gate.release() }
        let completionRecorder = EagerDerivedAtomCompletionRecorder()
        let projectionCount = EagerDerivedAtomTestCounter()
        let atom = makeEagerDerivedAtomTestNode(completionRecorder: completionRecorder)

        atom.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 1,
                outputContent: 10,
                gate: gate,
                projectionCount: projectionCount
            ))
        guard
            await requireEagerDerivedAtomTestEvent(
                "stopped projection start",
                wait: { await gate.waitUntilStarted() }
            )
        else { return }

        atom.stop()
        #expect(atom.freshness == .stopped)
        gate.release()
        guard
            await requireEagerDerivedAtomTestEvent(
                "stopped completion admission decision",
                wait: { await completionRecorder.wait(for: .cancelled(1)) }
            )
        else { return }

        #expect(atom.value == nil)
        #expect(atom.freshness == .stopped)
        #expect(atom.revision == 0)
    }

    @Test
    func repeatedStopIsIdempotent() {
        let atom = makeEagerDerivedAtomTestNode()

        atom.stop()
        atom.stop()

        #expect(atom.value == nil)
        #expect(atom.freshness == .stopped)
        #expect(atom.revision == 0)
    }

    @Test
    func admissionAfterStopIsRejected() {
        let projectionCount = EagerDerivedAtomTestCounter()
        let atom = makeEagerDerivedAtomTestNode()
        atom.stop()

        atom.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 1,
                outputContent: 10,
                projectionCount: projectionCount
            ))

        #expect(projectionCount.isEmpty)
        #expect(atom.value == nil)
        #expect(atom.freshness == .stopped)
        #expect(atom.revision == 0)
    }
}
