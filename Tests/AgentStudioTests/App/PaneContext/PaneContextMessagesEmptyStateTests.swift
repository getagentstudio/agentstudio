import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("Centered Messages empty states", .serialized)
struct PaneContextMessagesEmptyStateTests {
    enum EmptyState: String, CaseIterable {
        case allOff, nothingMatches, needsYou, failed, done, info, general
        var selection: Int {
            switch self {
            case .allOff: 0
            case .nothingMatches: 12
            case .needsYou: 1
            case .failed: 2
            case .done: 4
            case .info: 8
            case .general: 15
            }
        }
    }

    @Test("Every empty state centers its text in the fixed scroll body", arguments: EmptyState.allCases)
    func emptyTextIsCenteredInFixedBody(state: EmptyState) async throws {
        try await verifyEmptyState(state)
    }

    @Test("Retained action feedback stays visible without displacing the centered empty text")
    func retainedFeedbackDoesNotDisplaceEmptyText() async throws {
        try await verifyEmptyState(.allOff, feedback: "Invalid answer: field count")
    }

    private func verifyEmptyState(_ state: EmptyState, feedback: String? = nil) async throws {
        installTestCoreAtomsIfNeeded()
        let frames = PaneContextUIRoundFramesTests()
        let pane = PaneId.generateUUIDv7()
        let initial = await shape(.filterNone, pane: pane)
        let inputs = PaneContextUIRoundFramesTests.CombinedInputs(model: initial.messages)
        let native = PaneContextNativePopoverWindow(
            preparedRoot: AnyView(
                PaneContextUIRoundFramesTests.CombinedContent(inputs: inputs, pane: pane, width: 480)),
            viewportWidth: 480, viewportHeight: 520)
        do {
            native.window.appearance = NSAppearance(named: .darkAqua)
            let capture = ProcessInfo.processInfo.environment["AGENTSTUDIO_UI_ROUND_REVIEW"] == "1"
            if capture { try frames.setReviewAppearance(native.window) }
            native.layout()
            inputs.model = await PaneContextUIRoundFramesTests.prepareCombinedBodies(
                inputs.model, geometry: inputs.geometry, pane: pane)
            native.layout()
            let panel = try #require(native.find("pane-context.popover-panel") as? NSView)
            let openingHeight = panel.bounds.height
            inputs.feedback = feedback
            if state != .allOff {
                inputs.model = await shape(state == .nothingMatches ? .filterEmpty : nil, pane: pane).messages
            }
            let filters = PaneContextPopoverControlProjection.controls().filters
            for (index, membership) in [1, 2, 4, 8].enumerated() where (15 ^ state.selection) & membership != 0 {
                try native.press(filters[index + 1].identifier)
            }
            native.layout()
            try frames.applyLocalView(panel)
            let text = try #require(native.find("pane-context.filter-no-loaded") as? NSView)
            let body = try #require(text.enclosingScrollView?.contentView)
            let textBounds = body.convert(text.bounds, from: text)
            let scale = native.window.backingScaleFactor
            #expect(abs(textBounds.midX - body.bounds.midX) * scale <= 1)
            #expect(abs(textBounds.midY - body.bounds.midY) * scale <= 1)
            #expect(panel.bounds.height == openingHeight)
            #expect(text.accessibilityRole() == .staticText)
            if feedback != nil { #expect(native.find("pane-context.feedback") != nil) }
            if capture {
                try FileManager.default.createDirectory(at: frames.output, withIntermediateDirectories: true)
                try frames.save(
                    panel, name: "messages-empty-" + (feedback == nil ? state.rawValue : "retainedFeedback") + "-480",
                    opaqueBackground: .windowBackgroundColor)
            }
            print(
                "EMPTY_STATE_GEOMETRY", state.rawValue, "text", textBounds, "body", body.bounds, "height",
                panel.bounds.height)
            try await native.close()
        } catch {
            try? await native.close()
            throw error
        }
    }

    private func shape(_ frame: PaneContextUIRoundFramesTests.CombinedFrame?, pane: PaneId) async
        -> PaneContextPopoverShape
    {
        let messages = frame.map { PaneContextUIRoundFramesTests.combinedMessages(frame: $0, pane: pane) } ?? []
        return await PaneContextPopoverShaping.shape(
            PaneContextPopoverShapingTests.detail(paneId: pane, messages: messages), sourceTitles: [:],
            counts: .init(
                failure: messages.filter { $0.importance == .failure }.count,
                needsYou: messages.filter { $0.importance == .attention }.count,
                done: messages.filter { $0.importance == .done }.count,
                info: messages.filter { $0.importance == .info }.count), now: .distantPast)
    }
}
