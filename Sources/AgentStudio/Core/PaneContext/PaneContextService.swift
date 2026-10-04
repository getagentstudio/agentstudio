import AgentStudioInfrastructure
import Foundation
import GRDB
import Synchronization

struct PaneContextMessageKey: Hashable, Sendable {
    let paneId: PaneId
    let messageId: AgentMessageId
}

struct PaneContextRetirementMailbox: Sendable {
    var accepting = true
    var pending = Set<PaneId>()
    var retired = Set<PaneId>()
    var drain: Task<Void, Never>?
}

final class PaneContextRetirementMailboxBox: Sendable {
    let state = Mutex(PaneContextRetirementMailbox())
}

struct PaneContextStartupCommit: Sendable {
    let settlements: [(PaneContextMessageKey, PaneContextSettlementCommit)]
}

/// Messages and current values share one application-local transaction boundary.
package actor PaneContextService: PaneContextDetailReading, PaneContextPersonActing {
    let sqliteAccess: any PaneContextSQLiteAccess
    let clock: any Clock<Duration> & Sendable
    let wallNow: @Sendable () -> Date
    let membership: any PaneContextMembershipReading
    let currentBindingGeneration: @Sendable (PaneId, Database) throws -> UUID?
    let sessionSummary: @Sendable (PaneId) async throws -> SessionSummary?
    let openAskSink: @Sendable (PaneContextOpenAskUpdate) async -> Void
    let agentLineSink: @Sendable (AgentLineWork?, UUID) async -> Void
    let actionRunner: @Sendable (MessageAction) async -> MessageActionResult
    nonisolated let presentationLane: PaneContextPublicationLane?

    nonisolated let retirementMailbox = PaneContextRetirementMailboxBox()
    nonisolated let retirementWake: AsyncStream<Void>.Continuation
    var retirementCommit: Task<Void, Error>?
    var retirementCommitGeneration: UInt64 = 0
    var opening: Task<PaneContextStartupCommit, Error>?
    var openingToken: UUID?
    var didOpen = false
    var isStopping = false
    var deadlineScheduler: RepositoryRetentionScheduler?
    var deadlineRefreshGeneration: UInt64 = 0
    var waiters: [PaneContextMessageKey: [UUID: AsyncStream<AskOutcome>.Continuation]] = [:]
    var detailVersions: [PaneId: (version: PaneContextDetailVersion, revision: PaneContextRevision)] = [:]
    var membershipDrain: Task<Void, Never>?
    var membershipReconcile: Task<Void, Never>?

    package init(
        sqliteAccess: any PaneContextSQLiteAccess,
        clock: any Clock<Duration> & Sendable,
        wallNow: @escaping @Sendable () -> Date,
        membership: any PaneContextMembershipReading,
        currentBindingGeneration: @escaping @Sendable (PaneId, Database) throws -> UUID?,
        sessionSummary: @escaping @Sendable (PaneId) async throws -> SessionSummary? = { _ in nil },
        openAskSink: @escaping @Sendable (PaneContextOpenAskUpdate) async -> Void = { _ in },
        agentLineSink: @escaping @Sendable (AgentLineWork?, UUID) async -> Void = { _, _ in },
        presentationLane: PaneContextPublicationLane? = nil,
        actionRunner: @escaping @Sendable (MessageAction) async -> MessageActionResult = { _ in
            .unavailable(.databaseUnavailable)
        }
    ) {
        self.sqliteAccess = sqliteAccess
        self.clock = clock
        self.wallNow = wallNow
        self.membership = membership
        self.currentBindingGeneration = currentBindingGeneration
        self.sessionSummary = sessionSummary
        self.openAskSink = openAskSink
        self.agentLineSink = agentLineSink
        self.actionRunner = actionRunner
        self.presentationLane = presentationLane
        let wake = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        retirementWake = wake.continuation
        let retirementMailbox = self.retirementMailbox
        retirementMailbox.state.withLock { mailbox in
            mailbox.drain = Task { [weak self, retirementStream = wake.stream] in
                for await _ in retirementStream {
                    guard !Task.isCancelled, let self else { return }
                    do { try await self.ensureOpen() } catch {
                        // Keep pending retirements for the next demand or shutdown.
                    }
                }
            }
        }
    }

    func ensureOpen() async throws {
        guard !isStopping else { throw PaneContextStorageFailure.decode("serviceStopped") }
        if opening == nil {
            let sqliteAccess = self.sqliteAccess
            let wallNow = self.wallNow
            let binding = currentBindingGeneration
            openingToken = UUIDv7.generate()
            opening = Task {
                try await sqliteAccess.write { database in
                    let now = wallNow()
                    let rows = try Row.fetchAll(
                        database,
                        sql:
                            "SELECT pane_id, message_id FROM pane_request WHERE state = 'open' AND waiting = 'blocking'"
                    )
                    let settlements = try rows.map { row in
                        let key = PaneContextMessageKey(
                            paneId: PaneId(existingUUID: try PaneContextStorage.uuid(row, "pane_id")),
                            messageId: AgentMessageId(existingUUID: try PaneContextStorage.uuid(row, "message_id"))
                        )
                        return (
                            key,
                            try PaneContextAskSettlement.commit(
                                database, paneId: key.paneId, id: key.messageId, cause: .appStopping, now: now,
                                currentBindingGeneration: binding)
                        )
                    }
                    return PaneContextStartupCommit(settlements: settlements)
                }
            }
        }
        guard let opening else { return }
        let token = openingToken
        let startup: PaneContextStartupCommit
        do { startup = try await opening.value } catch {
            if token == openingToken {
                self.opening = nil
                openingToken = nil
            }
            throw error
        }
        guard !didOpen else {
            try await drainRetirements()
            return
        }
        didOpen = true
        for (key, commit) in startup.settlements { await acceptSettlement(commit, key: key) }
        try await drainRetirements()
        await refreshDeadline()
        await startPresentation()
    }

    func isPendingRetirement(_ paneId: PaneId) -> Bool {
        retirementMailbox.state.withLock { $0.retired.contains(paneId) }
    }

    func scopeAdmission() -> @Sendable (PaneId, Database) throws -> Bool {
        let membership = self.membership
        let mailbox = retirementMailbox
        return { paneId, database in
            guard membership.sources(for: paneId) != nil, !mailbox.state.withLock({ $0.retired.contains(paneId) })
            else { return false }
            return try !PaneContextStorage.isRetired(database, paneId: paneId)
        }
    }

    func acceptSettlement(_ commit: PaneContextSettlementCommit, key: PaneContextMessageKey) async {
        if let outcome = commit.outcome, let continuations = waiters.removeValue(forKey: key) {
            for continuation in continuations.values {
                continuation.yield(outcome)
                continuation.finish()
            }
        }
        if let update = commit.openAsks { await openAskSink(update) }
    }

    func storageFailure(_ error: any Error, writing: Bool = false) -> StorageFailureSummary {
        if let failure = error as? PaneContextStorageFailure {
            switch failure {
            case .decode(let field): return .decodeFailed(field)
            }
        }
        return writing ? .commitFailed : .databaseUnavailable
    }

    package func openAskSummaries() async -> [PaneContextOpenAskUpdate] {
        do {
            try await ensureOpen()
            return try await sqliteAccess.read { try PaneContextStorage.openAskUpdates($0) }
        } catch { return [] }
    }

    package func waitForAskOutcome(messageId: AgentMessageId, paneId: PaneId) async -> AskOutcome {
        let key = PaneContextMessageKey(paneId: paneId, messageId: messageId)
        let token = UUIDv7.generate()
        let channel = AsyncStream<AskOutcome>.makeStream(bufferingPolicy: .bufferingNewest(1))
        waiters[key, default: [:]][token] = channel.continuation
        defer {
            waiters[key]?.removeValue(forKey: token)
            if waiters[key]?.isEmpty == true { waiters.removeValue(forKey: key) }
            channel.continuation.finish()
        }
        do {
            try await ensureOpen()
            let outcome = try await sqliteAccess.read { database -> AskOutcome? in
                guard let message = try PaneContextStorage.message(database, paneId: paneId, messageId: messageId),
                    case .ask(_, _, _, let state) = message.detail.shape
                else { return .stale }
                return PaneContextStorage.outcome(state)
            }
            if let outcome {
                channel.continuation.yield(outcome)
                channel.continuation.finish()
            }
        } catch { return .stale }
        var iterator = channel.stream.makeAsyncIterator()
        return await iterator.next() ?? .stale
    }

    package func runAction(_ request: MessageActionRequest) async -> MessageActionResult {
        do {
            try await ensureOpen()
            let admitted = try await sqliteAccess.read { database in
                try PaneContextStorage.message(database, paneId: request.paneId, messageId: request.messageId)?.detail
                    .actions.contains(request.action) == true
            }
            guard admitted, membership.sources(for: request.paneId) != nil, !isPendingRetirement(request.paneId) else {
                return .notFound
            }
            return await actionRunner(request.action)
        } catch { return .unavailable(storageFailure(error)) }
    }
}
