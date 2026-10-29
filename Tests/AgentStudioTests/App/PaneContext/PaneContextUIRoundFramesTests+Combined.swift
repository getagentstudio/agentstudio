import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import Observation
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

extension PaneContextUIRoundFramesTests {
    enum CombinedFrame: String, CaseIterable {
        case filterNone, filterOne, filterTwo, filterEmpty
        case proseClosed, proseOpen, questionClosed, questionOpen, buildClosed, buildOpen, shortRows

        nonisolated static var reviewCases: [Self] {
            ProcessInfo.processInfo.environment["AGENTSTUDIO_UI_ROUND_FRAME_SET"] == "text-correction"
                ? [.proseClosed, .proseOpen, .questionClosed, .questionOpen, .buildClosed, .buildOpen] : allCases
        }
    }

    @MainActor @Observable
    final class CombinedInputs {
        var model: MessagesPopoverModel
        var selection = 0
        var details: PaneContextMessageTextValue?
        @ObservationIgnored var geometry: [PaneContextTextBodyKey: PaneContextMessageBodyGeometry] = [:]
        init(model: MessagesPopoverModel) { self.model = model }
    }

    private struct CombinedContent: View {
        let inputs: CombinedInputs
        let pane: PaneId
        let width: CGFloat
        var body: some View {
            MessagesPopover(
                paneId: pane.uuid, model: inputs.model,
                controls: PaneContextPopoverControlProjection.controls(), octiconLoader: makeTestOcticonLoader(),
                location: .pane, width: width,
                actions: .init(
                    answer: { _, _, _ in }, dismiss: { _, _ in }, dismissAllNotices: {},
                    runAction: { _, _, _ in }, goToPane: { _ in }, moreMessages: { _ in }, moreSources: { _ in },
                    dismissPopover: {}, captureBodyGeometry: { inputs.geometry[$0] = $1 }),
                interactions: .init(
                    selectedFilter: .init(get: { inputs.selection }, set: { inputs.selection = $0 }),
                    draft: { _ in .constant(.init()) },
                    details: .init(get: { inputs.details }, set: { inputs.details = $0 })))
        }
    }

    @Test(
        "Combined D83/D84a/D85 component review originals",
        .enabled(if: ProcessInfo.processInfo.environment["AGENTSTUDIO_UI_ROUND_REVIEW"] == "1"),
        arguments: CombinedFrame.reviewCases, [440, 480])
    func renderCombinedFrames(frame: CombinedFrame, width: Int) async throws {
        installTestCoreAtomsIfNeeded()
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let pane = PaneId.generateUUIDv7()
        let messages = Self.combinedMessages(frame: frame, pane: pane)
        let counts = PaneMessageKindCounts(
            failure: messages.filter { $0.importance == .failure }.count,
            needsYou: messages.filter { $0.importance == .attention }.count,
            done: messages.filter { $0.importance == .done }.count,
            info: messages.filter { $0.importance == .info }.count)
        let shape = await PaneContextPopoverShaping.shape(
            PaneContextPopoverShapingTests.detail(paneId: pane, messages: messages),
            sourceTitles: [:], counts: counts, now: .distantPast)
        let inputs = CombinedInputs(model: shape.messages)
        let native = PaneContextNativePopoverWindow(
            preparedRoot: AnyView(CombinedContent(inputs: inputs, pane: pane, width: CGFloat(width))),
            viewportWidth: CGFloat(width + 365), viewportHeight: 520)
        do {
            let screen = try #require(
                NSScreen.screens.first { $0.backingScaleFactor == 2 }, "A 2x native screen is required")
            native.window.setFrameOrigin(.init(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40))
            native.window.appearance = NSAppearance(named: .darkAqua)
            for root in native.roots { root.appearance = NSAppearance(named: .darkAqua) }
            native.layout()
            let panel = try #require(native.find("pane-context.popover-panel") as? NSView)
            try applyLocalView(panel)
            inputs.model = await Self.prepareCombinedBodies(inputs.model, geometry: inputs.geometry, pane: pane)
            native.layout()
            try applyLocalView(panel)
            try applyCombinedSelection(frame, native: native)
            if [.proseOpen, .questionOpen, .buildOpen].contains(frame) {
                let message = try #require(messages.first)
                let key = PaneContextTextBodyKey.message(.init(sourcePaneId: pane.uuid, messageId: message.id.uuid))
                try native.press(
                    PaneContextPopoverControlProjection.controls().showDetails.identifier(in: key.textIdentifier))
            }
            native.layout()
            let split = try #require(native.find("pane-context.details-panel.split") as? NSView)
            try applyLocalView(split)
            let prefix =
                ProcessInfo.processInfo.environment["AGENTSTUDIO_UI_ROUND_FRAME_SET"] == "text-correction"
                ? "combined-text-correction-" : "combined-"
            try save(
                split, name: prefix + "\(frame.rawValue)-\(width)",
                opaqueBackground: AppStyles.Shell.TabBar.titlebarBackground)
            print(
                "COMBINED_FRAME", frame.rawValue, "primary", panel.bounds.width,
                "split", split.bounds.width, "height", split.bounds.height, "scale", native.window.backingScaleFactor)
            try await native.close()
        } catch {
            try? await native.close()
            throw error
        }
    }

    private func applyCombinedSelection(_ frame: CombinedFrame, native: PaneContextNativePopoverWindow) throws {
        let controls = PaneContextPopoverControlProjection.controls().filters
        switch frame {
        case .filterOne: try native.press(controls[2].identifier)
        case .filterTwo:
            try native.press(controls[1].identifier)
            try native.press(controls[4].identifier)
        case .filterEmpty:
            try native.press(controls[3].identifier)
            try native.press(controls[4].identifier)
        default: break
        }
    }

    @concurrent nonisolated private static func prepareCombinedBodies(
        _ model: MessagesPopoverModel, geometry: [PaneContextTextBodyKey: PaneContextMessageBodyGeometry], pane: PaneId
    ) async -> MessagesPopoverModel {
        PaneContextPopoverShapingKernel.prepareBodyLayouts(
            model, geometry: geometry, baseline: [:], performance: .init(recorder: nil),
            consumer: .init(hostId: UUIDv7.generate(), surface: .paneMessages, paneId: pane)
        ).model
    }

    private static func combinedMessages(frame: CombinedFrame, pane: PaneId) -> [AgentMessageDetail] {
        let prose = """
            The workspace review is ready for your attention.

            The latest changes keep each pane's messages together and preserve your draft while you filter the list.
            The review includes the long notice, the question form, and the build log below.
            Please read the complete explanation before choosing the next step.
            Existing message actions still refer to the same pane and message.
            Short notices keep their compact spacing without a reserved details button.
            You can open this reading panel without losing your place in the list.
            """
        let question = """
            Which evidence should we collect before changing text-layout retention?

            Identify the executor that runs each text layout when the popover opens.
            Report total work and the longest layout for both schedules.
            Distinguish a requested key from a raw native width capture.
            Check whether repeated keys overlap or run again in sequence.
            Preserve the unchanged-minute zero-layout and zero-SQL proof.
            Keep the existing retention policy until the measurements are reviewed.
            """
        func message(_ body: String, _ importance: MessageImportance, ask: Bool = false) -> AgentMessageDetail {
            .init(
                id: .generateUUIDv7(), sourcePaneId: pane, sender: .pane(pane), sentAt: .distantPast,
                sourceOccurredAt: nil, importance: importance, body: body, why: nil, actions: [],
                shape: ask
                    ? .ask(.question, .freeText(placeholder: "Report the evidence"), .nonBlocking, .open)
                    : .notice(.unread))
        }
        switch frame {
        case .proseClosed, .proseOpen: return [message(prose, .info)]
        case .questionClosed, .questionOpen: return [message(question, .attention, ask: true)]
        case .buildClosed, .buildOpen:
            return [message("Build output\n\n```text\n" + compilerOutput + "\n```", .failure)]
        case .filterEmpty: return [message("Which branch should receive the fix?", .attention, ask: true)]
        case .filterNone, .filterOne, .filterTwo:
            return [
                message("The build failed in the terminal target.", .failure),
                message("Which branch should receive the fix?", .attention, ask: true),
                message("The review notes are ready.", .info),
            ]
        case .shortRows:
            return [
                message("A one-line information notice", .info),
                message("Type a short reply to verify the pane card", .attention, ask: true),
            ]
        }
    }
}
