import AgentStudioInfrastructure
import AppKit
import Synchronization
import Testing

@testable import AgentStudioRepoExplorer

@MainActor
private final class BrokerContentChild: RepoExplorerMaterializationContentChild {
    let view = NSView()
    private(set) var appliedGenerations: [UInt64] = []
    var responses: [RepoExplorerMaterializationChildDisposition] = [.accepted]
    private var responseIndex = 0

    func apply(
        _ candidate: RepoExplorerMaterializationContentCandidate,
        completion: @escaping (RepoExplorerMaterializationChildDisposition) -> Void
    ) {
        appliedGenerations.append(candidate.visibleGeneration)
        let response = responses[min(responseIndex, responses.count - 1)]
        responseIndex += 1
        completion(response)
    }

    func prepareForRemoval(
        visibleGeneration: UInt64,
        completion: @escaping (RepoExplorerMaterializationChildDisposition) -> Void
    ) {
        completion(.accepted)
    }

    func applySelection(rowID: RepoExplorerRowID?, scrollIntoView: Bool) -> Bool {
        _ = rowID
        _ = scrollIntoView
        return true
    }

    func performListKeyboardEffect(_ effect: RepoExplorerListKeyboardEffect) {
        _ = effect
    }

    func suspendDemand() {}

    func resumeDemand(visibleGeneration: UInt64) {
        _ = visibleGeneration
    }

    func detach() {}
}

private final class RepoExplorerProjectionWorkRecorder: Sendable {
    private let storage = Mutex<[RepoExplorerProjectionWork]>([])

    func record(_ work: RepoExplorerProjectionWork) {
        storage.withLock { $0.append(work) }
    }

    var values: [RepoExplorerProjectionWork] {
        storage.withLock { $0 }
    }
}

private final class RepoExplorerProjectionExecutionGate: Sendable {
    private let hasStarted = Mutex(false)
    private let releaseSemaphore = DispatchSemaphore(value: 0)

    func hold() throws(CancellationError) {
        hasStarted.withLock { $0 = true }
        releaseSemaphore.wait()
        if Task.isCancelled { throw CancellationError() }
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<10_000 {
            if hasStarted.withLock({ $0 }) { return true }
            await Task.yield()
        }
        return false
    }

    func release() {
        releaseSemaphore.signal()
    }
}

@MainActor
@Suite("Repo Explorer acknowledged-baseline broker", .serialized)
struct RepoExplorerProjectionBrokerTests {
    @Test("execution-time preparation captures semantic and host baselines separately")
    func preparationUsesLatestSemanticAndAcknowledgedHostBaselines() async throws {
        let recorder = RepoExplorerProjectionWorkRecorder()
        let adapter = RepoExplorerProjectionAdapter(
            project: { work throws(CancellationError) in
                recorder.record(work)
                return try projectBrokerWork(work)
            }
        )
        let host = makeBrokerHost(adapter: adapter, lifetimeByte: 1)
        #expect(adapter.registerMaterializationHost(host))
        defer {
            adapter.stop()
            host.detach()
        }
        let initialRequest = makeProjectionIntentRequest(generation: 1)

        adapter.admit(initialRequest)
        _ = try await waitForBrokerPublishedResult(generation: 1, adapter: adapter)
        let firstWork = try #require(recorder.values.first)

        #expect(firstWork.context.requestGeneration == 1)
        #expect(firstWork.context.semanticBaselineSequence == 0)
        #expect(firstWork.context.semanticBaselineResult == nil)
        #expect(firstWork.context.acknowledgedBaseline?.revision == 0)
        #expect(firstWork.context.acknowledgedBaseline?.lifetimeID == host.lifetimeID)

        let equalRequest = initialRequest.generated(generation: 2, trigger: .dataRefresh)
        adapter.admit(equalRequest)
        #expect(await waitForBrokerSemanticSequence(2, adapter: adapter))
        let secondWork = try #require(recorder.values.last)

        #expect(secondWork.context.requestGeneration == 2)
        #expect(secondWork.context.semanticBaselineSequence == 1)
        #expect(secondWork.context.semanticBaselineResult?.generation == 1)
        #expect(secondWork.context.acknowledgedBaseline?.revision == 1)
        #expect(adapter.semanticBaselineSequence == 2)
        #expect(adapter.acknowledgedMaterializationBaseline?.revision == 1)
    }

    @Test("A superseded by B and C prepares latest C after predecessor settlement")
    func pendingIntentPreparesAfterPredecessorSettlement() async throws {
        let gate = RepoExplorerProjectionExecutionGate()
        let recorder = RepoExplorerProjectionWorkRecorder()
        let adapter = RepoExplorerProjectionAdapter(
            project: { work throws(CancellationError) in
                recorder.record(work)
                if work.targetRequest.generation == 1 {
                    try gate.hold()
                }
                return try projectBrokerWork(work)
            }
        )
        let host = makeBrokerHost(adapter: adapter, lifetimeByte: 1)
        #expect(adapter.registerMaterializationHost(host))
        defer {
            gate.release()
            adapter.stop()
            host.detach()
        }
        let repositoryID = UUIDv7.generate()
        let worktreeID = UUIDv7.generate()
        let requestA = makeProjectionIntentRequest(
            generation: 1,
            repositoryID: repositoryID,
            worktreeID: worktreeID
        )
        let requestB = makeProjectionIntentRequest(
            generation: 2,
            repositoryID: repositoryID,
            worktreeID: worktreeID,
            isPinned: true
        )
        let requestC = makeProjectionIntentRequest(
            generation: 3,
            repositoryID: repositoryID,
            worktreeID: worktreeID
        )

        adapter.admit(requestA)
        guard await gate.waitUntilStarted() else {
            Issue.record("Initial projection did not start")
            return
        }
        adapter.admitDelta([.repo(repositoryID)], request: requestB)
        adapter.admitDelta([.worktreeFact(worktreeID)], request: requestC)

        #expect(recorder.values.count == 1)
        gate.release()
        _ = try await waitForBrokerPublishedResult(generation: 3, adapter: adapter)
        let works = recorder.values

        #expect(works.count == 2)
        #expect(works.map(\.targetRequest.generation) == [1, 3])
        #expect(works[1].context.semanticBaselineResult == nil)
        #expect(works[1].context.acknowledgedBaseline?.revision == 0)
        guard case .full = works[1] else {
            Issue.record("Delta without a semantic baseline must promote to full Work")
            return
        }
    }

    @Test("demand suspension revokes work and same host reacknowledges retained R")
    func demandSuspendAndReentryReacknowledgeHost() {
        let adapter = RepoExplorerProjectionAdapter()
        let host = makeBrokerHost(adapter: adapter, lifetimeByte: 1)
        #expect(adapter.registerMaterializationHost(host))
        let initialBaseline = adapter.acknowledgedMaterializationBaseline
        defer {
            adapter.stop()
            host.detach()
        }

        adapter.updateDemand(isVisible: false, query: "")
        #expect(!host.isPresentationReady)
        #expect(adapter.acknowledgedMaterializationBaseline == nil)
        let suspendedEpoch = adapter.materializationDemandEpoch
        adapter.updateDemand(isVisible: false, query: "")
        #expect(adapter.materializationDemandEpoch == suspendedEpoch)

        adapter.updateDemand(isVisible: true, query: "")

        #expect(adapter.materializationDemandEpoch == suspendedEpoch)
        #expect(host.isPresentationReady)
        #expect(adapter.acknowledgedMaterializationBaseline?.demandEpoch == suspendedEpoch)
        #expect(adapter.acknowledgedMaterializationBaseline?.revision == initialBaseline?.revision)
        #expect(adapter.acknowledgedMaterializationBaseline?.lifetimeID == initialBaseline?.lifetimeID)
    }

    @Test("replacement host registers independent R0 and stale feedback is ignored")
    func replacementHostOwnsIndependentR0() {
        let adapter = RepoExplorerProjectionAdapter()
        let firstHost = makeBrokerHost(adapter: adapter, lifetimeByte: 1)
        #expect(adapter.registerMaterializationHost(firstHost))
        let firstBaseline = adapter.acknowledgedMaterializationBaseline
        adapter.unregisterMaterializationHost(lifetimeID: firstHost.lifetimeID)
        firstHost.detach()

        let replacementHost = makeBrokerHost(adapter: adapter, lifetimeByte: 2)
        #expect(adapter.registerMaterializationHost(replacementHost))
        let replacementBaseline = adapter.acknowledgedMaterializationBaseline
        defer {
            adapter.stop()
            replacementHost.detach()
        }

        #expect(replacementBaseline?.revision == 0)
        #expect(replacementBaseline?.visibleGeneration == 0)
        #expect(replacementBaseline?.lifetimeID != firstBaseline?.lifetimeID)
        if let firstBaseline {
            adapter.receiveMaterializationFeedback(
                .accepted(identity: .reentry, baseline: firstBaseline)
            )
        }
        #expect(adapter.acknowledgedMaterializationBaseline == replacementBaseline)
    }

    @Test("host rejection rearms once and late feedback cannot roll back R")
    func rejectionRearmsOnceAndLateFeedbackIsIgnored() async throws {
        let adapter = RepoExplorerProjectionAdapter()
        let child = BrokerContentChild()
        child.responses = [.rejected, .accepted]
        let host = makeBrokerHost(adapter: adapter, lifetimeByte: 1, child: child)
        #expect(adapter.registerMaterializationHost(host))
        let rowlessR0 = try #require(adapter.acknowledgedMaterializationBaseline)
        defer {
            adapter.stop()
            host.detach()
        }

        adapter.admit(makeProjectionIntentRequest(generation: 1))
        let accepted = try await waitForAnyBrokerPublishedResult(adapter: adapter)

        #expect(accepted.generation == 2)
        #expect(adapter.semanticBaselineSequence == 1)
        #expect(adapter.acknowledgedMaterializationBaseline?.revision == 1)
        #expect(child.appliedGenerations == [1, 2])

        adapter.receiveMaterializationFeedback(.accepted(identity: .reentry, baseline: rowlessR0))
        adapter.receiveMaterializationFeedback(
            .rejected(
                candidateID: RepoExplorerMaterializationCandidateID(rawValue: 1),
                reason: .childRejected
            )
        )

        #expect(adapter.acknowledgedMaterializationBaseline?.revision == 1)
        #expect(adapter.semanticBaselineSequence == 1)
        #expect(adapter.publishedResult?.generation == 2)
    }
}

@MainActor
private func makeBrokerHost(
    adapter: RepoExplorerProjectionAdapter,
    lifetimeByte: UInt8,
    child: BrokerContentChild = BrokerContentChild()
) -> RepoExplorerMaterializationHost {
    RepoExplorerMaterializationHost(
        lifetimeID: RepoExplorerMaterializationHostLifetimeID(
            rawValue: UUID(
                uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, lifetimeByte)
            )
        ),
        initialDemandEpoch: adapter.materializationDemandEpoch,
        initialPresentation: .noRepositories,
        makeContentChild: { child },
        onFeedback: { [weak adapter] feedback in
            adapter?.receiveMaterializationFeedback(feedback)
        }
    )
}

@MainActor
private func waitForBrokerPublishedResult(
    generation: Int,
    adapter: RepoExplorerProjectionAdapter
) async throws -> RepoExplorerProjectionResult {
    for _ in 0..<10_000 where adapter.publishedResult?.generation != generation {
        await Task.yield()
    }
    return try #require(adapter.publishedResult)
}

@MainActor
private func waitForBrokerSemanticSequence(
    _ sequence: UInt64,
    adapter: RepoExplorerProjectionAdapter
) async -> Bool {
    for _ in 0..<10_000 {
        if adapter.semanticBaselineSequence == sequence { return true }
        await Task.yield()
    }
    return false
}

@MainActor
private func waitForAnyBrokerPublishedResult(
    adapter: RepoExplorerProjectionAdapter
) async throws -> RepoExplorerProjectionResult {
    for _ in 0..<10_000 where adapter.publishedResult == nil {
        await Task.yield()
    }
    return try #require(adapter.publishedResult)
}

private func projectBrokerWork(
    _ work: RepoExplorerProjectionWork
) throws(CancellationError) -> RepoExplorerProjectionResult {
    do {
        return try RepoExplorerProjectionWorker.project(work)
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        preconditionFailure("Unexpected Repo Explorer broker projection error: \(error)")
    }
}
