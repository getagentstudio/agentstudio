import Testing

@testable import AgentStudioInfrastructure

@MainActor
@Suite("Eager derived atom family drain", .serialized)
struct EagerDerivedAtomFamilyDrainTests {
    private func makeFamily() -> EagerDerivedAtomTestFamily {
        EagerDerivedAtomTestFamily(
            intentIdentity: \EagerDerivedAtomTestRequest.identity,
            combinePendingIntents: { _, latestRequest in latestRequest },
            prepare: { request, _ in .prepared(request) },
            project: projectEagerDerivedAtomTestRequest,
            classify: { candidate, currentValue in
                currentValue?.content == candidate.content
                    ? .equalCurrent(candidate)
                    : .immediateAccepted(candidate)
            }
        )
    }

    @Test("remove and drain revokes readiness before awaiting termination")
    func removeAndDrainRevokesReadinessBeforeAwaitingTermination() async throws {
        let projectionCount = EagerDerivedAtomTestCounter()
        let family = makeFamily()
        family.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 1, outputContent: 1, projectionCount: projectionCount
            ),
            for: 1
        )
        let removedAtom = try #require(family.atom(for: 1))
        family.remove(for: 1)
        #expect(family.atom(for: 1) == nil)
        #expect(family.currentValue(for: 1) == nil)

        // No suspension since admit: projection's required MainActor completion
        // cannot have run yet. The drain must let it finish before replying.
        #expect(removedAtom.hasUnsettledProjectionTasks)
        await family.removeAndDrain(for: 1)
        #expect(!removedAtom.hasUnsettledProjectionTasks)
        #expect(projectionCount.count == 1)
        // Retain and join the node itself even when a broken family omits its join.
        await removedAtom.stopAndDrain()

        await family.removeAndDrain(for: 1)
        #expect(family.atom(for: 1) == nil)
    }

    @Test("family stop and drain awaits every removed and active slot")
    func stopAndDrainAwaitsRemovedAndActiveSlots() async throws {
        let firstProjectionCount = EagerDerivedAtomTestCounter()
        let secondProjectionCount = EagerDerivedAtomTestCounter()
        let family = makeFamily()
        family.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 1, outputContent: 1, projectionCount: firstProjectionCount
            ),
            for: 1
        )
        family.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 2, outputContent: 2, projectionCount: secondProjectionCount
            ),
            for: 2
        )
        let removedAtom = try #require(family.atom(for: 1))
        let activeAtom = try #require(family.atom(for: 2))
        family.remove(for: 1)
        family.stop()
        #expect(family.atoms.isEmpty)
        #expect(removedAtom.hasUnsettledProjectionTasks)
        #expect(activeAtom.hasUnsettledProjectionTasks)

        // Same actor segment as admission/revocation. Only a real drain can
        // suspend it long enough for both owned completions to run.
        await family.stopAndDrain()
        #expect(!removedAtom.hasUnsettledProjectionTasks)
        #expect(!activeAtom.hasUnsettledProjectionTasks)
        #expect(firstProjectionCount.count == 1)
        #expect(secondProjectionCount.count == 1)
        await removedAtom.stopAndDrain()
        await activeAtom.stopAndDrain()

        async let firstDrain: Void = family.stopAndDrain()
        async let secondDrain: Void = family.stopAndDrain()
        _ = await (firstDrain, secondDrain)
        #expect(family.atoms.isEmpty)
        await family.stopAndDrain()
        #expect(family.atoms.isEmpty)
    }

    @Test("remove and drain retains an awaiting-owner slot through synchronous revocation")
    func removeAndDrainRetainsAwaitingOwnerSlotThroughSynchronousRevocation() async {
        let awaitingOwner = EagerDerivedAtomTestSignal()
        var retainedToken: EagerDerivedAtomTestNode.CandidateToken?
        let family = EagerDerivedAtomTestFamily(
            intentIdentity: \EagerDerivedAtomTestRequest.identity,
            combinePendingIntents: { _, latestRequest in latestRequest },
            prepare: { request, _ in .prepared(request) },
            project: projectEagerDerivedAtomTestRequest,
            classify: { candidate, _ in .changedAwaitingOwner(candidate) },
            onAwaitingOwner: { _, token, _, _ in
                retainedToken = token
                awaitingOwner.signal()
            }
        )
        family.admit(
            makeEagerDerivedAtomTestRequest(
                identity: 1,
                outputContent: 1,
                projectionCount: EagerDerivedAtomTestCounter()
            ),
            for: 1
        )
        _ = await requireEagerDerivedAtomTestEvent("awaiting-owner candidate") {
            await awaitingOwner.wait()
        }
        let retainedAtom = family.atom(for: 1)

        await family.removeAndDrain(for: 1)

        #expect(family.atom(for: 1) == nil)
        #expect(retainedAtom?.hasUnsettledProjectionTasks == false)
        guard let retainedAtom, let retainedToken else {
            Issue.record("Expected the awaiting-owner atom and candidate token")
            return
        }
        #expect(
            !retainedAtom.settle(
                retainedToken,
                .accepted(EagerDerivedAtomTestValue(content: 1))
            ))
    }
}
