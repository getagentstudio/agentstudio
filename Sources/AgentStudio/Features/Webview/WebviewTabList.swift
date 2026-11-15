import AgentStudioInfrastructure
import Foundation

/// Identity of one open browser tab inside a browser pane.
package struct WebviewTabId: Hashable, Sendable {
    package let rawValue: UUID

    package init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    package static func generate() -> Self {
        Self(rawValue: UUIDv7.generate())
    }
}

/// Identity of one entry in a browser pane's Recently Closed list.
package struct WebviewClosedTabId: Hashable, Sendable {
    package let rawValue: UUID

    package static func generate() -> Self {
        Self(rawValue: UUIDv7.generate())
    }
}

/// One open browser tab: the page it currently shows, by committed address.
package struct WebviewTab: Equatable, Identifiable, Sendable {
    package let id: WebviewTabId
    package fileprivate(set) var url: URL
    package fileprivate(set) var title: String

    package init(id: WebviewTabId, url: URL, title: String) {
        self.id = id
        self.url = url
        self.title = title
    }

    package var address: BrowserPageAddress { BrowserPageAddress(url: url) }
}

/// A tab closed during this app run, kept so the person can reopen it.
package struct WebviewClosedTab: Equatable, Identifiable, Sendable {
    package let id: WebviewClosedTabId
    package let url: URL
    package let title: String
}

package enum WebviewTabOpenResult: Equatable, Sendable {
    /// A new tab was appended and made active.
    case added(WebviewTabId)
    /// An open tab already showed the page; it was made active in place.
    case reused(WebviewTabId)

    package var tabId: WebviewTabId {
        switch self {
        case .added(let id), .reused(let id): id
        }
    }
}

package enum WebviewTabCloseResult: Equatable, Sendable {
    /// The tab moved to Recently Closed; `activeTabId` is the tab active afterwards.
    case closed(activeTabId: WebviewTabId)
    /// The tab is the only one. It stays in the list and the browser pane must close.
    case closedLast
    /// No open tab has that id.
    case notOpen
}

/// The ordered tabs of one browser pane, with exactly one active tab.
///
/// Pure tab rules, no WebKit. Order is the array order: a new or reopened tab
/// goes last, a reused open keeps its place, and closing removes the gap.
/// Recently Closed is newest first. The active id always names an open tab:
/// every initializer and mutation keeps that true.
package struct WebviewTabList: Equatable, Sendable {
    package private(set) var tabs: [WebviewTab]
    package private(set) var activeTabId: WebviewTabId
    package private(set) var closedTabs: [WebviewClosedTab] = []

    package init(firstTab: WebviewTab) {
        self.tabs = [firstTab]
        self.activeTabId = firstTab.id
    }

    /// Restores saved tabs. Returns nil when there are no tabs or the active
    /// id names none of them.
    package init?(restoring tabs: [WebviewTab], activeTabId: WebviewTabId) {
        guard tabs.contains(where: { $0.id == activeTabId }) else { return nil }
        self.tabs = tabs
        self.activeTabId = activeTabId
    }

    package var activeTab: WebviewTab {
        guard let tab = tabs.first(where: { $0.id == activeTabId }) else {
            preconditionFailure("WebviewTabList active id names no open tab")
        }
        return tab
    }

    package func tab(_ id: WebviewTabId) -> WebviewTab? {
        tabs.first { $0.id == id }
    }

    /// Makes the first tab showing `page` active, or appends a new active tab.
    package mutating func open(
        _ page: BrowserPageAddress,
        title: String,
        newTabId: WebviewTabId = .generate()
    ) -> WebviewTabOpenResult {
        if let existing = tabs.first(where: { $0.address == page }) {
            activeTabId = existing.id
            return .reused(existing.id)
        }
        tabs.append(WebviewTab(id: newTabId, url: page.url, title: title))
        activeTabId = newTabId
        return .added(newTabId)
    }

    @discardableResult
    package mutating func select(_ id: WebviewTabId) -> Bool {
        guard tabs.contains(where: { $0.id == id }) else { return false }
        activeTabId = id
        return true
    }

    /// Closes a tab into Recently Closed. Closing the active tab activates the
    /// next tab, or the previous one when it was last.
    package mutating func close(_ id: WebviewTabId) -> WebviewTabCloseResult {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return .notOpen }
        guard tabs.count > 1 else { return .closedLast }
        let closing = tabs.remove(at: index)
        closedTabs.insert(
            WebviewClosedTab(id: .generate(), url: closing.url, title: closing.title),
            at: 0
        )
        if closing.id == activeTabId {
            activeTabId = tabs[min(index, tabs.count - 1)].id
        }
        return .closed(activeTabId: activeTabId)
    }

    /// Reopens a closed tab as a new active tab at the end.
    package mutating func reopen(
        _ id: WebviewClosedTabId,
        newTabId: WebviewTabId = .generate()
    ) -> WebviewTabId? {
        guard let index = closedTabs.firstIndex(where: { $0.id == id }) else { return nil }
        let closed = closedTabs.remove(at: index)
        tabs.append(WebviewTab(id: newTabId, url: closed.url, title: closed.title))
        activeTabId = newTabId
        return newTabId
    }

    /// Records a committed navigation of one tab, active or not.
    package mutating func update(_ id: WebviewTabId, url: URL, title: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].url = url
        tabs[index].title = title
    }
}
