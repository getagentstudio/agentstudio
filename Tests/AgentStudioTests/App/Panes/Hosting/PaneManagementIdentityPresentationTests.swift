import AgentStudioRepoExplorer
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite(.serialized)
struct PaneManagementIdentityPresentationTests {
    @Test(arguments: [false, true])
    func locationOnlyAddsDistinctInformation(belowRoot: Bool) {
        let context = PaneIdentityCardFixture.context(belowRoot: belowRoot)
        let model = ManagementPaneIdentityPresentation(context: context, lines: [.title("Agent | project")])
        #expect(model.rows.map(\.id) == (belowRoot ? ["repo", "branch", "cwd", "pane"] : ["repo", "branch", "pane"]))
        #expect(Set(model.rows.map(\.text)).count == model.rows.count)
        #expect(model.title == "Agent | project")
    }

    @Test(arguments: [false, true])
    func worktreeRootComparisonUsesThePath(hasDirectoryHint: Bool) {
        let base = PaneIdentityCardFixture.context()
        let context = PaneManagementContext(
            paneId: base.paneId, identityRows: base.identityRows, statusChips: base.statusChips,
            targetPath: URL(filePath: "/tmp/project", directoryHint: hasDirectoryHint ? .isDirectory : .notDirectory),
            showsIdentityBlock: true)
        let model = ManagementPaneIdentityPresentation(context: context, lines: [])
        #expect(!model.rows.contains { $0.id == "cwd" })
    }

    @Test func distinctWorktreeAndChildDirectoryRemainVisible() {
        let base = PaneIdentityCardFixture.context(belowRoot: true)
        let rows = base.identityRows.map { row in
            row.id == "worktree"
                ? PaneManagementIdentityRow(id: row.id, icon: row.icon, text: "feature", toolTip: row.toolTip) : row
        }
        let context = PaneManagementContext(
            paneId: base.paneId, identityRows: rows, statusChips: base.statusChips,
            targetPath: base.targetPath, showsIdentityBlock: true)
        let model = ManagementPaneIdentityPresentation(context: context, lines: [])
        #expect(model.rows.map(\.id) == ["repo", "branch", "worktree", "cwd", "pane"])
        #expect(model.rows.first { $0.id == "cwd" }?.text == "Sources/App")
    }

    @Test(arguments: [false, true])
    func hookStatusIsOptional(hasStatus: Bool) throws {
        let working = try #require(RepoExplorerPaneContextLine.session(.working(.active)))
        let lines: [RepoExplorerPaneRowLine] =
            hasStatus ? [.title("Agent"), .sessionStatus(working)] : [.title("Agent")]
        let model = ManagementPaneIdentityPresentation(context: PaneIdentityCardFixture.context(), lines: lines)
        #expect(model.status == (hasStatus ? working : nil))
        #expect(model.secondaryLines.isEmpty)
    }

    @Test func secondaryLinesHaveFixedOrder() {
        let message = PaneIdentityCardFixture.message
        let warning = PaneIdentityCardFixture.warning
        let model = ManagementPaneIdentityPresentation(
            context: PaneIdentityCardFixture.context(),
            lines: [.note("Keep this pane"), .connectionIssue(warning), .agentLine(message), .title("Agent")])
        #expect(model.secondaryLines == [.agentLine(message), .connectionIssue(warning), .note("Keep this pane")])
    }

    @Test func sessionUsesOnlyTheContextsVerifiedRow() {
        let context = PaneIdentityCardFixture.context()
        let noSession = ManagementPaneIdentityPresentation(context: context, lines: [])
        #expect(!noSession.rows.contains { $0.id == "session" })
        // Session verification is exercised through the live read in CaptureTests;
        // this presentation seam must preserve, rather than infer, that result.
        let verified = PaneManagementContext(
            paneId: context.paneId,
            identityRows: context.identityRows + [
                .init(id: "session", icon: .system("terminal"), text: "codex · verified-session", toolTip: nil)
            ],
            statusChips: nil, targetPath: context.targetPath, showsIdentityBlock: true)
        let model = ManagementPaneIdentityPresentation(context: verified, lines: [])
        #expect(model.rows.filter { $0.id == "session" }.map(\.text) == ["codex · verified-session"])
    }
    @Test func identityCopyActionsComeFromTheCatalog() {
        let context = PaneIdentityCardFixture.context()
        let model = ManagementPaneIdentityPresentation(context: context, lines: [])
        let pane = context.identityRows.first { $0.id == "pane" }!
        let session = PaneManagementIdentityRow(
            id: "session", icon: .system("terminal"), text: "codex · verified-session", toolTip: nil)
        #expect(model.copyAction(for: pane).label == "Copy Pane ID")
        #expect(model.copyAction(for: pane).helpText == "Copy the full pane ID")
        #expect(model.copyAction(for: session).label == "Copy Session ID")
        #expect(model.copyAction(for: session).helpText == "Copy the full session ID")
        #expect(model.copyAction(for: pane).icon == .system(.documentOnDocument))
        #expect(model.copyAction(for: session).icon == .system(.documentOnDocument))
    }

}
