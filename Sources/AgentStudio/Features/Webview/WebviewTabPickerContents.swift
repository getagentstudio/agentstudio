import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation

/// One search of the tab picker: the tabs it searches and the query. A new
/// request replaces the old one; a result for an old request is never shown.
package struct WebviewTabPickerRequest: Equatable, Sendable {
    package let tabList: WebviewTabList
    package let query: String
    /// The folder a local file's address shows as `~`.
    package let homeDirectory: String

    package init(tabList: WebviewTabList, query: String, homeDirectory: String) {
        self.tabList = tabList
        self.query = query
        self.homeDirectory = homeDirectory
    }
}

/// What the tab picker shows for one request, prepared off the main actor:
/// Open Tabs in tab order, then Recently Closed newest first, each filtered by
/// title or address, with every value the view reads already formatted.
package struct WebviewTabPickerContents: Equatable, Sendable {
    package enum RowId: Hashable, Sendable {
        case open(WebviewTabId)
        case closed(WebviewClosedTabId)
    }

    package struct Row: Equatable, Identifiable, Sendable {
        package let id: RowId
        /// The page title, or its address when the page has none.
        package let title: String
        /// The address as shown: a local file's path with the home folder as `~`, otherwise the URL.
        package let displayAddress: String
        /// The full address, for the row's tooltip.
        package let addressTooltip: ControlTooltipRenderValue
        package let isActive: Bool

        /// The open tab this row's close control closes; nil for a Recently Closed row.
        package var closesTab: WebviewTabId? {
            guard case .open(let tabId) = id else { return nil }
            return tabId
        }
    }

    package let request: WebviewTabPickerRequest
    package let openRows: [Row]
    package let closedRows: [Row]
    package let showsNoMatches: Bool
    /// Every row in display order; only open rows support the close action.
    package let keyboardItems: [SelectablePopoverKeyboardItem<RowId>]

    @concurrent
    package nonisolated static func prepare(_ request: WebviewTabPickerRequest) async -> Self {
        Self(request: request)
    }

    package nonisolated init(request: WebviewTabPickerRequest) {
        let needle = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let tabList = request.tabList
        let openRows = tabList.tabs.compactMap { tab in
            Self.row(
                id: .open(tab.id), url: tab.url, title: tab.title, isActive: tab.id == tabList.activeTabId,
                needle: needle, homeDirectory: request.homeDirectory)
        }
        let closedRows = tabList.closedTabs.compactMap { tab in
            Self.row(
                id: .closed(tab.id), url: tab.url, title: tab.title, isActive: false,
                needle: needle, homeDirectory: request.homeDirectory)
        }
        self.request = request
        self.openRows = openRows
        self.closedRows = closedRows
        showsNoMatches = openRows.isEmpty && closedRows.isEmpty
        keyboardItems = (openRows + closedRows).map { row in
            SelectablePopoverKeyboardItem(id: row.id, supportsAuxiliaryAction: row.closesTab != nil)
        }
    }

    /// The address a row shows: a local file's path with the home folder as
    /// `~`, otherwise the URL.
    package nonisolated static func displayAddress(_ url: URL, homeDirectory: String) -> String {
        guard url.isFileURL else { return url.absoluteString }
        let path = url.path(percentEncoded: false)
        guard !homeDirectory.isEmpty else { return path }
        if path == homeDirectory { return "~" }
        let homePrefix = homeDirectory.hasSuffix("/") ? homeDirectory : homeDirectory + "/"
        guard path.hasPrefix(homePrefix) else { return path }
        return "~/" + path.dropFirst(homePrefix.count)
    }

    private nonisolated static func row(
        id: RowId, url: URL, title: String, isActive: Bool, needle: String, homeDirectory: String
    ) -> Row? {
        let displayAddress = displayAddress(url, homeDirectory: homeDirectory)
        let fullAddress = url.isFileURL ? url.path(percentEncoded: false) : url.absoluteString
        if !needle.isEmpty,
            !title.localizedCaseInsensitiveContains(needle),
            !displayAddress.localizedCaseInsensitiveContains(needle),
            !fullAddress.localizedCaseInsensitiveContains(needle)
        {
            return nil
        }
        return Row(
            id: id, title: title.isEmpty ? displayAddress : title, displayAddress: displayAddress,
            addressTooltip: ControlTooltipResolver.resolve(
                .dynamicData(url.isFileURL ? .filesystemPath : .userDataLabel, text: fullAddress)),
            isActive: isActive)
    }
}
