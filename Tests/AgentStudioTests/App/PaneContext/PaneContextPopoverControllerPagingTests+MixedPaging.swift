import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions

extension PaneContextPopoverControllerPagingTests {
    @Test("F15 discovered-source message cursors advance and background replay preserves their progress")
    func discoveredSourceMessagesKeepAdvancingAcrossReplay() async throws {
        try await withDiscoveredMessageSource { harness, opened, reader, source, initial in
            let original = try #require(initial.pages.first { $0.sourcePaneId == source.uuid })
            let continuation = try await boundedMessagePage(reader, owner: harness.key.paneId, cursor: original)
            let expected = try #require(continuation.truncation?.omitted.first { $0.source == source })
            try #require(expected.next.position < original.position)
            let prefix = sourceMessageIds(initial, source: source)
            let newIds = Set(continuation.drawerMessages.flatMap(\.messages).map { $0.id.uuid })
            try #require(!newIds.isEmpty && newIds.isDisjoint(with: prefix))

            let advanced = try await loadMixedPage(
                .messages(source: source, rank: original.rank, position: original.position),
                harness: harness, opened: opened)
            #expect(sourceMessageIds(advanced, source: source) == prefix.union(newIds))
            #expect(advanced.pages.first { $0.sourcePaneId == source.uuid }?.position == expected.next.position)
            let replayed = try await backgroundMixedReplay(harness, opened: opened)
            #expect(replayed.pages.first { $0.sourcePaneId == source.uuid }?.position == expected.next.position)
            #expect(sourceMessageIds(replayed, source: source) == prefix.union(newIds))

            // Follow the cursor actually offered to the person, not the reference page's cursor.
            let offered = try #require(replayed.pages.first { $0.sourcePaneId == source.uuid })
            let following = try await boundedMessagePage(reader, owner: harness.key.paneId, cursor: offered)
            let beforeClick = sourceMessageIds(replayed, source: source)
            let nextIds = Set(following.drawerMessages.flatMap(\.messages).map { $0.id.uuid })
            let next = try await loadMixedPage(
                .messages(source: source, rank: offered.rank, position: offered.position),
                harness: harness, opened: opened)
            #expect(!nextIds.subtracting(beforeClick).isEmpty, "The next offered cursor must reach genuinely new rows")
            #expect(sourceMessageIds(next, source: source) == beforeClick.union(nextIds))
            #expect(sourceMessageIds(next, source: source).count > beforeClick.count)
        }
    }

    @Test("F15 an exhausted discovered source never regains a More Messages control during replay")
    func exhaustedDiscoveredSourceDoesNotRegainMessageCursor() async throws {
        try await withDiscoveredMessageSource { harness, opened, reader, source, initial in
            var cursor = try #require(initial.pages.first { $0.sourcePaneId == source.uuid })
            var seen = Set<UInt64>()
            var expectedIds = sourceMessageIds(initial, source: source)
            var assembled = initial
            while true {
                try #require(seen.insert(cursor.position).inserted, "The real service cursor must make finite progress")
                let page = try await boundedMessagePage(reader, owner: harness.key.paneId, cursor: cursor)
                expectedIds.formUnion(page.drawerMessages.flatMap(\.messages).map { $0.id.uuid })
                assembled = try await loadMixedPage(
                    .messages(source: source, rank: cursor.rank, position: cursor.position),
                    harness: harness, opened: opened)
                guard let omission = page.truncation?.omitted.first(where: { $0.source == source }) else { break }
                try #require(omission.next.position < cursor.position)
                // Traverse the real service's full finite chain even if the assembled UI rewinds it.
                cursor = .init(
                    sourcePaneId: source.uuid, rank: omission.next.rank, position: omission.next.position,
                    openAsks: omission.openAsks, unreadNotices: omission.unreadNotices)
            }
            #expect(expectedIds.count == 32, "Every seeded target row must have been reached")
            #expect(sourceMessageIds(assembled, source: source) == expectedIds)
            #expect(!assembled.pages.contains { $0.sourcePaneId == source.uuid })
            let replayed = try await backgroundMixedReplay(harness, opened: opened)
            #expect(sourceMessageIds(replayed, source: source) == expectedIds)
            #expect(!replayed.pages.contains { $0.sourcePaneId == source.uuid })
        }
    }

    private func withDiscoveredMessageSource(
        _ operation:
            @MainActor @Sendable (
                PopoverOwnerHarness, PopoverOwnerHarness.Owner.Opening, PaneContextBudgetedTestReader,
                PaneId, MessagesPopoverModel
            ) async throws -> Void
    ) async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let service = fixture.composition.paneContextService
        var harness: PopoverOwnerHarness?
        do {
            // Recorded membership and live metadata, not a native graph, force real bounded source discovery.
            let drawers = (0..<160).map { _ in PaneId.generateUUIDv7() }
            let target = try #require(drawers.last)
            fixture.directory.install(
                .init(
                    workspaceId: fixture.workspaceId, membershipRevision: 2,
                    entries: [.init(paneId: fixture.ownerId, placement: .layout, ownedDrawerChildIds: drawers)]
                        + drawers.map {
                            .init(
                                paneId: $0, placement: .drawerChild(parentPaneID: fixture.ownerId.uuid),
                                ownedDrawerChildIds: [])
                        }))
            for source in [fixture.ownerId] + drawers {
                let sender = try fixture.sender(await fixture.bind(paneId: source))
                for number in 0..<(source == target ? 32 : 1) {
                    let id = AgentMessageId.generateUUIDv7()
                    let body =
                        source == target
                        ? "Row \(number) " + String(repeating: "x", count: 4000) : "Source discovery row"
                    try #require(
                        await service.send(
                            .init(
                                paneId: source, messageId: id, sender: sender, sourceOccurredAt: nil,
                                importance: .info, body: body, why: nil, actions: [], shape: .notice)) == .created(id))
                }
            }
            let reader = PaneContextBudgetedTestReader(service: service)
            let subject = PopoverOwnerHarness(
                detail: PaneContextPopoverShapingTests.detail(paneId: fixture.ownerId),
                service: .init(epoch: UUIDv7.generate(), reader: reader, invalidations: service, person: service))
            harness = subject
            subject.capture.setSource(
                PaneContextPreparedDetailFixture.source(fixture.ownerId, children: drawers), for: fixture.ownerId)
            let opened = try await subject.open()
            #expect(try await subject.completed(opened.initialExecution) == .published)
            var model = try #require(await subject.projections.shapes[subject.key]?.messages)
            try #require(!model.pages.contains { $0.sourcePaneId == target.uuid })
            var discoveryCursors = Set<UUID>()
            repeat {
                let after = try #require(model.nextSourcesAfter, "The real bounded first page must omit live sources")
                try #require(discoveryCursors.insert(after).inserted)
                model = try await loadMixedPage(
                    .sources(after: .init(existingUUID: after)), harness: subject, opened: opened)
            } while !model.pages.contains(where: { $0.sourcePaneId == target.uuid })
            try await operation(subject, opened, reader, target, model)
            try await subject.finish()
            try await fixture.close()
        } catch {
            try? await harness?.finish()
            try? await fixture.close()
            throw error
        }
    }

    private func boundedMessagePage(
        _ reader: PaneContextBudgetedTestReader, owner: PaneId, cursor: MessagePageCursorModel
    ) async throws -> PaneContextDetail {
        let result = await reader.readDetail(
            .init(
                paneId: owner,
                page: .more(
                    source: .init(existingUUID: cursor.sourcePaneId),
                    after: .init(rank: cursor.rank, position: cursor.position))))
        let detail: PaneContextDetail? = if case .detail(let value) = result { value } else { nil }
        return try #require(detail, "The real bounded continuation must return detail: \(result)")
    }

    private func loadMixedPage(
        _ scope: PaneContextPopoverPageScope, harness: PopoverOwnerHarness,
        opened: PopoverOwnerHarness.Owner.Opening
    ) async throws -> MessagesPopoverModel {
        let request = await harness.owner.requestPage(scope, for: harness.key, opening: opened.epoch)
        let execution = try #require(await harness.owner.latestExecution(for: harness.key))
        let outcome = try await harness.completed(execution)
        #expect(outcome == .published || outcome == .equal)
        try await harness.pageFinished(request, expected: .loaded)
        return try #require(await harness.projections.shapes[harness.key]?.messages)
    }

    private func backgroundMixedReplay(
        _ harness: PopoverOwnerHarness, opened: PopoverOwnerHarness.Owner.Opening
    ) async throws -> MessagesPopoverModel {
        let capture = harness.capture.snapshot(for: [harness.key.paneId])
        let owner = try #require(capture.sources[harness.key.paneId])
        harness.capture.setSource(
            .init(
                structuralFacts: owner.structuralFacts, title: "Background title", note: nil,
                session: nil, display: nil, activity: nil), for: harness.key.paneId)
        let sources = Set(
            [harness.key.paneId] + (owner.structuralFacts?.ownedDrawerPaneIDs ?? []).map { PaneId(existingUUID: $0) })
        await harness.owner.receive(harness.capture.snapshot(for: sources), for: harness.key, opening: opened.epoch)
        let timer = try await harness.timer()
        try #require(timer.deadline == harness.clock.now.advanced(by: .seconds(10)))
        harness.clock.advance(by: .seconds(10))
        await timer.task.value
        let execution = try #require(await harness.owner.latestExecution(for: harness.key))
        #expect(execution.kind == .background)
        _ = try await harness.completed(execution)
        return try #require(await harness.projections.shapes[harness.key]?.messages)
    }

    private func sourceMessageIds(_ model: MessagesPopoverModel, source: PaneId) -> Set<UUID> {
        Set(model.messageRows.filter { $0.key.sourcePaneId == source.uuid }.map(\.id))
    }
}
