import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Arrangements compact table projection")
struct ArrangementTableProjectionTests {
    @Test("unlinked panes have no repository or branch and no projected cwd line")
    func unlinkedCwd() async throws {
        let cwd = FileManager.default.homeDirectoryForCurrentUser.appending(path: "code/scratch")
        let source = makeArrangementPaneSource()
        var state = source.state
        state.metadata.facets.cwd = cwd
        let inputSource = ArrangementTableInput.PaneSource(
            state: state, display: nil, session: nil, repository: nil, worktree: nil,
            repositoryUnavailable: false, worktreeUnavailable: false, enrichment: nil)

        let result = try await ArrangementTableProjector.project(makeArrangementInput([inputSource]))

        #expect(result.panes.first?.repositoryName == nil)
        #expect(result.panes.first?.detailLine == nil)
        #expect(result.groups.map(\.id) == [.other])
        #expect(result.panes.first?.branchName == nil)
    }

    @Test("Agent Line wins over note and retains its age even in a dimmed hidden row", arguments: [false, true])
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
        #expect(row.detailLine == .agentLine(.init(summary: "Running Swift tests", ageText: "[2 min ago]")))
        #expect(result.nextAgeChange == Date(timeIntervalSince1970: 1055))
        #expect(row.visibleAge == "[2 min ago]")
        #expect(row.isMinimized == hidden)
        #expect(row.agentStatus == .unavailable)
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

    @Test("hidden Agent Line remains displayed and keeps its age boundary")
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

        #expect(
            result.panes.first?.detailLine == .agentLine(.init(summary: "Waiting for review", ageText: "[2 min ago]")))
        #expect(result.panes.first?.isMinimized == true)
        #expect(result.panes.first?.agentStatus == .unavailable)
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
        case .bridgePanel: #expect(result.panes.first?.paneIcon == .octicon(.gitBranch))
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

    @Test("repository groups merge their worktrees in root order and keep Other last")
    func worktreeGroupsAndOtherLast() async throws {
        let repoId = UUIDv7.generate()
        let firstWorktree = Worktree(
            id: UUIDv7.generate(), repoId: repoId, name: "agentstudio.pane-fixes", path: URL(filePath: "/tmp/first"))
        let secondWorktree = Worktree(
            id: UUIDv7.generate(), repoId: repoId, name: "agentstudio.pane-context", path: URL(filePath: "/tmp/second"))
        let repo = Repo(
            id: repoId, name: "agentstudio", repoPath: URL(filePath: "/tmp/repo"),
            worktrees: [firstWorktree, secondWorktree])
        let first = makeArrangementPaneSource(title: "First", repo: repo, worktree: firstWorktree)
        let second = makeArrangementPaneSource(title: "Second", repo: repo, worktree: secondWorktree)
        let sameGroup = makeArrangementPaneSource(title: "Same group", repo: repo, worktree: firstWorktree)
        let otherA = makeArrangementPaneSource(title: "Other A", cwd: URL(filePath: "/tmp/unlinked-a"))
        let otherB = makeArrangementPaneSource(title: "Other B", cwd: URL(filePath: "/tmp/unlinked-b"))

        let result = try await ArrangementTableProjector.project(
            makeArrangementInput([otherA, second, first, otherB, sameGroup]))

        #expect(result.groups.map(\.id) == [.repository(repoId), .other])
        #expect(result.groups.map(\.title) == ["agentstudio", "Other"])
        #expect(result.groups[0].panes.map(\.id) == [second.state.id, first.state.id, sameGroup.state.id])
        #expect(result.groups.last?.panes.map(\.id) == [otherA.state.id, otherB.state.id])
        #expect(result.groups.first?.icon != nil)
        #expect(result.groups.last?.icon == nil)
    }

    @Test("different repository identities with the same name never merge")
    func sameNameDistinctWorktrees() async throws {
        let firstRepoId = UUIDv7.generate()
        let secondRepoId = UUIDv7.generate()
        let first = Worktree(
            id: UUIDv7.generate(), repoId: firstRepoId, name: "Checkout", path: URL(filePath: "/tmp/a"))
        let second = Worktree(
            id: UUIDv7.generate(), repoId: secondRepoId, name: "Checkout", path: URL(filePath: "/tmp/b"))
        let firstRepo = Repo(id: firstRepoId, name: "Same name", repoPath: first.path, worktrees: [first])
        let secondRepo = Repo(id: secondRepoId, name: "Same name", repoPath: second.path, worktrees: [second])
        let result = try await ArrangementTableProjector.project(
            makeArrangementInput([
                makeArrangementPaneSource(repo: firstRepo, worktree: first),
                makeArrangementPaneSource(repo: secondRepo, worktree: second),
            ]))
        #expect(result.groups.map(\.id) == [.repository(firstRepoId), .repository(secondRepoId)])
        #expect(result.groups.allSatisfy { $0.panes.count == 1 })
    }

    @Test(
        "provider labels come from verified presentation, never from a pane title",
        arguments: [
            ("claude-code", "Claude"), ("codex", "Codex"), ("cursor", "Cursor"),
        ])
    func canonicalProvider(provider: String, label: String) async throws {
        let source = makeArrangementPaneSource(
            title: "A misleading terminal title",
            session: .init(
                status: .working(.active), evidence: .verifiedLive, provider: try .init(provider)))

        let result = try await ArrangementTableProjector.project(makeArrangementInput([source]))

        #expect(result.panes.first?.providerName == label)
    }

    @Test("unverified or absent provider cannot invent an agent line", arguments: [false, true])
    func providerRequiresEvidence(unverified: Bool) async throws {
        let source = makeArrangementPaneSource(
            title: "claude",
            session: .init(
                status: .working(.active), evidence: unverified ? .unverified : .verifiedLive,
                provider: unverified ? try .init("claude-code") : nil))

        let result = try await ArrangementTableProjector.project(makeArrangementInput([source]))

        #expect(result.panes.first?.providerName == nil)
    }

    @Test("a missing status hides the incomplete provider/status token line")
    func missingStatusHidesProviderLine() async throws {
        let source = makeArrangementPaneSource(
            session: .init(
                status: .unknown, evidence: .verifiedLive, provider: try .init("claude-code")))

        let result = try await ArrangementTableProjector.project(makeArrangementInput([source]))

        #expect(result.panes.first?.providerName == nil)
        #expect(result.panes.first?.agentStatus == .unavailable)
    }

    @Test(
        "projected Agent Line ignores fallback-note changes but publishes changed visible text",
        arguments: [false, true])
    func semanticRowEquality(hidden: Bool) async throws {
        let id = UUIDv7.generate()
        let line = AgentLineDetail(
            summary: "First", refs: [], writer: .pane(.init(existingUUID: id)),
            updatedAt: Date(timeIntervalSince1970: 875))
        let display = PaneContextDisplay(
            revision: .init(1), agentTitle: nil, agentLine: line,
            own: .zero, includingDrawers: .zero, pullRequests: .notApplicable)
        let first = makeArrangementPaneSource(id: id, display: display, note: "Unused note")
        let changedNote = makeArrangementPaneSource(id: id, display: display, note: "Changed unused note")
        let input = makeArrangementInput([first], minimized: hidden ? [id] : [])
        func replacementInput(_ source: ArrangementTableInput.PaneSource) -> ArrangementTableInput {
            .init(
                graph: input.graph, activeArrangementId: input.activeArrangementId,
                sources: [id: source], zoom: input.zoom, shellExecutablePath: input.shellExecutablePath,
                referenceDate: input.referenceDate)
        }
        let a = try await ArrangementTableProjector.project(input)
        let b = try await ArrangementTableProjector.project(replacementInput(changedNote))
        #expect(a == b)
        let changedLine = AgentLineDetail(
            summary: "Changed", refs: [], writer: .pane(.init(existingUUID: id)),
            updatedAt: line.updatedAt)
        let changedDisplay = PaneContextDisplay(
            revision: .init(2), agentTitle: nil, agentLine: changedLine,
            own: .zero, includingDrawers: .zero, pullRequests: .notApplicable)
        let changed = makeArrangementPaneSource(id: id, display: changedDisplay, note: "Unused note")
        let c = try await ArrangementTableProjector.project(
            replacementInput(changed))
        #expect(a != c)
    }

    @Test("table keeps title and Agent Line with repository grouping and inline branch")
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
        #expect(row.detailLine == .agentLine(.init(summary: "Running Swift tests", ageText: "[2 min ago]")))
        #expect(row.repositoryName == "Repository")
        #expect(row.branchName == "feature/table")
        #expect(
            row.agentStatus
                == .agent(.init(kind: .working, label: "Working", detail: "Working", icon: .system(.circleFill))))
        #expect(row.paneIcon == .octicon(.gitWorktree))
        #expect(row.supportsZoom)
        #expect(row.section == .repository(repo.id))
    }

    @Test(
        "agent evidence is required and hiding keeps the underlying status fact",
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
        #expect(hidden.panes.first?.isMinimized == true)
        #expect(hidden.panes.first?.agentStatus == row.agentStatus)
        #expect(source.session?.status == .working(.active))
        #expect(row.detailLine == nil)
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

    @Test("short status retains its complete reason while the row mark is a filled circle")
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
        #expect(status.icon == .system(.circleFill))
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

    @Test("a mismatched worktree supplies no branch without erasing its valid repository")
    func rejectsMismatchedAssociation() async throws {
        let worktree = Worktree(
            id: UUIDv7.generate(), repoId: UUIDv7.generate(), name: "Wrong", path: URL(filePath: "/tmp/wrong"))
        let repo = Repo(id: UUIDv7.generate(), name: "Repository", repoPath: URL(filePath: "/tmp/repo"))
        let projected = try await ArrangementTableProjector.project(
            makeArrangementInput([makeArrangementPaneSource(repo: repo, worktree: worktree)]))
        #expect(projected.panes.first?.repositoryName == "Repository")
        #expect(projected.panes.first?.branchName == nil)
        #expect(projected.groups.map(\.id) == [.repository(repo.id)])
    }
}

private func makeArrangementPaneSource(
    id: UUID = UUIDv7.generate(), title: String = "/tmp/checkout", content: PaneContent? = nil,
    display: PaneContextDisplay? = nil, session: PaneAgentStatusPresentation? = nil,
    repo: Repo? = nil, worktree: Worktree? = nil, enrichment: WorktreeEnrichment? = nil, parent: UUID? = nil,
    cwd: URL? = URL(filePath: "/tmp/checkout"), note: String? = nil
) -> ArrangementTableInput.PaneSource {
    let pane = Pane(
        id: id,
        content: content ?? .terminal(.init(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())),
        metadata: PaneMetadata(
            launchDirectory: cwd, title: title,
            facets: .init(repoId: repo?.id, worktreeId: worktree?.id, cwd: cwd), note: note),
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
