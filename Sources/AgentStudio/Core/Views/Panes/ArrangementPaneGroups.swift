import AgentStudioInfrastructure
import AgentStudioSharedComponents
import SwiftUI

struct ArrangementPaneGroups: View {
    let groups: [ArrangementPaneGroup]
    let octiconLoader: OcticonLoader
    let commandActionResolver: TargetedCommandControlActionResolver
    let highlightPaneId: UUID?
    let highlightVisible: Bool

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: AppStyles.General.Spacing.standard) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: AppStyles.Components.ArrangementPanel.rowDetailSpacing) {
                            groupReadout(group.title, fullPath: group.fullPath)
                                .font(
                                    .system(
                                        size: AppStyles.Components.ArrangementPanel.titleFontSize, weight: .semibold))
                            if let detail = group.detail {
                                groupReadout(detail).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, AppStyles.General.Spacing.standard)
                        .background {
                            AccessibilityLabelBridge(
                                identifier: "arrangement-panel-group-\(group.id.accessibilityKey)", label: group.title,
                                role: .group)
                        }
                        ForEach(group.panes) { pane in
                            Divider()
                            ArrangementPaneGroupRow(
                                pane: pane, octiconLoader: octiconLoader,
                                commandActionResolver: commandActionResolver,
                                isHighlighted: pane.id == highlightPaneId && highlightVisible)
                        }
                    }
                }
            }
        }
        .font(.system(size: AppStyles.Components.ArrangementPanel.detailFontSize))
        .frame(maxHeight: AppStyles.Components.ArrangementPanel.maximumRowsHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func groupReadout(_ text: String, fullPath: String? = nil) -> some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
            .controlHelp(
                LocalActionSpec.arrangementDataReadout(fullPath ?? text).actionSpec.controlTooltipRenderValue(
                    provenance: .localAction(rawValue: "arrangementGroup")))
    }
}

private struct ArrangementPaneGroupRow: View {
    let pane: PaneVisibilityInfo
    let octiconLoader: OcticonLoader
    let commandActionResolver: TargetedCommandControlActionResolver
    let isHighlighted: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: AppStyles.Components.ArrangementPanel.columnSpacing) {
            Circle()
                .fill(statusColor)
                .frame(
                    width: AppStyles.Components.ArrangementPanel.statusDotSize,
                    height: AppStyles.Components.ArrangementPanel.statusDotSize
                )
                .padding(.top, AppStyles.General.Spacing.tight)
                .accessibilityHidden(true)
            paneGlyph.padding(.top, AppStyles.General.Spacing.tight)
            VStack(alignment: .leading, spacing: AppStyles.Components.ArrangementPanel.rowDetailSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: AppStyles.General.Spacing.loose) {
                    readout(pane.title)
                        .font(.system(size: AppStyles.Components.ArrangementPanel.titleFontSize, weight: .semibold))
                    Spacer(minLength: 0)
                    if pane.isMinimized {
                        readout(LocalActionSpec.arrangementPaneHidden.actionSpec.label)
                            .foregroundStyle(.secondary)
                            .background {
                                AccessibilityLabelBridge(
                                    identifier: "arrangement-panel-pane-\(pane.id.uuidString)-hidden",
                                    label: LocalActionSpec.arrangementPaneHidden.actionSpec.label, role: .staticText)
                            }
                    } else if let line = pane.agentLine {
                        PaneAgentLineAge(line.ageText, identifier: "arrangement-panel-pane-\(pane.id.uuidString)-age")
                    }
                }
                if let provider = pane.providerName {
                    readout(
                        "\(provider) • \(ArrangementTableMetrics.statusText(pane.agentStatus))", tooltip: statusDetail
                    )
                    .foregroundStyle(.secondary)
                    .background {
                        AccessibilityLabelBridge(
                            identifier: "arrangement-panel-pane-\(pane.id.uuidString)-agent",
                            label: provider, role: .staticText,
                            value: ArrangementTableMetrics.statusText(pane.agentStatus))
                    }
                }
                if pane.section == .other {
                    readout(pane.cwdPath ?? LocalActionSpec.arrangementValueUnavailable.actionSpec.label)
                        .foregroundStyle(.secondary)
                        .background {
                            AccessibilityLabelBridge(
                                identifier: "arrangement-panel-pane-\(pane.id.uuidString)-cwd",
                                label: pane.cwdPath ?? LocalActionSpec.arrangementValueUnavailable.actionSpec.label,
                                role: .staticText)
                        }
                }
                if let detail = pane.paneNote ?? pane.agentLine?.summary {
                    readout(detail).foregroundStyle(.secondary)
                        .background {
                            AccessibilityLabelBridge(
                                identifier: "arrangement-panel-pane-\(pane.id.uuidString)-detail",
                                label: detail, role: .staticText)
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
                .frame(width: AppStyles.Components.ArrangementPanel.actionsWidth, alignment: .trailing)
                .padding(.top, AppStyles.General.Spacing.tight)
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
            if pane.paneIcon != .octicon(.gitBranch) {
                RoundedRectangle(cornerRadius: AppStyles.Components.ArrangementPanel.glyphCornerRadius)
                    .strokeBorder(.secondary, lineWidth: AppStyles.Components.ArrangementPanel.glyphStrokeWidth)
            }
        }
        .accessibilityHidden(true)
    }

    private func readout(_ text: String, tooltip: String? = nil) -> some View {
        let spec = LocalActionSpec.arrangementDataReadout(tooltip ?? text).actionSpec
        return Text(text).fixedSize(horizontal: false, vertical: true)
            .controlHelp(spec.controlTooltipRenderValue(provenance: .localAction(rawValue: "arrangementDataReadout")))
    }

    private var statusDetail: String {
        switch pane.agentStatus {
        case .agent(let line): line.detail
        case .unavailable: LocalActionSpec.arrangementValueUnavailable.actionSpec.helpText
        }
    }

    private var statusColor: Color {
        switch pane.agentStatus {
        case .unavailable: .secondary
        case .agent(let line):
            switch line.kind {
            case .working, .monitoring: PaneContextChipTone.accent.foregroundColor
            case .needsYou: AppStyles.Components.ArrangementPanel.needsYouColor
            case .failed: PaneContextChipTone.danger.foregroundColor
            case .idle: .secondary
            }
        }
    }

    private var actions: some View {
        HStack(spacing: AppStyles.General.Spacing.tight) {
            if pane.supportsZoom,
                let zoom = commandActionResolver(.zoomPane, .inlineControl, pane.id, .pane)
            {
                actionButton(zoom, suffix: "zoom")
            } else {
                actionButton(
                    .init(commandSpec: AppCommand.zoomPane.definition, isEnabled: false, perform: {}),
                    suffix: "zoom", display: pane.supportsZoom ? nil : .arrangementTerminalOnlyZoom)
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
