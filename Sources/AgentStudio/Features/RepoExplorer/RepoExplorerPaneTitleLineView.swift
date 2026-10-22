import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import SwiftUI

package struct RepoExplorerPaneTitleLineView: View {
    let text: String
    let isDrawerPane: Bool
    let octiconLoader: OcticonLoader
    let shortcutDisplay: ShortcutDisplayText?

    package init(
        text: String, isDrawerPane: Bool, octiconLoader: OcticonLoader,
        shortcutDisplay: ShortcutDisplayText? = nil
    ) {
        self.text = text
        self.isDrawerPane = isDrawerPane
        self.octiconLoader = octiconLoader
        self.shortcutDisplay = shortcutDisplay
    }

    package var body: some View {
        HStack(spacing: AppStyles.Shell.Sidebar.groupIconTitleSpacing) {
            (isDrawerPane ? AppEntityIcon.drawer : .pane).swiftUIImage(
                loader: octiconLoader,
                size: AppStyles.Shell.Sidebar.rowIdentityIconSize
            )
            .frame(
                width: AppStyles.Shell.Sidebar.rowLeadingIconColumnWidth,
                alignment: .leading
            )
            Text(text)
                .font(.system(size: AppStyles.General.Typography.textBase, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sidebarShortcutHint(
            shortcutDisplay,
            style: .toolbarStamp,
            alignment: .trailing,
            offset: CGSize(width: -AppStyles.Shell.Sidebar.KeyboardHint.rowTrailingInset, height: 0)
        )
    }

}
