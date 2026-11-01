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
            VStack(alignment: .leading, spacing: AppStyles.General.Spacing.loose) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: AppStyles.Components.ArrangementPanel.rowSpacing) {
                        HStack(spacing: AppStyles.General.Spacing.standard) {
                            if let icon = group.icon {
                                icon.swiftUIImage(
                                    loader: octiconLoader, size: AppStyles.Components.ArrangementPanel.glyphSize
                                )
                                .frame(
                                    width: AppStyles.Components.ArrangementPanel.glyphSize,
                                    height: AppStyles.Components.ArrangementPanel.glyphSize
                                )
                                .background {
                                    AccessibilityLabelBridge(
                                        identifier: "arrangement-panel-group-\(group.id.accessibilityKey)-icon",
                                        label: group.title, role: .staticText)
                                }
                            }
                            Text(group.title).lineLimit(1).truncationMode(.tail)
                                .font(
                                    .system(
                                        size: AppStyles.Components.ArrangementPanel.titleFontSize, weight: .semibold))
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, AppStyles.General.Spacing.standard)
                        .controlHelp(
                            LocalActionSpec.arrangementDataReadout(group.title).actionSpec
                                .controlTooltipRenderValue(provenance: .localAction(rawValue: "arrangementGroup"))
                        )
                        .background {
                            AccessibilityLabelBridge(
                                identifier: "arrangement-panel-group-\(group.id.accessibilityKey)", label: group.title,
                                role: .group)
                        }
                        ForEach(group.panes) { pane in
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
}

struct ArrangementPaneGroupRow: View {
    let pane: PaneVisibilityInfo
    let octiconLoader: OcticonLoader
    let commandActionResolver: TargetedCommandControlActionResolver
    let isHighlighted: Bool

    var body: some View {
        HStack(
            alignment: .arrangementTitleFirstLineCenter,
            spacing: AppStyles.Components.ArrangementPanel.columnSpacing
        ) {
            statusGlyph.background {
                AccessibilityLabelBridge(
                    identifier: "arrangement-panel-pane-\(pane.id)-status-glyph",
                    label: statusDetail, role: .staticText)
            }.accessibilityHidden(true)
            paneGlyph
            VStack(alignment: .leading, spacing: AppStyles.Components.ArrangementPanel.rowDetailSpacing) {
                HStack(alignment: .arrangementTitleFirstLineCenter, spacing: AppStyles.General.Spacing.standard) {
                    readout(pane.title)
                        .font(.system(size: AppStyles.Components.ArrangementPanel.titleFontSize))
                        .foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
                        .background {
                            AccessibilityLabelBridge(
                                identifier: "arrangement-panel-pane-\(pane.id)-title", label: pane.title,
                                role: .staticText)
                        }
                        .alignmentGuide(.arrangementTitleFirstLineCenter) { dimensions in dimensions.height / 2 }
                    if let branch = pane.branchName {
                        readout(branch).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                            .background {
                                AccessibilityLabelBridge(
                                    identifier: "arrangement-panel-pane-\(pane.id)-branch", label: branch,
                                    role: .staticText)
                            }
                    }
                    Spacer(minLength: 0)
                }
                if let provider = pane.providerName {
                    HStack(spacing: 0) {
                        Text(provider + " · ").foregroundStyle(.secondary)
                        Text(ArrangementTableMetrics.statusText(pane.agentStatus)).foregroundStyle(statusColor)
                        Spacer(minLength: AppStyles.General.Spacing.standard)
                        HStack(spacing: AppStyles.Shell.Sidebar.chipRowSpacing) {
                            ForEach(pane.messageChips, id: \.model.kind) { chip in
                                PaneMessageKindChip.label(
                                    model: chip.model, control: chip.control, octiconLoader: octiconLoader
                                )
                                .controlHelp(chip.control.tooltip)
                                .accessibilityHidden(true)
                                .background {
                                    AccessibilityLabelBridge(
                                        identifier: "arrangement-panel-pane-\(pane.id)-messages-\(chip.model.kind)",
                                        label: chip.control.label, role: .staticText)
                                }
                            }
                        }
                    }
                    .lineLimit(1)
                    .controlHelp(
                        LocalActionSpec.arrangementDataReadout(statusDetail).actionSpec.controlTooltipRenderValue(
                            provenance: .localAction(rawValue: "arrangementDataReadout"))
                    )
                    .background {
                        AccessibilityLabelBridge(
                            identifier: "arrangement-panel-pane-\(pane.id)-agent", label: provider, role: .staticText,
                            value: ArrangementTableMetrics.statusText(pane.agentStatus))
                    }
                }
                detailLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions.frame(width: AppStyles.Components.ArrangementPanel.actionsWidth, alignment: .trailing)
        }
        .font(.system(size: AppStyles.Components.ArrangementPanel.detailFontSize))
        .padding(.horizontal, AppStyles.Components.ArrangementPanel.rowHorizontalPadding)
        .padding(.vertical, AppStyles.Components.ArrangementPanel.rowVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: AppStyles.General.CornerRadius.button)
                .fill(
                    isHighlighted
                        ? AppStyles.General.Accent.primaryColor.opacity(AppStyles.General.Fill.selected)
                        : Color.white.opacity(AppStyles.General.Fill.subtle))
        )
        .opacity(pane.isMinimized ? AppStyles.General.Foreground.dim : 1)
    }

    @ViewBuilder private var detailLine: some View {
        switch pane.detailLine {
        case .agentLine(let line):
            PaneAgentLineText(Text(line.summary), ageText: line.ageText)
                .lineLimit(1).truncationMode(.tail)
                .foregroundStyle(.secondary)
                .controlHelp(
                    LocalActionSpec.arrangementDataReadout(line.accessibilityText).actionSpec.controlTooltipRenderValue(
                        provenance: .localAction(rawValue: "arrangementDataReadout"))
                )
                .background {
                    AccessibilityLabelBridge(
                        identifier: "arrangement-panel-pane-\(pane.id)-detail", label: line.accessibilityText,
                        role: .staticText)
                }
        case .note(let text):
            readout(text).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                .background {
                    AccessibilityLabelBridge(
                        identifier: "arrangement-panel-pane-\(pane.id)-detail", label: text, role: .staticText)
                }
        case nil: EmptyView()
        }
    }

    private var paneGlyph: some View {
        Group {
            if pane.paneIcon == .system(.terminal) {
                Text(LocalActionSpec.arrangementTerminalPrompt.actionSpec.label)
                    .font(
                        .system(
                            size: AppStyles.Components.ArrangementPanel.terminalPromptFontSize,
                            weight: .medium, design: .monospaced)
                    ).fixedSize()
            } else {
                pane.paneIcon.swiftUIImage(
                    loader: octiconLoader,
                    size: pane.paneIcon == .octicon(.gitWorktree)
                        ? AppStyles.Components.ArrangementPanel.worktreeGlyphSize
                        : AppStyles.Components.ArrangementPanel.glyphSize)
            }
        }
        .foregroundStyle(.secondary)
        .frame(
            width: AppStyles.Components.ArrangementPanel.kindGlyphFrameSize,
            height: AppStyles.Components.ArrangementPanel.kindGlyphFrameSize
        )
        .background {
            AccessibilityLabelBridge(
                identifier: "arrangement-panel-pane-\(pane.id)-kind-glyph", label: pane.title, role: .staticText)
        }
        .accessibilityHidden(true)
    }

    var statusGlyph: some View {
        let icon: CommandIcon
        if case .agent(let status) = pane.agentStatus {
            icon = status.icon
        } else {
            icon = LocalActionSpec.arrangementPaneStatusMark(nil).actionSpec.icon
        }
        return icon.swiftUIImage(loader: octiconLoader, size: AppStyles.Components.ArrangementPanel.statusDotSize)
            .foregroundStyle(statusColor)
            .frame(
                width: AppStyles.Components.ArrangementPanel.statusDotSize,
                height: AppStyles.Components.ArrangementPanel.statusDotSize)
    }

    private func readout(_ text: String) -> some View {
        Text(text).controlHelp(
            LocalActionSpec.arrangementDataReadout(text).actionSpec.controlTooltipRenderValue(
                provenance: .localAction(rawValue: "arrangementDataReadout")))
    }

    private var statusDetail: String {
        switch pane.agentStatus {
        case .agent(let status): status.detail
        case .unavailable: LocalActionSpec.arrangementValueUnavailable.actionSpec.helpText
        }
    }

    private var statusColor: Color {
        switch pane.agentStatus {
        case .unavailable: .secondary
        case .agent(let status):
            switch status.kind {
            case .working, .monitoring: PaneContextChipTone.accent.foregroundColor
            case .needsYou: PaneContextChipTone.warning.foregroundColor
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

private enum ArrangementTitleFirstLineCenter: AlignmentID {
    nonisolated static func defaultValue(in dimensions: ViewDimensions) -> CGFloat {
        dimensions[VerticalAlignment.center]
    }
}

extension VerticalAlignment {
    fileprivate static let arrangementTitleFirstLineCenter = VerticalAlignment(ArrangementTitleFirstLineCenter.self)
}
