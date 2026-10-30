import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

extension PaneContextUIRoundFramesTests {
    enum PolishOpeningFrame: String, CaseIterable {
        case needsYouIndicator, failedIndicator, doneIndicator, infoIndicator
        case cardMore, cardShowMessages, cardAnswer

        var indicatorKind: KindChipModel.Kind? {
            switch self {
            case .needsYouIndicator: .needsYou
            case .failedIndicator: .failure
            case .doneIndicator: .done
            case .infoIndicator: .info
            case .cardMore, .cardShowMessages, .cardAnswer: nil
            }
        }

        static var reviewCases: [Self] {
            ProcessInfo.processInfo.environment["AGENTSTUDIO_UI_ROUND_FRAME_SET"] == "unshown-asks"
                ? allCases.filter { $0.indicatorKind != nil } : allCases
        }

        var controlIdentifier: String {
            switch self {
            case .needsYouIndicator: "pane-context.messages.needsYou"
            case .failedIndicator: "pane-context.messages.failure"
            case .doneIndicator: "pane-context.messages.done"
            case .infoIndicator: "pane-context.messages.info"
            case .cardMore: "pane-context.card-more"
            case .cardShowMessages: "pane-context.card-messages"
            case .cardAnswer: "pane-context.answer-in-messages"
            }
        }
    }

    @Test(
        "Owner review captures the actual indicator and card Messages openings",
        .enabled(if: ProcessInfo.processInfo.environment["AGENTSTUDIO_UI_ROUND_REVIEW"] == "1"),
        arguments: PolishOpeningFrame.reviewCases)
    func renderOpeningIntentFrames(frame: PolishOpeningFrame) async throws {
        installTestCoreAtomsIfNeeded()
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let atoms = CoreAtomScope.store
        let store = WorkspaceStore(
            catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
            interactionAtom: atoms.workspaceTabLayout)
        let pane = store.createPane(title: "Messages review")
        defer { store.removePane(pane.id) }
        let fixture = try await CompositionFactoryFixture.make(ownerId: .init(existingUUID: pane.id))
        var mounted: PaneContextPreparedNativeHost?
        do {
            let ask = try await seedOpeningFrame(frame, fixture: fixture)
            let adapter = PaneContextUIAdapter(service: fixture.composition.paneContextService)
            let owners = PaneContextTestSourceOwners(
                sessionStatus: .init(), presentation: fixture.presentationAtom,
                pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
            let host: PaneContextPreparedNativeHost
            if let kind = frame.indicatorKind {
                host = owners.makeNativeHost(
                    paneId: fixture.ownerId, entry: .kind(.init(kind: kind, count: 1)), wallNow: fixture.now)
            } else {
                host = owners.makeNativeCardHost(
                    context: .project(paneId: pane.id, store: store), wallNow: fixture.now)
            }
            mounted = host
            try setReviewAppearance(host.native.window)
            if frame.indicatorKind == nil {
                try await host.open()
                try await host.renderedCard()
                let card = try #require(host.native.find("paneManagement.identityStrip") as? NSView)
                try applyLocalView(card)
                try save(card, name: "card-" + frame.rawValue, opaqueBackground: .windowBackgroundColor)
                print("CARD_FRAME", frame.rawValue, "width", card.bounds.width, "height", card.bounds.height)
                if frame == .cardMore { #expect(host.cardValue?.card?.moreCount == 1) }
            }
            let producer = try host.beginOpening(frame.controlIdentifier)
            try await host.completeOpening(producer)
            try await host.rendered()
            try await host.bodyLayoutsPrepared()
            let popover = try #require(host.native.popoverWindow)
            try setReviewAppearance(popover)
            host.native.layout()
            let selection: Int
            switch frame {
            case .needsYouIndicator: selection = 1
            case .failedIndicator: selection = 2
            case .doneIndicator: selection = 4
            case .infoIndicator: selection = 8
            case .cardMore, .cardShowMessages, .cardAnswer: selection = 15
            }
            // Card and child popover have separate opening-local interaction owners.
            #expect(host.interactions.selectedFilter == (frame.indicatorKind == nil ? 0 : selection))
            for (index, membership) in [1, 2, 4, 8].enumerated() {
                let chip = try #require(
                    host.native.find(PaneContextPopoverControlProjection.controls().filters[index + 1].identifier)
                        as? any NSAccessibilityProtocol)
                #expect(chip.isAccessibilitySelected() == (selection & membership != 0))
            }
            let target: PaneContextMessagesTarget
            switch frame {
            case .needsYouIndicator: target = .section(.needsYou)
            case .failedIndicator: target = .section(.failed)
            case .doneIndicator: target = .section(.done)
            case .infoIndicator: target = .section(.info)
            case .cardAnswer: target = .message(.init(paneId: fixture.ownerId, messageId: try #require(ask)))
            case .cardMore, .cardShowMessages: target = .top
            }
            #expect(host.value?.shape?.messagesTarget == target)
            let panel = try #require(host.native.find("pane-context.popover-panel") as? NSView)
            try applyLocalView(panel)
            try save(panel, name: "messages-opening-" + frame.rawValue, opaqueBackground: .windowBackgroundColor)
            print(
                "OPENING_FRAME", frame.rawValue, "control", frame.controlIdentifier,
                "filter", selection, "target", String(describing: target), "width", panel.bounds.width,
                "height", panel.bounds.height, "scale", popover.backingScaleFactor)
            try await host.close()
            try await fixture.close()
        } catch {
            try? await mounted?.close()
            try? await fixture.close()
            throw error
        }
    }

    private func seedOpeningFrame(_ frame: PolishOpeningFrame, fixture: CompositionFactoryFixture) async throws
        -> AgentMessageId?
    {
        let service = fixture.composition.paneContextService
        let sender = try fixture.sender(await fixture.bind(paneId: fixture.ownerId))
        var ask: AgentMessageId?
        if frame != .cardShowMessages {
            let id = AgentMessageId.generateUUIDv7()
            let form: AskForm =
                frame == .cardAnswer
                ? .elicitation(
                    .init(
                        properties: [
                            .init(
                                name: "checks", title: "Checks", description: nil,
                                type: .string(.init(choices: nil, minLength: 1, maxLength: nil, format: nil)))
                        ], required: ["checks"]))
                : .freeText(placeholder: "Describe the checks")
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.ownerId, messageId: id, sender: sender, sourceOccurredAt: nil,
                        importance: .attention, body: "Which checks should we run before merging the Messages changes?",
                        why: "Keep the review evidence together before choosing the next step.", actions: [],
                        shape: .ask(
                            reason: .question, form: form,
                            waiting: .nonBlocking))) == .created(id))
            ask = id
        }
        for (importance, body) in [
            (MessageImportance.failure, "The preview build needs a corrected source path."),
            (.info, "The review frames are ready for inspection."),
        ] {
            let id = AgentMessageId.generateUUIDv7()
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.ownerId, messageId: id, sender: sender, sourceOccurredAt: nil,
                        importance: importance, body: body, why: nil, actions: [], shape: .notice)) == .created(id))
        }
        if frame == .doneIndicator {
            let id = AgentMessageId.generateUUIDv7()
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.ownerId, messageId: id, sender: sender, sourceOccurredAt: nil,
                        importance: .done, body: "The preview verification is complete.", why: nil, actions: [],
                        shape: .notice)) == .created(id))
        }
        await fixture.composition.presentationLane.publishPending()
        return ask
    }

    func setReviewAppearance(_ window: NSWindow) throws {
        let screen = try #require(NSScreen.screens.first { $0.backingScaleFactor == 2 })
        window.setFrameOrigin(.init(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40))
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView?.appearance = NSAppearance(named: .darkAqua)
        #expect(window.backingScaleFactor == 2)
    }
}
