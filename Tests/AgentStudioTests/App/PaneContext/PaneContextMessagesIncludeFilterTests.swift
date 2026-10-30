import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("Messages include filters and opening geometry", .serialized)
struct PaneContextMessagesIncludeFilterTests {
    @Test("A normal opening includes all four types with compact counts and named accessibility")
    func normalOpeningIncludesEveryType() async throws {
        try await withScene { scene in
            #expect(scene.host.interactions.selectedFilter == 15)
            let controls = PaneContextPopoverControlProjection.controls().filters
            let labels = ["Needs you, 2", "Failed, 0", "Done, 0", "Info, 1"]
            let counts = ["2", "0", "0", "1"]
            let model = try messages(scene)
            for index in 0..<4 {
                let chip = try #require(
                    scene.host.native.find(controls[index + 1].identifier) as? any NSAccessibilityProtocol)
                #expect(chip.isAccessibilitySelected())
                #expect(chip.accessibilityLabel() == labels[index])
                #expect(model.filters[1 << index].control.label == counts[index])
            }
        }
    }

    @Test("A real chip press excludes and restores exactly its type")
    func chipPressExcludesAndRestoresItsType() async throws {
        try await withScene { scene in
            try await scene.filter(15)
            let needsYou = PaneContextPopoverControlProjection.controls().filters[1].identifier
            try scene.host.native.press(needsYou)
            try await scene.host.bodyLayoutsPrepared()
            #expect(scene.host.interactions.selectedFilter == 14)
            #expect(scene.host.native.find("pane-context.group.needsYou") == nil)
            #expect(scene.host.native.find("pane-context.group.info") != nil)
            try scene.host.native.press(needsYou)
            try await scene.host.bodyLayoutsPrepared()
            #expect(scene.host.interactions.selectedFilter == 15)
            #expect(scene.host.native.find("pane-context.group.needsYou") != nil)
            #expect(scene.host.native.find("pane-context.group.info") != nil)
        }
    }

    @Test("All-off prompts for a filter while selected empty types retain their own empty copy")
    func allOffIsDifferentFromAnEmptySelectedType() async throws {
        try await withScene { scene in
            try await scene.filter(0)
            let noSelection = scene.host.native.find("pane-context.filter-no-loaded") as? any NSAccessibilityProtocol
            #expect(noSelection?.accessibilityLabel() == "Select at least one filter")
            #expect(scene.host.native.find("pane-context.group.needsYou") == nil)
            #expect(scene.host.native.find("pane-context.group.info") == nil)
            try await scene.filter(4)
            let noDone = try #require(
                scene.host.native.find("pane-context.filter-no-loaded") as? any NSAccessibilityProtocol)
            #expect(noDone.accessibilityLabel() == "No done messages")
        }
    }

    @Test("An opening keeps its outer and header heights and each chip frame across all memberships")
    func filteringKeepsOpeningAndChipGeometry() async throws {
        try await withScene { scene in
            try await scene.filter(15)
            let panel = try view(scene, "pane-context.popover-panel")
            let header = try view(scene, "pane-context.messages-header")
            let height = panel.bounds.height
            let headerHeight = header.bounds.height
            let controls = PaneContextPopoverControlProjection.controls().filters
            let initialFrames = try (1...4).map { index in
                try view(scene, controls[index].identifier).convert(
                    view(scene, controls[index].identifier).bounds, to: panel)
            }
            try #require(height > 0)
            for selection in [1, 8, 9, 0, 4, 15] {
                try await scene.filter(selection)
                scene.host.native.layout()
                #expect(panel.bounds.height == height, "The opening height changed for membership \(selection)")
                #expect(header.bounds.height == headerHeight)
                let frames = try (1...4).map { index in
                    try view(scene, controls[index].identifier).convert(
                        view(scene, controls[index].identifier).bounds, to: panel)
                }
                #expect(frames == initialFrames, "Toggling inclusion may change paint, never chip frames")
            }
        }
    }

    @Test("Resolved items follow original type without changing their own section or live counts")
    func resolvedItemsFollowOriginalTypeMembership() async throws {
        let pane = PaneId.generateUUIDv7()
        let settledAsk = try PaneContextPopoverShapingTests.message(
            paneId: pane,
            shape: .ask(.question, .freeText(placeholder: nil), .nonBlocking, .expired), importance: .attention)
        let withdrawnInfo = try PaneContextPopoverShapingTests.message(
            paneId: pane, shape: .notice(.withdrawn), importance: .info)
        let shape = await PaneContextPopoverShaping.shape(
            PaneContextPopoverShapingTests.detail(paneId: pane, messages: [settledAsk, withdrawnInfo]),
            sourceTitles: [:], counts: .zero, now: .distantPast)
        let all = shape.messages.filters[15].groups
        #expect(all.map(\.kind) == [.resolved])
        #expect(
            Set(all.flatMap(\.items).map(\.id)) == [
                .message(.init(sourcePaneId: pane.uuid, messageId: settledAsk.id.uuid)),
                .message(.init(sourcePaneId: pane.uuid, messageId: withdrawnInfo.id.uuid)),
            ])
        let withoutNeedsYou = shape.messages.filters[14].groups
        #expect(withoutNeedsYou.map(\.kind) == [.resolved])
        #expect(
            withoutNeedsYou.flatMap(\.items).map(\.id) == [
                .message(.init(sourcePaneId: pane.uuid, messageId: withdrawnInfo.id.uuid))
            ])
        #expect(shape.messages.filters[0].groups.isEmpty)
        #expect(shape.messages.filters[0].noLoadedContent?.label == "Select at least one filter")
        #expect(shape.messages.filters[1].control.label == "0")
    }

    @Test("The frozen opening includes its completed disclosure row before any filtering")
    func openingHeightIncludesCompletedDisclosureRow() async throws {
        let fixture = try await CompositionFactoryFixture.make()
        var mounted: PaneContextPreparedNativeHost?
        do {
            let sender = try fixture.sender(await fixture.bind(paneId: fixture.ownerId))
            let message = AgentMessageId.generateUUIDv7()
            let body = Array(
                repeating: "Read the complete verification evidence before choosing the next step.", count: 14
            )
            .joined(separator: " ")
            try #require(
                await fixture.composition.paneContextService.send(
                    .init(
                        paneId: fixture.ownerId, messageId: message, sender: sender, sourceOccurredAt: nil,
                        importance: .info, body: body, why: nil, actions: [], shape: .notice)) == .created(message))
            await fixture.composition.presentationLane.publishPending()
            let bridge = PopoverOwnerFactBridge()
            let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
            let time = PaneContextTestTime(clock: clock)
            let host = PaneContextPreparedNativeHost(
                fixture: fixture,
                entry: .messagesAction(PaneContextPopoverControlProjection.controls().messages, target: .top),
                clock: clock, wallNow: { time.now }, bridge: bridge)
            mounted = host
            try await host.open()
            try await host.bodyLayoutsPrepared()
            host.native.layout()
            let panel = try #require(host.native.find("pane-context.popover-panel") as? NSView)
            let key = PaneContextTextBodyKey.message(.init(sourcePaneId: fixture.ownerId.uuid, messageId: message.uuid))
            let row = try #require(host.native.find(key.textIdentifier) as? NSView)
            let viewport = try #require(row.enclosingScrollView?.contentView)
            let rowBounds = viewport.convert(row.bounds, from: row)
            try #require(panel.bounds.height < 480, "This single-row case must fit without the maximum-height cap")
            #expect(
                viewport.bounds.contains(rowBounds), "Opening height must include both Details and the trailing age")
            try await host.close()
            mounted = nil
            try await fixture.close()
        } catch {
            try? await mounted?.close()
            try? await fixture.close()
            throw error
        }
    }

    @Test(
        "A typed opening freezes its own completed rows before other types are included",
        arguments: [KindChipModel.Kind.needsYou, .info])
    func typedOpeningKeepsItsOwnHeight(kind: KindChipModel.Kind) async throws {
        try await withScene(entry: .kind(.init(kind: kind, count: kind == .needsYou ? 2 : 1))) { scene in
            let panel = try view(scene, "pane-context.popover-panel")
            let height = panel.bounds.height
            #expect(scene.host.interactions.selectedFilter == (kind == .needsYou ? 1 : 8))
            for selection in [15, 0, 4, 9] {
                try await scene.filter(selection)
                scene.host.native.layout()
                #expect(panel.bounds.height == height, "A typed opening cannot adopt another filter's content height")
            }
        }
    }

    private func messages(_ scene: PaneContextInteractionTestScene) throws -> MessagesPopoverModel {
        guard case .messages(let model, _) = scene.host.value?.content.body else {
            throw SceneFailure.messagesMissing
        }
        return model
    }

    private func view(_ scene: PaneContextInteractionTestScene, _ identifier: String) throws -> NSView {
        try #require(scene.host.native.find(identifier) as? NSView)
    }

    private func withScene(
        entry: PaneContextPopoverEntry? = nil,
        _ operation: (PaneContextInteractionTestScene) async throws -> Void
    ) async throws {
        let scene = try await PaneContextInteractionTestScene.make(entry: entry)
        do {
            try await operation(scene)
            try await scene.close()
        } catch {
            try? await scene.close()
            throw error
        }
    }

    private enum SceneFailure: Error { case messagesMissing }
}
