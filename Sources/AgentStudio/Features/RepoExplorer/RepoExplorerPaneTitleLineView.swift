import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import SwiftUI

package struct RepoExplorerPaneTitleLineView: View {
    let text: String
    let isDrawerPane: Bool
    let octiconLoader: OcticonLoader
    let shortcutDisplay: ShortcutDisplayText?
    let maximumLineCount: Int

    package init(
        text: String, isDrawerPane: Bool, octiconLoader: OcticonLoader,
        shortcutDisplay: ShortcutDisplayText? = nil, maximumLineCount: Int = 1
    ) {
        self.text = text
        self.isDrawerPane = isDrawerPane
        self.octiconLoader = octiconLoader
        self.shortcutDisplay = shortcutDisplay
        self.maximumLineCount = maximumLineCount
    }

    package var body: some View {
        HStack(
            alignment: maximumLineCount > 1 ? .firstTextBaseline : .center,
            spacing: AppStyles.Shell.Sidebar.groupIconTitleSpacing
        ) {
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
                .lineLimit(maximumLineCount)
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
