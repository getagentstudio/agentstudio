import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import SwiftUI

enum RepoExplorerOrganizationSelector: Hashable {
    case sortField
    case grouping
}

extension RepoExplorerView {
    var sidebarSurfaceSelector: some View {
        let presentation = RepoExplorerToolbarCommandPresentation.resolve(snapshot: commandPresentationSnapshot)
        return SidebarEntityToggle(
            segments: [AppCommand.showReposSidebar, .showPanesSidebar].map { command in
                SidebarToolbarSegment(
                    value: command,
                    label: command.definition.label,
                    accessibilityIdentifier: "sidebarSurface.\(command.rawValue)",
                    tooltipValue: command.definition.controlTooltipRenderValue(
                        shortcutTextOverride: sidebarShortcutDisplay(for: command)
                    ),
                    isEnabled: presentation.command(command)?.isEnabled == true
                )
            },
            selection: repoExplorerPrefs.sidebarSurface == .repos ? .showReposSidebar : .showPanesSidebar,
            octiconLoader: octiconLoader,
            entityIcon: { $0 == .showReposSidebar ? .repo : .pane },
            shortcutDisplay: sidebarShortcutDisplay,
            onSelect: { command in commandDispatcher.dispatch(command) }
        )
        .accessibilityIdentifier("sidebarSurfaceSelector")
    }

    var repoToolbarRow: some View {
        let presentation = RepoExplorerToolbarCommandPresentation.resolve(snapshot: commandPresentationSnapshot)
        let isPanes = repoExplorerPrefs.sidebarSurface == .panes
        return HStack(spacing: AppStyles.General.Spacing.tight) {
            Spacer(minLength: 0)
            commandToggle(
                isPanes ? .togglePanesShowsPinned : .toggleReposShowsPinned,
                selected: repoExplorerPrefs.showsPinned, presentation: presentation
            )
            if isPanes {
                commandToggle(
                    .togglePanesShowsDrawers,
                    selected: repoExplorerPrefs.showsDrawerPanes,
                    presentation: presentation
                )
            }
            if !isPanes {
                SidebarToolbarDivider()
                sortDirectionButton(.toggleReposSortDirection, presentation: presentation)
                sortFieldSelector(
                    commands: [.setReposSortFieldName, .setReposSortFieldActivity],
                    presentation: presentation
                )
                SidebarToolbarDivider()
                groupingSelector(
                    commands: [.setReposGroupingRepo, .setReposGroupingActivity],
                    presentation: presentation
                )
            }
        }
        .accessibilityIdentifier("repoSidebarToolbarRow")
        .onChange(of: repoExplorerPrefs.sidebarSurface) { _, _ in openOrganizationSelector = nil }
    }

    private func sortFieldSelector(
        commands: [AppCommand],
        presentation: RepoExplorerToolbarCommandPresentation
    ) -> some View {
        let selected = commands[repoExplorerPrefs.sortField == .name ? 0 : 1]
        let options = commandOptions(commands, presentation: presentation)
        return SidebarToolbarPickerButton(
            label: selected.definition.helpText,
            selectionLabel: selected.definition.label,
            accessibilityIdentifier: "repoSidebarSortFieldButton",
            tooltipValue: selected.definition.controlTooltipRenderValue(),
            isOpen: openOrganizationSelector == .sortField,
            showsIcon: false,
            icon: { EmptyView() },
            action: { toggleOrganizationSelector(.sortField) }
        )
        .popover(isPresented: organizationSelectorBinding(.sortField), arrowEdge: .top) {
            SidebarPopoverReveal {
                let sortAction = LocalActionSpec.sortRepoExplorerItems.actionSpec
                PopoverPanel {
                    PopoverPanelSectionHeader(sortAction.label) {
                        sortAction.icon.swiftUIImage(loader: octiconLoader, size: AppStyles.General.Icon.compact)
                    }
                    SidebarGroupingPopover(
                        items: options.filter(\.isEnabled).map(\.value),
                        selectedItem: selected,
                        icon: { command in
                            command.definition.icon.swiftUIImage(
                                loader: octiconLoader, size: AppStyles.General.Icon.compact
                            )
                        },
                        label: { command in command.definition.label },
                        onSelect: { command in
                            guard presentation.command(command)?.isEnabled == true else { return }
                            commandDispatcher.dispatch(command)
                            openOrganizationSelector = nil
                        },
                        onDismiss: { openOrganizationSelector = nil }
                    )
                }

            }
        }
    }

    private func groupingSelector(
        commands: [AppCommand],
        presentation: RepoExplorerToolbarCommandPresentation
    ) -> some View {
        let organizationAction = LocalActionSpec.showRepoExplorerOrganization.actionSpec
        let groupingAction = LocalActionSpec.groupRepoExplorerWorktrees.actionSpec
        let subgroupAction = LocalActionSpec.subgroupRepoExplorerWorktrees.actionSpec
        return SidebarToolbarPickerButton(
            label: organizationAction.label,
            selectionLabel: groupingSelectionLabel,
            accessibilityIdentifier: "repoSidebarGroupingButton",
            tooltipValue: organizationAction.controlTooltipRenderValue(
                provenance: .localAction(rawValue: organizationAction.label)
            ),
            isOpen: openOrganizationSelector == .grouping,
            icon: {
                organizationAction.icon.swiftUIImage(
                    loader: octiconLoader, size: AppStyles.General.Icon.compact
                )
            },
            action: { toggleOrganizationSelector(.grouping) }
        )
        .popover(isPresented: organizationSelectorBinding(.grouping), arrowEdge: .top) {
            SidebarPopoverReveal {
                SidebarOrganizationPopover(
                    group: SidebarOrganizationPopoverSection(
                        title: groupingAction.label,
                        options: commandOptions(commands, presentation: presentation),
                        selection: groupingCommand
                    ),
                    subgroup: nil,
                    subgroupTitle: subgroupAction.label,
                    unavailableSubgroupText: LocalActionSpec.noRepoExplorerSubgroups.actionSpec.label,
                    unavailableSubgroupIcon: {
                        LocalActionSpec.noRepoExplorerSubgroups.actionSpec.icon.swiftUIImage(
                            loader: octiconLoader, size: AppStyles.General.Icon.compact
                        )
                    },
                    icon: { command in
                        command.definition.icon.swiftUIImage(
                            loader: octiconLoader, size: AppStyles.General.Icon.compact
                        )
                    },
                    headerIcon: { level in
                        let action = level == .group ? groupingAction : subgroupAction
                        action.icon.swiftUIImage(loader: octiconLoader, size: AppStyles.General.Icon.compact)
                    },
                    onSelect: { item in
                        guard presentation.command(item.value)?.isEnabled == true else { return }
                        commandDispatcher.dispatch(item.value)
                    },
                    onDismiss: { openOrganizationSelector = nil }
                )
            }
        }
    }

    private func commandOptions(
        _ commands: [AppCommand],
        presentation: RepoExplorerToolbarCommandPresentation
    ) -> [SidebarToolbarSegment<AppCommand>] {
        commands.map { command in
            SidebarToolbarSegment(
                value: command,
                label: command.definition.label,
                accessibilityIdentifier: controlAccessibilityIdentifier(command),
                tooltipValue: command.definition.controlTooltipRenderValue(),
                isEnabled: presentation.command(command)?.isEnabled == true
            )
        }
    }

    private var groupingCommand: AppCommand {
        repoExplorerPrefs.groupingMode == .activity ? .setReposGroupingActivity : .setReposGroupingRepo
    }

    private var groupingSelectionLabel: String {
        groupingCommand.definition.label
    }

    private func organizationSelectorBinding(
        _ selector: RepoExplorerOrganizationSelector
    ) -> Binding<Bool> {
        Binding(
            get: { openOrganizationSelector == selector },
            set: { setOrganizationSelector($0 ? selector : nil) }
        )
    }

    private func toggleOrganizationSelector(_ selector: RepoExplorerOrganizationSelector) {
        setOrganizationSelector(openOrganizationSelector == selector ? nil : selector)
    }

    private func setOrganizationSelector(_ selector: RepoExplorerOrganizationSelector?) {
        let isOpeningSelector = openOrganizationSelector == nil && selector != nil
        openOrganizationSelector = selector
        if isOpeningSelector {
            onPreviewEligibilityLoss()
        }
    }

    private func controlAccessibilityIdentifier(_ command: AppCommand) -> String {
        switch command {
        case .setReposGroupingRepo: "repoSidebarGroupingSegment.repo"
        case .setReposGroupingActivity: "repoSidebarGroupingSegment.activity"
        default: "sidebarOrganization.\(command.rawValue)"
        }
    }

    @ViewBuilder
    private func sortDirectionButton(
        _ command: AppCommand, presentation: RepoExplorerToolbarCommandPresentation
    ) -> some View {
        if let sortCommand = presentation.command(command) {
            SidebarToolbarSortButton(
                sortValue: repoExplorerPrefs.sortDirection,
                isReversed: repoExplorerPrefs.sortDirection == .descending,
                label: sortCommand.commandSpec.label,
                accessibilityIdentifier: "repoSidebarSortButton",
                tooltipValue: sortCommand.commandSpec.controlTooltipRenderValue(
                    textOverride: "Sort \(repoExplorerPrefs.sortDirection.title.lowercased())"
                ),
                icon: {
                    sortCommand.commandSpec.icon.swiftUIImage(
                        loader: octiconLoader, size: AppStyles.General.Icon.compact
                    )
                },
                onToggle: { commandDispatcher.dispatch(command) }
            )
            .id("repoSidebarSortButton.stable")
            .disabled(!sortCommand.isEnabled)
        }
    }

    @ViewBuilder
    private func commandToggle(
        _ command: AppCommand, selected: Bool, presentation: RepoExplorerToolbarCommandPresentation
    ) -> some View {
        if let presented = presentation.command(command) {
            SidebarToolbarActionButton(
                label: presented.commandSpec.label,
                accessibilityIdentifier: "sidebarOrganization.\(command.rawValue)",
                tooltipValue: presented.commandSpec.controlTooltipRenderValue(
                    shortcutTextOverride: sidebarShortcutDisplay(for: command)
                ),
                icon: {
                    presented.commandSpec.icon.swiftUIImage(
                        loader: octiconLoader, size: AppStyles.General.Icon.compact
                    )
                },
                isActive: selected,
                showsActiveBackground: false,
                action: { commandDispatcher.dispatch(command) }
            )
            .sidebarShortcutHint(
                sidebarShortcutDisplay(for: command),
                style: .toolbarStamp,
                alignment: .bottomTrailing,
                offset: CGSize(
                    width: -AppStyles.Shell.Sidebar.KeyboardHint.controlTrailingInset,
                    height: AppStyles.Shell.Sidebar.KeyboardHint.toggleVerticalOffset
                )
            )
            .disabled(!presented.isEnabled)
        }
    }
}
