import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioTestHarness
import Foundation
import GRDB
import Synchronization

@testable import AgentStudio

enum OutboxDrainCaller: Hashable, Sendable { case first, second, third, cancelled }

enum OutboxDrainReadContext {
    @TaskLocal static var caller: OutboxDrainCaller?
}

/// Holds a completed real SQLite snapshot, never the database transaction or its executor.
actor HeldOutboxDrainSQLiteAccess: SessionsSQLiteAccess {
    let base: FailableOutboxSessionsSQLiteAccess
    let heldRead: Int
    let first = HeldStep<Void>("first drain's SQLite snapshot")
    let second = HeldStep<Void>("second drain's SQLite snapshot")
    private var reads: [OutboxDrainCaller: Int] = [:]

    init(base: FailableOutboxSessionsSQLiteAccess, heldRead: Int) {
        self.base = base
        self.heldRead = heldRead
    }

    func read<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        let value = try await base.read(operation)
        if let caller = OutboxDrainReadContext.caller {
            reads[caller, default: 0] += 1
            if reads[caller] == heldRead {
                switch caller {
                case .first: try await first.arrive(())
                case .second: try await second.arrive(())
                case .third, .cancelled: break
                }
            }
        }
        return value
    }

    func write<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        try await base.write(operation)
    }

    func readCount(for caller: OutboxDrainCaller) -> Int { reads[caller, default: 0] }

    nonisolated func retire() {
        first.retire()
        second.retire()
    }
}

final class OutboxRestoreImportLedger: Sendable {
    private struct State {
        var reports: [UUID] = []
        var historyLosses = 0
    }
    private let state = Mutex(State())

    func record(_ item: ClosedAppOutboxItem) {
        state.withLock { state in
            switch item {
            case .report(let report): state.reports.append(report.reportId)
            case .historyLost: state.historyLosses += 1
            case .refused: break
            }
        }
    }

    var reports: [UUID] { state.withLock { $0.reports } }
    var historyLosses: Int { state.withLock { $0.historyLosses } }
}

struct RecordingOutboxRestoreParticipant: AgentStudioSessions.ClosedAppRestoreEvidenceParticipant {
    let base: AgentStudio.ClosedAppRestoreEvidenceParticipant
    let ledger: OutboxRestoreImportLedger

    func commit(in database: Database, item: ClosedAppOutboxItem, latestBindings: SessionsLatestBindings) throws {
        try base.commit(in: database, item: item, latestBindings: latestBindings)
        ledger.record(item)
    }
}

struct StartedOutboxDrain: Sendable {
    let task: Task<PaneCLIOutboxDrain.DrainReport, Never>
    let queued: Bool
}

/// Task.immediate enters on the isolated owner through its first suspension.
/// Queue state chooses the interleaving only; all verdict assertions use real effects.
func startOutboxDrain(
    on drain: isolated PaneCLIOutboxDrain, storeURL: URL, caller: OutboxDrainCaller,
    held: HeldOutboxDrainSQLiteAccess
) -> StartedOutboxDrain {
    let task = OutboxDrainReadContext.$caller.withValue(caller) {
        Task.immediate {
            defer {
                switch caller {
                case .first: held.first.retire()
                case .second: held.second.retire()
                case .third, .cancelled: break
                }
            }
            return await drain.drain(storeURL: storeURL)
        }
    }
    return .init(task: task, queued: !drain.pendingDrains.isEmpty)
}

@MainActor
func makeHeldOutboxDrain(
    harness: PaneCLIOutboxDrainHarness, held: HeldOutboxDrainSQLiteAccess, ledger: OutboxRestoreImportLedger
) throws -> PaneCLIOutboxDrain {
    let membership = harness.membership
    return try PaneCLIOutboxDrain(
        admission: harness.admission, sqliteAccess: held, expectedChannel: .debug,
        ingestion: harness.ingestion,
        restoreEvidence: RecordingOutboxRestoreParticipant(base: harness.restoreEvidence, ledger: ledger),
        paneExists: { membership.sources(for: PaneId(existingUUID: $0)) != nil })
}
