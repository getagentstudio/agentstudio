import AgentStudioInfrastructure
import AppKit
import Testing

@MainActor
@Suite("Pane context disclosure policy copy", .serialized)
struct PaneContextDisclosureCopyTests {
    @Test("F9 the real Show-less accessibility help follows the current preview-line policy")
    func nativeCollapseHelpFollowsThePreviewPolicy() async throws {
        let scene = try await PaneContextInteractionTestScene.make()
        do {
            try await scene.filter(4)
            let more = try #require(
                scene.host.native.find(scene.disclosure(expanded: false)) as? any NSAccessibilityProtocol)
            try #require(more.accessibilityPerformPress())
            try await scene.host.bodyLayoutsPrepared()
            let less = try #require(
                scene.host.native.find(scene.disclosure(expanded: true)) as? any NSAccessibilityProtocol)
            let previewLineLimit = AppPolicies.PaneContext.collapsedMessageBodyLines
            #expect(less.accessibilityLabel() == "Show less")
            #expect(less.accessibilityHelp() == "Show the first \(previewLineLimit) lines")
            try await scene.close()
        } catch {
            try? await scene.close()
            throw error
        }
    }
}
