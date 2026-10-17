import AgentStudioCore
import Testing

@testable import AgentStudioRepoExplorer

@Suite
struct RepoExplorerPanePullRequestTests {
    @Test
    func existingSinglePRAndLoadingChipRemainUnchanged() {
        let states: [GitBranchStatus] = [
            .init(
                isDirty: false, syncState: .noUpstream, prCount: 1, linesAdded: 0, linesDeleted: 0,
                untrackedFileCount: 0),
            .init(
                isDirty: false, syncState: .noUpstream, prCount: 1, pullRequestIsLoading: true, linesAdded: 0,
                linesDeleted: 0, untrackedFileCount: 0),
            .init(
                isDirty: false, syncState: .noUpstream, prCount: nil, pullRequestIsLoading: true, linesAdded: 0,
                linesDeleted: 0, untrackedFileCount: 0),
            .init(
                isDirty: false, syncState: .noUpstream, prCount: 1, pullRequestDataUnavailable: true, linesAdded: 0,
                linesDeleted: 0, untrackedFileCount: 0),
        ]
        let expected: [SidebarPullRequestChipSpec.Presentation] = [
            .accent(count: 1), .neutral(count: 1), .neutral(count: nil), .hidden,
        ]
        for (status, expected) in zip(states, expected) {
            #expect(
                SidebarPullRequestChipSpec.presentation(branchStatus: status, usesPanesLoadingChip: true) == expected)
            let variant = RepoExplorerPaneRowVariants.make(
                title: "Pane", branchContext: nil, note: nil, isDrawer: false,
                branchStatus: status, isActive: false)
            #expect(variant.compact.chips == (expected == .hidden ? [.clock] : [.gitPR, .clock]))
        }
    }

}
