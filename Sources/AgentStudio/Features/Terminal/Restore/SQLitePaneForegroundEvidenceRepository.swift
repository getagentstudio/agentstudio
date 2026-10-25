import AgentStudioCore
import Foundation
import GRDB
import Synchronization

/// Single writer of current foreground evidence; Core owns each transaction.
package actor SQLitePaneForegroundEvidenceRepository: PaneForegroundEvidenceRepository {
    private let access: any ForegroundEvidenceSQLiteAccess
    private let observerLaunchId: UUID
    private let paneSessions: @Sendable () async throws -> [UUID: ZmxSessionID]
    private let retirementFence = ForegroundRetirementFence()

    package init(
        access: any ForegroundEvidenceSQLiteAccess, observerLaunchId: UUID,
        paneSessions: @escaping @Sendable () async throws -> [UUID: ZmxSessionID] = { [:] }
    ) {
        self.access = access
        self.observerLaunchId = observerLaunchId
        self.paneSessions = paneSessions
    }

    package func eligiblePanes() async throws -> [ForegroundPaneBinding] {
        let sessions = try await paneSessions()
        let retired = retirementFence.snapshot()
        let access = access
        return try await access.read { database in
            try sessions.compactMap { paneId, sessionId in
                guard !retired.contains(paneId), let binding = try access.latestBinding(database, paneId),
                    binding.isLive
                else { return nil }
                if let stored = try ForegroundEvidenceRow.load(paneId: paneId, in: database), stored.look == nil,
                    stored.evidence.bindingGenerationId == binding.bindingGenerationId
                {
                    return nil
                }
                return ForegroundPaneBinding(
                    paneId: paneId, sessionId: sessionId, bindingGenerationId: binding.bindingGenerationId)
            }
        }
    }

    package func admit(_ look: PaneForegroundLook) async throws -> ForegroundEvidenceAdmission {
        guard look.observerLaunchId == observerLaunchId else { return .olderLook }
        guard let identity = try? ZmxSessionIdentity.decode(look.sessionIdentity),
            ForegroundEvidenceRow.canStore(identity: identity, sequence: look.sequence)
        else { return .invalidIdentity }
        let access = access
        let retirementFence = retirementFence
        return try await access.write { database in
            try Task.checkCancellation()
            return try retirementFence.withAdmission { retired in
                guard !retired.contains(look.paneId) else { return .retiredPane }
                let generation = try access.latestBinding(database, look.paneId)?.bindingGenerationId
                guard generation == look.bindingGenerationId else { return .bindingChanged }
                if let previous = try ForegroundEvidenceRow.load(paneId: look.paneId, in: database) {
                    if previous.look == nil, previous.evidence.bindingGenerationId == generation {
                        return .reportedEvidence
                    }
                    if previous.evidence.observerLaunchId == look.observerLaunchId,
                        previous.evidence.sequence >= look.sequence
                    {
                        return .olderLook
                    }
                }
                try ForegroundEvidenceRow.write(look, identity: identity, in: database)
                return .admitted
            }
        }
    }

    package func load(paneId: UUID) async throws -> PaneForegroundLook? {
        guard !retirementFence.contains(paneId) else { return nil }
        let look = try await access.read { try ForegroundEvidenceRow.load(paneId: paneId, in: $0)?.look }
        return retirementFence.contains(paneId) ? nil : look
    }

    package func loadEvidence(paneId: UUID) async throws -> PaneForegroundEvidence? {
        guard !retirementFence.contains(paneId) else { return nil }
        let access = access
        let evidence: PaneForegroundEvidence? = try await access.read { database in
            guard let stored = try ForegroundEvidenceRow.load(paneId: paneId, in: database) else { return nil }
            if stored.look == nil, let latest = try access.latestBinding(database, paneId),
                stored.evidence.bindingGenerationId != latest.bindingGenerationId
            {
                return nil
            }
            return stored.evidence
        }
        return retirementFence.contains(paneId) ? nil : evidence
    }

    package func clearReportedEvidenceForChangedBinding(paneId: UUID) async throws {
        let access = access
        try await access.write { database in
            guard let previous = try ForegroundEvidenceRow.load(paneId: paneId, in: database), previous.look == nil,
                let latest = try access.latestBinding(database, paneId),
                previous.evidence.bindingGenerationId != latest.bindingGenerationId
            else { return }
            try database.execute(
                sql: "DELETE FROM terminal_pane_foreground_evidence WHERE pane_id = ? AND evidence_kind != 'look'",
                arguments: [paneId.uuidString])
        }
    }

    /// Joins the supplied Sessions commit; never opens a nested transaction.
    package nonisolated func write(
        in database: Database, evidence: ForegroundEvidence, paneId: UUID, bindingGenerationId: UUID?,
        sequence: UInt64, observedAt: Date
    ) throws -> ForegroundEvidenceAdmission {
        guard Int64(exactly: sequence) != nil else { return .invalidIdentity }
        if case .look = evidence { return .invalidIdentity }
        return try retirementFence.withAdmission { retired in
            guard !retired.contains(paneId) else { return .retiredPane }
            let generation = try access.latestBinding(database, paneId)?.bindingGenerationId
            guard generation == bindingGenerationId else { return .bindingChanged }
            if let previous = try ForegroundEvidenceRow.load(paneId: paneId, in: database),
                previous.evidence.bindingGenerationId == bindingGenerationId,
                Self.priority(of: previous.evidence.value) > Self.priority(of: evidence)
            {
                return .reportedEvidence
            }
            try ForegroundEvidenceRow.writeReported(
                .init(
                    paneId: paneId, bindingGenerationId: bindingGenerationId,
                    observerLaunchId: observerLaunchId, sequence: sequence, observedAt: observedAt, value: evidence),
                in: database)
            return .admitted
        }
    }

    private nonisolated static func priority(of evidence: ForegroundEvidence) -> Int {
        switch evidence {
        case .look: 0
        case .reportedEnd: 1
        case .reportedOtherSessionEnd: 2
        case .reportedOtherStart: 3
        case .reportsUnreadable: 4
        }
    }

    package func retire(paneId: UUID) async throws {
        retirementFence.retire(paneId)
        try await access.write { database in
            try database.execute(
                sql: "DELETE FROM terminal_pane_foreground_evidence WHERE pane_id = ?",
                arguments: [paneId.uuidString])
        }
    }
}

private final class ForegroundRetirementFence: Sendable {
    private let retiredPanes = Mutex<Set<UUID>>([])
    func snapshot() -> Set<UUID> { retiredPanes.withLock { $0 } }
    func contains(_ paneId: UUID) -> Bool { retiredPanes.withLock { $0.contains(paneId) } }
    func retire(_ paneId: UUID) { retiredPanes.withLock { _ = $0.insert(paneId) } }
    func withAdmission(_ operation: (Set<UUID>) throws -> ForegroundEvidenceAdmission) rethrows
        -> ForegroundEvidenceAdmission
    {
        try retiredPanes.withLock { try operation($0) }
    }
}
