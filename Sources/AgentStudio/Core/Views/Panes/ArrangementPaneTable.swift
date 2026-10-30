import AgentStudioInfrastructure
import AgentStudioSharedComponents
import SwiftUI

struct ArrangementPaneTable: View {
    let panes: [PaneVisibilityInfo]
    var metrics: ArrangementTableMetrics = .minimum
    let octiconLoader: OcticonLoader
    let commandActionResolver: TargetedCommandControlActionResolver
    let highlightPaneId: UUID?
    let highlightVisible: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppStyles.Components.ArrangementPanel.columnSpacing) {
                header(.arrangementPaneColumn, identifier: "pane")
                    .frame(
                        width: metrics.paneWidth + AppStyles.Components.ArrangementPanel.glyphTileSize
                            + AppStyles.Components.ArrangementPanel.columnSpacing,
                        alignment: .leading)
                header(.arrangementWorktreeColumn, identifier: "worktree")
                    .frame(width: metrics.worktreeWidth, alignment: .leading)
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
                            pane: pane, metrics: metrics, octiconLoader: octiconLoader,
                            commandActionResolver: commandActionResolver,
                            isHighlighted: pane.id == highlightPaneId && highlightVisible)
                    }
                }
            }
            .frame(maxHeight: AppStyles.Components.ArrangementPanel.maximumRowsHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func header(_ action: LocalActionSpec, identifier: String) -> some View {
        let spec = action.actionSpec
        return Text(spec.label)
            .font(.system(size: AppStyles.Components.ArrangementPanel.detailFontSize, weight: .semibold))
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
    let metrics: ArrangementTableMetrics
    let octiconLoader: OcticonLoader
    let commandActionResolver: TargetedCommandControlActionResolver
    let isHighlighted: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: AppStyles.Components.ArrangementPanel.columnSpacing) {
            paneGlyph
            VStack(alignment: .leading, spacing: AppStyles.Components.ArrangementPanel.rowDetailSpacing) {
                readout(pane.title)
                    .font(.system(size: AppStyles.Components.ArrangementPanel.titleFontSize, weight: .semibold))
                if let line = pane.paneNote ?? pane.agentLine { readout(line).foregroundStyle(.secondary) }
            }
            .frame(width: metrics.paneWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: AppStyles.Components.ArrangementPanel.rowDetailSpacing) {
                readout(
                    pane.worktreeName ?? pane.cwdPath ?? LocalActionSpec.arrangementValueUnavailable.actionSpec.label,
                    tooltip: pane.worktreePath
                )
                .font(
                    .system(
                        size: pane.worktreeName == nil
                            ? AppStyles.Components.ArrangementPanel.detailFontSize
                            : AppStyles.Components.ArrangementPanel.titleFontSize,
                        weight: pane.worktreeName == nil ? .regular : .semibold))
                if let branch = pane.branchName { readout(branch).foregroundStyle(.secondary) }
            }
            .frame(width: metrics.worktreeWidth, alignment: .leading)
            status
                .frame(width: AppStyles.Components.ArrangementPanel.statusColumnWidth, alignment: .leading)
            actions.frame(width: AppStyles.Components.ArrangementPanel.actionsWidth, alignment: .trailing)
        }
        .font(.system(size: AppStyles.Components.ArrangementPanel.detailFontSize))
        .padding(.vertical, AppStyles.Components.ArrangementPanel.rowVerticalPadding)
        .frame(minHeight: AppStyles.Components.ArrangementPanel.rowHeight)
        .background(
            isHighlighted
                ? AppStyles.General.Accent.primaryColor.opacity(AppStyles.General.Fill.selected)
                : isHovered ? Color.primary.opacity(AppStyles.General.Fill.hover) : .clear
        )
        .onHover { isHovered = $0 }
    }

    private var paneGlyph: some View {
        Group {
            if pane.paneIcon == .system(.terminal) {
                Text(LocalActionSpec.arrangementTerminalPrompt.actionSpec.label)
                    .font(
                        .system(
                            size: AppStyles.Components.ArrangementPanel.terminalPromptFontSize, weight: .medium,
                            design: .monospaced)
                    )
                    .fixedSize()
            } else {
                pane.paneIcon.swiftUIImage(loader: octiconLoader, size: AppStyles.Components.ArrangementPanel.glyphSize)
            }
        }
        .foregroundStyle(.secondary)
        .frame(
            width: AppStyles.Components.ArrangementPanel.glyphTileSize,
            height: AppStyles.Components.ArrangementPanel.glyphTileSize
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppStyles.Components.ArrangementPanel.glyphCornerRadius)
                .strokeBorder(.secondary, lineWidth: AppStyles.Components.ArrangementPanel.glyphStrokeWidth)
        }
        .accessibilityHidden(true)
    }

    private func readout(_ text: String, tooltip: String? = nil) -> some View {
        let spec = LocalActionSpec.arrangementDataReadout(tooltip ?? text).actionSpec
        return Text(text).fixedSize(horizontal: false, vertical: true)
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
                Circle()
                    .fill(statusColor(line.kind))
                    .frame(
                        width: AppStyles.Components.ArrangementPanel.statusDotSize,
                        height: AppStyles.Components.ArrangementPanel.statusDotSize
                    )
                    .accessibilityHidden(true)
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
        case .needsYou: AppStyles.Components.ArrangementPanel.needsYouColor
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
            } else if !pane.supportsZoom {
                actionButton(
                    .init(commandSpec: AppCommand.zoomPane.definition, isEnabled: false, perform: {}),
                    suffix: "zoom", display: .arrangementTerminalOnlyZoom)
            } else {
                Color.clear.frame(width: AppStyles.Components.ArrangementPanel.actionSize, height: 1)
            }
            if let visibility = commandActionResolver(
                pane.isMinimized ? .expandPane : .minimizePane, .inlineControl, pane.id, .pane)
            {
                actionButton(
                    visibility, suffix: "visibility",
                    display: pane.isMinimized ? .showPane : .hidePane)
            }
        }
    }

    private func actionButton(
        _ action: TargetedCommandControlAction, suffix: String, display: LocalActionSpec? = nil
    ) -> some View {
        let displaySpec = display?.actionSpec

        return Button(action: action.perform) {
            (displaySpec?.icon ?? action.commandSpec.icon).swiftUIImage(
                loader: octiconLoader, size: AppStyles.Components.ArrangementPanel.actionIconSize, weight: .semibold
            )
            .frame(
                width: AppStyles.Components.ArrangementPanel.actionSize,
                height: AppStyles.Components.ArrangementPanel.actionSize
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).disabled(!action.isEnabled)
        .controlHelp(
            displaySpec?.controlTooltipRenderValue(provenance: .localAction(rawValue: "arrangementVisibility"))
                ?? action.commandSpec.controlTooltipRenderValue()
        )
        .accessibilityHidden(true)
        .background {
            AccessibilityPressBridge(
                identifier: "arrangement-panel-pane-\(pane.id.uuidString)-\(suffix)",
                label: displaySpec?.label ?? action.commandSpec.label, isEnabled: action.isEnabled,
                help: displaySpec?.helpText,
                action: action.perform)
        }
    }
}
