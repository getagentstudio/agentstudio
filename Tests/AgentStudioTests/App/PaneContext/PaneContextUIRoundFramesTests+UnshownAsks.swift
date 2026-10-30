import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

extension PaneContextUIRoundFramesTests {
    enum UnshownAskFrame: String, CaseIterable {
        case capitalizedChoice, radioThree, radioFour, pickerSix, longRadioThree
        case multipleChoice, booleanCheckbox, requiredField

        static var reviewCases: [Self] {
            ProcessInfo.processInfo.environment["AGENTSTUDIO_UI_ROUND_FRAME_SET"] == "unshown-picker-interactive"
                ? [.pickerSix] : allCases
        }
    }

    @Test(
        "Owner review of previously unshown D64/D65 ask controls",
        .enabled(if: ProcessInfo.processInfo.environment["AGENTSTUDIO_UI_ROUND_REVIEW"] == "1"),
        arguments: UnshownAskFrame.reviewCases)
    func renderUnshownAskFrames(frame: UnshownAskFrame) async throws {
        installTestCoreAtomsIfNeeded()
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = try await CompositionFactoryFixture.make()
        var mounted: PaneContextPreparedNativeHost?
        do {
            let service = fixture.composition.paneContextService
            let sender = try fixture.sender(await fixture.bind(paneId: fixture.ownerId))
            let id = AgentMessageId.generateUUIDv7()
            let request = try unshownAskRequest(frame, pane: fixture.ownerId, id: id, sender: sender)
            try #require(await service.send(request) == .created(id))
            await fixture.composition.presentationLane.publishPending()
            let bridge = PopoverOwnerFactBridge()
            let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
            let time = PaneContextTestTime(clock: clock)
            let host = PaneContextPreparedNativeHost(
                fixture: fixture,
                entry: .messagesAction(PaneContextPopoverControlProjection.controls().messages, target: .top),
                clock: clock, wallNow: { time.now }, bridge: bridge)
            mounted = host
            try setReviewAppearance(host.native.window)
            try await host.open()
            try await host.rendered()
            try await host.bodyLayoutsPrepared()
            for root in host.native.roots {
                root.appearance = NSAppearance(named: .darkAqua)
                root.window?.appearance = NSAppearance(named: .darkAqua)
            }
            host.native.layout()
            let panel = try #require(host.native.find("pane-context.popover-panel") as? NSView)
            #expect(panel.bounds.width == 480)
            try assertUnshownChoiceProjection(frame, host: host)
            try applyLocalView(panel)
            try save(panel, name: "ask-" + frame.rawValue + "-480", opaqueBackground: .windowBackgroundColor)
            print("UNSHOWN_ASK_FRAME", frame.rawValue, "width", panel.bounds.width, "height", panel.bounds.height)
            if frame == .longRadioThree {
                let key = PaneContextTextBodyKey.message(.init(sourcePaneId: fixture.ownerId.uuid, messageId: id.uuid))
                try host.native.press(
                    PaneContextPopoverControlProjection.controls().showDetails.identifier(in: key.textIdentifier))
                host.native.layout()
                let split = try #require(host.native.find("pane-context.details-panel.split") as? NSView)
                try applyLocalView(split)
                try save(split, name: "ask-longRadioThree-detailsOpen-480", opaqueBackground: .windowBackgroundColor)
            }
            if ProcessInfo.processInfo.environment["AGENTSTUDIO_UI_ROUND_FRAME_SET"] == "unshown-picker-interactive" {
                try await reviewWindow(host, panel: panel, name: "unshown-pickerSix-open-480")
            }
            try await host.close()
            mounted = nil
            try await fixture.close()
        } catch {
            try? await mounted?.close()
            try? await fixture.close()
            throw error
        }
    }

    private func assertUnshownChoiceProjection(_ frame: UnshownAskFrame, host: PaneContextPreparedNativeHost) throws {
        guard
            [.capitalizedChoice, .radioThree, .radioFour, .pickerSix, .longRadioThree, .multipleChoice].contains(frame)
        else { return }
        let groups = try #require(host.value?.shape?.messages.groups)
        let row = try #require(
            groups.flatMap(\.items).compactMap { item -> MessageRowModel? in
                if case .message(let row) = item { return row }
                return nil
            }.first)
        guard case .ask(_, .choice(let options, let presentation), _, _) = row.shape else {
            Issue.record("The real publisher did not prepare the expected choice form")
            return
        }
        let expected: AskChoicePresentation =
            frame == .multipleChoice ? .checkboxes : frame == .pickerSix ? .picker : .radio
        #expect(presentation == expected)
        if frame == .capitalizedChoice {
            #expect(options.map(\.label) == ["Compact", "Expanded"])
            #expect(options.map(\.id) == ["compact", "expanded"])
        }
    }

    private func unshownAskRequest(
        _ frame: UnshownAskFrame, pane: PaneId, id: AgentMessageId, sender: AgentMessageSender
    ) throws -> PaneMessageSendRequest {
        let body: String
        let form: AskForm
        switch frame {
        case .capitalizedChoice:
            body = "Which layout should the preview use?"
            form = try unshownChoice(["compact", "expanded"])
        case .radioThree:
            body = "Choose one of the three preview layouts."
            form = try unshownChoice(["compact", "balanced", "expanded"])
        case .radioFour:
            body = "Choose one of the four verification environments."
            form = try unshownChoice(["local", "development", "staging", "production"])
        case .pickerSix:
            body = "Choose one of the six preview environments."
            form = try unshownChoice(["local", "development", "staging", "qa", "preview", "production"])
        case .longRadioThree:
            body = [
                "Which verification path should we take?",
                "Review the failing compiler diagnostic first and preserve the existing public contract.",
                "Compare the source with the last passing build and record the exact toolchain and test result.",
                "Choose the next step after reading the complete evidence and checking the current implementation.",
            ].joined(separator: " ")
            form = try unshownChoice([
                "inspect the complete failing Swift compiler diagnostic and preserve the evidence before changing the implementation",
                "compare the last passing build", "run the focused suite",
            ])
        case .multipleChoice:
            body = "Which checks should run before merge?"
            form = try unshownChoice(["swift tests", "bridgeweb tests", "lint"], multiple: true)
        case .booleanCheckbox:
            body = "Should this verification be a dry run?"
            form = .elicitation(
                .init(
                    properties: [
                        .init(name: "dry_run", title: "Dry run", description: nil, type: .boolean)
                    ], required: []))
        case .requiredField:
            body = "Provide the workspace for the verification run."
            form = .elicitation(
                .init(
                    properties: [
                        .init(
                            name: "workspace", title: "Workspace", description: nil,
                            type: .string(.init(choices: nil, minLength: 1, maxLength: nil, format: nil)))
                    ], required: ["workspace"]))
        }
        return .init(
            paneId: pane, messageId: id, sender: sender, sourceOccurredAt: nil, importance: .attention,
            body: body, why: nil, actions: [], shape: .ask(reason: .question, form: form, waiting: .nonBlocking))
    }

    private func unshownChoice(_ labels: [String], multiple: Bool = false) throws -> AskForm {
        .choice(options: try labels.map { try AskChoice(id: .init($0), label: $0) }, allowsMultiple: multiple)
    }
}
