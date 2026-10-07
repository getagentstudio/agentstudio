import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import SwiftUI

package struct RepoExplorerPaneContextLineView: View {
    let line: RepoExplorerPaneContextLine
    let isAgentLine: Bool
    let octiconLoader: OcticonLoader

    package init(line: RepoExplorerPaneContextLine, isAgentLine: Bool, octiconLoader: OcticonLoader) {
        self.line = line
        self.isAgentLine = isAgentLine
        self.octiconLoader = octiconLoader
    }
    package var body: some View {
        HStack(spacing: AppStyles.Shell.Sidebar.groupIconTitleSpacing) {
            line.icon.swiftUIImage(loader: octiconLoader, size: AppStyles.Shell.Sidebar.branchIconSize)
                .foregroundStyle(glyphColor)
                .frame(width: AppStyles.Shell.Sidebar.rowLeadingIconColumnWidth, alignment: .leading)
            Text(line.text)
                .font(.system(size: AppStyles.Shell.Sidebar.branchFontSize))
                .foregroundStyle(isAgentLine ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(line.stale ? AppStyles.General.Foreground.secondary : 1)
        .controlHelp(line.tooltip)
    }
    private var glyphColor: Color {
        switch line.tone {
        case .neutral: .secondary
        case .info: AppStyles.Shell.Sidebar.chipInfoColor
        case .success: AppStyles.Shell.Sidebar.chipSuccessColor
        case .warning: AppStyles.Shell.Sidebar.chipWarningColor
        case .danger: AppStyles.Shell.Sidebar.chipDangerColor
        }
    }
}
