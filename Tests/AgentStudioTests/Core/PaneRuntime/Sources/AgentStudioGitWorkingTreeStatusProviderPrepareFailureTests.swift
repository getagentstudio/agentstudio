import AgentStudioGit
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

extension AgentStudioGitWorkingTreeStatusProviderTests {
    @Test(
        "every preparation failure preserves ordinary status facts without authority",
        arguments: [
            GitCleanContinuityPrepareFailure.unsupportedObservation,
            .bindingPlanUnavailable, .clientShutdown, .registrationMissing, .rootMismatch,
            .replacementCreationFailed, .shutdownDuringReplacementInstall, .replacementInstallLost,
            .sharedBindingInstallFailed,
            .preFlushBarrierUnavailable, .compositeStreamsUnavailable, .streamFlushFailed,
            .postFlushBarrierUnavailable, .barrierChangedDuringFlush, .compositeStreamsChangedDuringFlush,
        ]
    )
    func preparationFailurePreservesOrdinaryStatusFacts(
        failure: GitCleanContinuityPrepareFailure
    ) async throws {
        let rootPath = URL(fileURLWithPath: "/tmp/repo")
        let observationPlan = gitStatusProviderTestObservationPlan(rootPath: rootPath)
        let witness = TestGitCleanContinuityWitness(commitSucceeds: true, prepareFailure: failure)
        let snapshot = gitStatusProviderTestSnapshot()
        let provider = AgentStudioGitWorkingTreeStatusProvider(
            slowObservationScheduler: PassiveStatusSlowObservationScheduler(),
            physicalGate: AgentStudioGitStatusPhysicalGate(),
            continuityWitness: witness,
            statusObservationPlanReader: { _ in observationPlan },
            verifiedStatusFactsReader: { _, _, suppliedPlan in
                AgentStudioGit.GitStatusFactsRead(
                    facts: snapshot.facts,
                    exactCleanBaseline: suppliedPlan.map {
                        AgentStudioGit.GitExactCleanBaseline(observationIdentity: $0.identity)
                    }
                )
            },
            statusReader: { _, _ in snapshot }
        )

        let result = await provider.exactCleanStatusFactsResult(
            for: UUIDv7.generate(),
            rootPath: rootPath
        )

        guard case .available(let facts) = result else {
            Issue.record("preparation failure changed the ordinary fallback: \(result)")
            return
        }
        #expect(facts.changed == snapshot.facts.summary.unstagedFileCount)
        #expect(facts.branch == "main")
        #expect(facts.exactCleanAuthority == nil)
        #expect(witness.prepareCount == 1)
        #expect(witness.commitCount == 0)
    }

}
