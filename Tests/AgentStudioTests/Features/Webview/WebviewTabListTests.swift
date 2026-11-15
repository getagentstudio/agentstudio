import Foundation
import Testing

@testable import AgentStudioWebview

/// Tab rules from the drawer browser Specification: R5, R8, R10, R12, R20,
/// R30, R31, and same-link identity (E1). Expected values come from those
/// obligations, not from the implementation.
@Suite
struct WebviewTabListTests {
    private static func url(_ string: String) -> URL { URL(string: string)! }

    private static func listWith(_ addresses: [String]) -> WebviewTabList {
        var list = WebviewTabList(
            firstTab: WebviewTab(id: .generate(), url: url(addresses[0]), title: addresses[0])
        )
        for address in addresses.dropFirst() {
            _ = list.open(BrowserPageAddress(url: url(address)), title: address)
        }
        return list
    }

    private static func addresses(_ list: WebviewTabList) -> [String] {
        list.tabs.map(\.url.absoluteString)
    }

    // MARK: - Same-link reuse (R12, R20, E1)

    @Test
    func test_open_sameAddress_reusesTabAndKeepsOrder() {
        // Arrange
        var list = Self.listWith(["https://a.test/", "https://b.test/", "https://c.test/"])
        let tabB = list.tabs[1].id

        // Act
        let result = list.open(BrowserPageAddress(url: Self.url("https://b.test/")), title: "B")

        // Assert
        #expect(result == .reused(tabB))
        #expect(list.activeTabId == tabB)
        #expect(Self.addresses(list) == ["https://a.test/", "https://b.test/", "https://c.test/"])
    }

    @Test(arguments: [
        ("https://b.test/page#section", "https://b.test/page"),
        ("HTTPS://B.TEST/page", "https://b.test/page"),
        ("https://b.test:443/page", "https://b.test/page"),
        ("https://b.test", "https://b.test/"),
        ("file:///tmp/x/../report.html", "file:///tmp/report.html"),
    ])
    func test_open_normalizedEquivalentAddress_reusesTab(opened: String, existing: String) {
        // Arrange
        var list = Self.listWith(["https://a.test/", existing])
        let existingTab = list.tabs[1].id
        _ = list.select(list.tabs[0].id)

        // Act
        let result = list.open(BrowserPageAddress(url: Self.url(opened)), title: "")

        // Assert
        #expect(result == .reused(existingTab))
        #expect(list.tabs.count == 2)
    }

    @Test
    func test_open_newAddress_appendsActiveTabAndLeavesOthersUnchanged() {
        // Arrange
        var list = Self.listWith(["https://a.test/", "https://b.test/"])
        let before = list.tabs

        // Act
        let result = list.open(BrowserPageAddress(url: Self.url("https://c.test/")), title: "C")

        // Assert
        guard case .added(let newId) = result else {
            Issue.record("expected an added tab, got \(result)")
            return
        }
        #expect(list.activeTabId == newId)
        #expect(Array(list.tabs.prefix(2)) == before)
        #expect(list.tabs.last?.url.absoluteString == "https://c.test/")
    }

    @Test
    func test_open_afterTabNavigatedXToY_reusesForYAndAddsForX() {
        // Arrange: tab one showed X, then committed a navigation to Y.
        var list = Self.listWith(["https://x.test/", "https://other.test/"])
        let navigatedTab = list.tabs[0].id
        list.update(navigatedTab, url: Self.url("https://y.test/"), title: "Y")

        // Act
        let openY = list.open(BrowserPageAddress(url: Self.url("https://y.test/")), title: "")
        let openX = list.open(BrowserPageAddress(url: Self.url("https://x.test/")), title: "")

        // Assert
        #expect(openY == .reused(navigatedTab))
        guard case .added = openX else {
            Issue.record("a stale address was matched: opening X reused \(openX)")
            return
        }
        #expect(list.tabs.count == 3)
    }

    // MARK: - Close, order and active tab (R10, R30, R31)

    @Test
    func test_closeActiveMiddleTab_activatesNextAndClosesGap() {
        // Arrange
        var list = Self.listWith(["https://a.test/", "https://b.test/", "https://c.test/"])
        let tabB = list.tabs[1].id
        let tabC = list.tabs[2].id
        _ = list.select(tabB)

        // Act
        let result = list.close(tabB)

        // Assert
        #expect(result == .closed(activeTabId: tabC))
        #expect(Self.addresses(list) == ["https://a.test/", "https://c.test/"])
        #expect(list.closedTabs.map(\.url.absoluteString) == ["https://b.test/"])
    }

    @Test
    func test_closeActiveLastTab_activatesPrevious() {
        // Arrange
        var list = Self.listWith(["https://a.test/", "https://b.test/", "https://c.test/"])
        let tabB = list.tabs[1].id
        let tabC = list.tabs[2].id

        // Act
        let result = list.close(tabC)

        // Assert
        #expect(result == .closed(activeTabId: tabB))
    }

    @Test
    func test_closeInactiveTab_keepsActiveTab() {
        // Arrange
        var list = Self.listWith(["https://a.test/", "https://b.test/", "https://c.test/"])
        let tabA = list.tabs[0].id
        let tabC = list.tabs[2].id

        // Act
        let result = list.close(tabA)

        // Assert
        #expect(result == .closed(activeTabId: tabC))
    }

    @Test
    func test_closeOnlyTab_reportsClosedLastAndKeepsTab() {
        // Arrange
        var list = Self.listWith(["https://a.test/"])
        let only = list.tabs[0].id

        // Act
        let result = list.close(only)

        // Assert
        #expect(result == .closedLast)
        #expect(list.activeTabId == only)
    }

    @Test
    func test_recentlyClosed_isNewestFirst_andReopenAppendsAndActivates() {
        // Arrange
        var list = Self.listWith(["https://a.test/", "https://b.test/", "https://c.test/"])
        _ = list.close(list.tabs[0].id)
        _ = list.close(list.tabs[0].id)
        #expect(list.closedTabs.map(\.url.absoluteString) == ["https://b.test/", "https://a.test/"])
        let closedA = list.closedTabs[1].id

        // Act
        let reopened = list.reopen(closedA)

        // Assert
        #expect(reopened == list.activeTabId)
        #expect(Self.addresses(list) == ["https://c.test/", "https://a.test/"])
        #expect(list.closedTabs.map(\.url.absoluteString) == ["https://b.test/"])
    }

    @Test
    func test_selectUnknownTab_leavesActiveTab() {
        // Arrange
        var list = Self.listWith(["https://a.test/", "https://b.test/"])
        let active = list.activeTabId

        // Act
        let selected = list.select(.generate())

        // Assert
        #expect(!selected)
        #expect(list.activeTabId == active)
    }

    @Test
    func test_restoring_rejectsEmptyOrForeignActiveId() {
        let tab = WebviewTab(id: .generate(), url: Self.url("https://a.test/"), title: "A")
        #expect(WebviewTabList(restoring: [], activeTabId: tab.id) == nil)
        #expect(WebviewTabList(restoring: [tab], activeTabId: .generate()) == nil)
        #expect(WebviewTabList(restoring: [tab], activeTabId: tab.id)?.activeTabId == tab.id)
    }
}
