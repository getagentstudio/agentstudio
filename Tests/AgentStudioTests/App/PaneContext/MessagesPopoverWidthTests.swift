import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite("Opening-scoped prepared Messages width", .serialized)
struct MessagesPopoverWidthTests {
    struct Scenario: Sendable {
        let multiline: Bool
        let visible: CGFloat
        let expected: CGFloat
    }

    @Test(arguments: [
        Scenario(multiline: false, visible: 1440, expected: 480),
        Scenario(multiline: true, visible: 1440, expected: 560),
        Scenario(multiline: false, visible: 500, expected: 468),
        Scenario(multiline: true, visible: 500, expected: 468),
        Scenario(multiline: false, visible: 472, expected: 440),
        Scenario(multiline: true, visible: 472, expected: 440),
        Scenario(multiline: false, visible: 430, expected: 398),
        Scenario(multiline: true, visible: 430, expected: 398),
    ])
    func openingWidthHonorsContentScreenInsetAndFloor(scenario: Scenario) async throws {
        let pane = PaneId.generateUUIDv7()
        let ports = PaneContextPopoverTestPorts(detail(pane, multiline: scenario.multiline))
        try await PaneContextPreparedDetailFixture.withOpen(
            pane: pane, ports: ports,
            screenVisibleWidth: Double(scenario.visible)
        ) { _, handle in
            #expect(handle.atom.value?.content.width == Double(scenario.expected))
        }
    }

    @Test(arguments: [false, true])
    func firstReadyContentFreezesWidthForLaterReads(multilineFirst: Bool) async throws {
        let pane = PaneId.generateUUIDv7()
        let ports = PaneContextPopoverTestPorts(detail(pane, multiline: multilineFirst))
        try await PaneContextPreparedDetailFixture.withOpen(
            pane: pane, ports: ports,
            screenVisibleWidth: 1440
        ) { fixture, handle in
            #expect(handle.opening.loadingWidth == 480)
            #expect(handle.atom.value?.content.width == (multilineFirst ? 560 : 480))
            await ports.setDetail(detail(pane, multiline: !multilineFirst))
            try await fixture.refresh(handle)
            #expect(
                handle.atom.value?.content.width == (multilineFirst ? 560 : 480),
                "Later content must not resize an open popover; its captured screen is immutable")
            await fixture.bindings.beginClose(handle.key).value
            let reopened = try await fixture.open(pane, screenVisibleWidth: 430, hostId: handle.key.hostId)
            #expect(reopened.opening.epoch != handle.opening.epoch)
            #expect(reopened.opening.loadingWidth == 398)
            #expect(reopened.atom.value?.content.width == 398, "A new opening samples its current screen")
        }
    }

    private func detail(_ pane: PaneId, multiline: Bool) -> PaneContextDetail {
        let message = AgentMessageDetail(
            id: .generateUUIDv7(), sourcePaneId: pane, sender: .pane(pane),
            sentAt: Date(timeIntervalSince1970: 2), sourceOccurredAt: nil, importance: .info,
            body: multiline ? "Line one\nLine two" : "Line one", why: nil, actions: [], shape: .notice(.unread))
        return PaneContextPopoverShapingTests.detail(paneId: pane, messages: [message])
    }
}
