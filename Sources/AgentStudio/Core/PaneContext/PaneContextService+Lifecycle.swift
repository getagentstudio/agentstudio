import AgentStudioInfrastructure
import Foundation
import GRDB

private struct PaneContextLifecycleCommit: Sendable {
    let settlements: [(PaneContextMessageKey, PaneContextSettlementCommit)]
    let affectedSources: Set<PaneId>
}

extension PaneContextService {
    package nonisolated func retire(_ paneIds: [PaneId]) {
        let changed = retirementMailbox.state.withLock { mailbox in
            guard mailbox.accepting else { return false }
            mailbox.pending.formUnion(paneIds)
            mailbox.retired.formUnion(paneIds)
            return !paneIds.isEmpty
        }
        if changed {
            for paneId in paneIds { presentationLane?.mailbox.retire(paneId) }
            retirementWake.yield(())
        }
    }

    func drainRetirements() async throws {
        if let retirementCommit {
            let generation = retirementCommitGeneration
            try await retirementCommit.value
            if retirementCommitGeneration == generation { self.retirementCommit = nil }
        }
        let panes = retirementMailbox.state.withLock { mailbox in
            let panes = mailbox.pending
            mailbox.pending.removeAll()
            return panes
        }
        guard !panes.isEmpty else { return }
        let access = sqliteAccess
        let now = wallNow
        retirementCommitGeneration &+= 1
        let generation = retirementCommitGeneration
        let task = Task {
            try await access.write { database in
                let retiredAt = now()
                for pane in panes {
                    try database.execute(
                        sql: "INSERT OR IGNORE INTO pane_retirement(pane_id, retired_at, purge_after) VALUES (?, ?, ?)",
                        arguments: [
                            pane.uuidString, try PaneContextStorage.timestamp(retiredAt),
                            try PaneContextStorage.timestamp(
                                retiredAt.addingTimeInterval(AppPolicies.PaneContext.panePurgeLifetime)),
                        ])
                }
            }
        }
        retirementCommit = task
        do { try await task.value } catch {
            retirementMailbox.state.withLock { $0.pending.formUnion(panes) }
            if retirementCommitGeneration == generation { retirementCommit = nil }
            throw error
        }
        if retirementCommitGeneration == generation { retirementCommit = nil }
        await refreshDeadline()
        await presentationLane?.publishPending()
        if retirementMailbox.state.withLock({ !$0.pending.isEmpty }) { try await drainRetirements() }
    }

    package func purgeRetired() async {
        do {
            try await ensureOpen()
            let now = wallNow
            try await sqliteAccess.write { database in try PaneContextStorage.purgeRetired(database, now: now()) }
            await refreshDeadline()
        } catch {
            // Retired panes remain refused; the next demand retries the purge.
        }
    }

    func refreshDeadline() async {
        guard !isStopping else { return }
        deadlineRefreshGeneration &+= 1
        let generation = deadlineRefreshGeneration
        do {
            let deadline = try await sqliteAccess.read { database -> Date? in
                let value = try Int64.fetchOne(
                    database,
                    sql: """
                        SELECT MIN(deadline) FROM (
                            SELECT deadline FROM pane_request WHERE state = 'open' AND waiting = 'blocking'
                            UNION ALL SELECT expires_at FROM pane_state WHERE kind = 'agentLine' AND stale = 0 AND expires_at IS NOT NULL
                            UNION ALL SELECT purge_after FROM pane_retirement
                            UNION ALL SELECT settled_at + ? FROM pane_request WHERE display_hidden = 0 AND settled_at IS NOT NULL
                            UNION ALL SELECT settled_at + ? FROM pane_event WHERE kind = 'notice' AND display_hidden = 0 AND settled_at IS NOT NULL
                        )
                        """,
                    arguments: [
                        try PaneContextStorage.timestamp(
                            Date(timeIntervalSince1970: AppPolicies.PaneContext.settledMessageLifetime)),
                        try PaneContextStorage.timestamp(
                            Date(timeIntervalSince1970: AppPolicies.PaneContext.settledMessageLifetime)),
                    ])
                return value.map { Date(timeIntervalSince1970: Double($0) / 1_000_000) }
            }
            guard generation == deadlineRefreshGeneration, !isStopping else { return }
            if deadlineScheduler == nil {
                let sourceClock: any Clock<Duration> & Sendable = self.clock
                deadlineScheduler = makePaneContextDeadlineScheduler(clock: sourceClock) { [weak self] in
                    await self?.deadlineReached()
                }
            }
            await deadlineScheduler?.schedule(after: deadline.map { .seconds(max(0, $0.timeIntervalSince(wallNow()))) })
        } catch {
            // A later demand retries the deadline read.
        }
    }

    func deadlineReached() async {
        guard !isStopping else { return }
        let now = wallNow
        let binding = currentBindingGeneration
        do {
            let commit = try await sqliteAccess.write { database in
                let before = try PaneContextStorage.presentationRevisions(database)
                let instant = now()
                let rows = try Row.fetchAll(
                    database,
                    sql:
                        "SELECT pane_id, message_id FROM pane_request WHERE state = 'open' AND waiting = 'blocking' AND deadline <= ?",
                    arguments: [try PaneContextStorage.timestamp(instant)])
                let commits = try rows.map { row in
                    let key = PaneContextMessageKey(
                        paneId: PaneId(existingUUID: try PaneContextStorage.uuid(row, "pane_id")),
                        messageId: AgentMessageId(existingUUID: try PaneContextStorage.uuid(row, "message_id")))
                    return (
                        key,
                        try PaneContextAskSettlement.commit(
                            database, paneId: key.paneId, id: key.messageId, cause: .deadline, now: instant,
                            currentBindingGeneration: binding)
                    )
                }
                try PaneContextStorage.expireLines(database, now: instant)
                try PaneContextStorage.hideSettled(database, now: instant)
                try PaneContextStorage.purgeRetired(database, now: instant)
                return PaneContextLifecycleCommit(
                    settlements: commits,
                    affectedSources: try PaneContextStorage.changedPresentationSources(database, since: before))
            }
            for (key, settlement) in commit.settlements { await acceptSettlement(settlement, key: key) }
            await publishAffectedSources(commit.affectedSources)
            await refreshDeadline()
        } catch {
            // The next demand retries; no outcome is published without a commit.
        }
    }

    package func sessionEnded(bindingGenerationId: UUID) async {
        do {
            try await ensureOpen()
            let commit = try await sqliteAccess.write { database in
                let before = try PaneContextStorage.presentationRevisions(database)
                let lines = try Row.fetchAll(
                    database,
                    sql:
                        "SELECT pane_id FROM pane_state WHERE kind = 'agentLine' AND writer_binding_generation = ? AND stale = 0 AND summary IS NOT NULL",
                    arguments: [bindingGenerationId.uuidString])
                try database.execute(
                    sql: "UPDATE pane_state SET stale = 1 WHERE kind = 'agentLine' AND writer_binding_generation = ?",
                    arguments: [bindingGenerationId.uuidString])
                for row in lines {
                    try PaneContextStorage.bumpRevision(
                        database, paneId: PaneId(existingUUID: PaneContextStorage.uuid(row, "pane_id")))
                }
                let receipts = try Row.fetchAll(
                    database,
                    sql:
                        "SELECT DISTINCT pane_id FROM pane_request WHERE sender_binding_generation = ? AND receipt = 'notYetConfirmed'",
                    arguments: [bindingGenerationId.uuidString])
                try database.execute(
                    sql:
                        "UPDATE pane_request SET receipt = 'unconfirmed' WHERE sender_binding_generation = ? AND receipt = 'notYetConfirmed'",
                    arguments: [bindingGenerationId.uuidString])
                for row in receipts {
                    try PaneContextStorage.bumpRevision(
                        database, paneId: PaneId(existingUUID: PaneContextStorage.uuid(row, "pane_id")))
                }
                return try PaneContextStorage.changedPresentationSources(database, since: before)
            }
            await agentLineSink(nil, bindingGenerationId)
            await publishAffectedSources(commit)
            await refreshDeadline()
        } catch {
            // Persistent state is unchanged on a failed transaction.
        }
    }

    package func stop() async {
        guard !isStopping else { return }
        isStopping = true
        let retirementDrain = retirementMailbox.state.withLock { mailbox in
            mailbox.accepting = false
            let drain = mailbox.drain
            mailbox.drain = nil
            return drain
        }
        membershipDrain?.cancel()
        membershipReconcile?.cancel()
        await membershipReconcile?.value
        await membershipDrain?.value
        membershipDrain = nil
        await presentationLane?.shutdown()
        retirementWake.finish()
        retirementDrain?.cancel()
        await retirementDrain?.value
        try? await retirementCommit?.value
        try? await drainRetirements()
        _ = try? await opening?.value
        await deadlineScheduler?.shutdown()
        if didOpen {
            let now = wallNow
            let binding = currentBindingGeneration
            let commits = try? await sqliteAccess.write { database in
                let rows = try Row.fetchAll(
                    database,
                    sql: "SELECT pane_id, message_id FROM pane_request WHERE state = 'open' AND waiting = 'blocking'")
                return try rows.map { row in
                    let key = PaneContextMessageKey(
                        paneId: PaneId(existingUUID: try PaneContextStorage.uuid(row, "pane_id")),
                        messageId: AgentMessageId(existingUUID: try PaneContextStorage.uuid(row, "message_id")))
                    return (
                        key,
                        try PaneContextAskSettlement.commit(
                            database, paneId: key.paneId, id: key.messageId, cause: .appStopping, now: now(),
                            currentBindingGeneration: binding)
                    )
                }
            }
            for (key, commit) in commits ?? [] { await acceptSettlement(commit, key: key) }
        }
        for continuations in waiters.values {
            for continuation in continuations.values {
                continuation.yield(.stale)
                continuation.finish()
            }
        }
        waiters.removeAll()
    }
}

/// Opens the existential at a function boundary; the scheduler keeps its existing
/// generic initializer and is still the only clock-erasure owner.
private func makePaneContextDeadlineScheduler<SourceClock: Clock & Sendable>(
    clock: SourceClock,
    onDeadline: @escaping @Sendable () async -> Void
) -> RepositoryRetentionScheduler where SourceClock.Duration == Duration {
    RepositoryRetentionScheduler(clock: clock, onDeadline: onDeadline)
}

extension PaneContextStorage {
    static func expireLines(_ database: Database, now: Date) throws {
        let rows = try Row.fetchAll(
            database, sql: "SELECT pane_id FROM pane_state WHERE kind = 'agentLine' AND stale = 0 AND expires_at <= ?",
            arguments: [try timestamp(now)])
        try database.execute(
            sql: "UPDATE pane_state SET stale = 1 WHERE kind = 'agentLine' AND stale = 0 AND expires_at <= ?",
            arguments: [try timestamp(now)])
        for row in rows { try bumpRevision(database, paneId: PaneId(existingUUID: uuid(row, "pane_id"))) }
    }

    static func hideSettled(_ database: Database, now: Date) throws {
        let panes = try String.fetchAll(
            database, sql: "SELECT pane_id FROM pane_request UNION SELECT pane_id FROM pane_event WHERE kind = 'notice'"
        )
        for text in panes {
            guard let uuid = UUID(uuidString: text) else { throw PaneContextStorageFailure.decode("pane_id") }
            let pane = PaneId(existingUUID: uuid)
            let settled = try messages(database, paneId: pane).filter { $0.settledAt != nil && !$0.displayHidden }
                .sorted { $0.position > $1.position }
            var changed = false
            for (index, message) in settled.enumerated() {
                guard
                    index >= AppPolicies.PaneContext.maximumSettledMessages
                        || message.settledAt.map({
                            $0.addingTimeInterval(AppPolicies.PaneContext.settledMessageLifetime) <= now
                        }) == true
                else { continue }
                let table: String
                switch message.detail.shape {
                case .ask: table = "pane_request"
                case .notice: table = "pane_event"
                }
                try database.execute(
                    sql: "UPDATE \(table) SET display_hidden = 1 WHERE id = ?", arguments: [message.rowId.uuidString])
                changed = true
            }
            if changed { try bumpRevision(database, paneId: pane) }
        }
    }

    static func purgeRetired(_ database: Database, now: Date) throws {
        let panes = try String.fetchAll(
            database, sql: "SELECT pane_id FROM pane_retirement WHERE purge_after <= ?", arguments: [try timestamp(now)]
        )
        for pane in panes {
            for table in [
                "pane_state", "pane_request", "pane_event", "pane_write_order", "pane_epoch_claim",
                "pane_answer_position", "pane_retirement",
            ] {
                try database.execute(sql: "DELETE FROM \(table) WHERE pane_id = ?", arguments: [pane])
            }
        }
    }
}
