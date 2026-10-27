import Foundation
import Testing

@testable import AgentStudio

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
    func openingWidthHonorsContentScreenInsetAndFloor(scenario: Scenario) {
        #expect(
            MessagesPopoverWidthState.resolve(
                hasMultilineBody: scenario.multiline, screenVisibleWidth: scenario.visible) == scenario.expected)
    }

    @Test(arguments: [false, true])
    func firstReadyContentFreezesWidthForLaterReads(multilineFirst: Bool) {
        let loading = MessagesPopoverWidthState.loading(screenVisibleWidth: 1440)
        #expect(loading.width == 480)
        let ready = loading.receivingContent(hasMultilineBody: multilineFirst, screenVisibleWidth: 1440)
        #expect(ready.width == (multilineFirst ? 560 : 480))
        let later = ready.receivingContent(hasMultilineBody: !multilineFirst, screenVisibleWidth: 430)
        #expect(
            later.width == (multilineFirst ? 560 : 480), "Later content/screen samples must not resize an open popover")
        #expect(
            MessagesPopoverWidthState.loading(screenVisibleWidth: 430).width == 398,
            "A new opening samples its current screen")
    }
}
