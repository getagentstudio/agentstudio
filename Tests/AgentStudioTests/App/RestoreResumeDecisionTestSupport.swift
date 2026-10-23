import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioTerminal
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio

struct ColdResumeTestPane: Sendable {
    let paneId: UUID
    let sessionId: String
    let look: PaneForegroundLook
    let repository: SQLitePaneForegroundEvidenceRepository

    @MainActor static func make(
        harness: PaneCLIOutboxDrainHarness, provider: String = "codex", paneId: UUID = UUIDv7.generate(),
        sessionId: String = UUIDv7.generate().uuidString, session: ZmxSessionID = .generateUUIDv7(),
        bootId: String = "boot-A", program: ForegroundProgram = .codex, nativeIdentity: Data? = nil
    ) async throws -> Self {
        _ = await harness.drain()
        harness.membership.addPane(.init(existingUUID: paneId))
        let admitted = try await harness.ingestion.submitHook(
            .init(
                paneId: paneId, providerIdentifier: provider, providerVersion: "1", sessionId: sessionId,
                eventName: .sessionStart, turnId: nil, signal: .sessionStart,
                recordId: UUIDv7.generate(), admittedAt: Date(timeIntervalSince1970: 10)))
        guard case .committed(let commit) = admitted, commit.binding.providerConversationId == sessionId else {
            throw ColdResumeFixtureFailure.bindingNotAdmitted
        }
        let binding = try #require(try await harness.repository.statusContext(paneId: paneId).currentBinding)
        let observerId = UUIDv7.generate()
        let repository = SQLitePaneForegroundEvidenceRepository(
            access: WorkspaceForegroundEvidenceSQLiteAccess(sqliteAccess: harness.sqliteAccess),
            observerLaunchId: observerId, paneSessions: { [paneId: session] })
        let identity =
            try nativeIdentity
            ?? ZmxSessionIdentity(
                version: 1, bootID: bootId, daemon: .init(pid: 3111, startSeconds: 1, startMicroseconds: 1),
                terminalLeader: .init(pid: 3112, startSeconds: 1, startMicroseconds: 2),
                processGroupID: 3112, sessionCreatedAt: 1
            ).encoded()
        let look = PaneForegroundLook(
            paneId: paneId, zmxSessionId: session, sessionIdentity: identity,
            bindingGenerationId: binding.bindingGenerationId, program: program,
            observerLaunchId: observerId, sequence: 1, observedAt: Date(timeIntervalSince1970: 11))
        #expect(try await repository.admit(look) == .admitted)
        return Self(paneId: paneId, sessionId: sessionId, look: look, repository: repository)
    }

    @MainActor func decision(
        harness: PaneCLIOutboxDrainHarness, foreground: (any PaneForegroundEvidenceRepository)? = nil
    ) -> ColdRestoreResumeDecision {
        .init(
            ingestion: harness.ingestion, foregroundRepository: foreground ?? repository,
            drain: harness.drainOwner, storeURL: harness.storeURL)
    }

    func resolve(
        _ decision: ColdRestoreResumeDecision, previousBoot: String? = "boot-B",
        currentBoot: String = "boot-B", inventory: ZmxSessionInventory = .complete([:])
    ) async -> ColdRestoreResumeVerdict {
        await decision.resolve(
            paneId: paneId, sessionId: look.zmxSessionId, preRestoreLook: look,
            readiness: .ready, launchBoot: .init(previousBootId: previousBoot, currentBootId: currentBoot),
            inventory: inventory)
    }
}

actor HeldResumeEvidenceRepository: PaneForegroundEvidenceRepository {
    let base: any PaneForegroundEvidenceRepository
    let hold: HeldStep<PaneForegroundEvidence?>
    let heldRead: Int
    private var reads = 0
    init(base: any PaneForegroundEvidenceRepository, hold: HeldStep<PaneForegroundEvidence?>, heldRead: Int) {
        self.base = base
        self.hold = hold
        self.heldRead = heldRead
    }
    func loadEvidence(paneId: UUID) async throws -> PaneForegroundEvidence? {
        let value = try await base.loadEvidence(paneId: paneId)
        reads += 1
        if reads == heldRead { try await hold.arrive(value) }
        return value
    }
    func eligiblePanes() async throws -> [ForegroundPaneBinding] { try await base.eligiblePanes() }
    func admit(_ look: PaneForegroundLook) async throws -> ForegroundEvidenceAdmission { try await base.admit(look) }
    func load(paneId: UUID) async throws -> PaneForegroundLook? { try await base.load(paneId: paneId) }
    func clearReportedEvidenceForChangedBinding(paneId: UUID) async throws {
        try await base.clearReportedEvidenceForChangedBinding(paneId: paneId)
    }
    func retire(paneId: UUID) async throws { try await base.retire(paneId: paneId) }
}

func coldResumeBasePlan(session: ZmxSessionID) -> TerminalColdRestorePlan {
    .init(
        zmxExecutable: URL(fileURLWithPath: "/unused/zmx"), zmxDirectory: URL(fileURLWithPath: "/unused/zmx-root"),
        sessionID: session, loginShell: URL(fileURLWithPath: "/bin/zsh"),
        folderCandidates: [URL(fileURLWithPath: "/tmp/cold-resume-proof")],
        notice: .init(linesByCandidateIndex: ["Restored after restart\nno saved output"]),
        replayFile: nil, resume: nil, attemptID: .generate())
}

private enum ColdResumeFixtureFailure: Error { case bindingNotAdmitted }
