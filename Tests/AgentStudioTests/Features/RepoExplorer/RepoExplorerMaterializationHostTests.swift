import AppKit
import Testing

@testable import AgentStudioRepoExplorer

enum ControlledRepoExplorerContentResponse {
    case accepted
    case rejected
    case missing
    case duplicate
}

@MainActor
private final class RepoExplorerMaterializationFeedbackRecorder {
    private(set) var feedback: [RepoExplorerMaterializationFeedback] = []
    private(set) var invariantMessages: [String] = []

    func record(_ value: RepoExplorerMaterializationFeedback) {
        feedback.append(value)
    }

    func recordInvariant(_ message: String) {
        invariantMessages.append(message)
    }
}

@MainActor
private final class ControlledRepoExplorerContentChild:
    RepoExplorerMaterializationContentChild
{
    let view = NSView()
    var applyResponse: ControlledRepoExplorerContentResponse = .accepted
    var removalResponse: ControlledRepoExplorerContentResponse = .accepted
    var onApply: (() -> Void)?
    var onSuspendDemand: (() -> Void)?
    var onResumeDemand: ((UInt64) -> Void)?
    private(set) var appliedCandidates: [RepoExplorerMaterializationContentCandidate] = []
    private(set) var removalGenerations: [UInt64] = []
    private(set) var suspendDemandCount = 0
    private(set) var resumedVisibleGenerations: [UInt64] = []
    private(set) var detachCount = 0

    func apply(
        _ candidate: RepoExplorerMaterializationContentCandidate,
        completion: @escaping (RepoExplorerMaterializationChildDisposition) -> Void
    ) {
        appliedCandidates.append(candidate)
        onApply?()
        respond(applyResponse, completion: completion)
    }

    func prepareForRemoval(
        visibleGeneration: UInt64,
        completion: @escaping (RepoExplorerMaterializationChildDisposition) -> Void
    ) {
        removalGenerations.append(visibleGeneration)
        respond(removalResponse, completion: completion)
    }

    func applySelection(rowID: RepoExplorerRowID?, scrollIntoView: Bool) -> Bool {
        _ = rowID
        _ = scrollIntoView
        return true
    }

    func performListKeyboardEffect(_ effect: RepoExplorerListKeyboardEffect) {
        _ = effect
    }

    func suspendDemand() {
        suspendDemandCount += 1
        onSuspendDemand?()
    }

    func resumeDemand(visibleGeneration: UInt64) {
        resumedVisibleGenerations.append(visibleGeneration)
        onResumeDemand?(visibleGeneration)
    }

    func detach() {
        detachCount += 1
    }

    private func respond(
        _ response: ControlledRepoExplorerContentResponse,
        completion: (RepoExplorerMaterializationChildDisposition) -> Void
    ) {
        switch response {
        case .accepted:
            completion(.accepted)
        case .rejected:
            completion(.rejected)
        case .missing:
            break
        case .duplicate:
            completion(.accepted)
            completion(.accepted)
        }
    }
}

@MainActor
private struct MaterializationHostFixture {
    let recorder: RepoExplorerMaterializationFeedbackRecorder
    let child: ControlledRepoExplorerContentChild
    let lifetimeID: RepoExplorerMaterializationHostLifetimeID
    let host: RepoExplorerMaterializationHost

    init(
        lifetimeID: RepoExplorerMaterializationHostLifetimeID = makeMaterializationLifetime(1),
        initialDemandEpoch: UInt64 = 7,
        initialPresentation: RepoExplorerRowlessPresentation = .noRepositories
    ) {
        let recorder = RepoExplorerMaterializationFeedbackRecorder()
        let child = ControlledRepoExplorerContentChild()
        self.recorder = recorder
        self.child = child
        self.lifetimeID = lifetimeID
        host = RepoExplorerMaterializationHost(
            lifetimeID: lifetimeID,
            initialDemandEpoch: initialDemandEpoch,
            initialPresentation: initialPresentation,
            makeContentChild: { child },
            onFeedback: { recorder.record($0) },
            onInvariantViolation: { recorder.recordInvariant($0) }
        )
    }

    func candidate(
        id: UInt64,
        generation: UInt64,
        expectedRevision: UInt64,
        proposedRevision: UInt64,
        demandEpoch: UInt64 = 7,
        presentation: RepoExplorerMaterializationPresentation,
        lifetimeID: RepoExplorerMaterializationHostLifetimeID? = nil
    ) -> RepoExplorerMaterializationCandidate {
        let baseline = host.acceptedBaseline!
        let plan = try! RepoExplorerNativeUpdatePlan.validating(
            baseline: baseline,
            candidate: presentation,
            requestGeneration: generation
        ).get()
        return RepoExplorerMaterializationCandidate(
            id: RepoExplorerMaterializationCandidateID(rawValue: id),
            lifetimeID: lifetimeID ?? self.lifetimeID,
            demandEpoch: demandEpoch,
            requestGeneration: generation,
            visibleGeneration: generation,
            expectedRevision: expectedRevision,
            proposedRevision: proposedRevision,
            presentation: presentation,
            nativeUpdatePlan: plan
        )
    }
}

private func makeMaterializationLifetime(_ value: UInt8)
    -> RepoExplorerMaterializationHostLifetimeID
{
    RepoExplorerMaterializationHostLifetimeID(
        rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
    )
}

private func makeContentPresentation(
    fingerprint: UInt64
) -> RepoExplorerMaterializationPresentation {
    let groupID = "materialization-group-\(fingerprint)"
    let presentation = RepoExplorerMaterializedRowPresentation.groupHeader(
        RepoExplorerMaterializedGroupHeaderPresentation(
            groupID: groupID,
            icon: .repo,
            title: groupID,
            organizationName: nil,
            colorHex: nil,
            isExpanded: true,
            repoIDs: [],
            semanticRepoPath: nil,
            paneDestinations: []
        )
    )
    let row = RepoExplorerMaterializedRow(
        id: .group(groupID: groupID),
        contentRevision: RepoExplorerRowContentRevision(presentation: presentation),
        layout: RepoExplorerRowLayout.make(for: presentation),
        representedRepoID: nil,
        representedWorktreeID: nil
    )
    let snapshot = RepoExplorerMaterializationSnapshot(rows: [row])
    return .content(snapshot: snapshot, fingerprint: .make(snapshot: snapshot))
}

@MainActor
@Suite("Repo Explorer materialization host", .serialized)
struct RepoExplorerMaterializationHostTests {
    @Test(
        "new lifetime synchronously accepts explicit rowless R0",
        arguments: RepoExplorerRowlessPresentation.allCases
    )
    func newLifetimeAcceptsRowlessR0(presentation: RepoExplorerRowlessPresentation) throws {
        let fixture = MaterializationHostFixture(initialPresentation: presentation)
        let baseline = try #require(fixture.host.acceptedBaseline)

        #expect(baseline.lifetimeID == fixture.lifetimeID)
        #expect(baseline.demandEpoch == 7)
        #expect(baseline.revision == 0)
        #expect(baseline.visibleGeneration == 0)
        #expect(baseline.presentation == .rowless(presentation))
        #expect(fixture.host.isPresentationReady)
        #expect(
            fixture.recorder.feedback == [
                .accepted(identity: .initial, baseline: baseline)
            ]
        )
    }

    @Test("equal empty is R to R with no child change or acknowledgment")
    func equalEmptyDoesNotAdvanceRevisionOrAcknowledge() throws {
        let fixture = MaterializationHostFixture(initialPresentation: .noPanes)
        let initialBaseline = try #require(fixture.host.acceptedBaseline)
        let candidate = fixture.candidate(
            id: 1,
            generation: 1,
            expectedRevision: 0,
            proposedRevision: 0,
            presentation: .rowless(.noPanes)
        )

        #expect(fixture.host.apply(candidate) == .equal(initialBaseline))
        #expect(fixture.host.acceptedBaseline == initialBaseline)
        #expect(fixture.recorder.feedback.count == 1)
        #expect(fixture.child.appliedCandidates.isEmpty)
        #expect(fixture.child.removalGenerations.isEmpty)
    }

    @Test("changed empty to empty accepts R plus one")
    func changedEmptyToEmptyAdvancesRevision() throws {
        let fixture = MaterializationHostFixture(initialPresentation: .noRepositories)
        let candidate = fixture.candidate(
            id: 1,
            generation: 4,
            expectedRevision: 0,
            proposedRevision: 1,
            presentation: .rowless(.searchNoResults)
        )

        let disposition = fixture.host.apply(candidate)
        let acceptedBaseline = try #require(fixture.host.acceptedBaseline)

        #expect(disposition == .accepted(acceptedBaseline))
        #expect(acceptedBaseline.revision == 1)
        #expect(acceptedBaseline.visibleGeneration == 4)
        #expect(acceptedBaseline.presentation == .rowless(.searchNoResults))
        #expect(
            fixture.recorder.feedback.last
                == .accepted(
                    identity: .candidate(candidate.id),
                    baseline: acceptedBaseline
                ))
    }

    @Test(
        "content transitions to every typed empty presentation",
        arguments: RepoExplorerRowlessPresentation.allCases
    )
    func contentTransitionsToEveryEmpty(presentation: RepoExplorerRowlessPresentation) throws {
        let fixture = MaterializationHostFixture()
        let contentCandidate = fixture.candidate(
            id: 1,
            generation: 1,
            expectedRevision: 0,
            proposedRevision: 1,
            presentation: makeContentPresentation(fingerprint: 10)
        )
        guard case .accepted = fixture.host.apply(contentCandidate) else {
            Issue.record("Initial content candidate was not accepted")
            return
        }

        let emptyCandidate = fixture.candidate(
            id: 2,
            generation: 2,
            expectedRevision: 1,
            proposedRevision: 2,
            presentation: .rowless(presentation)
        )
        let disposition = fixture.host.apply(emptyCandidate)
        let baseline = try #require(fixture.host.acceptedBaseline)

        #expect(disposition == .accepted(baseline))
        #expect(baseline.presentation == .rowless(presentation))
        #expect(fixture.child.appliedCandidates.count == 1)
        #expect(fixture.child.removalGenerations == [2])
        #expect(fixture.child.detachCount == 1)
    }

    @Test("empty to content and content to content use one controlled child")
    func contentTransitionsUseControlledChild() throws {
        let fixture = MaterializationHostFixture()
        let firstPresentation = makeContentPresentation(fingerprint: 10)
        let firstCandidate = fixture.candidate(
            id: 1,
            generation: 1,
            expectedRevision: 0,
            proposedRevision: 1,
            presentation: firstPresentation
        )
        guard case .accepted = fixture.host.apply(firstCandidate) else {
            Issue.record("Initial content candidate was not accepted")
            return
        }

        let secondPresentation = makeContentPresentation(fingerprint: 11)
        let secondCandidate = fixture.candidate(
            id: 2,
            generation: 2,
            expectedRevision: 1,
            proposedRevision: 2,
            presentation: secondPresentation
        )
        let disposition = fixture.host.apply(secondCandidate)
        let baseline = try #require(fixture.host.acceptedBaseline)

        #expect(disposition == .accepted(baseline))
        #expect(baseline.presentation == secondPresentation)
        #expect(fixture.child.appliedCandidates.count == 2)
        #expect(fixture.child.detachCount == 0)
    }

    @Test("retained content child suspends before readiness clears and resumes after reacknowledgment")
    func retainedContentChildFollowsHostDemandLifecycle() throws {
        let fixture = MaterializationHostFixture()
        let contentCandidate = fixture.candidate(
            id: 1,
            generation: 4,
            expectedRevision: 0,
            proposedRevision: 1,
            presentation: makeContentPresentation(fingerprint: 10)
        )
        guard case .accepted = fixture.host.apply(contentCandidate) else {
            Issue.record("Initial content candidate was not accepted")
            return
        }
        let contentBaseline = try #require(fixture.host.acceptedBaseline)
        var wasReadyDuringSuspend = false
        var resumedDemandEpoch: UInt64?
        fixture.child.onSuspendDemand = {
            wasReadyDuringSuspend = fixture.host.isPresentationReady
        }
        fixture.child.onResumeDemand = { _ in
            resumedDemandEpoch = fixture.host.acceptedBaseline?.demandEpoch
        }

        fixture.host.suspendDemand()

        #expect(wasReadyDuringSuspend)
        #expect(fixture.child.suspendDemandCount == 1)
        #expect(!fixture.host.isPresentationReady)

        let reacknowledged = fixture.host.reacknowledgeRetainedPresentation(demandEpoch: 8)

        #expect(reacknowledged?.revision == contentBaseline.revision)
        #expect(reacknowledged?.demandEpoch == 8)
        #expect(fixture.child.resumedVisibleGenerations == [contentBaseline.visibleGeneration])
        #expect(resumedDemandEpoch == 8)
    }

    @Test(
        "missing duplicate and rejected child dispositions retain the accepted baseline",
        arguments: [
            ControlledRepoExplorerContentResponse.missing,
            .duplicate,
            .rejected,
        ]
    )
    func invalidChildDispositionRetainsBaseline(
        response: ControlledRepoExplorerContentResponse
    ) throws {
        let fixture = MaterializationHostFixture()
        fixture.child.applyResponse = response
        let initialBaseline = try #require(fixture.host.acceptedBaseline)
        let candidate = fixture.candidate(
            id: 1,
            generation: 1,
            expectedRevision: 0,
            proposedRevision: 1,
            presentation: makeContentPresentation(fingerprint: 10)
        )

        guard case .rejected = fixture.host.apply(candidate) else {
            Issue.record("Child disposition was not rejected for response \(response)")
            return
        }

        #expect(fixture.host.acceptedBaseline == initialBaseline)
        #expect(fixture.host.isPresentationReady)
        #expect(fixture.child.detachCount == 1)
        if response == .rejected {
            #expect(fixture.recorder.invariantMessages.isEmpty)
        } else {
            #expect(fixture.recorder.invariantMessages.count == 1)
        }
    }

    @Test(
        "invalid content removal disposition retains the content baseline",
        arguments: [
            ControlledRepoExplorerContentResponse.missing,
            .duplicate,
            .rejected,
        ]
    )
    func invalidRemovalDispositionRetainsContentBaseline(
        response: ControlledRepoExplorerContentResponse
    ) throws {
        let fixture = MaterializationHostFixture()
        let contentCandidate = fixture.candidate(
            id: 1,
            generation: 1,
            expectedRevision: 0,
            proposedRevision: 1,
            presentation: makeContentPresentation(fingerprint: 10)
        )
        guard case .accepted = fixture.host.apply(contentCandidate) else {
            Issue.record("Initial content candidate was not accepted")
            return
        }
        let contentBaseline = try #require(fixture.host.acceptedBaseline)
        fixture.child.removalResponse = response
        let rowlessCandidate = fixture.candidate(
            id: 2,
            generation: 2,
            expectedRevision: 1,
            proposedRevision: 2,
            presentation: .rowless(.noTabs)
        )

        guard case .rejected = fixture.host.apply(rowlessCandidate) else {
            Issue.record("Invalid removal disposition was not rejected for response \(response)")
            return
        }

        #expect(fixture.host.acceptedBaseline == contentBaseline)
        #expect(fixture.host.presentedChildView === fixture.child.view)
        #expect(fixture.child.detachCount == 0)
        if response == .rejected {
            #expect(fixture.recorder.invariantMessages.isEmpty)
        } else {
            #expect(fixture.recorder.invariantMessages.count == 1)
        }
    }

    @Test("wrong late duplicate and detached candidates are rejected without mutation")
    func staleCandidatesAreRejectedWithoutMutation() throws {
        let fixture = MaterializationHostFixture()
        let initialBaseline = try #require(fixture.host.acceptedBaseline)
        let presentation = makeContentPresentation(fingerprint: 10)
        let invalidCandidates = [
            fixture.candidate(
                id: 1,
                generation: 1,
                expectedRevision: 0,
                proposedRevision: 1,
                presentation: presentation,
                lifetimeID: makeMaterializationLifetime(2)
            ),
            fixture.candidate(
                id: 2,
                generation: 1,
                expectedRevision: 0,
                proposedRevision: 1,
                demandEpoch: 8,
                presentation: presentation
            ),
            fixture.candidate(
                id: 3,
                generation: 1,
                expectedRevision: 9,
                proposedRevision: 10,
                presentation: presentation
            ),
        ]

        for candidate in invalidCandidates {
            guard case .rejected = fixture.host.apply(candidate) else {
                Issue.record("Stale candidate \(candidate.id) was not rejected")
                return
            }
        }
        #expect(fixture.host.acceptedBaseline == initialBaseline)

        let acceptedCandidate = fixture.candidate(
            id: 4,
            generation: 1,
            expectedRevision: 0,
            proposedRevision: 1,
            presentation: presentation
        )
        guard case .accepted = fixture.host.apply(acceptedCandidate) else {
            Issue.record("Valid candidate was not accepted")
            return
        }
        let acceptedBaseline = try #require(fixture.host.acceptedBaseline)
        guard case .rejected = fixture.host.apply(acceptedCandidate) else {
            Issue.record("Duplicate candidate was not rejected")
            return
        }
        #expect(fixture.host.acceptedBaseline == acceptedBaseline)

        let afterDetach = fixture.candidate(
            id: 5,
            generation: 2,
            expectedRevision: 1,
            proposedRevision: 2,
            presentation: .rowless(.noTabs)
        )
        fixture.host.detach()
        guard case .rejected(.hostDetached) = fixture.host.apply(afterDetach) else {
            Issue.record("Detached host accepted a candidate")
            return
        }
        #expect(fixture.host.acceptedBaseline == nil)
        #expect(!fixture.host.isPresentationReady)
    }

    @Test("same host reacknowledges retained R under a new demand epoch")
    func sameHostReacknowledgesRetainedBaseline() throws {
        let fixture = MaterializationHostFixture(initialDemandEpoch: 7)
        let initialBaseline = try #require(fixture.host.acceptedBaseline)

        fixture.host.suspendDemand()
        #expect(!fixture.host.isPresentationReady)
        let suspendedCandidate = fixture.candidate(
            id: 1,
            generation: 1,
            expectedRevision: 0,
            proposedRevision: 1,
            presentation: makeContentPresentation(fingerprint: 10)
        )
        #expect(fixture.host.apply(suspendedCandidate) == .rejected(.demandSuspended))
        let reacknowledged = try #require(
            fixture.host.reacknowledgeRetainedPresentation(demandEpoch: 8)
        )

        #expect(reacknowledged.lifetimeID == initialBaseline.lifetimeID)
        #expect(reacknowledged.demandEpoch == 8)
        #expect(reacknowledged.revision == initialBaseline.revision)
        #expect(reacknowledged.visibleGeneration == initialBaseline.visibleGeneration)
        #expect(reacknowledged.presentation == initialBaseline.presentation)
        #expect(fixture.host.isPresentationReady)
        #expect(
            fixture.recorder.feedback.last
                == .accepted(
                    identity: .reentry,
                    baseline: reacknowledged
                ))
    }

    @Test("child callback reentry cannot install a second candidate")
    func childCallbackReentryIsRejected() throws {
        let fixture = MaterializationHostFixture()
        let firstCandidate = fixture.candidate(
            id: 1,
            generation: 1,
            expectedRevision: 0,
            proposedRevision: 1,
            presentation: makeContentPresentation(fingerprint: 10)
        )
        let reentrantCandidate = fixture.candidate(
            id: 2,
            generation: 2,
            expectedRevision: 0,
            proposedRevision: 1,
            presentation: makeContentPresentation(fingerprint: 11)
        )
        var reentrantDisposition: RepoExplorerMaterializationApplyDisposition?
        fixture.child.onApply = {
            reentrantDisposition = fixture.host.apply(reentrantCandidate)
        }

        guard case .accepted = fixture.host.apply(firstCandidate) else {
            Issue.record("Initial content candidate was not accepted")
            return
        }
        let baseline = try #require(fixture.host.acceptedBaseline)

        #expect(reentrantDisposition == .rejected(.candidateInProgress))
        #expect(baseline.revision == 1)
        #expect(baseline.presentation == firstCandidate.presentation)
        #expect(fixture.child.appliedCandidates.count == 1)
    }

    @Test("replacement lifetime starts from independent numeric R0")
    func replacementLifetimeStartsFromIndependentR0() throws {
        let first = MaterializationHostFixture(lifetimeID: makeMaterializationLifetime(1))
        let staleCandidate = first.candidate(
            id: 1,
            generation: 1,
            expectedRevision: 0,
            proposedRevision: 1,
            presentation: makeContentPresentation(fingerprint: 10)
        )
        first.host.detach()

        let replacement = MaterializationHostFixture(
            lifetimeID: makeMaterializationLifetime(2),
            initialDemandEpoch: 7
        )
        let baseline = try #require(replacement.host.acceptedBaseline)

        #expect(baseline.revision == 0)
        #expect(baseline.visibleGeneration == 0)
        guard case .rejected(.lifetimeMismatch) = replacement.host.apply(staleCandidate) else {
            return
        }
        #expect(replacement.host.acceptedBaseline == baseline)
    }
}
