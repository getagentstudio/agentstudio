import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Arrangements compact table projection")
struct ArrangementTableProjectionTests {
    @Test("unlinked panes use their home-abbreviated cwd without inventing a worktree")
    func unlinkedCwd() async throws {
        let cwd = FileManager.default.homeDirectoryForCurrentUser.appending(path: "code/scratch")
        let source = makeArrangementPaneSource()
        var state = source.state
        state.metadata.facets.cwd = cwd
        let inputSource = ArrangementTableInput.PaneSource(
            state: state, display: nil, session: nil, repository: nil, worktree: nil,
            repositoryUnavailable: false, worktreeUnavailable: false, enrichment: nil)

        let result = try await ArrangementTableProjector.project(makeArrangementInput([inputSource]))

        #expect(result.panes.first?.cwdPath == "~/code/scratch")
        #expect(result.panes.first?.worktreeName == nil)
        #expect(result.panes.first?.worktreePath == nil)
        #expect(result.panes.first?.branchName == nil)
    }

    @Test("note wins over Agent Line, and hidden rows keep the same subtitle", arguments: [false, true])
    func notePriorityAndHiddenSubtitle(hidden: Bool) async throws {
        let paneId = UUIDv7.generate()
        let line = AgentLineDetail(
            summary: "Running Swift tests", refs: [], writer: .pane(.init(existingUUID: paneId)),
            updatedAt: Date(timeIntervalSince1970: 875))
        let display = PaneContextDisplay(
            revision: .init(1), agentTitle: nil, agentLine: line,
            own: .zero, includingDrawers: .zero, pullRequests: .notApplicable)
        let base = makeArrangementPaneSource(id: paneId, display: display)
        var state = base.state
        state.metadata.note = "Scratch shell"
        let source = ArrangementTableInput.PaneSource(
            state: state, display: display, session: nil, repository: nil, worktree: nil,
            repositoryUnavailable: false, worktreeUnavailable: false, enrichment: nil)

        let result = try await ArrangementTableProjector.project(
            makeArrangementInput([source], minimized: hidden ? [paneId] : []))

        let row = try #require(result.panes.first)
        #expect(row.agentLine == nil)
        #expect(row.paneNote == "Scratch shell")
        #expect(result.nextAgeChange == nil)
        #expect(row.agentStatus == (hidden ? .hidden : .unavailable))
    }

    @Test(
        "each canonical agent status retains its label and kind",
        arguments: [
            AgentSessionStatus.working(.active), .working(.monitoring), .needsYou(.approval), .needsYou(.question),
            .needsYou(.blocked), .failed(.init(category: "Tool failed")), .idle(.done), .idle(.ready),
            .idle(.interrupted), .idle(.ended), .unknown,
        ])
    func everyStatus(status: AgentSessionStatus) async throws {
        let source = makeArrangementPaneSource(session: .init(status: status, evidence: .verifiedLive))

        let result = try await ArrangementTableProjector.project(makeArrangementInput([source]))

        let row = try #require(result.panes.first)
        if status == .unknown {
            #expect(row.agentStatus == .unavailable)
            return
        }
        guard case .agent(let projected) = row.agentStatus else {
            Issue.record("Verified status was lost: \(status)")
            return
        }
        switch status {
        case .working(.active):
            #expect(projected.kind == .working)
            #expect(projected.label == "Working")
        case .working(.monitoring):
            #expect(projected.kind == .monitoring)
            #expect(projected.label == "Working")
        case .needsYou:
            #expect(projected.kind == .needsYou)
            #expect(projected.label == "Needs you")
        case .failed:
            #expect(projected.kind == .failed)
            #expect(projected.label == "Failed")
        case .idle:
            #expect(projected.kind == .idle)
            #expect(projected.label == "Idle")
        case .unknown: Issue.record("Unknown cannot invent a status")
        }
    }

    @Test("hidden Agent Line keeps its age and next age boundary")
    func hiddenAgentLineAge() async throws {
        let paneId = UUIDv7.generate()
        let line = AgentLineDetail(
            summary: "Waiting for review", refs: [], writer: .pane(.init(existingUUID: paneId)),
            updatedAt: Date(timeIntervalSince1970: 875))
        let display = PaneContextDisplay(
            revision: .init(1), agentTitle: nil, agentLine: line,
            own: .zero, includingDrawers: .zero, pullRequests: .notApplicable)
        let source = makeArrangementPaneSource(id: paneId, display: display)

        let result = try await ArrangementTableProjector.project(makeArrangementInput([source], minimized: [paneId]))

        #expect(result.panes.first?.agentLine == "Waiting for review [2 min ago]")
        #expect(result.panes.first?.agentStatus == .hidden)
        #expect(result.nextAgeChange == Date(timeIntervalSince1970: 1055))
    }

    @Test(
        "every content kind gets its canonical glyph and only terminals can zoom",
        arguments: [
            PaneContent.webview(.init(url: URL(filePath: "/tmp/web"))),
            .bridgePanel(.init(panelKind: .diffViewer, source: nil)),
            .codeViewer(.init(filePath: URL(filePath: "/tmp/source.swift"), scrollToLine: nil)),
            .unsupported(.init(type: "plugin", version: 1, rawState: nil)),
        ])
    func contentKindGlyphs(content: PaneContent) async throws {
        let result = try await ArrangementTableProjector.project(
            makeArrangementInput([makeArrangementPaneSource(content: content)]))

        #expect(result.panes.first?.supportsZoom == false)
        switch content {
        case .webview: #expect(result.panes.first?.paneIcon == .system(.globe))
        case .bridgePanel: #expect(result.panes.first?.paneIcon == .system(.bubbleLeft))
        case .codeViewer: #expect(result.panes.first?.paneIcon == .octicon(.codeSquare))
        case .unsupported: #expect(result.panes.first?.paneIcon == .system(.squareSplit2x1))
        case .terminal: Issue.record("Nonterminal fixture unexpectedly terminal")
        }
    }

    @Test("long projected content grows to the width cap without shortening its text")
    func longContentRetained() async throws {
        let title = String(repeating: "Long pane title ", count: 30)
        let source = makeArrangementPaneSource(title: title)

        let result = try await ArrangementTableProjector.project(makeArrangementInput([source]))

        #expect(result.panes.first?.title == title.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(result.tableMetrics.panelWidth == AppStyles.Components.ArrangementPanel.maximumWidth)
    }

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
            updatedAt: Date(timeIntervalSince1970: 875))
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
        #expect(row.agentLine == "Running Swift tests [2 min ago]")
        #expect(row.worktreeName == "Friendly checkout")
        #expect(row.branchName == "feature/table")
        #expect(row.worktreePath == "/tmp/different-folder")
        #expect(
            row.agentStatus
                == .agent(.init(kind: .working, label: "Working", detail: "Working", icon: .system(.circleFill))))
        #expect(row.paneIcon == .system(.terminal))
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
        shellExecutablePath: "/bin/fish", referenceDate: Date(timeIntervalSince1970: 1000))
}
