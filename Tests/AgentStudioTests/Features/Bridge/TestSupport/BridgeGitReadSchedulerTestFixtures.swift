import AgentStudioCore
import Foundation

@testable import AgentStudioBridge

func makeBridgeGitReadContext(rootURL: URL) -> BridgeGitReadContext {
    BridgeGitReadContext(
        scheduler: BridgeGitReadScheduler(
            topology: .recoveryBaseline,
            deadlineScheduler: BridgeGitReadManualDeadlineScheduler()
        ),
        worktreeKey: BridgeGitReadWorktreeKey(token: StableKey.fromPath(rootURL))
    )
}

func loadTestBridgeFileIgnorePolicy(rootURL: URL) async -> BridgeWorktreeFileIgnorePolicy {
    await BridgeWorktreeFileIgnorePolicy.load(
        rootURL: rootURL,
        gitReadContext: makeBridgeGitReadContext(rootURL: rootURL),
        statusProvider: ProductFileSourceStatusProvider()
    )
}
