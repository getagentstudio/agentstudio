import AgentStudioAppIPC
import AgentStudioCLIStore
import AgentStudioCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import Darwin
import Foundation
import Synchronization

/// The app reads the CLI's immutable outbox. Its own local.sqlite cursor joins
/// the existing pane-context transaction; a retry holds the rest of the prefix.
actor PaneCLIOutboxDrain {
    enum RefusalReason: String, Sendable {
        case malformedEnvelope
        case ineligibleMethod
        case ineligibleVariant
        case foreignPane
        case unknownKind
        case invalidStoredRow
        case qualificationRejected
        case foreignStore
    }

    struct DrainReport: Equatable, Sendable {
        var readOutcome: ClosedAppReadOutcome = .unreadable(.cancelled)
        var admittedEntryCount = 0
        var refusedEntryCount = 0
        var malformedEntryCount = 0
        var retryableEntryCount = 0
        var refusedStoreCount = 0
        var importedLegacyLineCount = 0

        var hasWork: Bool {
            admittedEntryCount + refusedEntryCount + malformedEntryCount + retryableEntryCount
                + refusedStoreCount + importedLegacyLineCount > 0
        }
    }

    let ingestion: SessionsIngestion
    let restoreEvidence: any AgentStudioSessions.ClosedAppRestoreEvidenceParticipant
    let paneExists: @Sendable (UUID) async throws -> Bool
    let admission: AgentStudioIPCPaneContextAdapter
    let sqliteAccess: any SessionsSQLiteAccess
    private let expectedChannel: CLIStoreChannel
    let maximumPayloadBytes: Int
    private let refusalProbe: @Sendable (RefusalReason) -> Void
    let descriptors: [String: IPCAnyMethodDescriptor]

    init(
        admission: AgentStudioIPCPaneContextAdapter,
        sqliteAccess: any SessionsSQLiteAccess,
        expectedChannel: CLIStoreChannel,
        ingestion: SessionsIngestion, restoreEvidence: any AgentStudioSessions.ClosedAppRestoreEvidenceParticipant,
        paneExists: @escaping @Sendable (UUID) async throws -> Bool,
        maximumPayloadBytes: Int = AppPolicies.IPC.offlineNoticeMaximumPayloadBytes,
        refusalProbe: @escaping @Sendable (RefusalReason) -> Void = { _ in }
    ) throws {
        self.ingestion = ingestion
        self.restoreEvidence = restoreEvidence
        self.paneExists = paneExists
        self.admission = admission
        self.sqliteAccess = sqliteAccess
        self.expectedChannel = expectedChannel
        self.maximumPayloadBytes = maximumPayloadBytes
        self.refusalProbe = refusalProbe
        descriptors = Dictionary(
            uniqueKeysWithValues: try IPCBuiltInMethodCatalog.offlineNotificationDescriptors(
                examples: .init(illustrativeIdentifier: UUIDv7.generate())
            ).map { ($0.metadata.name, $0) })
    }

    func drain(storeURL: URL, legacySpoolDirectory: URL? = nil) async -> DrainReport {
        // This is a one-time import input, never an active spool transport.
        let legacyDirectory = legacySpoolDirectory ?? storeURL.deletingLastPathComponent().appending(path: "spool/v2")
        let report = await importLegacyFiles(in: legacyDirectory)
        guard !Task.isCancelled else { return report }
        switch await prepareRead(storeURL: storeURL, report: report) {
        case .finished(let report): return report
        case .ready(let read): return await importBatch(read)
        }
    }

    private func prepareRead(storeURL: URL, report initialReport: DrainReport) async -> OutboxReadPreparation {
        var report = initialReport
        let storeState = await Self.readStoreState(url: storeURL, channel: expectedChannel)
        let presentId: UUID?
        switch storeState {
        case .present(let identity): presentId = identity.storeID
        case .absent: presentId = nil
        case .failed(let failure):
            switch failure {
            case .channelMismatch, .invalidIdentity, .superseded: presentId = nil
            case .busy:
                report.retryableEntryCount += 1
                report.readOutcome = .incomplete(heldAtId: nil)
                return .finished(report)
            default:
                report.readOutcome = .unreadable(.store(failure))
                return .finished(report)
            }
        }
        let historyLost: Bool
        do { historyLost = try await checkHistory(presentStoreId: presentId) } catch {
            report.retryableEntryCount += 1
            report.readOutcome = .unreadable(.localDatabase)
            return .finished(report)
        }
        let identity: CLIStoreIdentity
        switch storeState {
        case .present(let value): identity = value
        case .absent:
            report.readOutcome = historyLost ? .historyLost(thenComplete: nil) : .verifiedEmpty
            return .finished(report)
        case .failed(let failure):
            report.refusedStoreCount += 1
            refusalProbe(.foreignStore)
            report.readOutcome = historyLost ? .historyLost(thenComplete: nil) : .unreadable(.store(failure))
            return .finished(report)
        }
        let storeID = identity.storeID
        let cursor: Int64
        do {
            cursor = try await sqliteAccess.read { try CLIOutboxCursorCommitParticipant.read(in: $0, storeID: storeID) }
        } catch {
            report.retryableEntryCount += 1
            report.readOutcome = .unreadable(.localDatabase)
            return .finished(report)
        }
        let batch: OutboxIntakeBatch
        switch await Self.readBatch(url: storeURL, channel: expectedChannel, after: cursor) {
        case .success(let value): batch = value
        case .failure(let failure):
            report.retryableEntryCount += 1
            if case .busy = failure {
                report.readOutcome = .incomplete(heldAtId: cursor)
            } else {
                report.readOutcome = .unreadable(.store(failure))
            }
            return .finished(report)
        }
        // A replaced file has a different cursor namespace. Do not apply a
        // prefix read against the identity of the file it replaced.
        guard batch.identity == identity else {
            report.refusedStoreCount += 1
            refusalProbe(.foreignStore)
            report.readOutcome = .incomplete(heldAtId: cursor)
            return .finished(report)
        }
        let lifecycle: [Int64: ClosedAppOutboxItem]
        do { lifecycle = try await lifecycleItems(in: batch.entries) } catch {
            report.readOutcome = .unreadable(.membership)
            return .finished(report)
        }
        return .ready(
            .init(report: report, storeID: storeID, batch: batch, lifecycle: lifecycle, historyLost: historyLost))
    }

    private func importBatch(_ read: PreparedOutboxRead) async -> DrainReport {
        var report = read.report
        let batch = read.batch
        let storeID = read.storeID
        let lifecycle = read.lifecycle
        let historyLost = read.historyLost
        let items =
            (batch.entries.map { OutboxIntakeItem.entry($0) }
            + batch.issues.map { OutboxIntakeItem.invalid($0) }).sorted { $0.id < $1.id }
        for item in items {
            guard !Task.isCancelled else { return report }
            let participant = CLIOutboxCursorCommitParticipant(storeID: storeID, lastHandledID: item.id)
            let disposition: NoticeDisposition
            switch item {
            case .invalid(let issue):
                do { try await importLifecycle(.refused(paneId: nil), cursor: participant) } catch {
                    report.retryableEntryCount += 1
                    report.readOutcome = .incomplete(heldAtId: item.id)
                    return report
                }
                report.malformedEntryCount += 1
                refusalProbe(issue.field == .kind ? .unknownKind : .invalidStoredRow)
                continue
            case .entry(.sessionLifecycle(let entry)):
                guard let lifecycleItem = lifecycle[entry.id] else { return report }
                do { try await importLifecycle(lifecycleItem, cursor: participant) } catch {
                    report.retryableEntryCount += 1
                    report.readOutcome = .incomplete(heldAtId: item.id)
                    return report
                }
                if case .refused = lifecycleItem {
                    report.refusedEntryCount += 1
                    refusalProbe(.qualificationRejected)
                } else {
                    report.admittedEntryCount += 1
                }
                continue
            case .entry(.notice(let notice)):
                disposition = await admit(
                    payload: notice.payloadJSON, paneID: notice.paneID,
                    messageID: notice.messageID, participant: participant)
            }
            switch disposition {
            case .admitted:
                // Participant already committed beside the notice effect.
                report.admittedEntryCount += 1
            case .malformed(let reason):
                guard await commitCursor(participant) else {
                    report.retryableEntryCount += 1
                    report.readOutcome = .incomplete(heldAtId: item.id)
                    return report
                }
                report.malformedEntryCount += 1
                refusalProbe(reason)
            case .refused:
                guard await commitCursor(participant) else {
                    report.retryableEntryCount += 1
                    report.readOutcome = .incomplete(heldAtId: item.id)
                    return report
                }
                report.refusedEntryCount += 1
                refusalProbe(.qualificationRejected)
            case .retryable:
                report.retryableEntryCount += 1
                report.readOutcome = .incomplete(heldAtId: item.id)
                return report
            }
        }
        report.readOutcome =
            historyLost ? .historyLost(thenComplete: batch.lastReadID) : .complete(throughId: batch.lastReadID)
        return report
    }

    private func commitCursor(_ participant: CLIOutboxCursorCommitParticipant) async -> Bool {
        do {
            try await sqliteAccess.write { try participant.commit(in: $0) }
            return true
        } catch { return false }
    }

    private func admit(
        payload: String,
        paneID: UUID,
        messageID: UUID?,
        participant: (any PaneContextCommitParticipant)?
    ) async -> NoticeDisposition {
        guard let request = try? JSONRPCCodec.decodeRequest(payload, maxBytes: maximumPayloadBytes) else {
            return .malformed(.malformedEnvelope)
        }
        guard let descriptor = descriptors[request.method], descriptor.metadata.offlineEligibility == .noticeOnly else {
            return .malformed(.ineligibleMethod)
        }
        guard let parameters = request.params,
            let bytes = try? JSONEncoder().encode(parameters),
            let normalized = try? descriptor.normalizeParameters(bytes)
        else { return .malformed(.malformedEnvelope) }
        do {
            guard request.method == "pane.message.send" else { return .malformed(.ineligibleMethod) }
            let params = try JSONDecoder().decode(IPCPaneMessageSendParams.self, from: normalized.data)
            guard case .notice = params.shape else { return .malformed(.ineligibleVariant) }
            guard matchesPane(params.handle, paneID: paneID) else { return .malformed(.foreignPane) }
            guard messageID == nil || messageID == params.messageId else { return .malformed(.malformedEnvelope) }
            _ = try await admission.sendMessage(paneId: paneID, params: params, commitParticipant: participant)
            return .admitted
        } catch let error as AppIPCPaneContextError {
            switch error.reason {
            case .unavailable: return .retryable
            default: return .refused
            }
        } catch {
            // Admission can fail before its effect/cursor transaction commits.
            // Preserve the prefix for the next drain instead of consuming it.
            return .retryable
        }
    }

    private func matchesPane(_ handle: String, paneID: UUID) -> Bool { handle == "self" || handle == paneID.uuidString }

    @concurrent private nonisolated static func readStoreState(url: URL, channel: CLIStoreChannel) async
        -> OutboxStoreState
    {
        var information = stat()
        if lstat(url.path, &information) != 0 {
            return errno == ENOENT ? .absent : .failed(.unavailable)
        }
        switch CLIStore.openReader(url: url, expectedChannel: channel) {
        case .success(let reader):
            defer { try? reader.close() }
            return .present(reader.identity)
        case .failure(let failure): return .failed(failure)
        }
    }

    @concurrent private nonisolated static func readBatch(url: URL, channel: CLIStoreChannel, after cursor: Int64) async
        -> Result<OutboxIntakeBatch, CLIStoreFailure>
    {
        let issues = OutboxDecodeIssueRecorder()
        return CLIStore.openReader(
            url: url, expectedChannel: channel, logDecodeIssue: { issues.record($0) }
        ).flatMap { reader in
            defer { try? reader.close() }
            return reader.readOutbox(after: cursor).map { batch in
                OutboxIntakeBatch(
                    identity: reader.identity, entries: batch.entries, issues: issues.values,
                    lastReadID: batch.lastReadID)
            }
        }
    }

    private func importLegacyFiles(in directory: URL) async -> DrainReport {
        var report = DrainReport()
        for file in await LegacyPaneNoticeImport.readFiles(in: directory, maximumPayloadBytes: maximumPayloadBytes) {
            var completed = true
            report.malformedEntryCount += file.malformedLineCount
            for _ in 0..<file.malformedLineCount { refusalProbe(.malformedEnvelope) }
            for payload in file.payloads {
                guard !Task.isCancelled else { return report }
                switch await admit(payload: payload, paneID: file.paneID, messageID: nil, participant: nil) {
                case .admitted: report.importedLegacyLineCount += 1
                case .malformed(let reason):
                    report.malformedEntryCount += 1
                    refusalProbe(reason)
                case .refused:
                    report.refusedEntryCount += 1
                    refusalProbe(.qualificationRejected)
                case .retryable:
                    report.retryableEntryCount += 1
                    completed = false
                }
                if !completed { break }
            }
            if completed { await LegacyPaneNoticeImport.removeConsumedFile(file.url) }
        }
        return report
    }
}

private enum NoticeDisposition {
    case admitted
    case malformed(PaneCLIOutboxDrain.RefusalReason)
    case refused, retryable
}

private enum OutboxIntakeItem {
    case entry(CLIOutboxEntry)
    case invalid(CLIStoreDecodeIssue)
    var id: Int64 {
        switch self {
        case .entry(let entry): entry.id
        case .invalid(let issue): issue.rowID
        }
    }
}

private struct OutboxIntakeBatch: Sendable {
    let identity: CLIStoreIdentity
    let entries: [CLIOutboxEntry]
    let issues: [CLIStoreDecodeIssue]
    let lastReadID: Int64
}

private final class OutboxDecodeIssueRecorder: Sendable {
    private let recorded = Mutex<[CLIStoreDecodeIssue]>([])
    func record(_ issue: CLIStoreDecodeIssue) { recorded.withLock { $0.append(issue) } }
    var values: [CLIStoreDecodeIssue] { recorded.withLock { $0 } }
}

private enum OutboxStoreState: Sendable {
    case absent
    case present(CLIStoreIdentity)
    case failed(CLIStoreFailure)
}

private enum OutboxReadPreparation {
    case finished(PaneCLIOutboxDrain.DrainReport)
    case ready(PreparedOutboxRead)
}

private struct PreparedOutboxRead {
    let report: PaneCLIOutboxDrain.DrainReport
    let storeID: UUID
    let batch: OutboxIntakeBatch
    let lifecycle: [Int64: ClosedAppOutboxItem]
    let historyLost: Bool
}
