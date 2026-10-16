import AgentStudioInfrastructure
import Foundation
import GRDB

struct PaneContextSendCommit: Sendable {
    let result: PaneMessageSendResult
    let openAsks: PaneContextOpenAskUpdate?
}

extension PaneContextService {
    package func send(
        _ request: PaneMessageSendRequest, commitParticipant: (any PaneContextCommitParticipant)? = nil
    ) async -> PaneMessageSendResult {
        if let refusal = PaneContextAdmission.refusal(request) { return .refused(refusal) }
        do {
            try await ensureOpen()
            let admission = scopeAdmission()
            let binding = currentBindingGeneration
            let now = wallNow
            let commit = try await sqliteAccess.write { database -> PaneContextSendCommit in
                func refused(_ reason: PaneContextWriteRefusal) -> PaneContextSendCommit {
                    PaneContextSendCommit(result: .refused(reason), openAsks: nil)
                }
                guard try admission(request.paneId, database) else { return refused(.paneGone) }
                if let existing = try PaneContextStorage.message(
                    database, paneId: request.paneId, messageId: request.messageId)
                {
                    let sameIntent = try PaneContextStorage.sameIntent(request, stored: existing, database: database)
                    if sameIntent { try commitParticipant?.commit(in: database) }
                    return PaneContextSendCommit(
                        result: sameIntent ? .existing(request.messageId) : .refused(.conflict), openAsks: nil)
                }
                let isAsk: Bool
                switch request.shape {
                case .ask: isAsk = true
                case .notice: isAsk = false
                }
                if isAsk {
                    guard case .session(_, _, let generation) = request.sender else { return refused(.bindingRequired) }
                    guard try binding(request.paneId, database) == generation else { return refused(.writerReplaced) }
                }
                let count =
                    try Int.fetchOne(
                        database,
                        sql: isAsk
                            ? "SELECT COUNT(*) FROM pane_request WHERE pane_id = ? AND state = 'open'"
                            : "SELECT COUNT(*) FROM pane_event WHERE pane_id = ? AND kind = 'notice' AND notice_state = 'unread'",
                        arguments: [request.paneId.uuidString]) ?? 0
                let cap = isAsk ? AppPolicies.PaneContext.maximumOpenAsks : AppPolicies.PaneContext.maximumUnreadNotices
                guard count < cap else { return refused(.tooLarge(isAsk ? .openAsks : .unreadNotices)) }
                try PaneContextStorage.recordMessage(request, database: database, now: now())
                try commitParticipant?.commit(in: database)
                let update =
                    isAsk
                    ? try PaneContextStorage.openAskUpdate(
                        database, paneId: request.paneId, sender: request.sender, advancing: true) : nil
                return PaneContextSendCommit(result: .created(request.messageId), openAsks: update)
            }
            if let update = commit.openAsks { await openAskSink(update) }
            if case .created = commit.result {
                await refreshDeadline()
                await publishAffectedSources([request.paneId])
            }
            return commit.result
        } catch { return .unavailable(storageFailure(error, writing: true)) }
    }

    package func settleAsk(_ messageId: AgentMessageId, paneId: PaneId, cause: AskSettlementCause) async
        -> AskSettlementResult
    {
        do {
            try await ensureOpen()
            let now = wallNow
            let binding = currentBindingGeneration
            let commit = try await sqliteAccess.write { database in
                try PaneContextAskSettlement.commit(
                    database, paneId: paneId, id: messageId, cause: cause, now: now(),
                    currentBindingGeneration: binding)
            }
            await acceptSettlement(commit, key: PaneContextMessageKey(paneId: paneId, messageId: messageId))
            await refreshDeadline()
            await publishAffectedSources([paneId])
            return commit.result
        } catch { return .unavailable(storageFailure(error, writing: true)) }
    }

    package func answer(_ request: AnswerAskRequest) async -> AnswerAskResult {
        switch await settleAsk(
            request.messageId, paneId: request.paneId, cause: .answer(by: request.by, value: request.value))
        {
        case .settled(.answered): return .answered
        case .refused(let refusal): return .refused(refusal)
        case .notFound: return .refused(.notFound)
        case .unavailable(let failure): return .unavailable(failure)
        case .alreadySettled(let state), .settled(let state): return .refused(PaneContextStorage.refusal(state))
        case .stillOpen: return .refused(.notFound)
        }
    }

    package func dismiss(messageId: AgentMessageId, paneId: PaneId) async -> DismissResult {
        do {
            try await ensureOpen()
            let now = wallNow
            let binding = currentBindingGeneration
            let commit = try await sqliteAccess.write { database -> PaneContextDismissCommit in
                guard let message = try PaneContextStorage.message(database, paneId: paneId, messageId: messageId)
                else {
                    return PaneContextDismissCommit(result: .notFound, settlement: nil)
                }
                if case .ask = message.detail.shape {
                    let settlement = try PaneContextAskSettlement.commit(
                        database, paneId: paneId, id: messageId, cause: .dismiss, now: now(),
                        currentBindingGeneration: binding)
                    let result: DismissResult
                    switch settlement.result {
                    case .settled: result = .done
                    case .alreadySettled(let state):
                        result = .alreadySettled(.ask(try PaneContextStorage.requireTerminal(state)))
                    default: result = .notFound
                    }
                    return PaneContextDismissCommit(result: result, settlement: settlement)
                }
                if case .notice(let state) = message.detail.shape {
                    if state == .dismissed {
                        return PaneContextDismissCommit(result: .alreadySettled(.notice(.dismissed)), settlement: nil)
                    }
                    if state == .withdrawn {
                        return PaneContextDismissCommit(result: .alreadySettled(.notice(.withdrawn)), settlement: nil)
                    }
                }
                try PaneContextStorage.setNoticeState(
                    database, message: message, state: "dismissed", change: "dismissal", now: now())
                return PaneContextDismissCommit(result: .done, settlement: nil)
            }
            if let settlement = commit.settlement {
                await acceptSettlement(settlement, key: PaneContextMessageKey(paneId: paneId, messageId: messageId))
                await refreshDeadline()
            }
            if commit.result == .done { await publishAffectedSources([paneId]) }
            return commit.result
        } catch { return .unavailable(storageFailure(error, writing: true)) }
    }

    package func markRead(messageId: AgentMessageId, paneId: PaneId) async -> MarkReadResult {
        do {
            try await ensureOpen()
            let now = wallNow
            let result: MarkReadResult = try await sqliteAccess.write { database in
                guard let message = try PaneContextStorage.message(database, paneId: paneId, messageId: messageId),
                    case .notice(let state) = message.detail.shape
                else { return .notFound }
                guard state == .unread else { return .alreadyRead }
                try PaneContextStorage.setNoticeState(
                    database, message: message, state: "read", change: nil, now: now())
                return .done
            }
            if result == .done { await publishAffectedSources([paneId]) }
            return result
        } catch { return .unavailable(storageFailure(error, writing: true)) }
    }

    package func withdraw(messageId: AgentMessageId, paneId: PaneId, writer: AgentMessageSender) async
        -> PaneMessageWithdrawResult
    {
        do {
            try await ensureOpen()
            let now = wallNow
            let binding = currentBindingGeneration
            let commit = try await sqliteAccess.write { database -> PaneContextWithdrawCommit in
                guard let message = try PaneContextStorage.message(database, paneId: paneId, messageId: messageId)
                else { return PaneContextWithdrawCommit(result: .notFound, settlement: nil) }
                guard PaneContextStorage.writerKey(message.detail.sender) == PaneContextStorage.writerKey(writer) else {
                    return PaneContextWithdrawCommit(result: .refused(.notSender), settlement: nil)
                }
                switch message.detail.shape {
                case .notice(let state):
                    switch state {
                    case .read: return PaneContextWithdrawCommit(result: .refused(.noticeAlreadyRead), settlement: nil)
                    case .dismissed:
                        return PaneContextWithdrawCommit(result: .alreadySettled(.notice(.dismissed)), settlement: nil)
                    case .withdrawn:
                        return PaneContextWithdrawCommit(result: .alreadySettled(.notice(.withdrawn)), settlement: nil)
                    case .unread:
                        try PaneContextStorage.setNoticeState(
                            database, message: message, state: "withdrawn", change: "withdrawal", now: now())
                        return PaneContextWithdrawCommit(result: .withdrawn, settlement: nil)
                    }
                case .ask:
                    let settlement = try PaneContextAskSettlement.commit(
                        database, paneId: paneId, id: messageId, cause: .withdraw(writer: message.detail.sender),
                        now: now(), currentBindingGeneration: binding)
                    let result: PaneMessageWithdrawResult
                    switch settlement.result {
                    case .settled(.withdrawn): result = .withdrawn
                    case .alreadySettled(let state), .settled(let state):
                        result = .alreadySettled(.ask(try PaneContextStorage.requireTerminal(state)))
                    default: result = .notFound
                    }
                    return PaneContextWithdrawCommit(result: result, settlement: settlement)
                }
            }
            if let settlement = commit.settlement {
                await acceptSettlement(settlement, key: PaneContextMessageKey(paneId: paneId, messageId: messageId))
            }
            await refreshDeadline()
            if commit.result == .withdrawn { await publishAffectedSources([paneId]) }
            return commit.result
        } catch { return .unavailable(storageFailure(error, writing: true)) }
    }
}

struct PaneContextDismissCommit: Sendable {
    let result: DismissResult
    let settlement: PaneContextSettlementCommit?
}

struct PaneContextWithdrawCommit: Sendable {
    let result: PaneMessageWithdrawResult
    let settlement: PaneContextSettlementCommit?
}

extension PaneContextStorage {
    static func requireTerminal(_ state: AskState) throws -> AskTerminalState {
        switch state {
        case .open: throw PaneContextStorageFailure.decode("state")
        case .answered(let by, let value, let receipt): return .answered(by: by, value: value, receipt: receipt)
        case .handedBack: return .handedBack
        case .dismissed: return .dismissed
        case .expired: return .expired
        case .withdrawn: return .withdrawn
        case .stale: return .stale
        }
    }

    static func setNoticeState(
        _ database: Database, message: PaneContextStoredMessage, state: String, change: String?, now: Date
    ) throws {
        try transitionNoticeState(database, message: message, state: state, change: change, now: now)
        try bumpRevision(database, paneId: message.detail.sourcePaneId)
    }

    static func transitionNoticeState(
        _ database: Database, message: PaneContextStoredMessage, state: String, change: String?, now: Date
    ) throws {
        if let change { _ = try appendChange(database, message: message, kind: change, now: now) }
        let position = try nextPosition(database, paneId: message.detail.sourcePaneId)
        try database.execute(
            sql: "UPDATE pane_event SET notice_state = ?, settled_at = ?, position = ? WHERE id = ?",
            arguments: [state, try timestamp(now), try integer(position, field: "position"), message.rowId.uuidString])
    }
}
