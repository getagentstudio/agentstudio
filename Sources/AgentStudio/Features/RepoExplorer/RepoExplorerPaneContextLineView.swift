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
    let maximumTextWidth: CGFloat
    let maximumLineCount: Int

    package init(
        line: RepoExplorerPaneContextLine, isAgentLine: Bool, octiconLoader: OcticonLoader,
        showsTooltip: Bool = true, maximumLineCount: Int = 1,
        maximumTextWidth: CGFloat? = nil
    ) {
        self.line = line
        self.isAgentLine = isAgentLine
        self.octiconLoader = octiconLoader
        self.showsTooltip = showsTooltip
        self.maximumTextWidth =
            maximumTextWidth
            ?? (maximumLineCount > 1 ? .infinity : AppStyles.Shell.Sidebar.agentLineMaxWidth)
        self.maximumLineCount = maximumLineCount
    }
    package var body: some View {
        if showsTooltip {
            content.controlHelp(line.tooltip)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(
            alignment: maximumLineCount > 1 ? .firstTextBaseline : .center,
            spacing: AppStyles.Shell.Sidebar.groupIconTitleSpacing
        ) {
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
            if let ageText = line.ageText {
                PaneAgentLineText(
                    text, ageText: ageText, maximumTextWidth: maximumTextWidth,
                    ageIdentifier: "paneContext.agentLine.age"
                )
                .lineLimit(maximumLineCount)
                .truncationMode(.tail)
                .background {
                    AccessibilityLabelBridge(
                        identifier: "paneContext.agentLine.text", label: line.text, role: .staticText)
                }
            } else {
                text
                    .lineLimit(maximumLineCount)
                    .truncationMode(.tail)
                    .background {
                        AccessibilityLabelBridge(
                            identifier: "paneContext.status.text", label: line.text, role: .staticText)
                    }
            }
        }
    }

    private var text: Text {
        Text(line.text)
            .font(.system(size: AppStyles.Shell.Sidebar.branchFontSize))
            .foregroundColor(isAgentLine ? Color.primary : line.tone.foregroundColor)
    }

    private var opacityPulseIsActive: Bool {
        !reduceMotion && line.glyphMotion == .opacityPulse
    }
}
