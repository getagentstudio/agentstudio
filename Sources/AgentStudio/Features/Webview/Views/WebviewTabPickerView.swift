import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import SwiftUI

/// The browser's tab picker: a search field, Open Tabs in tab order and
/// Recently Closed newest first. Fully keyboard driven: type to filter,
/// Return opens the highlighted row, Down moves into the list, Up and Down
/// move the highlight, Command-Delete closes the highlighted open tab, and
/// Escape dismisses.
struct WebviewTabPickerView: View {
    @Bindable var controller: WebviewPaneController
    @State private var query = ""
    @State private var highlightedRowId: WebviewTabPickerContents.RowId?
    @FocusState private var focus: PickerFocus?

    private enum PickerFocus: Hashable {
        case search
        case list
    }

    private typealias Style = AppStyles.WorkspaceFocus.Webview

    private var contents: WebviewTabPickerContents {
        WebviewTabPickerContents(tabList: controller.tabList, query: query)
    }

    var body: some View {
        let contents = self.contents
        VStack(alignment: .leading, spacing: 0) {
            SidebarSearchField(
                placeholder: "Search Tabs",
                text: $query,
                focusedField: $focus,
                focusValue: PickerFocus.search,
                shortcutDisplay: AppShortcut.showBrowserTabs.trigger.displayText,
                onSubmit: { choose(contents.retainedRowId(highlightedRowId)) },
                onExit: dismiss,
                onDownArrow: {
                    highlightedRowId = contents.retainedRowId(highlightedRowId)
                    focus = .list
                    return .handled
                }
            )
            .padding(Style.tabPickerSectionPadding)

            Divider()

            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        section("Open Tabs", isEmpty: contents.openRows.isEmpty) {
                            ForEach(contents.openRows) { row in
                                pickerRow(
                                    id: row.id, title: row.tab.title, url: row.tab.url,
                                    isActive: row.isActive, closesTab: row.tab.id
                                )
                            }
                        }
                        if !contents.closedRows.isEmpty {
                            section("Recently Closed", isEmpty: false) {
                                ForEach(contents.closedRows) { row in
                                    pickerRow(
                                        id: row.id, title: row.tab.title, url: row.tab.url,
                                        isActive: false, closesTab: nil
                                    )
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: Style.tabPickerMaximumListHeight)
                .onChange(of: highlightedRowId) { _, rowId in
                    guard let rowId else { return }
                    scroller.scrollTo(rowId)
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focus, equals: .list)
            .onKeyPress(.upArrow) {
                let moved = contents.rowId(movedBy: -1, from: highlightedRowId)
                if moved == highlightedRowId || highlightedRowId == nil {
                    focus = .search
                } else {
                    highlightedRowId = moved
                }
                return .handled
            }
            .onKeyPress(.downArrow) {
                highlightedRowId = contents.rowId(movedBy: 1, from: highlightedRowId)
                return .handled
            }
            .onKeyPress(.return) {
                choose(contents.retainedRowId(highlightedRowId))
                return .handled
            }
            .onKeyPress(.escape) {
                dismiss()
                return .handled
            }
            .onKeyPress(keys: [.delete], phases: .down) { press in
                guard press.modifiers.contains(.command),
                    case .open(let tabId) = highlightedRowId
                else { return .ignored }
                close(tabId, contents: contents)
                return .handled
            }
        }
        .frame(maxWidth: Style.tabPickerMaximumWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppStyles.General.CornerRadius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: AppStyles.General.CornerRadius.panel)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .shadow(radius: AppStyles.General.CornerRadius.panel)
        .padding(Style.tabPickerEdgeInset)
        .onAppear {
            highlightedRowId = contents.firstRowId
            focus = .search
        }
        .onChange(of: query) { _, _ in
            highlightedRowId = self.contents.firstRowId
        }
    }

    @ViewBuilder
    private func section(
        _ title: String, isEmpty: Bool, @ViewBuilder rows: () -> some View
    ) -> some View {
        PopoverPanelSectionHeader(title)
            .padding(.horizontal, Style.tabPickerSectionPadding)
            .padding(.top, Style.tabPickerSectionPadding)
            .padding(.bottom, AppStyles.General.Spacing.tight)
        if isEmpty {
            Text("No matching tabs")
                .font(.system(size: AppStyles.General.Typography.textSm))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Style.tabPickerSectionPadding)
                .padding(.vertical, AppStyles.General.Spacing.standard)
        } else {
            rows()
        }
    }

    private func pickerRow(
        id: WebviewTabPickerContents.RowId, title: String, url: URL, isActive: Bool, closesTab: WebviewTabId?
    ) -> some View {
        let isHighlighted = id == highlightedRowId
        let closeSpec = LocalActionSpec.browserCloseTab.actionSpec
        return HStack(spacing: AppStyles.General.Spacing.loose) {
            Self.systemImage(.system(.globe))
                .foregroundStyle(.secondary)
                .frame(width: Style.tabPickerRowIconFrame, height: Style.tabPickerRowIconFrame)
                .background(
                    Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: AppStyles.General.CornerRadius.bar)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(title.isEmpty ? WebviewTabPickerContents.displayAddress(url) : title)
                    .font(.system(size: AppStyles.General.Typography.textBase, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(WebviewTabPickerContents.displayAddress(url))
                    .font(.system(size: AppStyles.General.Typography.textXs))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let closesTab {
                Button {
                    close(closesTab, contents: contents)
                } label: {
                    Self.systemImage(closeSpec.icon)
                        .font(.system(size: AppStyles.General.Typography.textSm, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(closeSpec.label)
                .help(closeSpec.helpText)
                .opacity(isHighlighted ? 1 : 0.55)
            }
        }
        .padding(.vertical, Style.tabPickerRowVerticalPadding)
        .padding(.horizontal, Style.tabPickerRowHorizontalPadding)
        .background(isHighlighted ? Color.primary.opacity(0.09) : .clear)
        .contentShape(Rectangle())
        .id(id)
        .onTapGesture { choose(id) }
        .onHover { hovering in
            if hovering { highlightedRowId = id }
        }
    }

    private func choose(_ rowId: WebviewTabPickerContents.RowId?) {
        switch rowId {
        case .open(let tabId):
            controller.selectTab(tabId)
        case .closed(let closedId):
            controller.reopenTab(closedId)
        case nil:
            return
        }
        dismiss()
    }

    private func close(_ tabId: WebviewTabId, contents: WebviewTabPickerContents) {
        let next = contents.rowId(movedBy: 1, from: .open(tabId))
        controller.closeTab(tabId)
        highlightedRowId = self.contents.retainedRowId(next == .open(tabId) ? nil : next)
    }

    private func dismiss() {
        controller.isTabPickerPresented = false
    }

    /// Browser chrome uses SF Symbol command icons only.
    static func systemImage(_ icon: CommandIcon) -> Image {
        guard case .system(let symbol) = icon else { return Image(systemName: "questionmark") }
        return Image(systemName: symbol.rawValue)
    }
}
