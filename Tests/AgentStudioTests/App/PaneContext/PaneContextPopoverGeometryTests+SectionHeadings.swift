import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioRepoExplorer

extension PaneContextPopoverGeometryTests {
    @Test("N2 sections retain scoped counts and urgency order as neutral content headings")
    func contentHeadersRetainScopedSidebarCountsWithoutKindChips() async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let service = fixture.composition.paneContextService
        var window: PaneContextPreparedNativeHost?
        do {
            var noticeKeys: [PaneContextMessageKey] = []
            for (source, importance, body) in [
                (fixture.ownerId, MessageImportance.failure, "Build failed: 3 errors in SessionsIngestion.swift"),
                (fixture.ownerId, .attention, "Review the migration plan"),
                (fixture.ownerId, .done, "Tests passed (412)"),
                (fixture.drawerId, .info, "Branch rebased onto main"),
            ] {
                let id = AgentMessageId.generateUUIDv7()
                noticeKeys.append(.init(paneId: source, messageId: id))
                let actions: [MessageAction] =
                    importance == .failure
                    ? [
                        .openFile(
                            path: "Sources/AgentStudio/Features/Sessions/Runtime/SessionsIngestion.swift", line: 142)
                    ]
                    : []
                try #require(
                    await service.send(
                        .init(
                            paneId: source, messageId: id, sender: .pane(source), sourceOccurredAt: nil,
                            importance: importance, body: body, why: nil, actions: actions, shape: .notice))
                        == .created(id))
            }
            await fixture.composition.presentationLane.publishPending()
            let display = try #require(fixture.presentationAtom.value(for: fixture.ownerId))
            #expect(display.includingDrawers.kinds == .init(failure: 1, needsYou: 1, done: 1, info: 1))
            #expect(display.own.kinds.info == 0)
            let sidebar = RepoExplorerPaneRowVariants.make(
                title: "Owner", counts: display.includingDrawers.kinds, now: fixture.now)
            #expect(
                sidebar.compact.chipModels == [
                    .init(kind: .failure, count: 1), .init(kind: .needsYou, count: 1),
                    .init(kind: .done, count: 1), .init(kind: .info, count: 1),
                ])
            let adapter = PaneContextUIAdapter(service: service)
            let owners = PaneContextTestSourceOwners(
                sessionStatus: SessionStatusAtom(), presentation: fixture.presentationAtom,
                pane: { _ in nil }, serviceProvider: { adapter })
            let mounted = owners.makeNativeHost(
                paneId: fixture.ownerId,
                entry: .messagesAction(PaneContextPopoverControlProjection.controls().messages, target: .top),
                location: .sidebar, wallNow: fixture.now)
            window = mounted
            mounted.native.window.appearance = NSAppearance(named: .darkAqua)
            try await mounted.open()
            try await mounted.rendered()
            mounted.native.popoverWindow?.appearance = NSAppearance(named: .darkAqua)
            mounted.native.layout()
            let groups = try #require(mounted.value?.shape?.messages.groups)
            #expect(groups.map(\.kind) == [.failed, .needsYou, .done, .info])
            let headerModels = groups.compactMap { group -> KindChipModel? in
                if case .kindChip(let model, _) = group.header { return model }
                return nil
            }
            #expect(headerModels == sidebar.compact.chipModels)
            var headerFrames: [CGRect] = []
            for name in ["failed", "needsYou", "done", "info"] {
                let header = try #require(mounted.native.find("pane-context.group." + name) as? NSView)
                headerFrames.append(header.convert(header.bounds, to: nil))
                #expect(
                    mounted.native.find("pane-context.group-chip." + name) == nil,
                    "N2 removes kind chips from section headers"
                )
                let title = try #require(groups.first { $0.kind.rawValue == name }?.kind.title)
                #expect(header.accessibilityLabel() == title + " 1")
                let host = try #require(mounted.native.popoverWindow?.contentView)
                let rect = host.convert(header.bounds, from: header)
                let actual = try PaneContextToolbarRenderingTests().pixels(in: host, rect: rect)
                let expected = try literalContentHeaderPixels(title, like: host, rect: rect)
                try recordPaintReview(host, rect: rect, name: "heading-\(title)-actual")
                #expect(
                    actual == expected, "N2 heading must paint title-case 13pt medium text with a neutral regular count"
                )
            }
            #expect(zip(headerFrames, headerFrames.dropFirst()).allSatisfy { $0.minY > $1.maxY })
            #expect(mounted.native.find("pane-context.group.resolved") == nil)
            try assertNoticeRowHeads(mounted.native, keys: noticeKeys)
            try assertMessagesTitle(mounted.native, count: 4)
            try await mounted.close()
            window = nil
            try await fixture.close()
        } catch {
            try? await window?.close()
            try? await fixture.close()
            throw error
        }
    }

    private func literalContentHeaderPixels(_ title: String, like actual: NSView, rect: CGRect) throws -> Data {
        let positionY = actual.isFlipped ? rect.midY : actual.bounds.height - rect.midY
        let host = NSHostingView(
            rootView: HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                Text("1").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .position(x: rect.midX, y: positionY)
            .frame(width: actual.bounds.width, height: actual.bounds.height)
            .environment(\.colorScheme, .dark))
        host.frame = CGRect(origin: .zero, size: actual.bounds.size)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = actual.effectiveAppearance
        window.backgroundColor = .black
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let crop = CGRect(
            x: rect.minX,
            y: actual.isFlipped == host.isFlipped ? rect.minY : actual.bounds.height - rect.maxY,
            width: rect.width, height: rect.height)
        try recordPaintReview(host, rect: crop, name: "heading-\(title)-reference")
        return try PaneContextToolbarRenderingTests().pixels(in: host, rect: crop)
    }
}
