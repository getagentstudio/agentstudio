import AgentStudioCore
import AgentStudioInfrastructure
import SwiftUI

enum WorkspaceEmptyStateLayout {
    static let visibleRecentCardLimit: Int = 6
    static let intakeActionRegionMinHeight: CGFloat = 92
}

enum WorkspaceEmptyStateCopy {
    static let intakeTitle = "Welcome to AgentStudio"
    static let intakeBody = "The terminal IDE built for coding agents."
    static let intakeHelper =
        "AgentStudio watches the folder and discovers your repos automatically."

    static let intakeBusyTitle = "Opening folder picker…"
    static let intakeBusyHelper = "Waiting for you to pick a folder."

    static let scanningHelper = "Looking for git folders…"

    static let scanEmptyRetryButton = "Choose Another Folder to Scan…"
    static let scanEmptyHelper =
        "AgentStudio will keep watching this folder and add repos as they appear."

    static func scanningTitle(folder: String) -> String {
        "Scanning \(folder)"
    }

    static func scanEmptyTitle(folder: String) -> String {
        "No git folders found in \(folder)"
    }

    static func displayName(for path: URL?, fallback: String) -> String {
        guard let path else { return fallback }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fullPath = path.path
        if fullPath == home {
            return "~"
        }
        if fullPath.hasPrefix(home + "/") {
            return "~" + fullPath.dropFirst(home.count)
        }
        return fullPath
    }

    static func titleFolderName(for path: URL?, fallback: String) -> String {
        guard let path else { return fallback }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fullPath = path.path
        if fullPath == home {
            return "~"
        }
        let leafName = path.lastPathComponent
        if leafName.isEmpty {
            return displayName(for: path, fallback: fallback)
        }
        return leafName
    }
}

struct WorkspaceEmptyStateView: View {
    let model: WorkspaceEmptyStateModel
    let octiconLoader: OcticonLoader
    let commandDispatcher: any AppCommandDispatching
    let onWatchFolder: () -> Void
    let onOpenRecent: (ApplicationRecentEntity) -> Void
    let onOpenAllRecent: () -> Void

    var body: some View {
        Group {
            switch model.kind {
            case .choosingFolder:
                VStack(spacing: 0) {
                    Spacer()
                    folderIntakeBusyBody
                    Spacer()
                }
                .id("choosingFolder")
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .noFolders:
                VStack(spacing: 0) {
                    Spacer()
                    folderIntakeBody
                    Spacer()
                }
                .id("noFolders")
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .scanning:
                VStack(spacing: 0) {
                    Spacer()
                    scanningBody
                    Spacer()
                }
                .id("scanning")
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .scanEmpty:
                VStack(spacing: 0) {
                    Spacer()
                    scanEmptyBody
                    Spacer()
                }
                .id("scanEmpty")
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .launcher:
                ScrollView(.vertical, showsIndicators: false) {
                    launcherBody()
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, AppStyles.Welcome.pageHorizontalPadding)
                        .padding(.bottom, AppStyles.Welcome.pageVerticalPadding)
                }
                .id("launcher")
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.20), value: model.kind)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var folderIntakeBody: some View {
        folderIntakeLayout {
            VStack(alignment: .leading, spacing: AppStyles.Welcome.intakeActionRowSpacing) {
                Button(LocalActionSpec.chooseFolderToScan.actionSpec.label, action: onWatchFolder)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                Text(WorkspaceEmptyStateCopy.intakeHelper)
                    .font(AppStyles.Welcome.Typography.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: WorkspaceEmptyStateLayout.intakeActionRegionMinHeight, alignment: .topLeading)
            .padding(.top, AppStyles.Welcome.intakeActionTopPadding)
        }
    }

    private var folderIntakeBusyBody: some View {
        folderIntakeLayout {
            VStack(alignment: .leading, spacing: AppStyles.Welcome.intakeActionRowSpacing) {
                HStack(spacing: AppStyles.Welcome.intakeScanningSpinnerGap) {
                    ProgressView()
                        .controlSize(.small)
                    Text(WorkspaceEmptyStateCopy.intakeBusyTitle)
                        .font(AppStyles.Welcome.Typography.h3)
                        .foregroundStyle(
                            .primary.opacity(AppStyles.Welcome.intakeScanningTitleOpacity)
                        )
                }

                Text(WorkspaceEmptyStateCopy.intakeBusyHelper)
                    .font(AppStyles.Welcome.Typography.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: WorkspaceEmptyStateLayout.intakeActionRegionMinHeight, alignment: .topLeading)
            .padding(.top, AppStyles.Welcome.intakeActionTopPadding)
        }
    }

    private var scanningBody: some View {
        folderIntakeLayout {
            VStack(alignment: .leading, spacing: AppStyles.Welcome.intakeActionRowSpacing) {
                HStack(spacing: AppStyles.Welcome.intakeScanningSpinnerGap) {
                    ProgressView()
                        .controlSize(.small)
                    Text(WorkspaceEmptyStateCopy.scanningTitle(folder: scanningFolderTitle))
                        .font(AppStyles.Welcome.Typography.h3)
                        .foregroundStyle(
                            .primary.opacity(AppStyles.Welcome.intakeScanningTitleOpacity)
                        )
                }

                Text(WorkspaceEmptyStateCopy.scanningHelper)
                    .font(AppStyles.Welcome.Typography.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: WorkspaceEmptyStateLayout.intakeActionRegionMinHeight, alignment: .topLeading)
            .padding(.top, AppStyles.Welcome.intakeActionTopPadding)
        }
    }

    private var scanEmptyBody: some View {
        folderIntakeLayout {
            VStack(alignment: .leading, spacing: AppStyles.Welcome.intakeActionRowSpacing) {
                Text(WorkspaceEmptyStateCopy.scanEmptyTitle(folder: emptyFolderTitle))
                    .font(AppStyles.Welcome.Typography.h3)
                    .foregroundStyle(
                        .primary.opacity(AppStyles.Welcome.intakeScanningTitleOpacity)
                    )

                Button(WorkspaceEmptyStateCopy.scanEmptyRetryButton, action: onWatchFolder)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                Text(WorkspaceEmptyStateCopy.scanEmptyHelper)
                    .font(AppStyles.Welcome.Typography.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: WorkspaceEmptyStateLayout.intakeActionRegionMinHeight, alignment: .topLeading)
            .padding(.top, AppStyles.Welcome.intakeActionTopPadding)
        }
    }

    @ViewBuilder
    private func folderIntakeLayout<Action: View>(
        @ViewBuilder actionRegion: () -> Action
    ) -> some View {
        HStack(alignment: .center, spacing: AppStyles.Welcome.intakeColumnSpacing) {
            WelcomeSidebarIllustration(octiconLoader: octiconLoader)

            VStack(alignment: .leading, spacing: AppStyles.Welcome.intakeRightColumnSpacing) {
                AppLogoView(size: AppStyles.Welcome.intakeLogoSize)

                Text(WorkspaceEmptyStateCopy.intakeTitle)
                    .font(.system(size: AppStyles.Welcome.titleFontSize, weight: .semibold))

                Text(WorkspaceEmptyStateCopy.intakeBody)
                    .font(.system(size: AppStyles.Welcome.bodyFontSize))
                    .foregroundStyle(.secondary)

                actionRegion()
            }
        }
        .frame(maxWidth: AppStyles.Welcome.launcherContentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var scanningFolderDisplayName: String {
        WorkspaceEmptyStateCopy.displayName(for: model.scanningFolderPath, fallback: "")
    }

    private var scanningFolderTitle: String {
        WorkspaceEmptyStateCopy.titleFolderName(for: model.scanningFolderPath, fallback: "")
    }

    private var emptyFolderDisplayName: String {
        WorkspaceEmptyStateCopy.displayName(for: model.emptyFolderPath, fallback: "this folder")
    }

    private var emptyFolderTitle: String {
        WorkspaceEmptyStateCopy.titleFolderName(for: model.emptyFolderPath, fallback: "this folder")
    }

    private func launcherBody() -> some View {
        let visibleRecentCards = Array(
            model.recentCards.prefix(WorkspaceEmptyStateLayout.visibleRecentCardLimit)
        )
        let subtitle =
            visibleRecentCards.isEmpty ? "Get started." : "Jump back in, fast."

        return VStack(alignment: .leading, spacing: AppStyles.Welcome.launcherSectionGap) {
            launcherHeader(subtitle: subtitle)

            launcherRecentSection(visibleRecentCards: visibleRecentCards)

            Divider()
                .opacity(AppStyles.Welcome.launcherDividerOpacity)

            launcherShortcutsBlock
        }
        .padding(.top, AppStyles.Welcome.launcherPageTopPadding)
        .frame(maxWidth: AppStyles.Welcome.launcherContentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func launcherHeader(subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: AppStyles.Welcome.titleBodyGap) {
            Text("Your workspace")
                .font(AppStyles.Welcome.Typography.h1)

            Text(subtitle)
                .font(AppStyles.Welcome.Typography.body)
                .foregroundStyle(.secondary)
        }
    }

    private var launcherShortcutsBlock: some View {
        VStack(alignment: .leading, spacing: AppStyles.Welcome.sectionHeaderToContentSpacing) {
            Text("Shortcuts")
                .font(AppStyles.Welcome.Typography.h2)
                .foregroundStyle(.primary.opacity(AppStyles.Welcome.TextColor.h2Opacity))

            launcherShortcutsColumns
        }
    }

    private var launcherShortcutsColumns: some View {
        let quickFindDefinition = AppCommand.showCommandBarEverything.definition
        let newTabOrWorktreeDefinition = AppCommand.showCommandBarRepos.definition
        let watchFolderDefinition = AppCommand.watchFolder.definition
        let commandContext = ShellTabBarCommandContext.current()
        let quickFindPresentation = ShellTabBarCommandPresentation(
            definition: quickFindDefinition,
            surface: .inlineControl,
            commandContext: commandContext,
            dispatcher: commandDispatcher
        )
        let repositoriesPresentation = ShellTabBarCommandPresentation(
            definition: newTabOrWorktreeDefinition,
            surface: .inlineControl,
            commandContext: commandContext,
            dispatcher: commandDispatcher
        )
        let watchFolderPresentation = ShellTabBarCommandPresentation(
            definition: watchFolderDefinition,
            surface: .inlineControl,
            commandContext: commandContext,
            dispatcher: commandDispatcher
        )

        return HStack(alignment: .top, spacing: AppStyles.Welcome.launcherShortcutsColumnsGap) {
            LauncherPreviewStack(octiconLoader: octiconLoader)

            VStack(alignment: .leading, spacing: AppStyles.Welcome.launcherRowGap) {
                if let quickFindPresentation {
                    launcherShortcutRow(
                        leadingContent: .preferred(
                            keyBindingDisplayString: quickFindDefinition.globalKeyBinding?.displayString,
                            icon: quickFindDefinition.actionSpec.icon
                        ),
                        title: quickFindDefinition.label,
                        subtitle: "Everything in the app, one keypress away.",
                        isEnabled: quickFindPresentation.isEnabled,
                        action: quickFindPresentation.perform
                    )
                }

                if let repositoriesPresentation {
                    launcherShortcutRow(
                        leadingContent: .preferred(
                            keyBindingDisplayString: newTabOrWorktreeDefinition.globalKeyBinding?.displayString,
                            icon: newTabOrWorktreeDefinition.actionSpec.icon
                        ),
                        title: newTabOrWorktreeDefinition.label,
                        subtitle: "Opens the # picker. New Empty Tab is always first.",
                        isEnabled: repositoriesPresentation.isEnabled,
                        action: repositoriesPresentation.perform
                    )
                }

                if let watchFolderPresentation {
                    launcherShortcutRow(
                        leadingContent: .preferred(
                            keyBindingDisplayString: watchFolderDefinition.globalKeyBinding?.displayString,
                            icon: watchFolderDefinition.actionSpec.icon
                        ),
                        title: watchFolderDefinition.label,
                        subtitle: "Scan and keep watching a folder for repos.",
                        isEnabled: watchFolderPresentation.isEnabled,
                        action: watchFolderPresentation.perform
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func launcherShortcutRow(
        leadingContent: LauncherShortcutLeadingContent,
        title: String,
        subtitle: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        LauncherShortcutRow(
            leadingContent: leadingContent,
            octiconLoader: octiconLoader,
            title: title,
            subtitle: subtitle,
            isEnabled: isEnabled,
            action: action
        )
    }

    private func launcherRecentSection(
        visibleRecentCards: [WorkspaceRecentCardModel]
    ) -> some View {
        VStack(alignment: .leading, spacing: AppStyles.Welcome.sectionHeaderToContentSpacing) {
            recentSectionHeader

            if visibleRecentCards.isEmpty {
                WorkspaceRecentPlaceholderCard()
            } else {
                WorkspaceRecentList(
                    cards: visibleRecentCards,
                    octiconLoader: octiconLoader,
                    onOpen: onOpenRecent
                )
            }
        }
    }

    private var recentSectionHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("Recent")
                .font(AppStyles.Welcome.Typography.h2)
                .foregroundStyle(.primary.opacity(AppStyles.Welcome.TextColor.h2Opacity))

            if model.showsOpenAll {
                Button(LocalActionSpec.openAllInTabs.actionSpec.label) {
                    onOpenAllRecent()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer(minLength: 0)
        }
    }
}

private struct WorkspaceRecentList: View {
    let cards: [WorkspaceRecentCardModel]
    let octiconLoader: OcticonLoader
    let onOpen: (ApplicationRecentEntity) -> Void

    var body: some View {
        VStack(spacing: AppStyles.Welcome.recentRowSpacing) {
            ForEach(cards) { card in
                WorkspaceRecentRowView(
                    card: card,
                    octiconLoader: octiconLoader,
                    onOpen: { onOpen(card.target) }
                )

                if card.id != cards.last?.id {
                    Divider()
                        .padding(.leading, 16)
                        .opacity(AppStyles.Welcome.recentListSeparatorOpacity)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: AppStyles.Welcome.recentListCornerRadius)
                .fill(Color.white.opacity(AppStyles.Welcome.cardFillOpacity))
        )
        .clipShape(
            RoundedRectangle(cornerRadius: AppStyles.Welcome.recentListCornerRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppStyles.Welcome.recentListCornerRadius)
                .stroke(Color.white.opacity(AppStyles.Welcome.cardStrokeOpacity), lineWidth: 1)
        )
    }
}

private struct WorkspaceRecentRowView: View {
    let card: WorkspaceRecentCardModel
    let octiconLoader: OcticonLoader
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    titleRow
                    branchRow
                }

                Spacer(minLength: 12)

                chipsRow
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(
                maxWidth: .infinity,
                minHeight: AppStyles.Welcome.recentRowMinHeight,
                alignment: .leading
            )
            .contentShape(Rectangle())
            .background(
                isHovered
                    ? Color.white.opacity(AppStyles.Welcome.cardHoverOpacity)
                    : Color.clear
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var iconColor: Color {
        let hex = card.iconColorHex ?? ""
        return Color(nsColor: NSColor(hex: hex) ?? AppStyles.General.Accent.primaryNSColor)
    }

    private var iconSymbol: String {
        switch card.checkoutIconKind ?? .gitWorktree {
        case .mainCheckout: return "star.fill"
        case .gitWorktree: return "arrow.triangle.branch"
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: iconSymbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 14, alignment: .leading)

            Text(card.repoName)
                .font(AppStyles.Welcome.Typography.h3)
                .foregroundStyle(.primary.opacity(AppStyles.Welcome.TextColor.h3Opacity))

            Text("/")
                .font(AppStyles.Welcome.Typography.h3)
                .foregroundStyle(.secondary)

            Text(card.worktreeDisplayName)
                .font(AppStyles.Welcome.Typography.h3)
                .foregroundStyle(.primary.opacity(AppStyles.Welcome.TextColor.h3Opacity))
        }
    }

    private var branchRow: some View {
        Text(card.detail)
            .font(AppStyles.Welcome.Typography.bodySm)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.leading, 20)
    }

    private var chipsRow: some View {
        WorkspaceStatusChipRow(
            octiconLoader: octiconLoader,
            model: card.statusChips
                ?? .init(
                    branchStatus: .init(
                        isDirty: false,
                        syncState: .unknown,
                        prCount: nil,
                        linesAdded: 0,
                        linesDeleted: 0,
                        untrackedFileCount: 0
                    )
                ),
            accentColor: iconColor
        )
    }
}

private struct WorkspaceRecentPlaceholderCard: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(AppStyles.Welcome.Typography.h3)
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .leading)

            Text("No recent worktrees yet.")
                .font(AppStyles.Welcome.Typography.h3)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    Color.white.opacity(AppStyles.Welcome.cardStrokeOpacity),
                    style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                )
        )
    }
}

private struct AppLogoView: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let url = Bundle.appResources.url(
                forResource: "AppLogoTransparent", withExtension: "svg"),
                let image = NSImage(contentsOf: url)
            {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(AppStyles.General.Accent.primaryColor)
            }
        }
        .frame(width: size, height: size)
    }
}
