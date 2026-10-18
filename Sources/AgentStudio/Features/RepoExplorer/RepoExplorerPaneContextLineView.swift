import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import SwiftUI

package struct RepoExplorerPaneContextLineView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseIsDimmed = false

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
                .opacity(
                    opacityPulseIsActive && pulseIsDimmed
                        ? AppStyles.Shell.Sidebar.paneLinePulseMinimumOpacity
                        : AppStyles.Shell.Sidebar.paneLinePulseMaximumOpacity
                )
                .animation(
                    opacityPulseIsActive
                        ? .easeInOut(duration: AppStyles.Shell.Sidebar.paneLinePulsePeriod / 2)
                            .repeatForever(autoreverses: true)
                        : nil,
                    value: pulseIsDimmed
                )
                .onChange(of: opacityPulseIsActive, initial: true) { _, isActive in
                    pulseIsDimmed = isActive
                }
                .symbolEffect(
                    .rotate,
                    options: .repeating.speed(AppStyles.Shell.Sidebar.paneLineRotationSpeed),
                    isActive: !reduceMotion && line.glyphMotion == .rotate
                )
                .foregroundStyle(line.tone.foregroundColor)
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

    private var opacityPulseIsActive: Bool {
        !reduceMotion && line.glyphMotion == .opacityPulse
    }
}
