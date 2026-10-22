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
    let showsTooltip: Bool

    package init(
        line: RepoExplorerPaneContextLine, isAgentLine: Bool, octiconLoader: OcticonLoader, showsTooltip: Bool = true
    ) {
        self.line = line
        self.isAgentLine = isAgentLine
        self.octiconLoader = octiconLoader
        self.showsTooltip = showsTooltip
    }
    package var body: some View {
        if showsTooltip {
            content.controlHelp(line.tooltip)
        } else {
            content
        }
    }

    private var content: some View {
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
    }

    private var opacityPulseIsActive: Bool {
        !reduceMotion && line.glyphMotion == .opacityPulse
    }
}
