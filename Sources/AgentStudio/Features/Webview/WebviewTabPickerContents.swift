import Foundation

/// What the tab picker shows for one search: Open Tabs in tab order, then
/// Recently Closed newest first, each filtered by title or address.
package struct WebviewTabPickerContents: Equatable {
    package enum RowId: Hashable, Sendable {
        case open(WebviewTabId)
        case closed(WebviewClosedTabId)
    }

    package struct OpenRow: Equatable, Identifiable {
        package let tab: WebviewTab
        package let isActive: Bool
        package var id: RowId { .open(tab.id) }
    }

    package struct ClosedRow: Equatable, Identifiable {
        package let tab: WebviewClosedTab
        package var id: RowId { .closed(tab.id) }
    }

    package let openRows: [OpenRow]
    package let closedRows: [ClosedRow]

    package init(tabList: WebviewTabList, query: String) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        openRows = tabList.tabs
            .filter { Self.matches(title: $0.title, url: $0.url, needle: needle) }
            .map { OpenRow(tab: $0, isActive: $0.id == tabList.activeTabId) }
        closedRows = tabList.closedTabs
            .filter { Self.matches(title: $0.title, url: $0.url, needle: needle) }
            .map { ClosedRow(tab: $0) }
    }

    /// Every row in display order, for keyboard movement.
    package var rowIds: [RowId] {
        openRows.map(\.id) + closedRows.map(\.id)
    }

    /// The row a fresh search highlights: the first row shown.
    package var firstRowId: RowId? { rowIds.first }

    /// The row `delta` steps from `rowId`, clamped to the ends. A highlight no
    /// longer shown moves to the first row.
    package func rowId(movedBy delta: Int, from rowId: RowId?) -> RowId? {
        let ids = rowIds
        guard !ids.isEmpty else { return nil }
        guard let rowId, let index = ids.firstIndex(of: rowId) else { return ids.first }
        return ids[min(max(index + delta, 0), ids.count - 1)]
    }

    /// The highlight to keep after the rows change: the same row while it is
    /// still shown, otherwise the first row.
    package func retainedRowId(_ rowId: RowId?) -> RowId? {
        guard let rowId, rowIds.contains(rowId) else { return firstRowId }
        return rowId
    }

    /// The address a row shows: a file path for local files, otherwise the URL.
    package static func displayAddress(_ url: URL) -> String {
        url.isFileURL ? url.path(percentEncoded: false) : url.absoluteString
    }

    private static func matches(title: String, url: URL, needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(needle)
            || displayAddress(url).localizedCaseInsensitiveContains(needle)
    }
}
