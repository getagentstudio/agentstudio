import AgentStudioInfrastructure
import Foundation
import GRDB

extension PaneContextService {
    package func claimEpoch(_ request: PaneEpochClaimRequest) async -> PaneEpochClaimResult {
        do {
            try await ensureOpen()
            let admission = scopeAdmission()
            let binding = currentBindingGeneration
            let now = wallNow
            return try await sqliteAccess.write { database in
                guard try admission(request.paneId, database) else { return .refused(.paneGone) }
                if case .session(_, _, let generation) = request.writer,
                    try binding(request.paneId, database) != generation
                {
                    return .refused(.writerReplaced)
                }
                return try PaneContextStorage.claimEpoch(request, database: database, now: now())
            }
        } catch { return .unavailable(storageFailure(error, writing: true)) }
    }

    package func setTitle(_ request: PaneTitleWriteRequest) async -> PaneOrderedWriteResult {
        if (request.text?.utf8.count ?? 0) > AppPolicies.PaneContext.maximumTitleBytes {
            return .refused(.tooLarge(.title))
        }
        do {
            try await ensureOpen()
            let admission = scopeAdmission()
            let binding = currentBindingGeneration
            let now = wallNow
            let result: PaneOrderedWriteResult = try await sqliteAccess.write { database in
                guard try admission(request.paneId, database) else { return .refused(.paneGone) }
                if case .session(_, _, let generation) = request.writer,
                    try binding(request.paneId, database) != generation
                {
                    return .stale(.writerReplaced)
                }
                if let stale = try PaneContextStorage.admitWrite(
                    request.writeNumber, paneId: request.paneId, writer: request.writer, stream: .title,
                    database: database)
                {
                    return .stale(stale)
                }
                try PaneContextStorage.writeTitle(request, database: database, now: now())
                return .applied
            }
            if result == .applied { await publishAffectedSources([request.paneId]) }
            return result
        } catch { return .unavailable(storageFailure(error, writing: true)) }
    }

    package func setLine(_ request: PaneLineWriteRequest) async -> PaneOrderedWriteResult {
        if let refusal = PaneContextAdmission.lineRefusal(request.line) { return .refused(refusal) }
        do {
            try await ensureOpen()
            let admission = scopeAdmission()
            let binding = currentBindingGeneration
            let now = wallNow
            let result: PaneOrderedWriteResult = try await sqliteAccess.write { database in
                guard try admission(request.paneId, database) else { return .refused(.paneGone) }
                if case .session(_, _, let generation) = request.writer,
                    try binding(request.paneId, database) != generation
                {
                    return .stale(.writerReplaced)
                }
                if let stale = try PaneContextStorage.admitWrite(
                    request.writeNumber, paneId: request.paneId, writer: request.writer, stream: .line,
                    database: database)
                {
                    return .stale(stale)
                }
                try PaneContextStorage.writeLine(request, database: database, now: now())
                return .applied
            }
            if result == .applied {
                if case .session(_, _, let generation) = request.writer {
                    await agentLineSink(request.line?.work, generation)
                }
                await refreshDeadline()
                await publishAffectedSources([request.paneId])
            }
            return result
        } catch { return .unavailable(storageFailure(error, writing: true)) }
    }
}
