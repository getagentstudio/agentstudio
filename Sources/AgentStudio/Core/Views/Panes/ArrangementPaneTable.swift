import AgentStudioInfrastructure
import AgentStudioSharedComponents
import SwiftUI

struct ArrangementPaneTable: View {
    let panes: [PaneVisibilityInfo]
    let octiconLoader: OcticonLoader
    let commandActionResolver: TargetedCommandControlActionResolver
    let highlightPaneId: UUID?
    let highlightVisible: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppStyles.Components.ArrangementPanel.columnSpacing) {
                Color.clear.frame(width: AppStyles.Shell.Sidebar.rowLeadingIconColumnWidth, height: 1)
                header(.arrangementPaneColumn, identifier: "pane")
                    .frame(maxWidth: .infinity, alignment: .leading)
                header(.arrangementWorktreeColumn, identifier: "worktree")
                    .frame(width: AppStyles.Components.ArrangementPanel.worktreeColumnWidth, alignment: .leading)
                header(.arrangementStatusColumn, identifier: "status")
                    .frame(width: AppStyles.Components.ArrangementPanel.statusColumnWidth, alignment: .leading)
                Color.clear.frame(width: AppStyles.Components.ArrangementPanel.actionsWidth, height: 1)
            }
            .padding(.bottom, AppStyles.General.Spacing.standard)
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(panes) { pane in
                        Divider()
                        ArrangementPaneTableRow(
                            pane: pane, octiconLoader: octiconLoader, commandActionResolver: commandActionResolver,
                            isHighlighted: pane.id == highlightPaneId && highlightVisible)
                    }
                }
            }
            .frame(
                height: min(
                    CGFloat(panes.count) * (AppStyles.Components.ArrangementPanel.rowHeight + 1),
                    AppStyles.Components.ArrangementPanel.maximumRowsHeight))
        }
    }

    private func header(_ action: LocalActionSpec, identifier: String) -> some View {
        let spec = action.actionSpec
        return Text(spec.label)
            .font(.system(size: AppStyles.General.Typography.textXs, weight: .semibold))
            .foregroundStyle(.secondary)
            .controlHelp(
                spec.controlTooltipRenderValue(
                    provenance: .localAction(rawValue: identifier), textOverride: spec.helpText)
            )
            .background {
                AccessibilityLabelBridge(identifier: "arrangement-panel-column-\(identifier)", label: spec.label)
            }
    }
}

private struct ArrangementPaneTableRow: View {
    let pane: PaneVisibilityInfo
    let octiconLoader: OcticonLoader
    let commandActionResolver: TargetedCommandControlActionResolver
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: AppStyles.Components.ArrangementPanel.columnSpacing) {
            pane.paneIcon.swiftUIImage(
                loader: octiconLoader, size: AppStyles.Shell.Sidebar.rowIdentityIconSize
            )
            .frame(width: AppStyles.Shell.Sidebar.rowLeadingIconColumnWidth)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppStyles.General.Spacing.tight) {
                readout(pane.title).fontWeight(.medium)
                if let line = pane.agentLine { readout(line).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: AppStyles.General.Spacing.tight) {
                readout(
                    pane.worktreeName ?? LocalActionSpec.arrangementValueUnavailable.actionSpec.label,
                    tooltip: pane.worktreePath)
                if let branch = pane.branchName { readout(branch).foregroundStyle(.secondary) }
            }
            .frame(width: AppStyles.Components.ArrangementPanel.worktreeColumnWidth, alignment: .leading)
            status
                .frame(width: AppStyles.Components.ArrangementPanel.statusColumnWidth, alignment: .leading)
            actions.frame(width: AppStyles.Components.ArrangementPanel.actionsWidth, alignment: .trailing)
        }
        .font(.system(size: AppStyles.General.Typography.textXs))
        .padding(.vertical, AppStyles.Components.ArrangementPanel.rowVerticalPadding)
        .frame(height: AppStyles.Components.ArrangementPanel.rowHeight)
        .background(
            isHighlighted ? AppStyles.General.Accent.primaryColor.opacity(AppStyles.General.Fill.selected) : .clear)
    }

    private func readout(_ text: String, tooltip: String? = nil) -> some View {
        let spec = LocalActionSpec.arrangementDataReadout(tooltip ?? text).actionSpec
        return Text(text).lineLimit(1).truncationMode(.tail)
            .controlHelp(spec.controlTooltipRenderValue(provenance: .localAction(rawValue: "arrangementDataReadout")))
    }

    @ViewBuilder private var status: some View {
        switch pane.agentStatus {
        case .hidden:
            readout(
                LocalActionSpec.arrangementPaneHidden.actionSpec.label,
                tooltip: LocalActionSpec.arrangementPaneHidden.actionSpec.helpText
            ).foregroundStyle(.secondary)
        case .unavailable:
            readout(LocalActionSpec.arrangementValueUnavailable.actionSpec.label).foregroundStyle(.tertiary)
        case .agent(let line):
            HStack(spacing: AppStyles.General.Spacing.tight) {
                line.icon.swiftUIImage(loader: octiconLoader, size: AppStyles.General.Icon.compact)
                    .foregroundStyle(statusColor(line.kind))
                readout(line.label, tooltip: line.detail)
            }
            .accessibilityHidden(true)
            .background {
                AccessibilityLabelBridge(
                    identifier: "arrangement-panel-pane-\(pane.id.uuidString)-status",
                    label: line.label, role: .staticText, help: line.detail, value: line.detail)
            }
            .controlHelp(
                LocalActionSpec.arrangementDataReadout(line.detail).actionSpec.controlTooltipRenderValue(
                    provenance: .localAction(rawValue: "arrangementStatus")))
        }
    }

    private func statusColor(_ kind: StatusLine.Kind) -> Color {
        switch kind {
        case .working, .monitoring: PaneContextChipTone.accent.foregroundColor
        case .needsYou: PaneContextChipTone.warning.foregroundColor
        case .failed: PaneContextChipTone.danger.foregroundColor
        case .idle: PaneContextChipTone.neutral.foregroundColor
        }
    }

    private var actions: some View {
        HStack(spacing: AppStyles.General.Spacing.tight) {
            if pane.supportsZoom,
                let zoom = commandActionResolver(.zoomPane, .inlineControl, pane.id, .pane)
            {
                actionButton(zoom, suffix: "zoom")
            } else {
                Color.clear.frame(width: AppStyles.Components.ArrangementPanel.actionSize, height: 1)
            }
            if let visibility = commandActionResolver(
                pane.isMinimized ? .expandPane : .minimizePane, .inlineControl, pane.id, .pane)
            {
                actionButton(visibility, suffix: "visibility")
            }
        }
    }

    private func actionButton(_ action: TargetedCommandControlAction, suffix: String) -> some View {
        Button(action: action.perform) {
            action.commandSpec.icon.swiftUIImage(loader: octiconLoader, size: AppStyles.General.Icon.compact)
                .frame(
                    width: AppStyles.Components.ArrangementPanel.actionSize,
                    height: AppStyles.Components.ArrangementPanel.actionSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).disabled(!action.isEnabled)
        .controlHelp(action.commandSpec.controlTooltipRenderValue())
        .accessibilityHidden(true)
        .background {
            AccessibilityPressBridge(
                identifier: "arrangement-panel-pane-\(pane.id.uuidString)-\(suffix)",
                label: action.commandSpec.label, isEnabled: action.isEnabled, action: action.perform)
        }
    }
}
