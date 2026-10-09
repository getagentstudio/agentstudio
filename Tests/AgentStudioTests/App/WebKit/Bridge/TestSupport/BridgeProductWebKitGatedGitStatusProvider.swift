import AgentStudioCore
import AgentStudioTestHarness
import Foundation

/// Holds one real File status read so the two-pane journey can inspect the
/// updating chrome while that File refresh is still in progress.
actor BridgeProductWebKitGatedGitStatusProvider: GitWorkingTreeStatusProvider {
    private let base: any GitWorkingTreeStatusProvider
    private var shouldBlockNextStatusRead = false
    private var blockedStatusReadCount = 0
    private var blockedStatusReadStep: HeldStep<Int>?
    private let blockedReads = FactRecorder<Int, Int>(
        vocabulary: .init(
            describeScope: { "blocked File status read \($0)" }, describeFact: { "blocked count \($0)" },
            isClosing: { _, _ in false }))

    init(base: any GitWorkingTreeStatusProvider) {
        self.base = base
    }

    func armNextStatusRead() {
        shouldBlockNextStatusRead = true
    }

    func waitForBlockedStatusReadCount(_ count: Int) async throws -> Int {
        if blockedStatusReadCount >= count { return blockedStatusReadCount }
        return try await blockedReads.expectNext(in: count, where: { $0 >= count }, "File status read blocked")
    }

    func releaseBlockedStatusRead() {
        shouldBlockNextStatusRead = false
        blockedStatusReadStep?.release()
        blockedStatusReadStep = nil
    }

    func statusResult(for rootPath: URL, pathspecs: [String]?) async -> GitWorkingTreeStatusResult {
        if shouldBlockNextStatusRead {
            shouldBlockNextStatusRead = false
            blockedStatusReadCount += 1
            let step = HeldStep<Int>("blocked File status read")
            blockedStatusReadStep = step
            blockedReads.append(scope: blockedStatusReadCount, fact: blockedStatusReadCount)
            try? await step.arrive(blockedStatusReadCount)
        }
        return await base.statusResult(for: rootPath, pathspecs: pathspecs)
    }

    func statusFactsResult(
        for rootPath: URL,
        pathspecs: [String]?
    ) async -> GitWorkingTreeStatusFactsResult {
        await base.statusFactsResult(for: rootPath, pathspecs: pathspecs)
    }

    func lineDetailResult(for rootPath: URL) async -> GitWorkingTreeLineDetailResult {
        await base.lineDetailResult(for: rootPath)
    }
}
