import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@Suite("Pane context IPC source traversal")
struct AgentStudioAppIPCPaneContextDetailTraversalTests {
    @Test("A single-worktree pane reports no applicable pull-request summary and unknown links")
    func singleWorktreeHasNoApplicablePullRequestSummary() async throws {
        try await withPaneContextIPCDomain { domain in
            let worktreeId = UUIDv7.generate()
            let pane = IPCPaneSummary(
                id: domain.paneId, ordinal: 1, contentKind: .terminal, residency: .active,
                tabId: nil, repoId: UUIDv7.generate(), worktreeId: worktreeId,
                isActive: true, isDrawerChild: false)
            try #require(pane.worktreeId == worktreeId)
            try await withPaneContextWire(domain: domain, panes: [pane]) { _, client in
                let detail = try await client.detail()
                #expect(detail.paneId == pane.id)
                #expect(detail.pullRequests == .notApplicable)
                #expect(detail.links == .unknown)
            }
        }
    }

    @Test("Owner and drawer groups retain source labels and ask-notice-settled ordering")
    func ownerAndDrawersPreserveLiveOrder() async throws {
        try await withPaneContextIPCDomain { domain in
            let owner = PaneId(existingUUID: domain.paneId)
            let drawers = [PaneId.generateUUIDv7(), PaneId.generateUUIDv7()]
            let unrelated = PaneId.generateUUIDv7()
            domain.membership.setDrawers(drawers, for: owner)
            domain.membership.addPane(unrelated)
            var expected: [PaneId: [UUID]] = [:]
            for source in [owner] + drawers {
                expected[source] = try await orderedMessages(domain: domain, source: source)
            }
            let panes = ([owner] + drawers + [unrelated]).enumerated().map {
                makePaneSummary(id: $0.element.uuid, ordinal: $0.offset + 1)
            }
            try await withPaneContextWire(domain: domain, panes: panes) { fixture, client in
                let detail = try await client.detail()
                #expect(detail.messages.map(\.id) == expected[owner])
                #expect(detail.messages.allSatisfy { $0.sourcePaneId == owner.uuid })
                #expect(detail.drawerMessages.map(\.sourcePaneId) == drawers.map(\.uuid))
                for group in detail.drawerMessages {
                    #expect(group.messages.map(\.id) == expected[PaneId(existingUUID: group.sourcePaneId)])
                    #expect(group.messages.allSatisfy { $0.sourcePaneId == group.sourcePaneId })
                }
                #expect(detail.truncation == nil)
                var drawerClient = try await PaneContextWireClient(fixture: fixture, paneId: drawers[0].uuid)
                defer { drawerClient.close() }
                let drawerDetail = try await drawerClient.detail()
                #expect(drawerDetail.messages.map(\.id) == expected[drawers[0]])
                #expect(drawerDetail.drawerMessages.isEmpty)
                var unrelatedClient = try await PaneContextWireClient(fixture: fixture, paneId: unrelated.uuid)
                defer { unrelatedClient.close() }
                let unrelatedDetail = try await unrelatedClient.detail()
                #expect(unrelatedDetail.messages.isEmpty)
                #expect(unrelatedDetail.drawerMessages.isEmpty)
            }
        }
    }

    @Test("Source-list and message continuations through the shrinking adapter reach every live row once")
    func sourceAndMessageContinuationsReachEveryLiveMessage() async throws {
        try await withPaneContextIPCDomain { domain in
            let dataset = try await manySources(domain: domain)
            let cap = dataset.encodedCap
            try await withPaneContextWire(domain: domain) { _, client in
                let full = try await client.detail()
                try #require(
                    try JSONEncoder().encode(full).count > cap, "The lowered cap must require real adapter shrink")
            }
            try await withPaneContextWire(domain: domain, maximumEncodedReplyBytes: cap) { _, client in
                var sourcePage = IPCPaneContextReadPage.first
                var sourceCursors = Set<UUID>()
                var seen = Set<UUID>()
                var sawMessageContinuation = false
                repeat {
                    let detail = try await client.detail(page: sourcePage)
                    #expect(try JSONEncoder().encode(detail).count <= cap)
                    try collectLiveMessages(detail, into: &seen)
                    for omitted in detail.truncation?.omitted ?? [] {
                        sawMessageContinuation = true
                        try await traverseMessages(
                            source: omitted.source, cursor: omitted.next, client: &client, seen: &seen)
                    }
                    guard let after = detail.truncation?.nextSourcesAfter else {
                        #expect(detail.truncation?.remainingLiveSources ?? 0 == 0)
                        break
                    }
                    try #require(sourceCursors.insert(after).inserted, "Source-list cursor must advance")
                    #expect(detail.truncation?.remainingLiveSources ?? 0 > 0)
                    sourcePage = .moreSources(after: after)
                } while true
                #expect(!sourceCursors.isEmpty)
                #expect(sawMessageContinuation)
                #expect(seen == dataset.messages)
            }
        }
    }

    @Test("Moving a drawer between wire pages invalidates both cursors and transfers its attribution")
    func movedDrawerRejectsBothContinuationKinds() async throws {
        try await withPaneContextIPCDomain { domain in
            let dataset = try await manySources(domain: domain)
            let otherOwner = PaneId.generateUUIDv7()
            domain.membership.addPane(otherOwner)
            let panes = [
                makePaneSummary(id: domain.paneId, ordinal: 1), makePaneSummary(id: otherOwner.uuid, ordinal: 2),
            ]
            try await withPaneContextWire(
                domain: domain, panes: panes, maximumEncodedReplyBytes: dataset.encodedCap
            ) { fixture, client in
                let first = try await client.detail()
                let moved = try #require(first.truncation?.nextSourcesAfter)
                let omission = try #require(first.truncation?.omitted.first { $0.source == moved })
                try #require(dataset.drawers.contains(PaneId(existingUUID: moved)))
                domain.membership.setDrawers(
                    dataset.drawers.filter { $0.uuid != moved }, for: PaneId(existingUUID: domain.paneId))
                domain.membership.setDrawers([PaneId(existingUUID: moved)], for: otherOwner)
                for page in [
                    IPCPaneContextReadPage.more(source: moved, after: omission.next), .moreSources(after: moved),
                ] {
                    let refusal = try await client.response(
                        method: "pane.context.get", params: IPCPaneContextGetParams(handle: "self", page: page))
                    #expect(paneContextRefusalReason(refusal) == "sourceNotInView")
                    #expect(refusal.result == nil)
                }
                let oldOwner = try await client.detail()
                #expect(!oldOwner.drawerMessages.contains { $0.sourcePaneId == moved })
                #expect(!(oldOwner.truncation?.omitted.contains { $0.source == moved } ?? false))
                var newOwner = try await PaneContextWireClient(fixture: fixture, paneId: otherOwner.uuid)
                defer { newOwner.close() }
                let newDetail = try await newOwner.detail()
                #expect(newDetail.messages.isEmpty)
                #expect(newDetail.drawerMessages.map(\.sourcePaneId) == [moved])
                #expect(
                    Set(newDetail.drawerMessages.flatMap { $0.messages.map(\.id) }) == dataset.messagesBySource[moved])
            }
        }
    }

    private func orderedMessages(domain: PaneContextIPCDomainCompanion, source: PaneId) async throws -> [UUID] {
        let writer = try await domain.bind(conversationId: source.uuidString, to: source.uuid)
        let oldNotice = try await domain.seedMessage(in: source, body: "old notice")
        let oldAsk = try await domain.seedMessage(in: source, body: "old ask", writer: writer)
        let newNotice = try await domain.seedMessage(in: source, body: "new notice")
        let newAsk = try await domain.seedMessage(in: source, body: "new ask", writer: writer)
        let settled = try await domain.seedMessage(in: source, body: "settled", writer: writer)
        try #require(
            await domain.service.dismiss(messageId: AgentMessageId(existingUUID: settled), paneId: source) == .done)
        return [newAsk, oldAsk, newNotice, oldNotice, settled]
    }

    private func manySources(domain: PaneContextIPCDomainCompanion) async throws -> SourceDataset {
        let owner = PaneId(existingUUID: domain.paneId)
        let framing =
            PaneContextDetailBudget.metadataBytes(title: nil, line: nil, session: nil)
            + PaneContextDetailBudget.truncationHeaderBytes + PaneContextDetailBudget.sourceContinuationBytes
        let drawerBytes = PaneContextDetailBudget.drawerHeaderBytes + PaneContextDetailBudget.sourceContinuationBytes
        let calibrationCount =
            (AppPolicies.PaneContext.minimumDetailBytes - framing - AppPolicies.PaneContext.maximumMessageDetailBytes)
            / drawerBytes + 1
        let calibrationDrawers = (0..<calibrationCount).map { _ in PaneId.generateUUIDv7() }
        domain.membership.setDrawers(calibrationDrawers, for: owner)
        var bySource: [UUID: Set<UUID>] = [:]
        for source in [owner] + calibrationDrawers {
            bySource[source.uuid] = [try await domain.seedMessage(in: source, body: "x")]
        }
        // Measure both floor layouts; later pages contain only drawer headers.
        let firstBytes = try await floorReplyBytes(domain: domain, page: .first)
        let drawerPageBytes = try await floorReplyBytes(domain: domain, page: .moreSources(after: owner))
        let envelope = try AppIPCPaneContextReplyBudget.envelopeOverheadBytes(id: .number(Int.max))
        let cap = max(firstBytes, drawerPageBytes) + envelope
        let omitted = IPCPaneOmittedLiveMessages(
            source: owner.uuid, openAsks: 0, unreadNotices: 1, next: IPCPaneLiveMessageCursor(rank: 0, position: 2))
        let omittedBytes = try JSONEncoder().encode(omitted).count
        // Even omission entries alone cannot fit every source in this cap.
        let drawerCount = cap / omittedBytes + 1
        try #require(drawerCount > calibrationDrawers.count)
        let extraDrawers = (calibrationDrawers.count..<drawerCount).map { _ in PaneId.generateUUIDv7() }
        let drawers = calibrationDrawers + extraDrawers
        domain.membership.setDrawers(drawers, for: owner)
        for source in extraDrawers {
            bySource[source.uuid] = [try await domain.seedMessage(in: source, body: "x")]
        }
        return SourceDataset(drawers: drawers, messagesBySource: bySource, encodedCap: cap)
    }

    private func floorReplyBytes(domain: PaneContextIPCDomainCompanion, page: PaneContextReadPage) async throws -> Int {
        let floor = try PaneContextIPCMapping.detail(
            await domain.service.readDetail(
                PaneContextReadRequest(paneId: PaneId(existingUUID: domain.paneId), page: page), maximumDetailBytes: 0))
        let truncation = try #require(floor.truncation)
        // Count/revision widths may grow after calibration; retain the actual
        // floor messages and measure the allowed numeric widths plus a cursor.
        let wideFloor = IPCPaneContextGetResult(
            paneId: floor.paneId, revision: UInt64(IPCSchemaScalars.maximumExactInteger),
            agentTitle: floor.agentTitle, agentLine: floor.agentLine, session: floor.session,
            messages: floor.messages, drawerMessages: floor.drawerMessages,
            links: floor.links, pullRequests: floor.pullRequests,
            truncation: IPCPaneDetailTruncation(
                omitted: truncation.omitted, remainingLiveSources: Int(IPCSchemaScalars.maximumExactInteger),
                nextSourcesAfter: truncation.nextSourcesAfter ?? domain.paneId))
        return try JSONEncoder().encode(wideFloor).count
    }

    private func collectLiveMessages(_ detail: IPCPaneContextGetResult, into seen: inout Set<UUID>) throws {
        for message in detail.messages + detail.drawerMessages.flatMap(\.messages) {
            try #require(seen.insert(message.id).inserted, "Live message must not be duplicated")
            #expect(message.shape == .notice(state: .unread))
        }
    }

    private func traverseMessages(
        source: UUID, cursor: IPCPaneLiveMessageCursor, client: inout PaneContextWireClient, seen: inout Set<UUID>
    ) async throws {
        var next = cursor
        var cursors: [IPCPaneLiveMessageCursor] = []
        repeat {
            try #require(!cursors.contains(next), "Message cursor must advance")
            #expect(next.position <= UInt64(IPCSchemaScalars.maximumExactInteger))
            cursors.append(next)
            let page = try await client.detail(page: .more(source: source, after: next))
            try #require(!(page.messages + page.drawerMessages.flatMap(\.messages)).isEmpty)
            try collectLiveMessages(page, into: &seen)
            guard let remaining = page.truncation?.omitted.first else { break }
            #expect(remaining.source == source)
            next = remaining.next
        } while true
    }
}

private struct SourceDataset {
    let drawers: [PaneId]
    let messagesBySource: [UUID: Set<UUID>]
    let encodedCap: Int
    var messages: Set<UUID> { Set(messagesBySource.values.flatMap { $0 }) }
}
