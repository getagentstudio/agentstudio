import AgentStudioInfrastructure
import Foundation
import GRDB

struct PaneContextDetailSnapshot: Sendable {
    let title: String?
    let line: AgentLineDetail?
    let sourceRevisions: [PaneContextRevision]
    let messages: [[PaneContextStoredMessage]]
    let initialCursors: [LiveMessageCursor?]
}

struct PaneContextDetailVersion: Sendable, Equatable {
    let sources: [PaneId]
    let membershipRevision: UInt64?
    let sourceRevisions: [PaneContextRevision]
    let session: SessionSummary?
}

extension PaneContextService {
    package func readDetail(_ request: PaneContextReadRequest) async -> PaneContextReadResult {
        await readDetail(request, maximumDetailBytes: AppPolicies.PaneContext.maximumDetailBytes)
    }

    package func readDetail(_ request: PaneContextReadRequest, maximumDetailBytes: Int) async -> PaneContextReadResult {
        do {
            try await ensureOpen()
            guard let view = captureMembershipView(paneId: request.paneId), !isPendingRetirement(request.paneId) else {
                return .paneGone
            }
            let sources = view.sources
            guard sourceIsInView(page: request.page, sources: sources) else { return .sourceNotInView }
            let session = try await sessionSummary(request.paneId)
            let now = wallNow
            let snapshot = try await sqliteAccess.write { database in
                try capturePaneContextDetail(database, paneId: request.paneId, sources: sources, now: now)
            }
            guard let snapshot, !isPendingRetirement(request.paneId) else { return .paneGone }
            let version = PaneContextDetailVersion(
                sources: sources, membershipRevision: view.revision,
                sourceRevisions: snapshot.sourceRevisions, session: session)
            let revision = detailRevision(for: request.paneId, version: version)
            var assembly = PaneContextDetailPageAssembly(
                request: request, sources: sources, snapshot: snapshot, session: session,
                maximumDetailBytes: maximumDetailBytes)
            assembly.reserveSourceMetadata()
            assembly.fillLiveMessages()
            assembly.fillSettledMessages()
            return .detail(assembly.detail(revision: revision))
        } catch { return .unavailable(storageFailure(error)) }
    }

    func detailRevision(for paneId: PaneId, version: PaneContextDetailVersion) -> PaneContextRevision {
        let stored = version.sourceRevisions.reduce(UInt64(0)) { $0 &+ $1.value }
        if let previous = detailVersions[paneId], previous.version == version { return previous.revision }
        let next = PaneContextRevision(max(stored, (detailVersions[paneId]?.revision.value ?? 0) &+ 1))
        detailVersions[paneId] = (version, next)
        return next
    }
}

private func sourceIsInView(page: PaneContextReadPage, sources: [PaneId]) -> Bool {
    switch page {
    case .first: true
    case .more(let source, _), .moreSources(let source): sources.contains(source)
    }
}

func capturePaneContextDetail(
    _ database: Database, paneId: PaneId, sources: [PaneId], now: @Sendable () -> Date
) throws -> PaneContextDetailSnapshot? {
    guard try !PaneContextStorage.isRetired(database, paneId: paneId) else { return nil }
    try PaneContextStorage.expireLines(database, now: now(), sources: sources)
    let messages: [[PaneContextStoredMessage]] = try sources.map { source in
        guard try !PaneContextStorage.isRetired(database, paneId: source) else { return [] }
        let loaded = try PaneContextStorage.messages(database, paneId: source)
        let hidden = try PaneContextStorage.hideSettled(
            database, paneId: source, rows: loaded.map(PaneContextRetentionMessage.init), now: now())
        return loaded.filter { !$0.displayHidden && !hidden.contains(PaneContextRetentionMessage($0).key) }
    }
    let cursors = messages.map { rows -> LiveMessageCursor? in
        guard let newest = rows.filter({ liveRank($0.detail) != nil }).map(\.position).max() else { return nil }
        return LiveMessageCursor(rank: 0, position: newest + 1)
    }
    return PaneContextDetailSnapshot(
        title: try PaneContextStorage.title(database, paneId: paneId),
        line: try PaneContextStorage.line(database, paneId: paneId),
        sourceRevisions: try sources.map { try PaneContextStorage.revision(database, paneId: $0) },
        messages: messages, initialCursors: cursors)
}

/// One read's stack-local accounting; the service remains the read owner.
private struct PaneContextDetailPageAssembly {
    let request: PaneContextReadRequest
    let sources: [PaneId]
    let snapshot: PaneContextDetailSnapshot
    let session: SessionSummary?
    let byteBudget: Int
    let liveMessages: [[PaneContextStoredMessage]]
    let candidateSourceIndices: [Int]
    var byteCount: Int
    var representedSourceIndices: [Int] = []
    var reservedDrawerHeaders = Set<Int>()
    var selectedMessages: [[AgentMessageDetail]]
    var lastCursors: [LiveMessageCursor?]
    var omittedMessages: [[PaneContextStoredMessage]]
    var blockedSources = Set<Int>()

    init(
        request: PaneContextReadRequest, sources: [PaneId], snapshot: PaneContextDetailSnapshot,
        session: SessionSummary?, maximumDetailBytes: Int
    ) {
        self.request = request
        self.sources = sources
        self.snapshot = snapshot
        self.session = session
        byteBudget = max(
            AppPolicies.PaneContext.minimumDetailBytes,
            min(maximumDetailBytes, AppPolicies.PaneContext.maximumDetailBytes))
        byteCount =
            PaneContextDetailBudget.metadataBytes(title: snapshot.title, line: snapshot.line, session: session)
            + PaneContextDetailBudget.truncationHeaderBytes
        let live = snapshot.messages.map { $0.filter { liveRank($0.detail) != nil }.sorted(by: livePrecedes) }
        liveMessages = live
        candidateSourceIndices = Self.candidates(page: request.page, sources: sources, live: live)
        selectedMessages = Array(repeating: [], count: sources.count)
        lastCursors = snapshot.initialCursors
        omittedMessages = Array(repeating: [], count: sources.count)
    }

    private static func candidates(
        page: PaneContextReadPage, sources: [PaneId], live: [[PaneContextStoredMessage]]
    ) -> [Int] {
        switch page {
        case .first: return sources.indices.filter { !live[$0].isEmpty }
        case .moreSources(let after):
            guard let previous = sources.firstIndex(of: after) else { return [] }
            return sources.indices.filter { $0 > previous && !live[$0].isEmpty }
        case .more(let source, _):
            guard let index = sources.firstIndex(of: source) else { return [] }
            return live[index].isEmpty ? [] : [index]
        }
    }

    mutating func reserveSourceMetadata() {
        for index in candidateSourceIndices {
            let header = sources[index] == request.paneId ? 0 : PaneContextDetailBudget.drawerHeaderBytes
            let reserve = header + PaneContextDetailBudget.sourceContinuationBytes
            // Preserve a message slot while reserving each source's omission entry.
            // Even a source contributing zero rows remains discoverable.
            if byteCount + reserve + AppPolicies.PaneContext.maximumMessageDetailBytes > byteBudget { break }
            byteCount += reserve
            representedSourceIndices.append(index)
            if header > 0 { reservedDrawerHeaders.insert(index) }
        }
    }

    mutating func fillLiveMessages() {
        switch request.page {
        case .first, .moreSources:
            for rank in [0, 1] {
                for index in representedSourceIndices {
                    for message in liveMessages[index] where liveRank(message.detail) == rank {
                        appendLive(message, sourceIndex: index)
                    }
                }
            }
        case .more(let source, let cursor):
            guard let index = sources.firstIndex(of: source) else { return }
            lastCursors[index] = cursor
            for message in liveMessages[index] where isAfter(message, cursor: cursor) {
                appendLive(message, sourceIndex: index)
            }
        }
    }

    private mutating func appendLive(_ message: PaneContextStoredMessage, sourceIndex: Int) {
        let cost = PaneContextDetailBudget.messageBytes(message.detail)
        if blockedSources.contains(sourceIndex) || byteCount + cost > byteBudget {
            blockedSources.insert(sourceIndex)
            omittedMessages[sourceIndex].append(message)
            return
        }
        byteCount += cost
        selectedMessages[sourceIndex].append(message.detail)
        lastCursors[sourceIndex] = LiveMessageCursor(rank: liveRank(message.detail) ?? 0, position: message.position)
    }

    mutating func fillSettledMessages() {
        // Settled rows have no live cursor; only the first page spends leftover
        // space on them, after all live rows.
        guard case .first = request.page else { return }
        for index in sources.indices {
            let settled = snapshot.messages[index].filter { liveRank($0.detail) == nil }.sorted {
                $0.position > $1.position
            }
            for message in settled {
                let header =
                    sources[index] != request.paneId && !reservedDrawerHeaders.contains(index)
                    ? PaneContextDetailBudget.drawerHeaderBytes : 0
                let cost = header + PaneContextDetailBudget.messageBytes(message.detail)
                if byteCount + cost > byteBudget { break }
                byteCount += cost
                if header > 0 { reservedDrawerHeaders.insert(index) }
                selectedMessages[index].append(message.detail)
            }
        }
    }

    private func omissionEntries() -> [OmittedLiveMessages] {
        representedSourceIndices.compactMap { index in
            guard !omittedMessages[index].isEmpty, let cursor = lastCursors[index] else { return nil }
            return OmittedLiveMessages(
                source: sources[index], openAsks: omittedMessages[index].filter { liveRank($0.detail) == 0 }.count,
                unreadNotices: omittedMessages[index].filter { liveRank($0.detail) == 1 }.count, next: cursor)
        }
    }

    private func truncation() -> DetailTruncation? {
        let omitted = omissionEntries()
        let remainingSources = candidateSourceIndices.count - representedSourceIndices.count
        guard !omitted.isEmpty || remainingSources > 0 else { return nil }
        let nextSourcesAfter = remainingSources > 0 ? representedSourceIndices.last.map { sources[$0] } : nil
        return DetailTruncation(
            omitted: omitted, remainingLiveSources: remainingSources, nextSourcesAfter: nextSourcesAfter)
    }

    func detail(revision: PaneContextRevision) -> PaneContextDetail {
        let ownerIndex = sources.firstIndex(of: request.paneId)
        let drawers = sources.indices.filter { sources[$0] != request.paneId && !selectedMessages[$0].isEmpty }.map {
            DrawerMessageGroup(sourcePaneId: sources[$0], messages: selectedMessages[$0])
        }
        return PaneContextDetail(
            paneId: request.paneId, revision: revision, agentTitle: snapshot.title, agentLine: snapshot.line,
            session: session, messages: ownerIndex.map { selectedMessages[$0] } ?? [], drawerMessages: drawers,
            links: .unknown, pullRequests: .notApplicable, truncation: truncation())
    }
}

private func liveRank(_ message: AgentMessageDetail) -> Int? {
    switch message.shape {
    case .ask(_, _, _, .open): 0
    case .notice(.unread): 1
    default: nil
    }
}

private func livePrecedes(_ lhs: PaneContextStoredMessage, _ rhs: PaneContextStoredMessage) -> Bool {
    let left = liveRank(lhs.detail) ?? 2
    let right = liveRank(rhs.detail) ?? 2
    return left == right ? lhs.position > rhs.position : left < right
}

private func isAfter(_ message: PaneContextStoredMessage, cursor: LiveMessageCursor) -> Bool {
    guard let rank = liveRank(message.detail) else { return false }
    return rank > cursor.rank || (rank == cursor.rank && message.position < cursor.position)
}
