import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Watched-folder rejected admission shutdown")
struct WatchedFolderScanSchedulerRejectionShutdownTests {
    enum RejectionOrdering: Sendable {
        case alreadyDraining
        case executorShutDown
    }

    private struct RejectedAdmission: Sendable {
        let request: RepoDiscoveryValidationRequest
        let admission: RepoDiscoveryValidationAdmissionResult
    }

    private enum ShutdownObservation: Equatable, Sendable {
        case sessionFactoryStarted(UInt64)
        case traversalTasksJoined
        case shutdownObserved(WatchedFolderScanSchedulerStateSnapshot)
    }

    @Test(
        "rejected admission discards dirty successor after the shutdown join snapshot",
        arguments: [
            RejectionOrdering.alreadyDraining, .executorShutDown,
        ])
    func rejectedAdmissionDiscardsDirtySuccessor(ordering: RejectionOrdering) async throws {
        let observations = makeShutdownObservations()
        let facts = try observations.attach()
        let discarded = makeDiscardObservations()
        let discardFacts = try discarded.attach()
        let beforeSubmit = HeldStep<RepoDiscoveryValidationRequest>(
            "generation-2 submit after executor shutdown", cancellation: .holdThroughCancellation
        )
        let rejectedReturn = HeldStep<RejectedAdmission>(
            "real rejected generation-2 admission return", cancellation: .holdThroughCancellation
        )
        let successorFactory = HeldStep<UInt64>(
            "dirty generation-3 session factory started during shutdown", cancellation: .holdThroughCancellation
        )
        let fixture = try makeFixture(
            ordering: ordering, observations: observations, discarded: discarded,
            beforeSubmit: beforeSubmit, rejectedReturn: rejectedReturn, successorFactory: successorFactory
        )
        let original = try fixture.makeRequest(name: "rejected-shutdown", containsGitMarker: true)
        let rootURL = URL(fileURLWithPath: original.canonicalRoot.aliases.onceResolvedCanonical.path)
        let replacement = try fixture.makeRequest(
            name: "rejected-shutdown", containsGitMarker: true, sourceID: original.sourceID,
            registrationGeneration: 2, rootURL: rootURL
        )
        let newest = try fixture.makeRequest(
            name: "rejected-shutdown", containsGitMarker: true, sourceID: original.sourceID,
            registrationGeneration: 3, rootURL: rootURL
        )
        _ = await fixture.scheduler.submit(original)
        let staleCandidate = await fixture.validationClient.nextCandidate()
        try await facts.expectNext(in: original.sourceID, .sessionFactoryStarted(1))
        _ = await fixture.scheduler.submit(replacement)
        if case .alreadyDraining = ordering {
            let rejected = try await rejectedReturn.firstArrival()
            #expect(rejected.admission == .rejected(.allPhysicalJobsDraining(count: 1)))
        } else {
            _ = try await beforeSubmit.firstArrival()
        }
        try await facts.expectNext(in: original.sourceID, .sessionFactoryStarted(2))
        _ = await fixture.scheduler.submit(newest)
        let opening = await facts.mark(original.sourceID)

        let shutdownTask = Task {
            await fixture.scheduler.shutdown()
            let state = await fixture.scheduler.stateSnapshot()
            // Failure cleanup observes the actual successor before closing the test operation.
            if state != .shutDown { _ = try? await successorFactory.firstArrival() }
            observations.sink(original.sourceID, .shutdownObserved(state))
            return state
        }
        try await facts.expectNext(in: original.sourceID, .traversalTasksJoined)
        if case .executorShutDown = ordering {
            beforeSubmit.release()
            let rejected = try await rejectedReturn.firstArrival()
            #expect(rejected.admission == .rejected(.shutdown))
        }
        await fixture.validationClient.complete(staleCandidate, with: .cancelled)
        rejectedReturn.release()
        let state = await shutdownTask.value
        #expect(state == .shutDown, "rejected admission must discard dirty custody at shutdown")
        do {
            try await facts.expectNone(
                of: { $0 == .sessionFactoryStarted(3) }, "generation-3 session factory",
                from: opening,
                closedBy: {
                    if case .shutdownObserved = $0 { return true }
                    return false
                }
            )
        } catch {
            Issue.record("shutdown dispatched a dirty successor: \(error)")
        }
        if state != .shutDown {
            successorFactory.release()
            try await discardFacts.expectNext(in: newest.canonicalRoot.registration, 3)
            #expect(await fixture.scheduler.stateSnapshot() == .shutDown)
        }
        beforeSubmit.release()
        successorFactory.release()
        try await facts.finish()
        try await discardFacts.finish()
        try await fixture.facts.finish()
    }

    private func makeShutdownObservations() -> LocalFactSource<FilesystemSourceID, ShutdownObservation> {
        LocalFactSource(
            vocabulary: FactVocabulary(
                describeScope: { String(describing: $0) }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in
                    if case .shutdownObserved = fact { return true }
                    return false
                }
            )
        )
    }

    private func makeDiscardObservations() -> LocalFactSource<FSEventRegistrationToken, UInt64> {
        LocalFactSource(
            vocabulary: FactVocabulary(
                describeScope: { String(describing: $0) }, describeFact: { String(describing: $0) },
                isClosing: { _, _ in true }
            )
        )
    }

    private func makeFixture(
        ordering: RejectionOrdering,
        observations: LocalFactSource<FilesystemSourceID, ShutdownObservation>,
        discarded: LocalFactSource<FSEventRegistrationToken, UInt64>,
        beforeSubmit: HeldStep<RepoDiscoveryValidationRequest>,
        rejectedReturn: HeldStep<RejectedAdmission>,
        successorFactory: HeldStep<UInt64>
    ) throws -> ValidationSchedulerFixture {
        try ValidationSchedulerFixture(
            maximumConcurrentScans: 1,
            validationBudget: RepoDiscoveryValidationBudget(
                logicalDeadline: .seconds(60), maximumPhysicalJobs: 1,
                maximumQueuedRequests: 4, maximumQueuedRequestsPerRoot: 1
            ),
            validationAdmissionAdapter: { executor, request in
                if request.scanRunGeneration == 2, case .executorShutDown = ordering {
                    do { try await beforeSubmit.arrive(request) } catch {
                        Issue.record("pre-submit shutdown hold failed: \(error)")
                    }
                }
                let admission = await executor.submit(request)
                if request.scanRunGeneration == 2 {
                    do {
                        try await rejectedReturn.arrive(RejectedAdmission(request: request, admission: admission))
                    } catch { Issue.record("rejected admission return hold failed: \(error)") }
                }
                return admission
            },
            schedulerFactObserver: { scope, fact in
                switch fact {
                case .shutdownAwaitingAdmission:
                    observations.sink(scope.registration.sourceID, .traversalTasksJoined)
                case .validationDiscardedDuringShutdown:
                    discarded.sink(scope.registration, scope.scanRunGeneration)
                default:
                    break
                }
            },
            sessionFactoryObservation: { request, generation in
                observations.sink(request.sourceID, .sessionFactoryStarted(generation))
                if generation == 3 {
                    do { try await successorFactory.arrive(generation) } catch {
                        Issue.record("successor session factory hold failed: \(error)")
                    }
                }
            }
        )
    }
}
