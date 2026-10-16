import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@MainActor
@Suite("Bridge annotation ownership retirement", .serialized)
struct BridgePaneProductSessionAnnotationRetirementTests {
    @Test("Dev Server worker replacement releases annotation edit ownership without restarting SQLite")
    func developmentWorkerReplacementReleasesAnnotationOwnership() async throws {
        // Arrange — the same real service and repository survive two native worker sessions.
        let repositoryURL = try await FilesystemTestGitRepo.create(named: "bridge-development-annotation-retirement")
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repositoryURL)
        let repository = try makeAnnotationRepository()
        let store = WorktreeAnnotationServiceActor(
            repositoryAccess: RepositoryBackedWorktreeAnnotationAccess(repository: repository)
        )
        let host = try await BridgeDevelopmentProductHost(
            source: makeDevelopmentProductSource(worktreeRoot: repositoryURL),
            worktreeAnnotationStore: store,
            operationDeadlineClock: TestPushClock(),
            contributionTargetCommit: developmentContributionTargetCommit(worktreeRoot: repositoryURL),
            makeReviewProvider: { _, _ in BridgeObservabilitySmokeReviewSourceProvider() }
        )
        try await withMainActorShutdownDevelopmentProductHost(host) {
            let initialRequest = try developmentDisplayBootstrapRequest(reason: "initial")
            let firstWorker = try DevelopmentDisplayWorkerClient(
                host: host,
                delivery: await host.issueBootstrap(for: initialRequest)
            )
            try await firstWorker.openSession()
            let detail = try await store.createRootDraft(
                makeCreateRootDraftProps(),
                ownerGeneration: firstWorker.workerInstanceId
            )
            let message = try #require(detail.threads.first?.messages.first)
            let draft = try #require(message.draft)

            // Act
            let replacementRequest = try developmentDisplayBootstrapRequest(
                paneSessionId: firstWorker.paneSessionId,
                reason: "workerReplacement"
            )
            let replacementWorker = try DevelopmentDisplayWorkerClient(
                host: host,
                delivery: await host.issueBootstrap(for: replacementRequest)
            )
            try await replacementWorker.openSession()
            let reclaimed = try await store.acquireEditToken(
                .init(
                    sessionID: detail.session.id,
                    messageID: message.id,
                    editToken: "development-replacement-editor",
                    expectedMessageRevision: message.semanticRevision,
                    expectedDraftRevision: draft.draftRevision,
                    now: Date(timeIntervalSince1970: 3)
                ),
                ownerGeneration: replacementWorker.workerInstanceId
            )

            // Assert
            #expect(replacementWorker.workerInstanceId != firstWorker.workerInstanceId)
            #expect(reclaimed.threads.first?.messages.first?.draft?.body == draft.body)
            #expect(reclaimed.threads.first?.messages.first?.draft?.draftRevision == draft.draftRevision + 1)
        }
    }

    @Test("a successful retirement retry releases the exact retired worker's annotation edit ownership")
    func successfulRetirementRetryReleasesAnnotationOwnership() async throws {
        // Arrange — the real annotation repository holds a draft leased to the active worker.
        let repository = try makeAnnotationRepository()
        let store = WorktreeAnnotationServiceActor(
            repositoryAccess: RepositoryBackedWorktreeAnnotationAccess(repository: repository)
        )
        let provider = BridgePaneProductSessionProviderGate()
        let admissionGate = BridgeProductAdmissionGate()
        let installation = try BridgeProductSessionInstallation.make(
            paneSessionId: bridgeProductTestPaneSessionId,
            provider: provider,
            productAdmissionGate: admissionGate
        )
        let owner = BridgePaneController.makeProductSessionOwner(
            paneSessionId: bridgeProductTestPaneSessionId,
            provider: provider,
            productAdmissionGate: admissionGate,
            activeInstallation: installation,
            worktreeAnnotationStore: store
        )
        try await openBridgePaneProductSession(installation)
        let detail = try await store.createRootDraft(
            makeCreateRootDraftProps(),
            ownerGeneration: installation.bootstrap.workerInstanceId
        )
        let message = try #require(detail.threads.first?.messages.first)
        let draft = try #require(message.draft)
        let replacementGeneration = UUIDv7.generate().uuidString.lowercased()
        let reclaim = WorktreeAnnotationEditTokenCommandProps(
            sessionID: detail.session.id,
            messageID: message.id,
            editToken: "replacement-editor",
            expectedMessageRevision: message.semanticRevision,
            expectedDraftRevision: draft.draftRevision,
            now: Date(timeIntervalSince1970: 3)
        )
        let contentReply = try await startContentReply(
            installation: installation,
            provider: provider,
            identitySuffix: "annotation-retirement-retry"
        )
        await provider.holdLifecycleAcknowledgements()

        // Act — retirement fails once after activeInstallation has already been cleared.
        let firstRetirement = Task { await owner.retire(reason: .paneDisposal) }
        _ = await provider.waitForLifecycleAcknowledgement(count: 1)
        await provider.releaseLifecycleAcknowledgements(result: false)
        #expect(await firstRetirement.value == .revocationFailed)
        #expect(await owner.activeInstallation == nil)
        await #expect(throws: WorktreeAnnotationRepositoryError.editTokenConflict) {
            try await store.acquireEditToken(reclaim, ownerGeneration: replacementGeneration)
        }
        await provider.succeedLifecycleAcknowledgements()
        #expect(await owner.retire(reason: .paneDisposal) == .retired)
        _ = try? await contentReply.value

        // Assert — the draft survives and a fresh worker can reclaim it only after retirement succeeds.
        let reclaimed = try await store.acquireEditToken(reclaim, ownerGeneration: replacementGeneration)
        let reclaimedDraft = try #require(reclaimed.threads.first?.messages.first?.draft)
        #expect(reclaimedDraft.body == draft.body)
        #expect(reclaimedDraft.draftRevision == draft.draftRevision + 1)
        #expect(await owner.snapshot() == .empty)
    }
}
