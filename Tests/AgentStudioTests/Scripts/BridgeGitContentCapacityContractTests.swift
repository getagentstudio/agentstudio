import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge Git content capacity cross-language contract")
struct BridgeGitContentCapacityContractTests {
    @Test("production Git content capacity covers the packaged worker response concurrency")
    func productionCapacityCoversPackagedWorkerConcurrency() throws {
        let root = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let source = try String(
            contentsOf: root.appending(
                path: "BridgeWeb/src/core/comm-worker/bridge-product-content-response-admission.ts"),
            encoding: .utf8
        )
        let declaration = try #require(
            source.split(separator: "\n").first {
                $0.hasPrefix("export const BRIDGE_PRODUCT_MAXIMUM_CONCURRENT_CONTENT_RESPONSES = ")
            })
        let literal = try #require(declaration.split(separator: "=").last)
            .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ";", with: "")
        let workerConcurrency = try #require(Int(literal))
        try #require(workerConcurrency > 0)
        let topology = BridgeGitReadSchedulerTopology.recoveryBaseline
        let queued = try #require(topology.maximumQueuedOperationCountByClass[.selectedVisibleContent])
        let slots = try #require(topology.slotsByOperationClass[.selectedVisibleContent])
        #expect(
            queued + slots.count >= workerConcurrency,
            "Production content capacity must cover one packaged worker's concurrent responses")
    }
}
