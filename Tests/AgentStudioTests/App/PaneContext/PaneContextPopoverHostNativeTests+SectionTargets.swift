import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AppKit
import Foundation
import Testing

@testable import AgentStudio

extension PaneContextPopoverHostNativeTests {
    @Test(
        "A native kind-chip press carries its section to the popover",
        arguments: [KindChipModel.Kind.failure, .needsYou, .done, .info],
        [PaneContextPopoverLocation.sidebar, .pane])
    func nativeKindChipReachesItsSection(kind: KindChipModel.Kind, location: PaneContextPopoverLocation) async throws {
        let pane = PaneId.generateUUIDv7()
        let group: MessagesGroupModel.Kind
        let importance: MessageImportance
        let counts: PaneMessageKindCounts
        let selection: Int
        switch kind {
        case .failure:
            group = .failed
            importance = .failure
            counts = .init(failure: 1, needsYou: 0, done: 0, info: 0)
            selection = 2
        case .needsYou:
            group = .needsYou
            importance = .attention
            counts = .init(failure: 0, needsYou: 1, done: 0, info: 0)
            selection = 1
        case .done:
            group = .done
            importance = .done
            counts = .init(failure: 0, needsYou: 0, done: 1, info: 0)
            selection = 4
        case .info:
            group = .info
            importance = .info
            counts = .init(failure: 0, needsYou: 0, done: 0, info: 1)
            selection = 8
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
        let owners = PaneContextTestSourceOwners(
            sessionStatus: SessionStatusAtom(), presentation: presentation, pane: { _ in nil },
            serviceProvider: { adapter })
        let mounted = owners.makeNativeHost(
            paneId: pane, entry: .kind(.init(kind: kind, count: 1)),
            location: location, wallNow: Date(timeIntervalSince1970: 2))
        do {
            try await mounted.open()
            try await mounted.rendered()
            #expect(mounted.interactions.selectedFilter == selection)
            for (offset, membership) in [1, 2, 4, 8].enumerated() {
                let identifier = PaneContextPopoverControlProjection.controls().filters[offset + 1].identifier
                let chip = try #require(mounted.native.find(identifier) as? any NSAccessibilityProtocol)
                #expect(chip.isAccessibilitySelected() == (membership == selection))
            }
            #expect(mounted.value?.shape?.messagesTarget == .section(group))
            #expect(mounted.native.find("pane-context.group." + group.rawValue) != nil)
            #expect(await ports.requests == [.init(paneId: pane, page: .first)])
            try await mounted.close()
            try await ports.finish()
        } catch {
            try? await mounted.close()
            try? await ports.finish()
            throw error
        }
    }

    @Test("A kind with no loaded row keeps its filter while scrolling falls back to top", arguments: [0, 1])
    func unloadedKindOpensAtTopWithoutExtraRead(count: Int) async throws {
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
        let owners = PaneContextTestSourceOwners(
            sessionStatus: SessionStatusAtom(), presentation: presentation, pane: { _ in nil },
            serviceProvider: { adapter })
        let mounted = owners.makeNativeHost(
            paneId: pane, entry: .kind(.init(kind: .done, count: count)),
            wallNow: Date(timeIntervalSince1970: 2))
        do {
            try await mounted.open()
            try await mounted.rendered()
            #expect(mounted.interactions.selectedFilter == 4)
            #expect(mounted.value?.shape?.messagesTarget == .top)
            #expect(mounted.value?.shape?.messages.groups.map(\.kind) == [.info])
            #expect(mounted.native.find("pane-context.group.done") == nil)
            #expect(mounted.native.find("pane-context.group.info") == nil)
            let empty = try #require(
                mounted.native.find("pane-context.filter-no-loaded") as? any NSAccessibilityProtocol)
            #expect(empty.accessibilityLabel() == "No done messages")
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
