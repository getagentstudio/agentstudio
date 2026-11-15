import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import GRDB
import Synchronization

@testable import AgentStudioSessions

enum MainElectionTableScenario: CaseIterable, Sendable {
    case ownEnd, cursorTakeover, cursorWithoutMain, endedNonStart, reopenEnded
    case newStart, supersedeUnconfirmed, confirmedOther, firstReport

    var provider: String {
        self == .cursorTakeover || self == .cursorWithoutMain ? "cursor" : "claude-code"
    }

    var elects: Bool {
        switch self {
        case .ownEnd, .endedNonStart, .confirmedOther: false
        default: true
        }
    }

    func incoming(pane: UUID, eligible: Bool) -> SessionsHookAdmission {
        let session: String
        let signal: SessionProviderSignal
        switch self {
        case .ownEnd:
            session = "A"
            signal = .sessionEnd
        case .cursorTakeover, .cursorWithoutMain:
            session = "B"
            signal = .turnStart
        case .endedNonStart:
            session = "A"
            signal = .toolActivity(toolName: "Read")
        case .reopenEnded:
            session = "A"
            signal = .sessionStart
        case .newStart:
            session = "B"
            signal = .sessionStart
        case .supersedeUnconfirmed, .confirmedOther, .firstReport:
            session = "B"
            signal = .toolActivity(toolName: "Read")
        }
        return mainEligibilityHook(
            pane: pane, session: session, provider: provider, signal: signal,
            chain: eligible ? TestMainAgentChain.observation : .unknown(.peerUnbound))
    }

    func seed(ingestion: SessionsIngestion, repository: SessionsRepository, pane: UUID) async throws -> Int {
        switch self {
        case .ownEnd, .confirmedOther:
            _ = try await ingestion.submitHook(
                mainEligibilityHook(
                    pane: pane, session: "A", signal: .toolActivity(toolName: "Read"),
                    chain: TestMainAgentChain.observation))
            return 1
        case .cursorTakeover:
            _ = try await ingestion.submitHook(
                mainEligibilityHook(
                    pane: pane, session: "A", provider: "cursor", signal: .turnStart,
                    chain: TestMainAgentChain.observation))
            return 1
        case .endedNonStart, .reopenEnded:
            for signal in [SessionProviderSignal.sessionStart, .sessionEnd] {
                _ = try await ingestion.submitHook(
                    mainEligibilityHook(pane: pane, session: "A", signal: signal, chain: TestMainAgentChain.observation)
                )
            }
            return 2
        case .newStart, .supersedeUnconfirmed:
            _ = try await repository.applyHook(
                mainEligibilityHook(
                    pane: pane, session: "A", signal: .toolActivity(toolName: "Read"),
                    chain: TestMainAgentChain.observation),
                eligibility: .eligible)
            return 1
        case .cursorWithoutMain, .firstReport: return 0
        }
    }

    func expected(eligible: Bool) -> MainElectionTableExpected {
        switch self {
        case .ownEnd:
            return .init(
                session: "A", status: .ended, evidence: .verifiedEnded, disposition: .applied, additionalEvidence: 1)
        case .cursorTakeover:
            return .init(
                session: eligible ? "B" : "A", status: .active, evidence: .verifiedLive,
                disposition: eligible ? .bound : nil,
                additionalEvidence: eligible ? 1 : 0)
        case .cursorWithoutMain, .firstReport:
            return .init(
                session: eligible ? "B" : nil, status: eligible ? .active : .unknown,
                evidence: eligible ? .verifiedLive : .none,
                disposition: eligible ? .bound : nil, additionalEvidence: eligible ? 1 : 0)
        case .endedNonStart:
            return .init(
                session: "A", status: .ended, evidence: .verifiedEnded, disposition: .recordedOnly,
                additionalEvidence: 1)
        case .reopenEnded:
            return .init(
                session: "A", status: eligible ? .unknown : .ended, evidence: eligible ? .verifiedLive : .verifiedEnded,
                disposition: eligible ? .bound : .recordedOnly,
                additionalEvidence: 1)
        case .newStart:
            return .init(
                session: eligible ? "B" : "A", status: eligible ? .unknown : .active,
                evidence: .verifiedLive,
                disposition: eligible ? .bound : nil, additionalEvidence: eligible ? 1 : 0)
        case .supersedeUnconfirmed:
            return .init(
                session: eligible ? "B" : "A", status: .active, evidence: .verifiedLive,
                disposition: eligible ? .bound : nil,
                additionalEvidence: eligible ? 1 : 0)
        case .confirmedOther:
            return .init(
                session: "A", status: .active, evidence: .verifiedLive, disposition: nil, additionalEvidence: 0)
        }
    }
}

struct MainElectionTableExpected {
    enum Status { case active, ended, unknown }
    let session: String?
    let statusKind: Status
    let evidence: StatusEvidence
    let disposition: SessionsHookDisposition?
    let additionalEvidence: Int

    init(
        session: String?, status: Status, evidence: StatusEvidence, disposition: SessionsHookDisposition?,
        additionalEvidence: Int
    ) {
        self.session = session
        statusKind = status
        self.evidence = evidence
        self.disposition = disposition
        self.additionalEvidence = additionalEvidence
    }

    var bindingStatus: SessionsBindingStatus? {
        session == nil ? nil : statusKind == .ended ? .ended : .active
    }
    var sourceHealth: IPCSessionSourceHealth {
        session == nil ? .unbound : statusKind == .ended ? .ended : .live
    }
    var effect: SessionsEvidenceStatusEffect? {
        disposition.map { $0 == .recordedOnly ? .recordedOnly : .applied }
    }
    var status: AgentSessionStatus {
        switch statusKind {
        case .active: .working(.active)
        case .ended: .idle(.ended)
        case .unknown: .unknown
        }
    }
    var wireStatus: IPCPaneSessionStatus? {
        guard session != nil else { return nil }
        switch statusKind {
        case .active: return .working(state: .active)
        case .ended: return .idle(state: .ended)
        case .unknown: return .unknown
        }
    }
}

struct MainEligibilityDatabaseFixture {
    let access: MainEligibilitySQLiteAccess
    let repository: SessionsRepository

    init() throws {
        let queue = try SQLiteDatabaseFactory.makeInMemoryQueue(label: "AgentStudio.sqlite.main-eligibility")
        try WorkspaceLocalMigrations.migrate(queue)
        access = MainEligibilitySQLiteAccess(queue: queue)
        repository = SessionsRepository(sqliteAccess: access)
    }

    func makeIngestion(reader: any PaneTerminalLeaderReading) -> SessionsIngestion {
        SessionsIngestion(
            repository: repository, limits: .init(maximumPendingPerPane: 32, maximumPendingGlobal: 128),
            probe: { _ in }, terminalLeaderReader: reader)
    }
}

struct MainEligibilitySQLiteAccess: SessionsSQLiteAccess {
    let queue: DatabaseQueue
    func read<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        try await queue.read(operation)
    }
    func write<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        try await queue.write(operation)
    }
}

final class MainEligibilityTableLeaderReader: PaneTerminalLeaderReading {
    let sessionID: ZmxSessionID?
    let leader: ZmxProcessIncarnation?
    private let reads = Mutex(0)
    init(leader: ZmxProcessIncarnation?, sessionID: ZmxSessionID?) {
        self.leader = leader
        self.sessionID = sessionID
    }
    var readCount: Int { reads.withLock { $0 } }
    func terminalSessionID(for paneId: UUID) async -> ZmxSessionID? { sessionID }
    func terminalLeader(for sessionID: ZmxSessionID) async -> ZmxProcessIncarnation? {
        reads.withLock { $0 += 1 }
        return sessionID == self.sessionID ? leader : nil
    }
}

func mainEligibilityHook(
    pane: UUID, session: String, provider: String = "claude-code", signal: SessionProviderSignal,
    chain: ProcessChainObservation
) -> SessionsHookAdmission {
    .init(
        paneId: pane, providerIdentifier: provider, providerVersion: "1", sessionId: session,
        eventName: signal.name, turnId: nil, signal: signal, recordId: UUIDv7.generate(), admittedAt: Date(),
        chain: chain)
}
