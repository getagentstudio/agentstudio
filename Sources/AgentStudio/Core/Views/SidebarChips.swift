import AgentStudioInfrastructure
import AgentStudioSharedComponents
import SwiftUI

extension SidebarChip.Icon {
    package static func system(_ symbol: SystemSymbol) -> Self {
        .system(symbol.rawValue)
    }
}

/// The single PR-count chip spec used everywhere a positive PR-count fact renders as a chip: same
/// glyph, same product-accent color, same pill style. By Repo worktree rows and pane rows (All
/// Panes/By Tab) both call this so the glyph and color can never diverge between surfaces.
package enum SidebarPullRequestChipSpec {
    package static let icon: SidebarChip.Icon = .octicon("octicon-git-pull-request")

    package enum Presentation: Equatable {
        case hidden
        case neutral(count: Int?)
        case accent(count: Int)
    }

    package nonisolated static func presentation(
        branchStatus: GitBranchStatus,
        usesPanesLoadingChip: Bool
    ) -> Presentation {
        guard !branchStatus.pullRequestDataUnavailable else { return .hidden }
        if usesPanesLoadingChip, branchStatus.pullRequestIsLoading {
            return .neutral(count: branchStatus.prCount.flatMap { $0 > 0 ? $0 : nil })
        }
        guard let count = branchStatus.prCount, count > 0 else { return .hidden }
        return .accent(count: count)
    }

    @MainActor
    package static func chip(
        presentation: Presentation,
        octiconLoader: OcticonLoader
    ) -> SidebarChip? {
        switch presentation {
        case .hidden:
            nil
        case .neutral(let count):
            SidebarChip(icon: icon, octiconLoader: octiconLoader, text: count.map(String.init), style: .neutral)
        case .accent(let count):
            chip(count: count, octiconLoader: octiconLoader)
        }
    }

    @MainActor
    package static func chip(count: Int, octiconLoader: OcticonLoader) -> SidebarChip {
        SidebarChip(
            icon: icon,
            octiconLoader: octiconLoader,
            text: "\(count)",
            style: .accent(AppStyles.Shell.Sidebar.checkoutDefaultAccentColor)
        )
    }
}

package struct SidebarGitStatusChips: View {
    package let branchStatus: GitBranchStatus
    package let octiconLoader: OcticonLoader
    package let usesPanesLoadingChip: Bool
    package let showsDetailedGitChips: Bool
    package let showsDiffChip: Bool
    package let showsSyncChip: Bool

    package init(
        branchStatus: GitBranchStatus,
        octiconLoader: OcticonLoader,
        usesPanesLoadingChip: Bool = false,
        showsDetailedGitChips: Bool = true,
        showsDiffChip: Bool = true,
        showsSyncChip: Bool = true
    ) {
        self.branchStatus = branchStatus
        self.octiconLoader = octiconLoader
        self.usesPanesLoadingChip = usesPanesLoadingChip
        self.showsDetailedGitChips = showsDetailedGitChips
        self.showsDiffChip = showsDiffChip
        self.showsSyncChip = showsSyncChip
    }

    package nonisolated static func diffDetail(
        branchStatus: GitBranchStatus
    ) -> SidebarDiffChip.WorkingTreeDetail? {
        SidebarDiffChip.workingTreeDetail(
            isDirty: branchStatus.isDirty,
            linesAdded: branchStatus.linesAdded,
            linesDeleted: branchStatus.linesDeleted,
            untrackedFileCount: branchStatus.untrackedFileCount
        )
    }

    package nonisolated static func showsSync(branchStatus: GitBranchStatus) -> Bool {
        switch branchStatus.syncState {
        case .ahead(let count), .behind(let count): count > 0
        case .diverged(let ahead, let behind): ahead > 0 || behind > 0
        case .synced, .noUpstream, .unknown: false
        }
    }

    package nonisolated static func hasContent(
        branchStatus: GitBranchStatus,
        usesPanesLoadingChip: Bool = false,
        showsDetailedGitChips: Bool = true
    ) -> Bool {
        presentationHasContent(branchStatus: branchStatus, usesPanesLoadingChip: usesPanesLoadingChip)
            || (branchStatus.prCount ?? 0) > 0 && !branchStatus.pullRequestDataUnavailable
            || showsDetailedGitChips && diffDetail(branchStatus: branchStatus) != nil
            || showsDetailedGitChips && showsSync(branchStatus: branchStatus)
    }

    private nonisolated static func presentationHasContent(
        branchStatus: GitBranchStatus,
        usesPanesLoadingChip: Bool
    ) -> Bool {
        usesPanesLoadingChip
            ? SidebarPullRequestChipSpec.presentation(
                branchStatus: branchStatus,
                usesPanesLoadingChip: true
            ) != .hidden
            : showsPendingPullRequestFacts(branchStatus: branchStatus)
    }

    package nonisolated static func showsPendingPullRequestFacts(branchStatus: GitBranchStatus) -> Bool {
        branchStatus.pullRequestIsLoading
            && !branchStatus.pullRequestDataUnavailable
    }

    private var syncCounts: (ahead: String, behind: String) {
        switch branchStatus.syncState {
        case .synced: ("0", "0")
        case .ahead(let count): ("\(count)", "0")
        case .behind(let count): ("0", "\(count)")
        case .diverged(let ahead, let behind): ("\(ahead)", "\(behind)")
        case .noUpstream: ("-", "-")
        case .unknown: ("?", "?")
        }
    }

    package var body: some View {
        HStack(spacing: AppStyles.Shell.Sidebar.chipRowSpacing) {
            if usesPanesLoadingChip {
                if let pullRequestChip = SidebarPullRequestChipSpec.chip(
                    presentation: SidebarPullRequestChipSpec.presentation(
                        branchStatus: branchStatus,
                        usesPanesLoadingChip: true
                    ),
                    octiconLoader: octiconLoader
                ) {
                    pullRequestChip
                }
            } else if let prCount = branchStatus.prCount,
                prCount > 0,
                !branchStatus.pullRequestDataUnavailable
            {
                SidebarPullRequestChipSpec.chip(count: prCount, octiconLoader: octiconLoader)
            }

            if showsDetailedGitChips, showsDiffChip,
                let diffDetail = Self.diffDetail(branchStatus: branchStatus)
            {
                SidebarDiffChip(octiconLoader: octiconLoader, detail: diffDetail)
            }

            if showsDetailedGitChips, showsSyncChip, Self.showsSync(branchStatus: branchStatus) {
                SidebarStatusSyncChip(
                    octiconLoader: octiconLoader,
                    aheadText: syncCounts.ahead,
                    behindText: syncCounts.behind,
                    hasSyncSignal: true
                )
            }
        }
    }

}

package struct SidebarPendingPullRequestIndicator: View {
    package init() {}

    package var body: some View {
        Image(systemName: SystemSymbol.circleDotted.rawValue)
            .font(.system(size: AppStyles.Shell.Sidebar.chipIconSize, weight: .medium))
            .foregroundStyle(.secondary)
            .symbolEffect(
                .variableColor.iterative,
                options: .repeating.speed(AppStyles.Shell.Sidebar.pendingFactsSymbolEffectSpeed)
            )
            .frame(height: AppStyles.Shell.Sidebar.chipLineHeight)
            .fixedSize(horizontal: true, vertical: true)
            .accessibilityLabel("Refreshing pull request status")
    }
}

package struct SidebarStatusChipRow<Content: View>: View {
    let isPendingPullRequestFacts: Bool
    @ViewBuilder let content: () -> Content

    package init(
        isPendingPullRequestFacts: Bool,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isPendingPullRequestFacts = isPendingPullRequestFacts
        self.content = content
    }

    package var body: some View {
        HStack(spacing: AppStyles.Shell.Sidebar.groupIconTitleSpacing) {
            Group {
                if isPendingPullRequestFacts {
                    SidebarPendingPullRequestIndicator()
                } else {
                    Color.clear
                        .frame(height: AppStyles.Shell.Sidebar.chipLineHeight)
                }
            }
            .frame(
                width: AppStyles.Shell.Sidebar.rowLeadingIconColumnWidth,
                alignment: .leading
            )

            HStack(spacing: AppStyles.Shell.Sidebar.chipRowSpacing) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

package struct SidebarStatusSyncChip: View {
    let octiconLoader: OcticonLoader
    let aheadText: String
    let behindText: String
    let hasSyncSignal: Bool

    private var effectiveStyle: SidebarChip.Style {
        hasSyncSignal ? .info : .neutral
    }

    package init(
        octiconLoader: OcticonLoader,
        aheadText: String,
        behindText: String,
        hasSyncSignal: Bool
    ) {
        self.octiconLoader = octiconLoader
        self.aheadText = aheadText
        self.behindText = behindText
        self.hasSyncSignal = hasSyncSignal
    }

    package var body: some View {
        HStack(spacing: AppStyles.Shell.Sidebar.chipContentSpacing) {
            HStack(spacing: AppStyles.Shell.Sidebar.syncClusterSpacing) {
                OcticonImage(
                    name: "octicon-arrow-up",
                    size: AppStyles.Shell.Sidebar.syncChipIconSize,
                    loader: octiconLoader
                )
                Text(aheadText)
            }
            HStack(spacing: AppStyles.Shell.Sidebar.syncClusterSpacing) {
                OcticonImage(
                    name: "octicon-arrow-down",
                    size: AppStyles.Shell.Sidebar.syncChipIconSize,
                    loader: octiconLoader
                )
                Text(behindText)
            }
        }
        .font(.system(size: AppStyles.Shell.Sidebar.chipFontSize, weight: .medium).monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, AppStyles.Shell.Sidebar.chipHorizontalPadding)
        .frame(height: AppStyles.Shell.Sidebar.chipLineHeight)
        .background(
            Capsule()
                .fill(Color.white.opacity(AppStyles.Shell.Sidebar.chipBackgroundOpacity))
                .overlay(
                    Capsule()
                        .fill(Color.black.opacity(AppStyles.Shell.Sidebar.chipMuteOverlayOpacity))
                )
        )
        .foregroundStyle(effectiveStyle.foreground.opacity(AppStyles.Shell.Sidebar.chipForegroundOpacity))
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(AppStyles.Shell.Sidebar.chipBorderOpacity), lineWidth: 1)
        )
        .fixedSize(horizontal: true, vertical: true)
    }
}

package struct SidebarDiffChip: View {
    /// The one working-tree fact the chip describes. The dirty dot is never rendered on its own, so
    /// every case here carries a label the reader can act on.
    package enum WorkingTreeDetail: Equatable {
        case lineCounts(added: Int, deleted: Int)
        case untrackedOnly
    }

    let octiconLoader: OcticonLoader
    let detail: WorkingTreeDetail

    private var plusColor: Color {
        AppStyles.Shell.Sidebar.chipSuccessColor.opacity(AppStyles.Shell.Sidebar.chipForegroundOpacity)
    }

    private var minusColor: Color {
        AppStyles.Shell.Sidebar.chipDangerColor.opacity(AppStyles.Shell.Sidebar.chipForegroundOpacity)
    }

    private var neutralColor: Color {
        SidebarChip.Style.neutral.foreground.opacity(AppStyles.Shell.Sidebar.chipForegroundOpacity)
    }

    package init(octiconLoader: OcticonLoader, detail: WorkingTreeDetail) {
        self.octiconLoader = octiconLoader
        self.detail = detail
    }

    /// Resolves the chip for a branch status, or `nil` when the checkout is clean and the row shows no
    /// diff chip at all.
    package nonisolated static func workingTreeDetail(
        isDirty: Bool,
        linesAdded: Int,
        linesDeleted: Int,
        untrackedFileCount: Int
    ) -> WorkingTreeDetail? {
        if linesAdded > 0 || linesDeleted > 0 {
            return .lineCounts(added: linesAdded, deleted: linesDeleted)
        }
        if untrackedFileCount > 0 {
            return .untrackedOnly
        }
        // A dirty checkout with no real tracked or untracked counts yet means enrichment hasn't
        // caught up, not a distinct presentable state (F7): the matrix authorizes only
        // +N -M, "untracked", or no chip. Showing nothing here is correct; the counts arrive with
        // the next enrichment pass.
        return nil
    }

    package var body: some View {
        HStack(spacing: AppStyles.Shell.Sidebar.chipContentSpacing) {
            OcticonImage(
                name: "octicon-dot-fill",
                size: AppStyles.Shell.Sidebar.chipIconSize,
                loader: octiconLoader
            )
            .foregroundStyle(
                SidebarChip.Style.danger.foreground.opacity(AppStyles.Shell.Sidebar.chipForegroundOpacity))

            switch detail {
            case .lineCounts(let added, let deleted):
                HStack(spacing: AppStyles.General.Spacing.tight) {
                    Text("+\(added)")
                        .foregroundStyle(plusColor)
                    Text("-\(deleted)")
                        .foregroundStyle(minusColor)
                }
            case .untrackedOnly:
                Text("untracked")
                    .foregroundStyle(neutralColor)
            }
        }
        .font(.system(size: AppStyles.Shell.Sidebar.chipFontSize, weight: .medium).monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, AppStyles.Shell.Sidebar.chipHorizontalPadding)
        .frame(height: AppStyles.Shell.Sidebar.chipLineHeight)
        .background(
            Capsule()
                .fill(Color.white.opacity(AppStyles.Shell.Sidebar.chipBackgroundOpacity))
                .overlay(
                    Capsule()
                        .fill(Color.black.opacity(AppStyles.Shell.Sidebar.chipMuteOverlayOpacity))
                )
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(AppStyles.Shell.Sidebar.chipBorderOpacity), lineWidth: 1)
        )
        .fixedSize(horizontal: true, vertical: true)
    }
}
