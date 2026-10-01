import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree removal outcome projector")
struct WorktreeRemovalOutcomeProjectorTests {
    @Test("retained branch options carry the exact command for each checkout path")
    func checkedOutBranchOptionsPreserveEveryPath() {
        let repository = URL(fileURLWithPath: "/tmp/repository with spaces", isDirectory: true)
        let paths = ["/tmp/first worktree", "/tmp/second-worktree"]

        let document = WorktreeRemovalOutcomeProjector.branchDocument(
            name: "feature/linked",
            commit: "observed-commit",
            reason: .checkedOut(worktreePaths: paths),
            repositoryPath: repository
        )

        #expect(document.disposition == .retained)
        #expect(document.reason == .checkedOut(worktreePaths: paths))
        #expect(
            document.options
                == [
                    "agentstudio worktree remove --repo '/tmp/repository with spaces' '/tmp/first worktree'",
                    "agentstudio worktree remove --repo '/tmp/repository with spaces' /tmp/second-worktree",
                ])
    }

    @Test("empty checkout details fail closed and retention options follow the reason")
    func emptyCheckoutDetailsAndOtherOptions() {
        let repository = URL(fileURLWithPath: "/tmp/repository")
        let checkoutUnknown = WorktreeRemovalOutcomeProjector.branchDocument(
            name: "feature/branch",
            commit: nil,
            reason: .checkedOut(worktreePaths: []),
            repositoryPath: repository
        )
        let remaining = WorktreeRemovalOutcomeProjector.branchDocument(
            name: "feature/remaining",
            commit: "observed-commit",
            reason: .hasRemainingContribution,
            repositoryPath: repository
        )
        let kept = WorktreeRemovalOutcomeProjector.branchDocument(
            name: "feature/kept",
            commit: "observed-commit",
            reason: .branchPolicyKeep,
            repositoryPath: repository
        )

        #expect(checkoutUnknown.reason == .checkoutUnknown)
        #expect(checkoutUnknown.options == ["agentstudio worktree remove --repo /tmp/repository feature/branch"])
        #expect(remaining.options == ["agentstudio worktree remove --repo /tmp/repository feature/remaining -D"])
        #expect(kept.options.isEmpty)
    }
}
