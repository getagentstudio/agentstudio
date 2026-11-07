import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import SwiftUI

/// The browser's tab picker, presented as a popover. It owns no chrome and no
/// key handling: `PopoverPanel` with `SidebarSearchField` as its header,
/// `PopoverPanelSectionHeader` sections, `PopoverCompoundOptionSurface` rows,
/// `ToolbarActionButton` close controls, and the selectable-popover keyboard
/// bridge while the search field keeps focus. Rows are prepared off the main
/// actor for the current request; a result for an older request is dropped.
struct WebviewTabPickerView: View {
    @Bindable var controller: WebviewPaneController
    let octiconLoader: OcticonLoader
    /// Prepares the rows for a request off the main actor. Tests pass a
    /// preparation they can hold; production uses `WebviewTabPickerContents.prepare`.
    let prepareContents: @Sendable (WebviewTabPickerRequest) async -> WebviewTabPickerContents

    init(
        controller: WebviewPaneController,
        octiconLoader: OcticonLoader,
        prepareContents: @escaping @Sendable (WebviewTabPickerRequest) async -> WebviewTabPickerContents =
            WebviewTabPickerContents.prepare
    ) {
        self.controller = controller
        self.octiconLoader = octiconLoader
        self.prepareContents = prepareContents
    }

    private enum PickerFocus: Hashable {
        case search
    }

    private typealias Style = AppStyles.WorkspaceFocus.Webview
    private typealias RowId = WebviewTabPickerContents.RowId

    private static let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
    private static let closeSpec = LocalActionSpec.browserCloseTab.actionSpec
    private static let closeTooltip = closeSpec.controlTooltipRenderValue(
        provenance: .localAction(rawValue: "browserCloseTab"))

    @State private var query = ""
    @State private var contents: WebviewTabPickerContents?
    @State private var highlightedRowId: RowId?
    @FocusState private var focus: PickerFocus?

    private var request: WebviewTabPickerRequest {
        WebviewTabPickerRequest(tabList: controller.tabList, query: query, homeDirectory: Self.homeDirectory)
    }

    private var transientSurfaceKind: TransientKeyboardSurfaceKind {
        .browserTabPicker(paneId: controller.paneId)
    }

    var body: some View {
        PopoverPanel(
            width: Style.tabPickerMaximumWidth,
            height: .contentSized(maximumHeight: Style.tabPickerMaximumHeight),
            openingContentIsReady: contents != nil
        ) {
            SidebarSearchField(
                placeholder: "Search Tabs",
                text: $query,
                focusedField: $focus,
                focusValue: PickerFocus.search,
                clearHelp: LocalActionSpec.clearFilter.actionSpec.helpText,
                shortcutDisplay: AppShortcut.showBrowserTabs.trigger.displayText,
                shortcutStyle: .secondaryText
            )
        } content: {
            if let contents {
                // Keeps the keyboard highlight in view as it moves past the visible rows.
                ScrollViewReader { scroller in
                    VStack(alignment: .leading, spacing: AppStyles.Components.PopoverPanel.sectionSpacing) {
                        sections(contents)
                    }
                    .onChange(of: highlightedRowId) { _, rowId in
                        guard let rowId else { return }
                        scroller.scrollTo(rowId)
                    }
                }
            }
        }
        .transientKeyboardSurface(transientSurfaceKind, workspaceWindowId: nil)
        .background(
            SelectablePopoverKeyboardBridge(
                items: contents?.keyboardItems ?? [],
                selectedItemId: highlightedRowId,
                auxiliaryAction: SelectablePopoverAuxiliaryAction(trigger: .commandDelete) { rowId in
                    if case .open(let tabId) = rowId { close(tabId) }
                },
                onSelect: choose,
                onHighlight: { highlightedRowId = $0 },
                onDismiss: dismiss,
                matchesAdditionalDismissShortcut: { event in
                    guard let trigger = ShortcutDecoder.decode(event: event) else { return false }
                    return TransientKeyboardSurfaceDismissRouter.shouldDismiss(
                        trigger: trigger, policy: transientSurfaceKind.defaultPolicy)
                },
                capturesFirstResponder: false
            )
            .frame(width: 0, height: 0)
        )
        .onAppear { focus = .search }
        .task(id: request) {
            let request = self.request
            let prepared = await prepareContents(request)
            // Apply only the result for the request still shown.
            guard !Task.isCancelled, prepared.request == self.request else { return }
            contents = prepared
            highlightedRowId = SelectablePopoverKeyboardRouter.defaultSelection(
                items: prepared.keyboardItems, preferredItemId: highlightedRowId)
        }
    }

    @ViewBuilder
    private func sections(_ contents: WebviewTabPickerContents) -> some View {
        if contents.showsNoMatches {
            Text("No matching tabs")
                .font(.system(size: AppStyles.General.Typography.textBase))
                .foregroundStyle(.secondary)
        }
        if !contents.openRows.isEmpty {
            section("Open Tabs", rows: contents.openRows)
        }
        if !contents.closedRows.isEmpty {
            section("Recently Closed", rows: contents.closedRows)
        }
    }

    private func section(_ title: String, rows: [WebviewTabPickerContents.Row]) -> some View {
        VStack(alignment: .leading, spacing: AppStyles.General.Spacing.tight) {
            PopoverPanelSectionHeader(title, variant: .content(count: nil))
            ForEach(rows) { row in
                pickerRow(row)
            }
        }
    }

    private func pickerRow(_ row: WebviewTabPickerContents.Row) -> some View {
        HStack(spacing: AppStyles.General.Spacing.loose) {
            Button {
                choose(row.id)
            } label: {
                HStack(spacing: AppStyles.General.Spacing.loose) {
                    CommandIcon.system(.globe)
                        .swiftUIImage(loader: octiconLoader, size: AppStyles.General.Icon.compact)
                        .foregroundStyle(.secondary)
                        .frame(width: Style.tabPickerRowIconFrame, height: Style.tabPickerRowIconFrame)
                        .background(
                            Color.white.opacity(AppStyles.General.Fill.muted),
                            in: RoundedRectangle(cornerRadius: AppStyles.General.CornerRadius.bar))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.title)
                            .font(.system(size: AppStyles.General.Typography.textBase))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(row.displayAddress)
                            .font(.system(size: AppStyles.General.Typography.textXs))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .controlHelp(row.addressTooltip)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            if let tabId = row.closesTab {
                ToolbarActionButton(
                    presentation: .init(
                        icon: Self.closeIcon, label: Self.closeSpec.label,
                        identifier: "browserTabPicker.close", tooltip: Self.closeTooltip, isEnabled: true),
                    octiconLoader: octiconLoader,
                    action: { close(tabId) })
            }
        }
        .modifier(PopoverCompoundOptionSurface(isSelected: row.isActive, isHighlighted: row.id == highlightedRowId))
        .id(row.id)
    }

    private static let closeIcon: ToolbarActionButtonPresentation.Icon = {
        switch closeSpec.icon {
        case .system(let symbol): .system(symbol.rawValue)
        case .octicon(let symbol): .octicon(symbol.rawValue)
        }
    }()

    private func choose(_ rowId: RowId) {
        switch rowId {
        case .open(let tabId):
            controller.selectTab(tabId)
        case .closed(let closedId):
            controller.reopenTab(closedId)
        }
        dismiss()
    }

    private func close(_ tabId: WebviewTabId) {
        controller.closeTab(tabId)
    }

    private func dismiss() {
        controller.isTabPickerPresented = false
    }
}
