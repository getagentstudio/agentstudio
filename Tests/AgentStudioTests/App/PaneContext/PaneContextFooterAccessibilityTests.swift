import AgentStudioSharedComponents
import AppKit
import Testing

@testable import AgentStudio

@MainActor
@Suite("Pane context compact footer accessibility", .serialized)
struct PaneContextFooterAccessibilityTests {
    @Test("F8 native footer keeps full action labels and scoped help beside compact visible copy")
    func nativeFooterKeepsFullAccessibleMeaning() async throws {
        let scene = try await PaneContextInteractionTestScene.make()
        do {
            let controls = PaneContextPopoverControlProjection.controls()
            #expect(controls.dismissAllNotices.label == "Dismiss all")
            #expect(controls.goToPane.label == "To pane")
            let dismiss = try #require(
                scene.host.native.find(controls.dismissAllNotices.identifier) as? any NSAccessibilityProtocol)
            let navigation = try #require(
                scene.host.native.find(controls.goToPane.identifier) as? any NSAccessibilityProtocol)
            #expect(dismiss.accessibilityLabel() == "Dismiss all notices")
            #expect(navigation.accessibilityLabel() == "Go to pane")
            #expect(
                dismiss.accessibilityHelp() == "Dismiss all notices in this pane and its drawer panes; asks stay open")
            #expect(navigation.accessibilityHelp() == "Focus this message's pane")
            try await scene.close()
        } catch {
            try? await scene.close()
            throw error
        }
    }
}
