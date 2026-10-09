import AgentStudioTestSupport
import Foundation
import Testing

@Suite("Bridge Review visibility static contract")
struct BridgeReviewVisibilityStaticContractTests {
    @Test("Review lifecycle visibility uses the accepted page mode")
    func reviewLifecycleDoesNotReadNativeDesiredSurface() throws {
        let projectRoot = URL(
            fileURLWithPath: TestPathResolver.projectRoot(from: #filePath)
        )
        let lifecyclePaths = [
            "Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneController+ReviewBuildAdmission.swift",
            "Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneController+RefreshAdmission.swift",
            "Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneController+ReviewRefreshImpact.swift",
            "Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneController+DiffCommands.swift",
        ]

        for relativePath in lifecyclePaths {
            let source = try String(
                contentsOf: projectRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            #expect(
                !source.contains("retainedViewerSurface"),
                "\(relativePath) must use the accepted page mode as Review visibility"
            )
        }
    }
}
