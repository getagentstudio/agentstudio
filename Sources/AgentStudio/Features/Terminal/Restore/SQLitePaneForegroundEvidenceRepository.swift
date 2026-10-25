import AgentStudioCore
import Foundation
import GRDB
import Synchronization

/// Single writer of retained closed-app reports; Core owns each transaction.
package actor SQLitePaneForegroundEvidenceRepository: PaneForegroundEvidenceRepository {
    private let access: any ForegroundEvidenceSQLiteAccess
    private let observerLaunchId: UUID
    private let retirementFence = ForegroundRetirementFence()

    package init(
        access: any ForegroundEvidenceSQLiteAccess, observerLaunchId: UUID
    ) {
        self.access = access
        self.observerLaunchId = observerLaunchId
    }

    package func loadEvidence(paneId: UUID) async throws -> PaneForegroundEvidence? {
        guard !retirementFence.contains(paneId) else { return nil }
        let access = access
        let evidence: PaneForegroundEvidence? = try await access.read { database in
            guard let stored = try ForegroundEvidenceRow.load(paneId: paneId, in: database) else { return nil }
            if let latest = try access.latestBinding(database, paneId),
                stored.bindingGenerationId != latest.bindingGenerationId
            {
                return nil
            }
            return stored
        }
        return retirementFence.contains(paneId) ? nil : evidence
    }

    /// Joins the supplied Sessions commit; never opens a nested transaction.
    package nonisolated func write(
        in database: Database, evidence: ForegroundEvidence, paneId: UUID, bindingGenerationId: UUID?,
        sequence: UInt64, observedAt: Date
    ) throws -> ForegroundEvidenceAdmission {
        guard Int64(exactly: sequence) != nil else { return .invalidIdentity }
        return try retirementFence.withAdmission { retired in
            guard !retired.contains(paneId) else { return .retiredPane }
            let generation = try access.latestBinding(database, paneId)?.bindingGenerationId
            guard generation == bindingGenerationId else { return .bindingChanged }
            if let previous = try ForegroundEvidenceRow.load(paneId: paneId, in: database),
                previous.bindingGenerationId == bindingGenerationId,
                Self.priority(of: previous.value) > Self.priority(of: evidence)
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
    func contains(_ paneId: UUID) -> Bool { retiredPanes.withLock { $0.contains(paneId) } }
    func retire(_ paneId: UUID) { retiredPanes.withLock { _ = $0.insert(paneId) } }
    func withAdmission(_ operation: (Set<UUID>) throws -> ForegroundEvidenceAdmission) rethrows
        -> ForegroundEvidenceAdmission
    {
        try retiredPanes.withLock { try operation($0) }
    }
}
