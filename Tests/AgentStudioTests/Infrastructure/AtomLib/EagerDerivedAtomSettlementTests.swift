import Synchronization
import Testing

@testable import AgentStudioInfrastructure

private struct SettlementTestIntent: Sendable {
    let identity: Int
    let accumulatedValue: Int
    let projectionGate: EagerDerivedAtomProjectionGate?
}

private struct SettlementTestWork: Sendable {
    let identity: Int
    let preparedValue: Int
    let projectionGate: EagerDerivedAtomProjectionGate?
}

private struct SettlementTestCandidate: Sendable {
    let identity: Int
    let proposedValue: Int
}

private typealias SettlementTestAtom = EagerDerivedAtom<
    SettlementTestIntent,
    Int,
    SettlementTestWork,
    SettlementTestCandidate,
    Int
>

private typealias SettlementTestClassifier =
    @MainActor @Sendable (
        SettlementTestCandidate,
        Int?
    ) -> SettlementTestAtom.CandidateDisposition

private typealias SettlementTestPreparer =
    @MainActor @Sendable (
        SettlementTestIntent,
        UInt64
    ) -> SettlementTestAtom.PreparationDisposition

private typealias SettlementTestFamily = EagerDerivedAtomFamily<
    Int,
    SettlementTestIntent,
    Int,
    SettlementTestWork,
    SettlementTestCandidate,
    Int
>

@MainActor
private final class SettlementTestOwner {
    struct PreparedIntent: Equatable {
        let identity: Int
        let accumulatedValue: Int
    }

    struct AwaitingCandidate {
        let token: SettlementTestAtom.CandidateToken
        let candidate: SettlementTestCandidate
        let proposedValue: Int
    }

    private(set) var preparedIntents: [PreparedIntent] = []
    private(set) var awaitingCandidates: [AwaitingCandidate] = []
    private(set) var completions: [SettlementTestAtom.ProjectionCompletion] = []
    private var awaitingWaiters: [(count: Int, signal: EagerDerivedAtomTestSignal)] = []
    private var completionWaiters:
        [(
            completion: SettlementTestAtom.ProjectionCompletion,
            signal: EagerDerivedAtomTestSignal
        )] = []

    func prepare(_ intent: SettlementTestIntent) -> SettlementTestWork {
        preparedIntents.append(
            PreparedIntent(
                identity: intent.identity,
                accumulatedValue: intent.accumulatedValue
            )
        )
        return SettlementTestWork(
            identity: intent.identity,
            preparedValue: intent.accumulatedValue,
            projectionGate: intent.projectionGate
        )
    }

    func recordAwaiting(
        token: SettlementTestAtom.CandidateToken,
        candidate: SettlementTestCandidate,
        proposedValue: Int
    ) {
        awaitingCandidates.append(
            AwaitingCandidate(
                token: token,
                candidate: candidate,
                proposedValue: proposedValue
            )
        )
        let readySignals = awaitingWaiters.compactMap { waiter in
            awaitingCandidates.count >= waiter.count ? waiter.signal : nil
        }
        awaitingWaiters.removeAll { awaitingCandidates.count >= $0.count }
        for signal in readySignals {
            signal.signal()
        }
    }

    func recordCompletion(_ completion: SettlementTestAtom.ProjectionCompletion) {
        completions.append(completion)
        let readySignals = completionWaiters.compactMap { waiter in
            waiter.completion == completion ? waiter.signal : nil
        }
        completionWaiters.removeAll { $0.completion == completion }
        for signal in readySignals {
            signal.signal()
        }
    }

    func waitForAwaitingCount(_ count: Int) async -> Bool {
        guard awaitingCandidates.count < count else { return true }
        let signal = EagerDerivedAtomTestSignal()
        awaitingWaiters.append((count, signal))
        return await signal.wait()
    }

    func waitForCompletion(_ completion: SettlementTestAtom.ProjectionCompletion) async -> Bool {
        guard !completions.contains(completion) else { return true }
        let signal = EagerDerivedAtomTestSignal()
        completionWaiters.append((completion, signal))
        return await signal.wait()
    }
}

private func projectSettlementTestWork(
    _ work: SettlementTestWork
) throws(CancellationError) -> SettlementTestCandidate {
    try work.projectionGate?.holdProjection()
    if Task.isCancelled {
        throw CancellationError()
    }
    return SettlementTestCandidate(
        identity: work.identity,
        proposedValue: work.preparedValue
    )
}

@MainActor
private func makeSettlementTestAtom(
    owner: SettlementTestOwner,
    prepare: SettlementTestPreparer? = nil,
    classify: @escaping SettlementTestClassifier = { candidate, currentValue in
        if currentValue == candidate.proposedValue {
            return .equalCurrent(candidate.proposedValue)
        }
        return .changedAwaitingOwner(candidate.proposedValue)
    }
) -> SettlementTestAtom {
    SettlementTestAtom(
        intentIdentity: \.identity,
        combinePendingIntents: { accumulatedIntent, latestIntent in
            SettlementTestIntent(
                identity: latestIntent.identity,
                accumulatedValue: accumulatedIntent.accumulatedValue + latestIntent.accumulatedValue,
                projectionGate: latestIntent.projectionGate
            )
        },
        prepare: prepare ?? { intent, _ in .prepared(owner.prepare(intent)) },
        project: projectSettlementTestWork,
        classify: classify,
        onAwaitingOwner: { token, candidate, proposedValue in
            owner.recordAwaiting(
                token: token,
                candidate: candidate,
                proposedValue: proposedValue
            )
        },
        onProjectionCompletion: { completion in
            owner.recordCompletion(completion)
        }
    )
}

@Suite(.serialized)
@MainActor
struct EagerDerivedAtomSettlementTests {
    @Test("pending intents remain pure and prepare from latest state only when execution starts")
    func pendingIntentIsPreparedAtExecutionStart() async {
        let firstGate = EagerDerivedAtomProjectionGate()
        let latestGate = EagerDerivedAtomProjectionGate()
        defer {
            firstGate.release()
            latestGate.release()
        }
        let owner = SettlementTestOwner()
        let atom = makeSettlementTestAtom(
            owner: owner,
            classify: { candidate, _ in .immediateAccepted(candidate.proposedValue) }
        )

        atom.admit(SettlementTestIntent(identity: 1, accumulatedValue: 1, projectionGate: firstGate))
        guard await firstGate.waitUntilStarted() else {
            Issue.record("Initial projection did not start")
            return
        }

        atom.admit(SettlementTestIntent(identity: 2, accumulatedValue: 10, projectionGate: latestGate))
        atom.admit(SettlementTestIntent(identity: 3, accumulatedValue: 100, projectionGate: latestGate))

        #expect(
            owner.preparedIntents == [
                SettlementTestOwner.PreparedIntent(identity: 1, accumulatedValue: 1)
            ]
        )
        firstGate.release()
        guard await owner.waitForCompletion(.superseded(1)) else {
            Issue.record("Initial projection did not settle as superseded")
            return
        }
        guard await latestGate.waitUntilStarted() else {
            Issue.record("Latest projection did not start")
            return
        }

        #expect(
            owner.preparedIntents == [
                SettlementTestOwner.PreparedIntent(identity: 1, accumulatedValue: 1),
                SettlementTestOwner.PreparedIntent(identity: 3, accumulatedValue: 111),
            ]
        )
        latestGate.release()
        guard await owner.waitForCompletion(.published(3)) else {
            Issue.record("Latest projection did not publish")
            return
        }
        #expect(atom.value == 111)
    }

    @Test("awaiting owner acceptance does not publish value readiness or revision")
    func awaitingOwnerDoesNotCommitBeforeAcceptance() async {
        let owner = SettlementTestOwner()
        let atom = makeSettlementTestAtom(owner: owner)

        atom.admit(SettlementTestIntent(identity: 1, accumulatedValue: 10, projectionGate: nil))
        guard await owner.waitForAwaitingCount(1) else {
            Issue.record("First awaiting-owner candidate did not arrive")
            return
        }

        let awaiting = owner.awaitingCandidates[0]
        #expect(atom.value == nil)
        #expect(atom.latestAcceptedValue == nil)
        #expect(atom.freshness == .running(1))
        #expect(atom.revision == 0)

        #expect(atom.settle(awaiting.token, .accepted(awaiting.proposedValue)))
        #expect(atom.value == 10)
        #expect(atom.latestAcceptedValue == 10)
        #expect(atom.freshness == .current(1))
        #expect(atom.revision == 0)
    }

    @Test("late duplicate token is ignored while the current token retains authority")
    func lateDuplicateTokenCannotSettleSuccessor() async {
        let owner = SettlementTestOwner()
        let atom = makeSettlementTestAtom(owner: owner)

        atom.admit(SettlementTestIntent(identity: 1, accumulatedValue: 10, projectionGate: nil))
        guard await owner.waitForAwaitingCount(1) else {
            Issue.record("First awaiting-owner candidate did not arrive")
            return
        }
        let first = owner.awaitingCandidates[0]
        #expect(atom.settle(first.token, .accepted(first.proposedValue)))

        atom.admit(SettlementTestIntent(identity: 2, accumulatedValue: 20, projectionGate: nil))
        guard await owner.waitForAwaitingCount(2) else {
            Issue.record("Successor awaiting-owner candidate did not arrive")
            return
        }
        let second = owner.awaitingCandidates[1]

        #expect(!atom.settle(first.token, .accepted(999)))
        #expect(atom.value == 10)
        #expect(atom.freshness == .running(2))
        #expect(atom.settle(second.token, .accepted(second.proposedValue)))
        #expect(!atom.settle(second.token, .accepted(999)))
        #expect(atom.value == 20)
        #expect(atom.freshness == .current(2))
        #expect(atom.revision == 1)
    }

    @Test("owner rejection preserves committed value and leaves latest identity unready")
    func ownerRejectionPreservesCommittedValue() async {
        let owner = SettlementTestOwner()
        let atom = makeSettlementTestAtom(owner: owner)

        atom.admit(SettlementTestIntent(identity: 1, accumulatedValue: 10, projectionGate: nil))
        guard await owner.waitForAwaitingCount(1) else {
            Issue.record("First awaiting-owner candidate did not arrive")
            return
        }
        let first = owner.awaitingCandidates[0]
        #expect(atom.settle(first.token, .accepted(first.proposedValue)))

        atom.admit(SettlementTestIntent(identity: 2, accumulatedValue: 20, projectionGate: nil))
        guard await owner.waitForAwaitingCount(2) else {
            Issue.record("Successor awaiting-owner candidate did not arrive")
            return
        }
        let second = owner.awaitingCandidates[1]
        #expect(atom.settle(second.token, .rejected))

        #expect(atom.value == 10)
        #expect(atom.latestAcceptedValue == 10)
        #expect(atom.freshness == .invalidated(2))
        #expect(atom.revision == 0)
    }

    @Test("preparation and candidate rejection never start or commit work")
    func rejectedPreparationAndCandidateRemainUnready() async {
        let preparationOwner = SettlementTestOwner()
        let preparationRejectedAtom = makeSettlementTestAtom(
            owner: preparationOwner,
            prepare: { _, _ in .rejected }
        )
        preparationRejectedAtom.admit(
            SettlementTestIntent(identity: 1, accumulatedValue: 10, projectionGate: nil)
        )
        #expect(await preparationOwner.waitForCompletion(.rejected(1)))
        #expect(preparationRejectedAtom.value == nil)
        #expect(preparationRejectedAtom.freshness == .invalidated(1))
        #expect(!preparationRejectedAtom.hasUnsettledProjectionTasks)

        let candidateOwner = SettlementTestOwner()
        let candidateRejectedAtom = makeSettlementTestAtom(
            owner: candidateOwner,
            classify: { _, _ in .rejected }
        )
        candidateRejectedAtom.admit(
            SettlementTestIntent(identity: 2, accumulatedValue: 20, projectionGate: nil)
        )
        #expect(await candidateOwner.waitForCompletion(.rejected(2)))
        #expect(candidateRejectedAtom.value == nil)
        #expect(candidateRejectedAtom.freshness == .invalidated(2))
        #expect(!candidateRejectedAtom.hasUnsettledProjectionTasks)
    }

    @Test("source invalidation revokes an awaiting owner token")
    func sourceInvalidationRevokesAwaitingOwner() async {
        let owner = SettlementTestOwner()
        let atom = makeSettlementTestAtom(owner: owner)

        atom.admit(SettlementTestIntent(identity: 1, accumulatedValue: 10, projectionGate: nil))
        guard await owner.waitForAwaitingCount(1) else {
            Issue.record("Awaiting-owner candidate did not arrive")
            return
        }
        let awaiting = owner.awaitingCandidates[0]

        atom.sourceDidInvalidate()
        #expect(!atom.settle(awaiting.token, .accepted(awaiting.proposedValue)))
        guard await owner.waitForCompletion(.superseded(1)) else {
            Issue.record("Invalidated candidate did not settle as superseded")
            return
        }

        #expect(atom.freshness == .invalidated(1))
        #expect(atom.value == nil)
        #expect(!atom.hasUnsettledProjectionTasks)
    }

    @Test(
        "family removal and stop revoke awaiting owner authority",
        arguments: [false, true]
    )
    func familyTerminationRevokesAwaitingOwner(shouldStopFamily: Bool) async {
        let owner = SettlementTestOwner()
        let family = SettlementTestFamily(
            intentIdentity: \.identity,
            combinePendingIntents: { _, latestIntent in latestIntent },
            prepare: { intent, _ in .prepared(owner.prepare(intent)) },
            project: projectSettlementTestWork,
            classify: { candidate, _ in .changedAwaitingOwner(candidate.proposedValue) },
            onAwaitingOwner: { _, token, candidate, proposedValue in
                owner.recordAwaiting(
                    token: token,
                    candidate: candidate,
                    proposedValue: proposedValue
                )
            },
            onProjectionCompletion: { _, completion in
                owner.recordCompletion(completion)
            }
        )
        let atom = family.materialize(for: 41)
        family.admit(
            SettlementTestIntent(identity: 1, accumulatedValue: 10, projectionGate: nil),
            for: 41
        )
        guard await owner.waitForAwaitingCount(1) else {
            Issue.record("Awaiting-owner candidate did not arrive")
            return
        }
        let awaiting = owner.awaitingCandidates[0]

        if shouldStopFamily {
            family.stop()
        } else {
            family.remove(for: 41)
        }
        guard await owner.waitForCompletion(.cancelled(1)) else {
            Issue.record("Terminated family candidate did not settle as cancelled")
            return
        }

        #expect(atom?.freshness == .stopped)
        #expect(family.currentValue(for: 41) == nil)
        #expect(atom?.settle(awaiting.token, .accepted(awaiting.proposedValue)) == false)
    }
}
