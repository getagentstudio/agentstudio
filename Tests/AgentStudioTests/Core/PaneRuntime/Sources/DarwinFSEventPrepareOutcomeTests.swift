import AgentStudioGit
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("Darwin FSEvent prepare outcomes")
struct DarwinFSEventPrepareOutcomeTests {
    @Test("missing registration and shutdown have distinct preparation failures")
    func missingRegistrationAndShutdownHaveDistinctFailures() async {
        let client = DarwinFSEventStreamClient()
        defer { client.shutdown() }
        let worktreeId = UUIDv7.generate()
        let rootPath = FileManager.default.temporaryDirectory
        let observationPlan = observationPlan(rootPath: rootPath)

        let missingOutcome = await client.prepare(
            worktreeId: worktreeId,
            rootPath: rootPath,
            observationPlan: observationPlan
        )
        #expect(missingOutcome == .unavailable(.registrationMissing))

        client.shutdown()

        let shutdownOutcome = await client.prepare(
            worktreeId: worktreeId,
            rootPath: rootPath,
            observationPlan: observationPlan
        )
        #expect(shutdownOutcome == .unavailable(.clientShutdown))
    }

    @Test("a supported plan without scopes identifies binding-plan rejection")
    func missingScopesIdentifyBindingPlanRejection() async {
        let client = DarwinFSEventStreamClient()
        defer { client.shutdown() }
        let rootPath = FileManager.default.temporaryDirectory
        let observationPlan = AgentStudioGit.GitStatusObservationPlan(
            identity: AgentStudioGit.GitStatusObservationIdentity(rawValue: "missing-scopes"),
            scopes: [],
            support: .supported
        )

        let outcome = await client.prepare(
            worktreeId: UUIDv7.generate(),
            rootPath: rootPath,
            observationPlan: observationPlan
        )

        #expect(outcome == .unavailable(.bindingPlanUnavailable))
    }

    @Test("preparation for another root rejects the retained registration")
    func anotherRootRejectsRetainedRegistration() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "darwin-prepare-outcomes-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let client = DarwinFSEventStreamClient()
        defer { client.shutdown() }
        let worktreeId = UUIDv7.generate()
        let registrationOutcome = client.register(
            worktreeId: worktreeId,
            repoId: UUIDv7.generate(),
            rootPath: fixtureRoot
        )
        try #require(registrationOutcome == .observing)

        let outcome = await client.prepare(
            worktreeId: worktreeId,
            rootPath: fixtureRoot.appending(path: "another-root"),
            observationPlan: observationPlan(rootPath: fixtureRoot)
        )

        #expect(outcome == .unavailable(.rootMismatch))
    }

    private func observationPlan(rootPath: URL) -> AgentStudioGit.GitStatusObservationPlan {
        AgentStudioGit.GitStatusObservationPlan(
            identity: AgentStudioGit.GitStatusObservationIdentity(rawValue: "prepare-outcomes"),
            scopes: [AgentStudioGit.GitStatusObservationScope(kind: .subtree, path: rootPath)],
            support: .supported
        )
    }
}
