import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Arrangements compact table projection")
struct ArrangementTableProjectionTests {
    @Test("table uses pane title and summary with a separate named worktree and branch")
    func canonicalColumnValues() async throws {
        let repoId = UUIDv7.generate()
        let worktree = Worktree(
            id: UUIDv7.generate(), repoId: repoId, name: "Friendly checkout",
            path: URL(filePath: "/tmp/different-folder"))
        let repo = Repo(id: repoId, name: "Repository", repoPath: URL(filePath: "/tmp/repo"), worktrees: [worktree])
        let paneId = UUIDv7.generate()
        let line = AgentLineDetail(
            summary: "Running Swift tests", refs: [], writer: .pane(.init(existingUUID: paneId)),
            updatedAt: .distantPast)
        let display = PaneContextDisplay(
            revision: .init(1), agentTitle: "✳ claude", agentLine: line,
            own: .zero, includingDrawers: .zero, pullRequests: .notApplicable)
        let source = makeArrangementPaneSource(
            id: paneId, display: display, session: .init(status: .working(.active), evidence: .verifiedLive),
            repo: repo, worktree: worktree,
            enrichment: .init(worktreeId: worktree.id, repoId: repo.id, branch: " feature/table "))

        let projection = try await ArrangementTableProjector.project(makeArrangementInput([source]))

        let row = try #require(projection.panes.first)
        #expect(row.title == "claude")
        #expect(row.agentLine == "Running Swift tests")
        #expect(row.worktreeName == "Friendly checkout")
        #expect(row.branchName == "feature/table")
        #expect(row.worktreePath == "/tmp/different-folder")
        #expect(
            row.agentStatus
                == .agent(.init(kind: .working, label: "Working", detail: "Working", icon: .system(.circleFill))))
        #expect(row.paneIcon == .pane)
        #expect(row.supportsZoom)
        #expect(row.section == .unsectioned)
    }

    @Test(
        "agent evidence is required and Hidden overrides the status without changing its source",
        arguments: [StatusEvidence.verifiedLive, .verifiedEnded, .unverified, .none])
    func hiddenAndEvidence(evidence: StatusEvidence) async throws {
        let source = makeArrangementPaneSource(session: .init(status: .working(.active), evidence: evidence))
        let visible = try await ArrangementTableProjector.project(makeArrangementInput([source]))
        let hidden = try await ArrangementTableProjector.project(
            makeArrangementInput([source], minimized: [source.state.id]))
        let row = try #require(visible.panes.first)
        switch evidence {
        case .verifiedLive, .verifiedEnded:
            #expect(
                row.agentStatus
                    == .agent(.init(kind: .working, label: "Working", detail: "Working", icon: .system(.circleFill))))
        case .unverified, .none: #expect(row.agentStatus == .unavailable)
        }
        #expect(hidden.panes.first?.agentStatus == .hidden)
        #expect(source.session?.status == .working(.active))
        #expect(row.agentLine == nil)
        #expect(row.title == "fish")
    }

    @Test("unknown branch and known detached branch remain different", arguments: [false, true])
    func branchEvidence(hasEnrichment: Bool) async throws {
        let repoId = UUIDv7.generate()
        let worktree = Worktree(
            id: UUIDv7.generate(), repoId: repoId, name: "Checkout", path: URL(filePath: "/tmp/checkout"))
        let repo = Repo(id: repoId, name: "Repository", repoPath: URL(filePath: "/tmp/repo"), worktrees: [worktree])
        let source = makeArrangementPaneSource(
            repo: repo, worktree: worktree,
            enrichment: hasEnrichment ? .init(worktreeId: worktree.id, repoId: repo.id, branch: " ") : nil)

        let projected = try await ArrangementTableProjector.project(makeArrangementInput([source]))

        #expect(projected.panes.first?.branchName == (hasEnrichment ? "detached HEAD" : nil))
    }

    @Test("short status label retains the complete reason and established glyph in its projected detail")
    func compactStatusRetainsReason() async throws {
        let prompt = CompactProviderPrompt(
            reason: .question, summary: "Use staging?", observedAt: .distantPast, omittedOrFurtherCount: 0)
        let source = makeArrangementPaneSource(
            session: .init(
                status: .needsYou(.question), evidence: .verifiedLive, compactPrompt: prompt))
        let projected = try await ArrangementTableProjector.project(makeArrangementInput([source]))
        let row = try #require(projected.panes.first)
        guard case .agent(let status) = row.agentStatus else {
            Issue.record("Expected verified agent status")
            return
        }
        #expect(status.label == "Needs you")
        #expect(status.detail == "Needs you · question: Use staging?")
        #expect(status.icon == .system(.flag))
        #expect(status.kind == .needsYou)
    }

    @Test("table keeps active root order and omits drawers and panes from another arrangement")
    func activeRootMembership() async throws {
        let first = makeArrangementPaneSource(title: "First")
        let second = makeArrangementPaneSource(title: "Second")
        let other = makeArrangementPaneSource(title: "Other arrangement")
        let drawer = makeArrangementPaneSource(title: "Drawer", parent: first.state.id)
        let projected = try await ArrangementTableProjector.project(
            makeArrangementInput(
                [first, other, drawer, second], layout: [second.state.id, drawer.state.id, first.state.id]))
        #expect(projected.panes.map(\.id) == [second.state.id, first.state.id])
    }

    @Test("a missing source cannot invent a Terminal row or an Idle agent")
    func missingSourceAndUnboundStatus() async throws {
        let source = makeArrangementPaneSource(title: "Known pane")
        let projected = try await ArrangementTableProjector.project(
            makeArrangementInput([source], layout: [UUIDv7.generate(), source.state.id]))
        #expect(projected.panes.map(\.title) == ["Known pane"])
        #expect(projected.panes.first?.agentStatus == .unavailable)
    }

    @Test("nonterminal retains its identity and cannot zoom")
    func nonterminalCapability() async throws {
        let source = makeArrangementPaneSource(
            title: "Bridge · Review", content: .webview(.init(url: URL(filePath: "/tmp/review"))))
        let projected = try await ArrangementTableProjector.project(makeArrangementInput([source]))
        #expect(projected.panes.first?.title == "Bridge · Review")
        #expect(projected.panes.first?.supportsZoom == false)
    }

    @Test("a mismatched repository association supplies no checkout or branch")
    func rejectsMismatchedAssociation() async throws {
        let worktree = Worktree(
            id: UUIDv7.generate(), repoId: UUIDv7.generate(), name: "Wrong", path: URL(filePath: "/tmp/wrong"))
        let repo = Repo(id: UUIDv7.generate(), name: "Repository", repoPath: URL(filePath: "/tmp/repo"))
        let projected = try await ArrangementTableProjector.project(
            makeArrangementInput([makeArrangementPaneSource(repo: repo, worktree: worktree)]))
        #expect(projected.panes.first?.worktreeName == nil)
        #expect(projected.panes.first?.branchName == nil)
    }
}

private func makeArrangementPaneSource(
    id: UUID = UUIDv7.generate(), title: String = "/tmp/checkout", content: PaneContent? = nil,
    display: PaneContextDisplay? = nil, session: PaneAgentStatusPresentation? = nil,
    repo: Repo? = nil, worktree: Worktree? = nil, enrichment: WorktreeEnrichment? = nil, parent: UUID? = nil
) -> ArrangementTableInput.PaneSource {
    let pane = Pane(
        id: id,
        content: content ?? .terminal(.init(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())),
        metadata: PaneMetadata(
            launchDirectory: URL(filePath: "/tmp/checkout"), title: title,
            facets: .init(repoId: repo?.id, worktreeId: worktree?.id, cwd: URL(filePath: "/tmp/checkout"))),
        kind: parent.map { .drawerChild(parentPaneId: $0) })
    return .init(
        state: PaneGraphState(pane: pane), display: display, session: session, repository: repo, worktree: worktree,
        repositoryUnavailable: false, worktreeUnavailable: false, enrichment: enrichment)
}

private func makeArrangementInput(
    _ sources: [ArrangementTableInput.PaneSource], layout: [UUID]? = nil, minimized: Set<UUID> = []
) -> ArrangementTableInput {
    let arrangementId = UUIDv7.generate()
    let graph = TabGraphState(
        tabId: UUIDv7.generate(), allPaneIds: sources.map(\.state.id),
        arrangements: [
            .init(
                id: arrangementId, name: "Layout", isDefault: false,
                layout: .autoTiled(layout ?? sources.map(\.state.id)), minimizedPaneIds: minimized, drawerViews: [:])
        ])
    return .init(
        graph: graph, activeArrangementId: arrangementId,
        sources: Dictionary(uniqueKeysWithValues: sources.map { ($0.state.id, $0) }), zoom: nil,
        shellExecutablePath: "/bin/fish")
}
