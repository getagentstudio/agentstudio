import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import SwiftUI
import Testing

@testable import AgentStudioRepoExplorer

@MainActor
@Suite("RepoExplorerWorktreeRow", .serialized)
struct RepoExplorerWorktreeRowTests {
    @Test("By Repo hides clean synced, no-upstream, and unknown sync metadata")
    func byRepoMetadataUsesZeroSuppression() {
        let cleanSynced = GitBranchStatus(
            isDirty: false,
            syncState: .synced,
            prCount: 0,
            linesAdded: 0,
            linesDeleted: 0,
            untrackedFileCount: 0
        )
        let noUpstream = GitBranchStatus(
            isDirty: false,
            syncState: .noUpstream,
            prCount: 0,
            linesAdded: 0,
            linesDeleted: 0,
            untrackedFileCount: 0
        )
        let dirtyAheadWithPullRequests = GitBranchStatus(
            isDirty: true,
            syncState: .ahead(2),
            prCount: 3,
            linesAdded: 4,
            linesDeleted: 1,
            untrackedFileCount: 0
        )

        #expect(!RepoExplorerWorktreeRowContent.shouldShowDiffChip(branchStatus: cleanSynced))
        #expect(!RepoExplorerWorktreeRowContent.shouldShowSyncChip(branchStatus: cleanSynced))
        #expect(!RepoExplorerWorktreeRowContent.shouldShowPullRequestChip(branchStatus: cleanSynced))
        #expect(!RepoExplorerWorktreeRowContent.shouldShowSyncChip(branchStatus: noUpstream))
        #expect(!RepoExplorerWorktreeRowContent.shouldShowSyncChip(branchStatus: .unknown))
        #expect(RepoExplorerWorktreeRowContent.shouldShowDiffChip(branchStatus: dirtyAheadWithPullRequests))
        #expect(RepoExplorerWorktreeRowContent.shouldShowSyncChip(branchStatus: dirtyAheadWithPullRequests))
        #expect(RepoExplorerWorktreeRowContent.shouldShowPullRequestChip(branchStatus: dirtyAheadWithPullRequests))
    }

    @Test("mounted By Repo row renders a positive pull request chip in the product accent color")
    func mountedByRepoRowRendersPositivePullRequestChip() throws {
        let hostingView = NSHostingView(
            rootView: RepoExplorerWorktreeRowContent(
                octiconLoader: makeRepoExplorerTestOcticonLoader(),
                checkoutTitle: "agent-studio",
                branchName: "feat/sidebar-grouping-rows",
                placementText: "",
                checkoutIconKind: .gitWorktree,
                iconColor: .accentColor,
                branchStatus: GitBranchStatus(
                    isDirty: false,
                    syncState: .synced,
                    prCount: 3,
                    linesAdded: 0,
                    linesDeleted: 0,
                    untrackedFileCount: 0
                ),
                showsPinnedControl: false
            )
            .frame(width: 320)
            .background(Color.black)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
        hostingView.layoutSubtreeIfNeeded()
        let renderedBitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: renderedBitmap)

        #expect(renderedBitmap.pixelsWide > 0)
        // The only chip on this row is the positive PR chip (clean/synced branch, no diff or sync
        // chip). Pixel-verifying the checkout yellow directly catches a regression back to either
        // system `.accentColor` (the pre-unification pane-row bug) or the product blue accent
        // (the pre-owner-directive shared token): the fixture's `iconColor: .accentColor` proves
        // the chip is NOT colored from the row's incidental `iconColor` either.
        #expect(containsCheckoutYellowPixel(in: renderedBitmap))
    }

    /// Scans for a pixel matching `AppStyles.Shell.Sidebar.checkoutDefaultAccentColor`'s specific
    /// signature: `#F5C451` has a dominant red channel (~0.96) and mid-high green (~0.77) alongside
    /// a clearly low blue (~0.32) — a real distinguishing feature from both macOS system blue
    /// (`#007AFF`) and the prior product blue token (`#409CFF`), which the fixture's
    /// `iconColor: .accentColor` or a regressed shared token would render instead.
    private func containsCheckoutYellowPixel(in bitmap: NSBitmapImageRep) -> Bool {
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                // Thresholds are loosened from the raw #F5C451 values to tolerate the chip's own
                // foreground opacity (0.82) blending over its translucent pill background.
                let matchesRed = color.redComponent > 0.55
                let matchesGreen = (0.35...0.75).contains(color.greenComponent)
                let matchesBlue = color.blueComponent < 0.40
                if matchesRed && matchesGreen && matchesBlue {
                    return true
                }
            }
        }
        return false
    }

    @Test("diff chip always carries a label and never renders +0 -0")
    func diffChipAlwaysCarriesALabel() {
        let clean = GitBranchStatus(
            isDirty: false,
            syncState: .synced,
            prCount: 0,
            linesAdded: 0,
            linesDeleted: 0,
            untrackedFileCount: 0
        )
        let untrackedOnly = GitBranchStatus(
            isDirty: true,
            syncState: .synced,
            prCount: 0,
            linesAdded: 0,
            linesDeleted: 0,
            untrackedFileCount: 3
        )
        let dirtyWithLineCounts = GitBranchStatus(
            isDirty: true,
            syncState: .synced,
            prCount: 0,
            linesAdded: 12,
            linesDeleted: 4,
            untrackedFileCount: 2
        )

        #expect(RepoExplorerWorktreeRowContent.diffChipDetail(branchStatus: clean) == nil)
        #expect(RepoExplorerWorktreeRowContent.diffChipDetail(branchStatus: untrackedOnly) == .untrackedOnly)
        #expect(
            RepoExplorerWorktreeRowContent.diffChipDetail(branchStatus: dirtyWithLineCounts)
                == .lineCounts(added: 12, deleted: 4)
        )
    }

    @Test("F7: dirty with zero tracked counts and zero untracked renders no chip at all")
    func dirtyWithZeroCountsAndZeroUntrackedRendersNoChip() {
        // Contract matrix authorizes only +N -M, "untracked", or no chip -- never an unlabeled
        // "changes" fallback. A dirty flag with no real counts yet means enrichment hasn't caught
        // up; the counts arrive with the next enrichment pass rather than showing a state the
        // matrix never authorized.
        let dirtyWithoutAnyRealCounts = GitBranchStatus(
            isDirty: true,
            syncState: .synced,
            prCount: 0,
            linesAdded: 0,
            linesDeleted: 0,
            untrackedFileCount: 0
        )

        #expect(RepoExplorerWorktreeRowContent.diffChipDetail(branchStatus: dirtyWithoutAnyRealCounts) == nil)
        #expect(!RepoExplorerWorktreeRowContent.shouldShowDiffChip(branchStatus: dirtyWithoutAnyRealCounts))
    }

    @Test("chip rows carry no timeline-driven animation")
    func chipRowsCarryNoTimelineDrivenAnimation() throws {
        let chipSource = try String(
            contentsOfFile: "Sources/AgentStudio/Core/Views/SidebarChips.swift",
            encoding: .utf8
        )
        let rowSource = try String(
            contentsOfFile: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerWorktreeRow.swift",
            encoding: .utf8
        )
        for source in [chipSource, rowSource] {
            #expect(!source.contains("repeatForever"))
        }
        #expect(chipSource.contains(".variableColor.iterative"))
    }

    @Test("branch and placement second lines render through the shared SidebarMetadataLine component")
    func branchAndPlacementLinesUseSharedMetadataLineComponent() throws {
        let rowSource = try String(
            contentsOfFile: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerWorktreeRow.swift",
            encoding: .utf8
        )

        #expect(rowSource.contains("SidebarMetadataLine("))
        #expect(rowSource.contains(".octicon(name: \"octicon-git-branch\", loader: octiconLoader)"))
        #expect(rowSource.contains("text: branchName"))
        #expect(rowSource.contains(".systemName(\"square.split.2x1\")"))
        #expect(rowSource.contains("text: placementText"))
        // The branch and placement lines no longer hand-roll their own icon+text HStack.
        #expect(!rowSource.contains("Image(systemName: \"square.split.2x1\")"))
    }

    @Test("pending pull request progress renders as a bare chip-height gutter glyph")
    func stalePullRequestMetadataRendersAsBareGlyph() throws {
        let rowSource = try String(
            contentsOfFile: "Sources/AgentStudio/Core/Views/SidebarChips.swift",
            encoding: .utf8
        )

        let glyphStart = try #require(rowSource.range(of: "package struct SidebarPendingPullRequestIndicator"))
        let glyphEnd = try #require(
            rowSource.range(
                of: "package struct SidebarStatusChipRow",
                range: glyphStart.upperBound..<rowSource.endIndex
            )
        )
        let glyphSource = String(rowSource[glyphStart.lowerBound..<glyphEnd.lowerBound])

        #expect(glyphSource.contains("Image(systemName: SystemSymbol.circleDotted.rawValue)"))
        #expect(glyphSource.contains(".frame(height: AppStyles.Shell.Sidebar.chipLineHeight)"))
        #expect(glyphSource.contains(".foregroundStyle(.secondary)"))
        #expect(glyphSource.contains(".symbolEffect("))
        #expect(glyphSource.contains(".variableColor.iterative"))
        #expect(glyphSource.contains("options: .repeating.speed("))
        #expect(!glyphSource.contains("SidebarChip("))
        #expect(!glyphSource.contains(".background("))
        #expect(!glyphSource.contains(".overlay("))
        #expect(!glyphSource.contains("rotationEffect"))
        #expect(!glyphSource.contains("repeatForever"))
    }

    @Test("every shared sidebar chip uses the standard outer height")
    func everySharedSidebarChipUsesStandardOuterHeight() throws {
        let coreChipSource = try String(
            contentsOfFile: "Sources/AgentStudio/Core/Views/SidebarChips.swift",
            encoding: .utf8
        )
        let sharedChipSource = try String(
            contentsOfFile: "Sources/AgentStudio/SharedComponents/SidebarChip.swift",
            encoding: .utf8
        )

        let standardHeight = ".frame(height: AppStyles.Shell.Sidebar.chipLineHeight)"
        let coreHeightSites = coreChipSource.components(separatedBy: standardHeight).count - 1
        let sharedHeightSites = sharedChipSource.components(separatedBy: standardHeight).count - 1
        #expect(coreHeightSites + sharedHeightSites == 5)
        #expect(!coreChipSource.contains(".padding(.vertical, AppStyles.Shell.Sidebar.chipVerticalPadding)"))
        #expect(!sharedChipSource.contains(".padding(.vertical, AppStyles.Shell.Sidebar.chipVerticalPadding)"))
    }

    @Test("pending progress occupies the fixed icon gutter without shifting chips")
    func pendingProgressOccupiesFixedIconGutterWithoutShiftingChips() throws {
        let sharedSource = try String(
            contentsOfFile: "Sources/AgentStudio/Core/Views/SidebarChips.swift",
            encoding: .utf8
        )
        let worktreeSource = try String(
            contentsOfFile: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerWorktreeRow.swift",
            encoding: .utf8
        )
        let paneSource = try String(
            contentsOfFile: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerPaneNavigation.swift",
            encoding: .utf8
        )

        #expect(sharedSource.contains("package struct SidebarStatusChipRow"))
        #expect(sharedSource.contains("AppStyles.Shell.Sidebar.rowLeadingIconColumnWidth"))
        #expect(sharedSource.contains("AppStyles.Shell.Sidebar.groupIconTitleSpacing"))
        #expect(sharedSource.contains(".accessibilityLabel(\"Refreshing pull request status\")"))
        #expect(!sharedSource.contains(".offset("))
        #expect(!sharedSource.contains("Pull request facts not fetched"))
        #expect(!sharedSource.contains("pendingPullRequestGlyph"))
        #expect(worktreeSource.contains("SidebarStatusChipRow("))
        #expect(
            worktreeSource.contains(
                "RepoExplorerWorktreeStatusPresentation.showsPendingIndicator(branchStatus)"
            )
        )
        // O12/O13 remove Git progress/play from pane rows; the pane stack consumes its variant.
        #expect(paneSource.contains("RepoExplorerPaneRowContent("))
        #expect(paneSource.contains("ForEach(variant.chipModels"))
        #expect(paneSource.contains("if let activity = variant.activityChip"))
    }

    @Test("a detached-HEAD worktree resolves pull request data unavailable immediately")
    func detachedHeadWorktreeResolvesPullRequestDataUnavailableImmediately() {
        let detachedEnrichment = WorktreeEnrichment(
            worktreeId: UUIDv7.generate(),
            repoId: UUIDv7.generate(),
            branch: "",
            isMainWorktree: false
        )
        let branchedEnrichment = WorktreeEnrichment(
            worktreeId: UUIDv7.generate(),
            repoId: UUIDv7.generate(),
            branch: "main",
            isMainWorktree: false
        )

        let detachedStatus = GitBranchStatus.status(enrichment: detachedEnrichment, pullRequestFacts: nil)
        let branchedIdleStatus = GitBranchStatus.status(enrichment: branchedEnrichment, pullRequestFacts: nil)

        // Detached HEAD is a local, synchronous fact of the enrichment itself
        // (no branch to key a forge query on) and must resolve to terminal
        // no-data without ever waiting on a forge query. A branched worktree
        // with no active request is unresolved but not visibly loading.
        #expect(detachedStatus.pullRequestDataUnavailable)
        #expect(detachedStatus.prCount == nil)
        #expect(!RepoExplorerWorktreeRowContent.shouldShowPullRequestChip(branchStatus: detachedStatus))

        #expect(!branchedIdleStatus.pullRequestDataUnavailable)
        #expect(!RepoExplorerWorktreeRowContent.shouldShowPullRequestChip(branchStatus: branchedIdleStatus))
        #expect(!RepoExplorerWorktreeStatusPresentation.showsPendingIndicator(branchedIdleStatus))
        #expect(!RepoExplorerWorktreeStatusPresentation.reservesStatusLine(branchedIdleStatus))
    }

    @Test("resolved-unavailable pull request state renders neither the pending glyph nor a chip")
    func resolvedUnavailablePullRequestStateRendersNoGlyphAndNoChip() {
        let idleWithoutFacts = GitBranchStatus(
            isDirty: false,
            syncState: .synced,
            prCount: nil,
            pullRequestIsLoading: false,
            pullRequestDataUnavailable: false,
            linesAdded: 0,
            linesDeleted: 0,
            untrackedFileCount: 0
        )
        let activeRequest = GitBranchStatus(
            isDirty: false,
            syncState: .synced,
            prCount: nil,
            pullRequestIsLoading: true,
            pullRequestDataUnavailable: false,
            linesAdded: 0,
            linesDeleted: 0,
            untrackedFileCount: 0
        )
        let terminallyUnavailable = GitBranchStatus(
            isDirty: false,
            syncState: .synced,
            prCount: nil,
            pullRequestDataUnavailable: true,
            linesAdded: 0,
            linesDeleted: 0,
            untrackedFileCount: 0
        )

        #expect(!RepoExplorerWorktreeRowContent.shouldShowPullRequestChip(branchStatus: idleWithoutFacts))
        #expect(!RepoExplorerWorktreeStatusPresentation.showsPendingIndicator(idleWithoutFacts))
        #expect(!RepoExplorerWorktreeStatusPresentation.reservesStatusLine(idleWithoutFacts))
        #expect(RepoExplorerWorktreeRowContent.shouldShowPullRequestChip(branchStatus: activeRequest))
        #expect(SidebarGitStatusChips.showsPendingPullRequestFacts(branchStatus: activeRequest))
        // Resolved-unavailable (no remote, or repeated failures past the
        // honesty threshold) must never render as still-pending.
        #expect(!RepoExplorerWorktreeRowContent.shouldShowPullRequestChip(branchStatus: terminallyUnavailable))
        #expect(!SidebarGitStatusChips.showsPendingPullRequestFacts(branchStatus: terminallyUnavailable))
        #expect(!RepoExplorerWorktreeStatusPresentation.showsPendingIndicator(terminallyUnavailable))
        #expect(!RepoExplorerWorktreeStatusPresentation.reservesStatusLine(terminallyUnavailable))
    }

    @Test("a stale positive PR count never renders once the repo resolves unavailable")
    func stalePositivePullRequestCountDoesNotRenderOnceUnavailable() throws {
        // GitBranchStatus.prCount and pullRequestDataUnavailable are independent fields: a repo can
        // carry a stale positive prCount from an earlier successful fetch while now being marked
        // terminally unavailable (no remote, or repeated failures past the honesty threshold). The
        // outer shouldShowPullRequestChip gate already accounts for this (prCount != 0 &&
        // !pullRequestDataUnavailable), but the chips-row render branch must independently guard the
        // same combination too — a merge between the chip-spec unification and the forge-honesty
        // work could otherwise drop this check from one side while keeping it on the other.
        let terminallyUnavailableWithStaleCount = GitBranchStatus(
            isDirty: false,
            syncState: .synced,
            prCount: 3,
            pullRequestDataUnavailable: true,
            linesAdded: 0,
            linesDeleted: 0,
            untrackedFileCount: 0
        )
        #expect(
            !RepoExplorerWorktreeRowContent.shouldShowPullRequestChip(
                branchStatus: terminallyUnavailableWithStaleCount))

        let rowSource = try String(
            contentsOfFile: "Sources/AgentStudio/Core/Views/SidebarChips.swift",
            encoding: .utf8
        )
        let renderBranchStart = try #require(rowSource.range(of: "if let prCount = branchStatus.prCount,"))
        let renderBranchEnd = try #require(
            rowSource.range(of: "{", range: renderBranchStart.upperBound..<rowSource.endIndex))
        let renderBranchSource = String(rowSource[renderBranchStart.lowerBound..<renderBranchEnd.lowerBound])
        #expect(renderBranchSource.contains("!branchStatus.pullRequestDataUnavailable"))
    }

    @Test("pinned state exposes explicit pin and unpin labels")
    func pinnedStateExposesExplicitLabels() {
        #expect(RepoExplorerWorktreeRowContent.pinnedAccessibilityLabel(isPinned: false) == "Pin Repository")
        #expect(RepoExplorerWorktreeRowContent.pinnedAccessibilityLabel(isPinned: true) == "Unpin Repository")
        #expect(
            RepoExplorerWorktreeRowContent.pinnedHelpText(isPinned: false)
                == "Pin this repository in the Repos sidebar"
        )
        #expect(
            RepoExplorerWorktreeRowContent.pinnedHelpText(isPinned: true)
                == "Unpin this repository from the Repos sidebar"
        )
        #expect(RepoExplorerWorktreeRowContent.pinnedActionSpec(isPinned: false).icon == .system(.pin))
        #expect(RepoExplorerWorktreeRowContent.pinnedActionSpec(isPinned: true).icon == .system(.pinFill))
    }

    @Test("inactive repository header uses one icon and compact hover copy")
    func inactiveRepositoryHeaderUsesIconOnlyPresentation() throws {
        let presentation = RepoExplorerMaterializedRowView.inactiveRepositoryStatus

        #expect(presentation.icon == .system(.memorychip))
        #expect(presentation.label == "Locally inactive")
        #expect(presentation.helpText == "Locally inactive")

        let source = try String(
            contentsOfFile: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerMaterializedRowView.swift",
            encoding: .utf8
        )
        let functionStart = try #require(
            source.range(of: "private func repositoryActivityTrailingContent")
        )
        let functionSource = source[functionStart.lowerBound...]
        #expect(!functionSource.contains("Text(inactivityStatus.label)"))
        #expect(!functionSource.contains("Text(\"Updating\")"))
        #expect(functionSource.contains("if controlState.revealsRefresh, let commandPresentation"))
        #expect(
            source.contains(
                "isUpdating: RepoExplorerRepositoryUpdatePresentation.isLoading("
            )
        )
        #expect(
            !source.contains(
                "isUpdating: RepoExplorerRepositoryUpdatePresentation.keepsActivitySlotVisible("
            )
        )
    }

    @Test("inactive repository refresh reveal is local and explicitly dismissible")
    func inactiveRepositoryRefreshRevealStateIsLocal() {
        var state = RepoExplorerInactiveRepositoryControlState()

        #expect(!state.revealsRefresh)
        state.revealRefresh()
        #expect(state.revealsRefresh)
        state.hideRefresh()
        #expect(!state.revealsRefresh)
        #expect(AppPolicies.RepoExplorer.inactiveRefreshRevealDuration == .seconds(30))
    }

    @Test("pinned control visibility uses main worktree identity for every action")
    func pinnedControlVisibilityUsesMainWorktreeIdentity() {
        let mainVisibility = RepoExplorerPinnedControlVisibility(isMainWorktree: true)
        let linkedVisibility = RepoExplorerPinnedControlVisibility(isMainWorktree: false)

        #expect(mainVisibility.showsInlineButton)
        #expect(mainVisibility.showsContextMenuAction)
        #expect(!linkedVisibility.showsInlineButton)
        #expect(!linkedVisibility.showsContextMenuAction)
    }

    @Test("pinned visibility policy guards inline and context-menu actions")
    func pinnedVisibilityPolicyGuardsEveryAction() throws {
        let rowSource = try String(
            contentsOfFile: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerWorktreeRow.swift",
            encoding: .utf8
        )
        let menuSource = try String(
            contentsOfFile: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerContextMenuPresenter.swift",
            encoding: .utf8
        )

        #expect(rowSource.contains("showsPinnedControl: pinnedControlVisibility.showsInlineButton"))
        #expect(menuSource.contains("showsPinnedControl: pinnedControlVisibility.showsContextMenuAction"))
        #expect(rowSource.contains(".controlHelp(pinnedActionSpec.controlTooltipRenderValue())"))
        #expect(!rowSource.contains(".help(pinnedActionSpec.helpText)"))
    }

    @Test("context menu exposes creation destinations at the top level")
    func contextMenuGroupsCreationActionsByDestination() throws {
        let source = try String(
            contentsOfFile: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerContextMenuPresenter.swift",
            encoding: .utf8
        )

        #expect(source.contains("action: .createNewInPane"))
        #expect(source.contains("action: .createNewInTab"))
        #expect(!source.contains("LocalActionSpec.createNew.actionSpec"))
        #expect(!source.contains("LocalActionSpec.openInCurrentTabMenu.actionSpec"))
        #expect(!source.contains("LocalActionSpec.openInNewTabMenu.actionSpec"))
        #expect(source.contains("LocalActionSpec.goToPane.actionSpec"))
        #expect(source.contains("LocalActionSpec.openInEditorMenu.actionSpec"))
        #expect(source.contains("command: commandPresentation.contextMenuCommand"))
        #expect(source.contains("[.openWorktreeInPane, .showBridgeReview, .showBridgeFiles].map(item.command)"))
        #expect(
            source.contains(
                "[.openNewTerminalInTab, .openBridgeReviewInNewTab, .openBridgeFilesInNewTab].map(item.command)"))
        #expect(!source.contains("AppCommand.openWorktreeInPane.definition.actionSpec"))
        #expect(!source.contains("AppCommand.openNewTerminalInTab.definition.actionSpec"))
        #expect(!source.contains("contextMenuCommand(.openWorktree)"))
        let createNewInPaneOffset = try #require(source.range(of: "action: .createNewInPane")?.lowerBound)
        let createNewInTabOffset = try #require(source.range(of: "action: .createNewInTab")?.lowerBound)
        let goToPaneOffset = try #require(source.range(of: "LocalActionSpec.goToPane.actionSpec")?.lowerBound)
        #expect(createNewInTabOffset < createNewInPaneOffset)
        #expect(createNewInPaneOffset < goToPaneOffset)
    }

    @Test("materialized SwiftUI rows do not own contextual menu lifetime")
    func materializedSwiftUIRowsDoNotOwnContextMenus() throws {
        for path in [
            "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerMaterializedRowView.swift",
            "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerWorktreeRow.swift",
        ] {
            let source = try String(contentsOfFile: path, encoding: .utf8)
            #expect(!source.contains(".contextMenu {"))
        }
    }

    @Test("context menu uses shared content labels for both creation destinations")
    func contextMenuUsesSharedContentLabels() throws {
        let source = try String(
            contentsOfFile: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerContextMenuPresenter.swift",
            encoding: .utf8
        )

        #expect(
            source.contains(
                "RepoExplorerWorktreeCommandPresentation.contextMenuLabel(for: command.command)"
            )
        )
        #expect(source.contains("?? actionSpec.label"))
    }

    @Test("context menu labels use the same content vocabulary in tabs and panes")
    func contextMenuLabelsUseSharedContentVocabulary() {
        #expect(
            RepoExplorerWorktreeCommandPresentation.contextMenuLabel(for: .openNewTerminalInTab) == "Terminal"
        )
        #expect(
            RepoExplorerWorktreeCommandPresentation.contextMenuLabel(for: .openWorktreeInPane) == "Terminal"
        )
        #expect(
            RepoExplorerWorktreeCommandPresentation.contextMenuLabel(for: .openBridgeReviewInNewTab) == "Review"
        )
        #expect(
            RepoExplorerWorktreeCommandPresentation.contextMenuLabel(for: .showBridgeReview) == "Review"
        )
        #expect(
            RepoExplorerWorktreeCommandPresentation.contextMenuLabel(for: .openBridgeFilesInNewTab) == "Files"
        )
        #expect(
            RepoExplorerWorktreeCommandPresentation.contextMenuLabel(for: .showBridgeFiles) == "Files"
        )
    }

    @Test("pane context lines and worktree metadata retain their shared styling owners")
    func paneRowsUseSharedSecondaryMetadataStyling() throws {
        let paneNavigationSource = try String(
            contentsOfFile: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerPaneNavigation.swift",
            encoding: .utf8
        )
        let worktreeRowSource = try String(
            contentsOfFile: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerWorktreeRow.swift",
            encoding: .utf8
        )

        // O12: the prepared variant replaces terminal-output/branch metadata in pane rows.
        #expect(paneNavigationSource.contains("ForEach(variant.lines"))
        #expect(paneNavigationSource.contains("RepoExplorerPaneContextLineView("))
        #expect(paneNavigationSource.contains("line: line, isAgentLine: true"))
        #expect(paneNavigationSource.contains("line: line, isAgentLine: false"))
        #expect(paneNavigationSource.contains("AppStyles.Shell.Sidebar.rowContentSpacing"))
        #expect(paneNavigationSource.contains("SidebarChip("))
        #expect(paneNavigationSource.contains("paneContextControl(paneId, .kind(chip))"))
        #expect(paneNavigationSource.contains("paneContextControl(paneId, .agentLine(line))"))
        #expect(paneNavigationSource.contains("text: activity.text, style: .neutral"))
        #expect(worktreeRowSource.contains(".systemName(\"square.split.2x1\")"))
        #expect(worktreeRowSource.contains("SidebarMetadataLine("))
        #expect(!worktreeRowSource.contains("Image(systemName: \"square.split.2x1\")"))
    }

    @Test("pane rows use By Repo rhythm, indent, and group-container color")
    func paneRowsMatchByRepoChromeAndTabGroupColor() throws {
        let materializationSource = try String(
            contentsOfFile:
                "Sources/AgentStudio/Features/RepoExplorer/Models/RepoExplorerMaterializationSnapshot.swift",
            encoding: .utf8
        )
        let appEntityIconSource = try String(
            contentsOfFile: "Sources/AgentStudio/SharedComponents/AppEntityIcon.swift",
            encoding: .utf8
        )
        #expect(
            materializationSource.contains("leadingInset = AppStyles.Shell.Sidebar.nativeGroupChildRowLeadingInset"))
        #expect(materializationSource.contains("branchStatus: inputs.branchStatusByWorktreeID[worktreeID]"))
        #expect(appEntityIconSource.contains("case .tabGroup:"))
        #expect(appEntityIconSource.contains("AppStyles.Shell.Sidebar.tabGroupIconColor"))
    }

    @Test("every grouping mode uses one content-independent sidebar grid")
    func everyGroupingModeUsesOneContentIndependentSidebarGrid() throws {
        let paneRowSource = try String(
            contentsOfFile: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerPaneNavigation.swift",
            encoding: .utf8
        )
        let paneTitleLineSource = try String(
            contentsOfFile: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerPaneTitleLineView.swift",
            encoding: .utf8
        )
        let worktreeRowSource = try String(
            contentsOfFile: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerWorktreeRow.swift",
            encoding: .utf8
        )
        let chipSource = try String(
            contentsOfFile: "Sources/AgentStudio/Core/Views/SidebarChips.swift",
            encoding: .utf8
        )
        let metadataLineSource = try String(
            contentsOfFile: "Sources/AgentStudio/SharedComponents/SidebarMetadataLine.swift",
            encoding: .utf8
        )
        let groupHeaderSource = try String(
            contentsOfFile: "Sources/AgentStudio/SharedComponents/SidebarSourceGroupHeader.swift",
            encoding: .utf8
        )
        let materializationSource = try String(
            contentsOfFile:
                "Sources/AgentStudio/Features/RepoExplorer/Models/RepoExplorerMaterializationSnapshot.swift",
            encoding: .utf8
        )

        for source in [paneRowSource, worktreeRowSource] {
            #expect(source.contains("VStack(alignment: .leading"))
        }
        #expect(worktreeRowSource.contains("SidebarStatusChipRow("))
        #expect(paneRowSource.contains("HStack(spacing: AppStyles.Shell.Sidebar.chipRowSpacing)"))
        for source in [paneRowSource, paneTitleLineSource, worktreeRowSource] {
            #expect(!source.contains("sidebarTextColumn"))
        }
        for source in [paneTitleLineSource, worktreeRowSource] {
            #expect(source.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        }
        #expect(chipSource.contains("package struct SidebarStatusChipRow"))
        #expect(chipSource.contains("width: AppStyles.Shell.Sidebar.rowLeadingIconColumnWidth"))
        #expect(chipSource.contains("spacing: AppStyles.Shell.Sidebar.groupIconTitleSpacing"))
        #expect(!metadataLineSource.contains("sidebarTextColumn"))
        #expect(paneTitleLineSource.contains("(isDrawerPane ? AppEntityIcon.drawer : .pane).swiftUIImage("))
        #expect(paneTitleLineSource.contains("size: AppStyles.Shell.Sidebar.rowIdentityIconSize"))
        #expect(worktreeRowSource.contains("AppStyles.Shell.Sidebar.worktreeIconSize"))
        #expect(AppStyles.Shell.Sidebar.rowLeadingIconColumnWidth == AppStyles.Shell.Sidebar.groupIconColumnWidth)
        #expect(
            materializationSource.contains(
                "leadingInset = AppStyles.Shell.Sidebar.nativeGroupChildRowLeadingInset"
            )
        )
        for source in [paneRowSource, paneTitleLineSource, worktreeRowSource, metadataLineSource, groupHeaderSource] {
            #expect(source.contains("alignment: .leading"))
        }
        #expect(!paneRowSource.contains("rowLeadingIconColumnWidth,\n                    alignment: .trailing"))
        #expect(!paneTitleLineSource.contains("rowLeadingIconColumnWidth,\n                alignment: .trailing"))
        #expect(!worktreeRowSource.contains("rowLeadingIconColumnWidth, alignment: .trailing"))
        #expect(!metadataLineSource.contains("rowLeadingIconColumnWidth, alignment: .trailing"))
        #expect(!groupHeaderSource.contains("groupIconColumnWidth,\n                            alignment: .trailing"))

        let groupIconOrigin =
            AppStyles.Shell.Sidebar.listRowLeadingInset
            + AppStyles.Shell.Sidebar.sectionHeaderChevronColumnWidth
            + AppStyles.Shell.Sidebar.sectionHeaderChevronLabelSpacing
        let itemIconOrigin =
            AppStyles.Shell.Sidebar.nativeGroupChildRowLeadingInset
            + AppStyles.Shell.Sidebar.rowHorizontalInset
        let groupTextOrigin =
            groupIconOrigin
            + AppStyles.Shell.Sidebar.groupIconColumnWidth
            + AppStyles.Shell.Sidebar.groupIconTitleSpacing
        let itemTextAndChipOrigin =
            itemIconOrigin
            + AppStyles.Shell.Sidebar.rowLeadingIconColumnWidth
            + AppStyles.Shell.Sidebar.groupIconTitleSpacing
        #expect(groupIconOrigin == itemIconOrigin)
        #expect(groupTextOrigin == itemTextAndChipOrigin)
    }

    @Test("native groups preserve standardized 12 point group and 8 point item spacing")
    func nativeGroupsPreserveVerticalRhythm() throws {
        let materializedRowSource = try String(
            contentsOfFile:
                "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerMaterializedRowView.swift",
            encoding: .utf8
        )

        #expect(
            AppStyles.Shell.Sidebar.nativeRowVerticalInset * 2
                == AppStyles.Shell.Sidebar.nativeItemSpacing
        )
        #expect(
            AppStyles.Shell.Sidebar.nativeRowVerticalInset
                + AppStyles.Shell.Sidebar.nativeGroupHeaderTopPadding
                + AppStyles.Shell.Sidebar.groupRowVerticalPadding
                == AppStyles.Shell.Sidebar.nativeGroupSpacing
        )
        #expect(
            AppStyles.Shell.Sidebar.groupRowVerticalPadding
                + AppStyles.Shell.Sidebar.nativeGroupHeaderBottomPadding
                + AppStyles.Shell.Sidebar.nativeRowVerticalInset
                == AppStyles.Shell.Sidebar.nativeItemSpacing
        )
        #expect(materializedRowSource.contains("nativeGroupHeaderTopPadding"))
        #expect(materializedRowSource.contains("nativeGroupHeaderBottomPadding"))
    }

    @Test("an admitted PR refresh shows gutter progress even when cached facts remain")
    func admittedPullRequestRefreshShowsProgressWithCachedFacts() {
        let enrichment = WorktreeEnrichment(
            worktreeId: UUIDv7.generate(),
            repoId: UUIDv7.generate(),
            branch: "main",
            isMainWorktree: true
        )
        let status = GitBranchStatus.status(
            enrichment: enrichment,
            pullRequestFacts: PullRequestFacts(openCount: 2, exactOpenURL: nil),
            pullRequestIsLoading: true
        )

        #expect(SidebarGitStatusChips.showsPendingPullRequestFacts(branchStatus: status))
    }

    @Test("repo explorer remains inbox-feature agnostic")
    func repoExplorerDoesNotReferenceInboxFeatureTypes() throws {
        let source = try String(
            contentsOfFile: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerWorktreeRow.swift",
            encoding: .utf8
        )

        #expect(!source.contains("InboxNotification"))
    }

}
