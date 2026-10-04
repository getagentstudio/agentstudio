import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite(.serialized)
struct PaneContextPopoverHostTests {
    @Test("Informational-only messages keep the entry point present")
    func informationalOnlyMessagesKeepEntryPointPresent() {
        let chip = PaneMessageChipModel(
            count: 0, tone: .neutral, countIncludingInformational: 2, toneIncludingInformational: .info)
        #expect(PaneContextPopoverHost.shouldPresentMessagesButton(chip: chip))
    }

    @Test
    func onlyANewBlockingAskInAVisiblePaneHostAutoOpens() {
        let first = AgentMessageId.generateUUIDv7()
        let second = AgentMessageId.generateUUIDv7()
        #expect(
            !PaneContextPopoverAutoOpenPolicy.shouldOpen(
                newestAskId: nil, lastPresentedAskId: nil, isVisible: true, location: .pane))
        #expect(
            !PaneContextPopoverAutoOpenPolicy.shouldOpen(
                newestAskId: first, lastPresentedAskId: nil, isVisible: false, location: .pane))
        #expect(
            !PaneContextPopoverAutoOpenPolicy.shouldOpen(
                newestAskId: first, lastPresentedAskId: nil, isVisible: true, location: .sidebar))
        #expect(
            PaneContextPopoverAutoOpenPolicy.shouldOpen(
                newestAskId: first, lastPresentedAskId: nil, isVisible: true, location: .pane))
        #expect(
            !PaneContextPopoverAutoOpenPolicy.shouldOpen(
                newestAskId: first, lastPresentedAskId: first, isVisible: true, location: .pane))
        #expect(
            PaneContextPopoverAutoOpenPolicy.shouldOpen(
                newestAskId: second, lastPresentedAskId: first, isVisible: true, location: .pane))
    }

    @Test("Window presentation facts gate auto-open until the pane is restored")
    func windowPresentationFactsGateAutoOpen() {
        let ask = AgentMessageId.generateUUIDv7()
        let hidden = WindowPresentationFacts(isVisible: false, isMiniaturized: false, isOccluded: true)
        let minimized = WindowPresentationFacts(isVisible: true, isMiniaturized: true, isOccluded: false)
        let restored = WindowPresentationFacts(isVisible: true, isMiniaturized: false, isOccluded: false)
        #expect(!PaneContextPopoverVisibility.hostIsVisible(isActiveTab: true, windowFacts: hidden))
        #expect(!PaneContextPopoverVisibility.hostIsVisible(isActiveTab: true, windowFacts: minimized))
        #expect(
            !PaneContextPopoverAutoOpenPolicy.shouldOpen(
                newestAskId: ask, lastPresentedAskId: nil,
                isVisible: PaneContextPopoverVisibility.hostIsVisible(
                    isActiveTab: true, windowFacts: hidden), location: .pane))
        #expect(
            PaneContextPopoverAutoOpenPolicy.shouldOpen(
                newestAskId: ask, lastPresentedAskId: nil,
                isVisible: PaneContextPopoverVisibility.hostIsVisible(
                    isActiveTab: true, windowFacts: restored), location: .pane))
    }

    @Test("Per-pane auto-open state survives host replacement")
    func perPaneAutoOpenStateSurvivesHostReplacement() {
        let pane = PaneId.generateUUIDv7()
        let ask = AgentMessageId.generateUUIDv7()
        let state = PaneContextPopoverAutoOpenState()
        #expect(
            PaneContextPopoverAutoOpenPolicy.shouldOpen(
                newestAskId: ask, lastPresentedAskId: state.lastPresentedAskId(for: pane),
                isVisible: true, location: .pane))
        state.rememberPresentedAsk(ask, for: pane)
        #expect(
            !PaneContextPopoverAutoOpenPolicy.shouldOpen(
                newestAskId: ask, lastPresentedAskId: state.lastPresentedAskId(for: pane),
                isVisible: true, location: .pane))
        #expect(
            PaneContextPopoverAutoOpenPolicy.shouldOpen(
                newestAskId: .generateUUIDv7(), lastPresentedAskId: state.lastPresentedAskId(for: pane),
                isVisible: true, location: .pane))
    }
    @Test
    func disappearanceOfTheProviderClearsControlsButRealStorageFailureStaysVisible() async throws {
        let pane = PaneId.generateUUIDv7()
        let ports = PaneContextPopoverTestPorts(PaneContextPopoverShapingTests.detail(paneId: pane))
        let controller = makePopoverController(ports: ports)
        await controller.open(pane)
        #expect(controller.state != nil)
        #expect(!controller.useCurrentService(nil))
        #expect(controller.state == nil)
        #expect(controller.unavailableNote == "Not available right now")
        let failing = PaneContextPopoverTestPorts(
            PaneContextPopoverShapingTests.detail(paneId: pane), results: [.unavailable(.databaseUnavailable)])
        #expect(controller.useCurrentService(.init(reader: failing, person: failing)))
        await controller.open(pane)
        #expect(controller.unavailableNote?.hasPrefix("Context unavailable:") == true)
        controller.close()
        try await ports.finish()
        try await failing.finish()
    }
    @Test
    func messageActionResolvesProviderAgainAndNilCannotRestoreOldControls() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let pane = PaneId.generateUUIDv7()
            let notice = try PaneContextPopoverShapingTests.message(
                paneId: pane, shape: .notice(.unread), importance: .attention)
            let detail = PaneContextPopoverShapingTests.detail(paneId: pane, messages: [notice])
            let original = PaneContextPopoverTestPorts(detail)
            let replacement = PaneContextPopoverTestPorts(detail)
            var adapter: PaneContextUIAdapter? = .init(reader: replacement, person: replacement)
            let readers = PaneContextUIReaders(
                sessionStatus: SessionStatusAtom(), presentation: atoms.paneContextPresentation,
                pane: { _ in nil }, serviceProvider: { adapter })
            let controller = makePopoverController(ports: original)
            await controller.open(pane)
            let completed = FactRecorder<Int, PopoverReleaseFact>(
                vocabulary: .init(
                    describeScope: { "host action \($0)" }, describeFact: { String(describing: $0) },
                    isClosing: { _, _ in true }))
            var actionNumber = 0
            let actions = PaneContextPopoverHostActions.messages(
                controller: controller, readers: readers,
                onGoToPane: { _ in },
                onActionCompleted: {
                    completed.append(scope: actionNumber, fact: .released)
                    actionNumber += 1
                })
            actions.markRead(notice.id.uuid, pane.uuid)
            try await completed.expectNext(in: 0, .released)
            #expect(await original.readsMarked.isEmpty)
            #expect(await replacement.readsMarked.count == 1)
            #expect(controller.state != nil)
            adapter = nil
            actions.markRead(notice.id.uuid, pane.uuid)
            try await completed.expectNext(in: 1, .released)
            #expect(await replacement.readsMarked.count == 1)
            #expect(controller.paneId == nil)
            #expect(controller.state == nil)
            #expect(controller.unavailableNote == "Not available right now")
            controller.close()
            try await completed.finish()
            try await original.finish()
            try await replacement.finish()
        }
    }
    @Test
    func toolbarShapingUsesRealDisplayCountsAndDrawerOwnScope() async {
        let display = PaneContextDisplay(
            revision: .init(1), agentTitle: nil, agentLine: nil,
            own: .init(
                needsApprovalCount: 1, needsReplyCount: 0, attentionCount: 0, informationalCount: 3,
                newestOpenBlockingAskId: .generateUUIDv7()),
            includingDrawers: .init(
                needsApprovalCount: 1, needsReplyCount: 2, attentionCount: 4, informationalCount: 8,
                newestOpenBlockingAskId: .generateUUIDv7()),
            pullRequests: .notApplicable)
        #expect(await PaneContextToolbarControls.shapeMessages(display: nil, isDrawer: false) == nil)
        #expect(await PaneContextToolbarControls.shapeMessages(display: display, isDrawer: false)?.count == 7)
        #expect(await PaneContextToolbarControls.shapeMessages(display: display, isDrawer: true)?.count == 1)
    }
}
