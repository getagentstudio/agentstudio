import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudioRepoExplorer

@Suite
struct RepoExplorerPaneContextLineTests {
    @Test("O6 strips leading terminal title spinners", arguments: ["✳", "⠃", "⠋"])
    func leadingTitleSpinnersAreHidden(spinner: String) {
        #expect(
            PaneContextPresentationRules.displayTitle(
                raw: "\(spinner)  Running tests", cwd: nil, shell: "/bin/zsh")
                == "Running tests")
    }

    @MainActor
    @Test("Working resolves to app accent and opacity pulse while success stays green")
    func workingUsesAppAccentAndGentlePulse() throws {
        let active = try #require(RepoExplorerPaneContextLine.session(.working(.active)))
        let monitoring = try #require(RepoExplorerPaneContextLine.session(.working(.monitoring)))

        #expect(active.tone.foregroundColor == AppStyles.General.Accent.primaryColor)
        #expect(active.glyphMotion == .opacityPulse)
        #expect(monitoring.tone.foregroundColor == AppStyles.General.Accent.primaryColor)
        #expect(monitoring.glyphMotion == .rotate)

        #expect(PaneContextChipTone.success.foregroundColor == AppStyles.Shell.Sidebar.chipSuccessColor)
        #expect(PaneContextChipTone.success.foregroundColor != AppStyles.General.Accent.primaryColor)
    }

    static let connectionCopy: [(AgentConnectionRefusalReason, String)] = [
        (.credentialNotRecognized, "Messages unavailable · restart this shell to reconnect"),
        (.paneNotFound, "Agent identity unavailable · run this from an open Agent Studio pane"),
        (.paneRetired, "Agent identity unavailable · this pane has closed"),
        (.otherWorkspace, "Agent identity unavailable · run this from the matching workspace"),
        (.intentRequiresToken, "Messages unavailable · restart this shell to reconnect"),
        (.noSessionId, "Agent identity unavailable · the provider did not supply a session ID"),
        (.undecodablePayload, "Agent identity unavailable · the provider hook report could not be read"),
        (.queueFull, "Agent report not accepted · the app’s report queue is full"),
        (.appUnavailable, "Agent request unavailable · Agent Studio could not be reached"),
        (.deadlineExceeded, "Agent request unavailable · the app did not reply in time"),
        (.orderingStoreUnavailable, "Agent Line unavailable · restart Agent Studio"),
    ]

    @Test(arguments: connectionCopy)
    func connectionWarningNamesUnavailableCapability(reason: AgentConnectionRefusalReason, expected: String) {
        let line = RepoExplorerPaneContextLine.connection(reason)

        #expect(Set(Self.connectionCopy.map(\.0)) == Set(AgentConnectionRefusalReason.allCases))
        #expect(line.text == expected)
        #expect(!line.text.contains(reason.rawValue))
        #expect(!line.text.contains("not connected"))
        #expect(!line.text.hasSuffix("."))
        #expect(line.tooltip.text.contains(expected))
        #expect(!line.tooltip.text.contains(reason.rawValue))
        #expect(line.tone == .warning)
        #expect(line.glyphMotion == .still)
    }

    struct StatusOracle: Sendable {
        let status: AgentSessionStatus
        let text: String?
        let icon: CommandIcon?
        let tone: PaneContextChipTone?
    }
    // Words and glyphs from Spec R21a, with the row-motion design's dotted monitoring glyph.
    static let statuses: [StatusOracle] = [
        .init(status: .needsYou(.approval), text: "Needs you · approval", icon: .system(.flag), tone: .warning),
        .init(status: .needsYou(.question), text: "Needs you · question", icon: .system(.flag), tone: .warning),
        .init(status: .needsYou(.blocked), text: "Needs you · blocked", icon: .system(.flag), tone: .warning),
        .init(
            status: .failed(.init(category: "Build")), text: "Failed · Build", icon: .system(.xmarkOctagon),
            tone: .danger),
        .init(status: .working(.active), text: "Working", icon: .system(.circleFill), tone: .accent),
        .init(
            status: .working(.monitoring), text: "Working · monitoring", icon: .system(.circleDotted), tone: .accent),
        .init(status: .idle(.done), text: "Idle · done", icon: .system(.checkmark), tone: .neutral),
        .init(status: .idle(.ready), text: "Idle · ready", icon: .system(.circle), tone: .neutral),
        .init(status: .idle(.interrupted), text: "Idle · interrupted", icon: .system(.circle), tone: .neutral),
        .init(status: .idle(.ended), text: "Idle · ended", icon: .system(.circle), tone: .neutral),
        .init(status: .unknown, text: nil, icon: nil, tone: nil),
    ]
    @Test(arguments: statuses)
    func sessionLineUsesItsOwnGlyphAndWords(_ oracle: StatusOracle) {
        let line = RepoExplorerPaneContextLine.session(oracle.status)
        #expect(line?.text == oracle.text)
        #expect(line?.icon == oracle.icon)
        #expect(line?.tone == oracle.tone)
        #expect(line?.tooltip.text == oracle.text)
    }

    // Motion oracle from the row-motion design: only active work and monitoring move.
    @Test(arguments: [
        (AgentSessionStatus.needsYou(.approval), PaneLineGlyphMotion.still),
        (.needsYou(.question), .still), (.needsYou(.blocked), .still),
        (.failed(.init(category: "Build")), .still),
        (.working(.active), .opacityPulse), (.working(.monitoring), .rotate),
        (.idle(.done), .still), (.idle(.ready), .still),
        (.idle(.interrupted), .still), (.idle(.ended), .still), (.unknown, .still),
    ])
    func sessionMotionMatchesStatus(status: AgentSessionStatus, motion: PaneLineGlyphMotion) {
        let line = RepoExplorerPaneContextLine.session(status)

        #expect((line?.glyphMotion ?? .still) == motion)
        #expect((line == nil) == (status == .unknown))
    }

    @Test(arguments: AgentConnectionRefusalReason.allCases)
    func connectionIssueNeverMoves(reason: AgentConnectionRefusalReason) {
        #expect(RepoExplorerPaneContextLine.connection(reason).glyphMotion == .still)
    }
    @Test
    func everyExistingLineShowsInBothVariantsWithIndependentMessage() throws {
        let line = AgentLineDetail(
            summary: "Watching CI", refs: [],
            writer: .session(
                provider: try .init("codex"), sessionRef: try .init("run"), bindingGeneration: UUIDv7.generate()),
            updatedAt: .distantPast)
        let variants = RepoExplorerPaneRowVariants.make(
            title: "Agent title",
            agentLine: line,
            sessionPresentation: .init(status: .needsYou(.approval), evidence: .verifiedLive),
            now: .distantPast)
        #expect(variants.compact.lines == variants.expanded.lines)
        #expect(variants.compact.lines.count == 3)
        #expect(variants.compact.fallbackLineCount == 4)
        #expect(variants.compact.statusChips == [.clock])
        guard case .sessionStatus(let statusLine) = variants.compact.lines[1],
            case .agentLine(let messageLine) = variants.compact.lines[2]
        else {
            Issue.record("Agent Line and Session status must remain separate ordered lines")
            return
        }
        #expect(messageLine.text == "Watching CI")
        #expect(messageLine.icon == .system(.textBubble))
        #expect(messageLine.tone == .neutral)
        #expect(messageLine.glyphMotion == .still)
        #expect(statusLine.icon == .system(.flag))
        #expect(statusLine.text == "Needs you · approval")
    }
    @Test
    func missingAndUnknownStatusHaveNoLine() {
        for status: AgentSessionStatus? in [nil, .unknown] {
            let variants = RepoExplorerPaneRowVariants.make(
                title: "Pane",
                sessionPresentation: status.map { .init(status: $0, evidence: .verifiedLive) },
                now: .distantPast)
            #expect(variants.compact.lines == [.title("Pane")])
            #expect(variants.compact.fallbackLineCount == 2)
            #expect(variants.compact.statusChips == [.clock])
        }
    }
    @Test
    func projectionKeepsDrawerStatusSeparateAndRetainsEndedStatus() throws {
        let owner = UUIDv7.generate()
        let drawer = UUIDv7.generate()
        let tab = UUIDv7.generate()
        let snapshot = RepoExplorerSnapshot(
            repos: [], repoEnrichmentByRepoId: [:], surface: .panes, query: "",
            unassociatedPaneLocations: [owner, drawer].enumerated().map { offset, pane in
                WorkspacePaneLocation(
                    paneId: pane, tabId: tab, tabIndex: 0, paneIndexInTab: offset, isActiveInTab: false)
            })
        let display = PaneContextDisplay(
            revision: .init(1), agentTitle: "Owner agent", agentLine: nil,
            own: .zero, includingDrawers: .zero, pullRequests: .notApplicable)
        let ownerFacts = RepoExplorerPaneRowFacts(
            terminalTitle: "Owner terminal",
            sessionPresentation: .init(status: .working(.active), evidence: .verifiedLive), contextDisplay: display,
            latestMessageText: "Private output", recencyReferenceDate: .distantPast, recencyText: "—", isActive: false)
        let drawerFacts = RepoExplorerPaneRowFacts(
            terminalTitle: "Drawer", sessionPresentation: .init(status: .idle(.ended), evidence: .verifiedEnded),
            latestMessageText: nil,
            recencyReferenceDate: .distantPast, recencyText: "—", isActive: false,
            isDrawerPane: true, drawerOwnerPaneID: owner)
        let projection = RepoExplorerProjection.project(
            snapshot, paneRowFactsByPaneId: [owner: ownerFacts, drawer: drawerFacts])
        let rows = projection.resolvedGroups.flatMap { projection.paneRowsByGroupId[$0.id] ?? [] }
        let ownerRow = try #require(rows.first { $0.destination.paneId == owner })
        let drawerRow = try #require(rows.first { $0.destination.paneId == drawer })
        #expect(ownerRow.primaryText == "Owner agent")
        #expect(
            ownerRow.variants?.compact.lines.last
                == .sessionStatus(try #require(RepoExplorerPaneContextLine.session(.working(.active)))))
        #expect(
            drawerRow.variants?.compact.lines.last
                == .sessionStatus(try #require(RepoExplorerPaneContextLine.session(.idle(.ended)))))
        #expect(drawerRow.variants?.compact.lines == drawerRow.variants?.expanded.lines)
    }

    @Test("Needs you stays in both rows while its scoped connection warning stays in the card")
    func connectionIssueNeverHidesStatus() throws {
        let variants = RepoExplorerPaneRowVariants.make(
            title: "Pane",
            sessionPresentation: .init(status: .needsYou(.approval), evidence: .verifiedLive),
            now: .distantPast)
        #expect(variants.compact.lines == variants.expanded.lines)
        #expect(variants.compact.lines.map(\.kind) == [.title, .sessionStatus])
        let card = RepoExplorerPaneRowVariants.informationLines(
            title: "Pane", note: nil, agentLine: nil, sessionStatus: .needsYou(.approval),
            connectionIssue: .credentialNotRecognized, now: .distantPast)
        try #require(card.count == 3)
        guard case .sessionStatus(let status) = card[1], case .connectionIssue(let connection) = card[2] else {
            Issue.record("Status and connection issue must remain distinct ordered card lines")
            return
        }
        #expect(status.text == "Needs you · approval")
        #expect(connection.text == "Messages unavailable · restart this shell to reconnect")
        #expect(connection.tooltip.text == "Messages unavailable · restart this shell to reconnect")
        #expect(connection.tone == .warning)
        #expect(variants.compact.fallbackLineCount == 3)
        #expect(variants.compact.statusChips == [.clock])
    }

}
