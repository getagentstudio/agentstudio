import AgentStudioInfrastructure
import AgentStudioSharedComponents
import SwiftUI

// MARK: - TrapezoidConnector

/// Rectangle bridge that visually connects a pane to its drawer icon bar.
/// Full pane width — the panel-to-pane taper is handled by DrawerOverlayTrapezoid
/// at the tab level, so this connector stays at pane width to match pane borders.
struct TrapezoidConnector: Shape {
    func path(in rect: CGRect) -> Path {
        Path(rect)
    }
}

private enum DrawerTooltipTarget: Hashable {
    case toggle
    case add
    case pin
    case note
    case finder
    case copyPath
    case chooser
    case gitStatus
    case paneSurfaceStatusIndicator(String)
    case paneSurfaceAction(String)
}

// MARK: - DrawerIconBar

enum DrawerIconBarLeadingControls {
    case drawer(
        isExpanded: Bool,
        addDrawerPaneAction: TargetedCommandControlAction?,
        toggleDrawerAction: TargetedCommandControlAction?
    )
    case hidden
}

/// Icon bar at the bottom of a pane showing drawer controls.
/// Layout: [toggle] | [+]
///
/// Toggle uses `sidebar.bottom` (macOS convention for bottom panel toggle).
/// Follows the same callback-driven pattern as `ArrangementBar`.
struct DrawerIconBar: View {
    let octiconLoader: OcticonLoader
    let pinPaneAction: TargetedCommandControlAction?
    let leadingControls: DrawerIconBarLeadingControls
    let trailingActions: DrawerOverlay.TrailingActions?
    let paneSurfaceActions: [PaneSurfaceToolbarAction]
    let paneContextActions: [PaneSurfaceToolbarAction]

    @State private var isAddHovered = false
    @State private var isToggleHovered = false
    @State private var isPinHovered = false
    @State private var isNoteHovered = false
    @State private var isFinderHovered = false
    @State private var isCopyPathHovered = false
    @State private var isChooserHovered = false
    @State private var isGitStatusHovered = false
    @State private var hoveredPaneSurfaceStatusIndicatorId: String?
    @State private var hoveredPaneSurfaceActionId: String?
    @State private var tooltipFrames: [DrawerTooltipTarget: CGRect] = [:]

    init(
        octiconLoader: OcticonLoader,
        leadingControls: DrawerIconBarLeadingControls,
        pinPaneAction: TargetedCommandControlAction? = nil,
        trailingActions: DrawerOverlay.TrailingActions?,
        paneSurfaceActions: [PaneSurfaceToolbarAction] = [],
        paneContextActions: [PaneSurfaceToolbarAction] = []
    ) {
        self.octiconLoader = octiconLoader
        self.pinPaneAction = pinPaneAction
        self.leadingControls = leadingControls
        self.trailingActions = trailingActions
        self.paneSurfaceActions = paneSurfaceActions
        self.paneContextActions = paneContextActions
    }

    private static let tooltipCoordinateSpaceName = "drawerTooltipBar"

    private var isExpanded: Bool {
        guard case .drawer(let isExpanded, _, _) = leadingControls else {
            return false
        }
        return isExpanded
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: DrawerLayout.iconBarCornerRadius)
                        .fill(AppStyles.Shell.DrawerToolbar.background)

                    HStack(spacing: 0) {
                        if !paneSurfaceActions.isEmpty {
                            HStack(spacing: AppStyles.Shell.DrawerToolbar.trailingClusterSpacing) {
                                ForEach(Array(paneSurfaceActions.enumerated()), id: \.offset) { _, action in
                                    paneSurfaceActionButton(action)
                                }
                            }

                            if case .drawer = leadingControls {
                                drawerToolbarDivider
                            }
                        }

                        if case .drawer(
                            _,
                            let addDrawerPaneAction,
                            let toggleDrawerAction
                        ) = leadingControls,
                            addDrawerPaneAction != nil || toggleDrawerAction != nil
                        {
                            HStack(spacing: AppStyles.Shell.DrawerToolbar.trailingClusterSpacing) {
                                if let toggleDrawerAction {
                                    let toggleToolTip = toggleDrawerAction.commandSpec.controlTooltipRenderValue(
                                        textOverride: isExpanded ? "Collapse Drawer" : "Expand Drawer"
                                    )
                                    commandButton(
                                        toggleDrawerAction, identifier: "paneSurfaceToolbar.drawerToggle",
                                        tooltip: toggleToolTip, isSelected: isExpanded
                                    )
                                    .disabled(!toggleDrawerAction.isEnabled)
                                    .onHover { hovering in
                                        withAnimation(.easeInOut(duration: AppStyles.General.Animation.fast)) {
                                            isToggleHovered = hovering
                                        }
                                    }
                                    .hoverTooltipAnchor(
                                        DrawerTooltipTarget.toggle,
                                        in: Self.tooltipCoordinateSpaceName
                                    )
                                    .controlHelp(toggleToolTip)

                                }

                                if let addDrawerPaneAction {
                                    let addToolTip = addDrawerPaneAction.commandSpec.controlTooltipRenderValue()
                                    commandButton(
                                        addDrawerPaneAction, identifier: "paneSurfaceToolbar.drawerAdd",
                                        tooltip: addToolTip
                                    )
                                    .disabled(!addDrawerPaneAction.isEnabled)
                                    .onHover { hovering in
                                        withAnimation(.easeInOut(duration: AppStyles.General.Animation.fast)) {
                                            isAddHovered = hovering
                                        }
                                    }
                                    .hoverTooltipAnchor(
                                        DrawerTooltipTarget.add,
                                        in: Self.tooltipCoordinateSpaceName
                                    )
                                    .controlHelp(addToolTip)

                                }
                                if let pinPaneAction {
                                    commandButton(
                                        pinPaneAction, identifier: "paneSurfaceToolbar.pinPane",
                                        tooltip: pinPaneAction.commandSpec.controlTooltipRenderValue()
                                    )
                                    .disabled(!pinPaneAction.isEnabled)
                                    .onHover { isPinHovered = $0 }
                                    .hoverTooltipAnchor(DrawerTooltipTarget.pin, in: Self.tooltipCoordinateSpaceName)

                                }
                            }
                        }

                        if let trailingActions,
                            let editPaneNoteAction = trailingActions.editPaneNoteAction
                        {
                            drawerToolbarDivider
                            let noteToolTip = editPaneNoteAction.commandSpec.controlTooltipRenderValue()
                            let presentPaneNote: @MainActor @Sendable () -> Void = {
                                if trailingActions.notePopoverContent != nil {
                                    trailingActions.notePopoverPresented.wrappedValue = true
                                } else {
                                    editPaneNoteAction.perform()
                                }
                            }
                            commandButton(
                                editPaneNoteAction, identifier: "paneSurfaceToolbar.note", tooltip: noteToolTip,
                                perform: presentPaneNote
                            )
                            .disabled(!editPaneNoteAction.isEnabled)

                            .popover(
                                isPresented: trailingActions.notePopoverPresented,
                                arrowEdge: .bottom
                            ) {
                                trailingActions.notePopoverContent
                            }
                            .onHover { hovering in
                                withAnimation(.easeInOut(duration: AppStyles.General.Animation.fast)) {
                                    isNoteHovered = hovering
                                }
                            }
                            .hoverTooltipAnchor(
                                DrawerTooltipTarget.note,
                                in: Self.tooltipCoordinateSpaceName
                            )
                        }

                        Spacer()

                        if let trailingActions {
                            HStack(spacing: 0) {
                                HStack(spacing: 0) {
                                    if let gitStatusPresentation = trailingActions.gitStatusPresentation {
                                        paneSurfaceGitStatus(gitStatusPresentation)

                                        if trailingActions.pullRequestBlockerIndicator != nil
                                            || trailingActions.openPullRequestAction != nil
                                            || hasPrimaryTrailingActions(trailingActions)
                                            || !paneContextActions.isEmpty
                                        {
                                            trailingActionDivider
                                        }
                                    }

                                    if trailingActions.pullRequestBlockerIndicator != nil
                                        || trailingActions.openPullRequestAction != nil
                                    {
                                        HStack(spacing: AppStyles.Shell.DrawerToolbar.trailingClusterSpacing) {
                                            if let blockerIndicator =
                                                trailingActions.pullRequestBlockerIndicator
                                            {
                                                paneSurfaceStatusIndicator(blockerIndicator)
                                            }

                                            if let openPullRequestAction = trailingActions.openPullRequestAction {
                                                paneSurfaceActionButton(openPullRequestAction)
                                            }
                                        }

                                        if hasPrimaryTrailingActions(trailingActions)
                                            || !paneContextActions.isEmpty
                                        {
                                            trailingActionDivider
                                        }
                                    }

                                    if hasPrimaryTrailingActions(trailingActions) {
                                        HStack(spacing: AppStyles.Shell.DrawerToolbar.trailingClusterSpacing) {
                                            if let openEditorMenuAction = trailingActions.openEditorMenuAction {
                                                let chooserToolTip =
                                                    openEditorMenuAction.commandSpec.controlTooltipRenderValue(
                                                        textOverride: "Open in Editor"
                                                    )
                                                commandButton(
                                                    openEditorMenuAction, identifier: "paneSurfaceToolbar.editor",
                                                    tooltip: chooserToolTip,
                                                    content: .editorChooser(title: trailingActions.buttonTitle)
                                                )
                                                .popover(
                                                    isPresented: trailingActions.editorMenuPresented,
                                                    arrowEdge: .bottom
                                                ) {
                                                    trailingActions.editorMenuContent
                                                }
                                                .disabled(!openEditorMenuAction.isEnabled)
                                                .controlHelp(chooserToolTip)

                                                .onHover { hovering in
                                                    withAnimation(
                                                        .easeInOut(duration: AppStyles.General.Animation.fast)
                                                    ) {
                                                        isChooserHovered = hovering
                                                    }
                                                }
                                                .hoverTooltipAnchor(
                                                    DrawerTooltipTarget.chooser,
                                                    in: Self.tooltipCoordinateSpaceName
                                                )
                                            }

                                            if hasLocationActions(trailingActions) {
                                                if let openFinderAction = trailingActions.openFinderAction {
                                                    let finderToolTip =
                                                        openFinderAction.commandSpec.controlTooltipRenderValue(
                                                            textOverride: "Open in Finder"
                                                        )
                                                    commandButton(
                                                        openFinderAction, identifier: "paneSurfaceToolbar.finder",
                                                        tooltip: finderToolTip
                                                    )
                                                    .disabled(!openFinderAction.isEnabled)

                                                    .onHover { hovering in
                                                        withAnimation(
                                                            .easeInOut(duration: AppStyles.General.Animation.fast)
                                                        ) {
                                                            isFinderHovered = hovering
                                                        }
                                                    }
                                                    .hoverTooltipAnchor(
                                                        DrawerTooltipTarget.finder,
                                                        in: Self.tooltipCoordinateSpaceName
                                                    )
                                                }

                                                if let copyPathAction = trailingActions.copyPathAction {
                                                    let copyPathToolTip =
                                                        copyPathAction.commandSpec.controlTooltipRenderValue(
                                                            textOverride: "Copy Path"
                                                        )
                                                    commandButton(
                                                        copyPathAction, identifier: "paneSurfaceToolbar.copyPath",
                                                        tooltip: copyPathToolTip
                                                    )
                                                    .disabled(!copyPathAction.isEnabled)

                                                    .onHover { hovering in
                                                        withAnimation(
                                                            .easeInOut(duration: AppStyles.General.Animation.fast)
                                                        ) {
                                                            isCopyPathHovered = hovering
                                                        }
                                                    }
                                                    .hoverTooltipAnchor(
                                                        DrawerTooltipTarget.copyPath,
                                                        in: Self.tooltipCoordinateSpaceName
                                                    )
                                                }
                                            }
                                        }
                                    }

                                    if let paneContextContent = trailingActions.paneContextContent {
                                        paneContextContent
                                    }
                                    if !paneContextActions.isEmpty {
                                        if hasPrimaryTrailingActions(trailingActions) {
                                            trailingActionDivider
                                        }
                                        HStack(spacing: AppStyles.Shell.DrawerToolbar.trailingClusterSpacing) {
                                            ForEach(Array(paneContextActions.enumerated()), id: \.offset) { _, action in
                                                paneSurfaceActionButton(action)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(DrawerLayout.iconBarVerticalPadding)

                    FloatingHoverTooltipPresenter(
                        activeTarget: activeTooltipTarget,
                        anchorFrames: tooltipFrames,
                        availableWidth: geo.size.width,
                        tooltipValue: tooltipValue(for:)
                    )
                }
                .coordinateSpace(name: Self.tooltipCoordinateSpaceName)
                .onPreferenceChange(HoverTooltipAnchorPreferenceKey<DrawerTooltipTarget>.self) { tooltipFrames = $0 }
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: DrawerIconBarFrameKey.self,
                        value: geo.frame(in: .named("tabContainer"))
                    )
                }
            )
            .frame(height: DrawerLayout.iconButtonSize + (DrawerLayout.iconBarVerticalPadding * 2))
        }
    }

    private var trailingActionDivider: some View {
        drawerToolbarDivider
    }

    private var drawerToolbarDivider: some View {
        Divider()
            .frame(height: AppStyles.Shell.DrawerToolbar.dividerHeight)
            .padding(.horizontal, AppStyles.Shell.DrawerToolbar.dividerHorizontalPadding)
    }

    private var activeTooltipTarget: DrawerTooltipTarget? {
        if trailingActions?.editorMenuPresented.wrappedValue == true { return nil }
        if isToggleHovered { return .toggle }
        if isAddHovered { return .add }
        if isPinHovered { return .pin }
        if isNoteHovered { return .note }
        if isChooserHovered { return .chooser }
        if isFinderHovered { return .finder }
        if isCopyPathHovered { return .copyPath }
        if isGitStatusHovered { return .gitStatus }
        if let hoveredPaneSurfaceStatusIndicatorId {
            return .paneSurfaceStatusIndicator(hoveredPaneSurfaceStatusIndicatorId)
        }
        if let hoveredPaneSurfaceActionId {
            return .paneSurfaceAction(hoveredPaneSurfaceActionId)
        }
        return nil
    }

    private func hasPrimaryTrailingActions(
        _ trailingActions: DrawerOverlay.TrailingActions
    ) -> Bool {
        trailingActions.openEditorMenuAction != nil || hasLocationActions(trailingActions)
    }

    private func hasLocationActions(
        _ trailingActions: DrawerOverlay.TrailingActions
    ) -> Bool {
        trailingActions.openFinderAction != nil || trailingActions.copyPathAction != nil
    }

    private func tooltipValue(for target: DrawerTooltipTarget) -> ControlTooltipRenderValue? {
        switch target {
        case .toggle:
            guard
                case .drawer(_, _, let toggleDrawerAction) = leadingControls,
                let toggleDrawerAction
            else {
                return nil
            }
            return toggleDrawerAction.commandSpec.controlTooltipRenderValue(
                textOverride: isExpanded ? "Collapse Drawer" : "Expand Drawer"
            )
        case .add:
            guard
                case .drawer(_, let addDrawerPaneAction, _) = leadingControls,
                let addDrawerPaneAction
            else {
                return nil
            }
            return addDrawerPaneAction.commandSpec.controlTooltipRenderValue()
        case .pin:
            return pinPaneAction?.commandSpec.controlTooltipRenderValue()
        case .note:
            return trailingActions?.editPaneNoteAction?.commandSpec.controlTooltipRenderValue()
        case .finder:
            return trailingActions?.openFinderAction?.commandSpec.controlTooltipRenderValue(
                textOverride: "Open in Finder"
            )
        case .copyPath:
            return trailingActions?.copyPathAction?.commandSpec.controlTooltipRenderValue(
                textOverride: "Copy Path"
            )
        case .chooser:
            return trailingActions?.openEditorMenuAction?.commandSpec.controlTooltipRenderValue(
                textOverride: "Open in Editor"
            )
        case .gitStatus:
            guard let presentation = trailingActions?.gitStatusPresentation else { return nil }
            return ControlTooltipResolver.resolve(
                .dynamicData(.stateReadout, text: presentation.accessibilityLabel)
            )
        case .paneSurfaceStatusIndicator(let accessibilityIdentifier):
            guard
                let blockerIndicator = trailingActions?.pullRequestBlockerIndicator,
                blockerIndicator.accessibilityIdentifier == accessibilityIdentifier
            else {
                return nil
            }
            return blockerIndicator.tooltip
        case .paneSurfaceAction(let accessibilityIdentifier):
            var surfaceActions = paneSurfaceActions + paneContextActions
            if let openPullRequestAction = trailingActions?.openPullRequestAction {
                surfaceActions.append(openPullRequestAction)
            }
            return surfaceActions.first {
                $0.state.accessibilityIdentifier == accessibilityIdentifier
            }?.state.tooltip
        }
    }

    private func toolbarIcon(_ icon: CommandIcon) -> ToolbarActionButtonPresentation.Icon {
        switch icon {
        case .system(let symbol): .system(symbol.rawValue)
        case .octicon(let symbol): .octicon(symbol.rawValue)
        }
    }

    private func commandButton(
        _ command: TargetedCommandControlAction,
        identifier: String,
        tooltip: ControlTooltipRenderValue? = nil,
        isSelected: Bool = false,
        content: ToolbarActionButtonPresentation.Content = .icon(),
        perform: (@MainActor () -> Void)? = nil
    ) -> ToolbarActionButton {
        ToolbarActionButton(
            presentation: .init(
                icon: toolbarIcon(command.commandSpec.icon), label: command.commandSpec.label,
                identifier: identifier,
                tooltip: tooltip ?? command.commandSpec.controlTooltipRenderValue(),
                isEnabled: command.isEnabled, content: content,
                selection: isSelected ? .selected : .normal
            ),
            octiconLoader: octiconLoader, action: perform ?? command.perform
        )
    }

    private func paneSurfaceActionButton(_ action: PaneSurfaceToolbarAction) -> some View {
        let tone: ToolbarActionButtonPresentation.IconTone
        if let status = action.state.iconStatusTone {
            switch status {
            case .success: tone = .success
            case .warning: tone = .warning
            case .danger: tone = .danger
            }
        } else if let hex = action.state.iconAccentColorHex {
            tone = .repository(hex)
        } else {
            tone = .standard
        }
        return ToolbarActionButton(
            presentation: .init(
                icon: toolbarIcon(action.state.icon), label: action.state.label,
                identifier: action.state.accessibilityIdentifier, tooltip: action.state.tooltip,
                isEnabled: action.state.isEnabled, content: .icon(label: action.state.visibleLabel),
                selection: action.state.isSelected
                    ? (action.state.selectionEmphasis == .accent ? .accent : .selected) : .normal,
                iconTone: tone
            ),
            octiconLoader: octiconLoader, action: action.perform
        )
        .hoverTooltipAnchor(
            DrawerTooltipTarget.paneSurfaceAction(action.state.accessibilityIdentifier),
            in: Self.tooltipCoordinateSpaceName
        )
        .onHover { hovering in
            hoveredPaneSurfaceActionId = hovering ? action.state.accessibilityIdentifier : nil
        }
    }

    private func paneSurfaceStatusIndicator(
        _ indicator: PaneSurfaceToolbarStatusIndicator
    ) -> some View {
        paneSurfaceActionIcon(indicator.icon)
            .foregroundStyle(paneSurfaceStatusToneForeground(indicator.iconStatusTone))
            .frame(width: DrawerLayout.iconButtonSize, height: DrawerLayout.iconButtonSize)
            .contentShape(Rectangle())
            .hoverTooltipAnchor(
                DrawerTooltipTarget.paneSurfaceStatusIndicator(
                    indicator.accessibilityIdentifier
                ),
                in: Self.tooltipCoordinateSpaceName
            )
            .controlHelp(indicator.tooltip)
            .accessibilityHidden(true)
            .background {
                AccessibilityLabelBridge(
                    identifier: indicator.accessibilityIdentifier,
                    label: indicator.label,
                    help: indicator.tooltip.text
                )
            }
            .onHover { hovering in
                hoveredPaneSurfaceStatusIndicatorId =
                    hovering ? indicator.accessibilityIdentifier : nil
            }
    }

    private func paneSurfaceGitStatus(
        _ presentation: PaneSurfaceGitStatusPresentation
    ) -> some View {
        DrawerGitStatusIndicatorContent(
            presentation: presentation,
            octiconLoader: octiconLoader
        )
        .frame(height: DrawerLayout.iconButtonSize)
        .fixedSize(horizontal: true, vertical: true)
        .contentShape(Rectangle())
        .hoverTooltipAnchor(
            DrawerTooltipTarget.gitStatus,
            in: Self.tooltipCoordinateSpaceName
        )
        .controlHelp(
            ControlTooltipResolver.resolve(
                .dynamicData(.stateReadout, text: presentation.accessibilityLabel)
            )
        )
        .accessibilityHidden(true)
        .background {
            AccessibilityLabelBridge(
                identifier: "paneSurfaceToolbar.gitStatus",
                label: presentation.accessibilityLabel,
                help: presentation.accessibilityLabel
            )
        }
        .onHover { isGitStatusHovered = $0 }
    }

    private func paneSurfaceStatusToneForeground(
        _ iconStatusTone: PaneSurfaceToolbarAction.IconStatusTone
    ) -> Color {
        let color =
            switch iconStatusTone {
            case .success: AppStyles.Shell.Sidebar.chipSuccessColor
            case .warning: AppStyles.Shell.Sidebar.chipWarningColor
            case .danger: AppStyles.Shell.Sidebar.chipDangerColor
            }
        return color.opacity(AppStyles.Shell.Sidebar.chipForegroundOpacity)
    }

    @ViewBuilder
    private func paneSurfaceActionIcon(_ icon: CommandIcon) -> some View {
        switch icon {
        case .system(let symbol):
            Image(systemName: symbol.rawValue)
                .font(.system(size: AppStyles.General.Icon.compact, weight: .medium))
        case .octicon(let symbol):
            OcticonImage(
                name: symbol.rawValue,
                size: AppStyles.General.Icon.compact,
                loader: octiconLoader
            )
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct DrawerIconBar_Previews: PreviewProvider {
        static var previews: some View {
            VStack {
                Spacer()
                DrawerIconBar(
                    octiconLoader: OcticonLoader(
                        resourceRootURL: URL(fileURLWithPath: "/dev/null")
                    ),
                    leadingControls: .hidden,
                    trailingActions: nil
                )
                Spacer()
            }
            .frame(width: 400, height: 200)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
#endif
