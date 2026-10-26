import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio

extension PaneContextPopoverHostNativeTests {
    @Test(
        "A native kind-chip press carries its section to the popover",
        arguments: [KindChipModel.Kind.failure, .needsYou, .done, .info])
    func nativeKindChipReachesItsSection(kind: KindChipModel.Kind) async throws {
        let pane = PaneId.generateUUIDv7()
        let group: MessagesGroupModel.Kind
        let importance: MessageImportance
        let counts: PaneMessageKindCounts
        switch kind {
        case .failure:
            group = .failed
            importance = .failure
            counts = .init(failure: 1, needsYou: 0, done: 0, info: 0)
        case .needsYou:
            group = .needsYou
            importance = .attention
            counts = .init(failure: 0, needsYou: 1, done: 0, info: 0)
        case .done:
            group = .done
            importance = .done
            counts = .init(failure: 0, needsYou: 0, done: 1, info: 0)
        case .info:
            group = .info
            importance = .info
            counts = .init(failure: 0, needsYou: 0, done: 0, info: 1)
        }
        let message = try PaneContextPopoverShapingTests.message(
            paneId: pane, shape: .notice(.unread), importance: importance)
        let ports = PaneContextPopoverTestPorts(
            PaneContextPopoverShapingTests.detail(paneId: pane, messages: [message]))
        let presentation = PaneContextPresentationAtom()
        let messageCounts = PaneMessageCounts(kinds: counts, newestOpenBlockingAskId: nil)
        presentation.apply([
            pane: .set(
                .init(
                    revision: .init(1), agentTitle: nil, agentLine: nil, own: messageCounts,
                    includingDrawers: messageCounts, pullRequests: .notApplicable))
        ])
        let adapter = PaneContextUIAdapter(reader: ports, person: ports)
        let readers = PaneContextUIReaders(
            sessionStatus: SessionStatusAtom(), presentation: presentation, pane: { _ in nil },
            serviceProvider: { adapter })
        let mounted = PaneContextNativePopoverWindow(
            paneId: pane, readers: readers, location: .sidebar,
            wallNow: Date(timeIntervalSince1970: 2), messageEntryKind: kind)
        do {
            try await mounted.open()
            #expect(mounted.controller?.state?.messagesTarget == .section(group))
            #expect(mounted.find("pane-context.group." + group.rawValue) != nil)
            #expect(await ports.requests == [.init(paneId: pane, page: .first)])
            try await mounted.close()
            try await ports.finish()
        } catch {
            try? await mounted.close()
            try? await ports.finish()
            throw error
        }
    }

    @Test("A kind with no loaded row opens at the top and leaves paging untouched")
    func unloadedKindOpensAtTopWithoutExtraRead() async throws {
        let pane = PaneId.generateUUIDv7()
        let info = try PaneContextPopoverShapingTests.message(paneId: pane, shape: .notice(.unread), importance: .info)
        let detail = PaneContextPopoverShapingTests.detail(
            paneId: pane, messages: [info],
            truncation: .init(
                omitted: [.init(source: pane, openAsks: 0, unreadNotices: 1, next: .init(rank: 1, position: 1))],
                remainingLiveSources: 0, nextSourcesAfter: nil))
        let ports = PaneContextPopoverTestPorts(detail)
        let presentation = PaneContextPresentationAtom()
        let counts = PaneMessageCounts(
            kinds: .init(failure: 0, needsYou: 0, done: 1, info: 1), newestOpenBlockingAskId: nil)
        presentation.apply([
            pane: .set(
                .init(
                    revision: .init(1), agentTitle: nil, agentLine: nil, own: counts,
                    includingDrawers: counts, pullRequests: .notApplicable))
        ])
        let adapter = PaneContextUIAdapter(reader: ports, person: ports)
        let readers = PaneContextUIReaders(
            sessionStatus: SessionStatusAtom(), presentation: presentation, pane: { _ in nil },
            serviceProvider: { adapter })
        let mounted = PaneContextNativePopoverWindow(
            paneId: pane, readers: readers, location: .pane,
            wallNow: Date(timeIntervalSince1970: 2), messageEntryKind: .done)
        do {
            try await mounted.open()
            #expect(mounted.controller?.state?.messagesTarget == .top)
            #expect(mounted.controller?.state?.messages.groups.map(\.kind) == [.info])
            #expect(mounted.find("pane-context.group.done") == nil)
            #expect(await ports.requests == [.init(paneId: pane, page: .first)])
            try await mounted.close()
            try await ports.finish()
        } catch {
            try? await mounted.close()
            try? await ports.finish()
            throw error
        }
    }
}
