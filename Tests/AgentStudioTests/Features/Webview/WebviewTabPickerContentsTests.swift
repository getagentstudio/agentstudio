import Foundation
import Testing

@testable import AgentStudioWebview

/// Picker contents from the Specification: R7 (search filters both lists by
/// title or address), R30 (Open Tabs in tab order, Recently Closed newest
/// first) and R9 (every row reachable by keyboard).
@Suite
struct WebviewTabPickerContentsTests {
    private static func list() -> WebviewTabList {
        var list = WebviewTabList(
            firstTab: WebviewTab(id: .generate(), url: URL(string: "https://docs.test/guide")!, title: "Guide")
        )
        _ = list.open(BrowserPageAddress(url: URL(string: "https://news.test/")!), title: "Morning News")
        _ = list.open(BrowserPageAddress(url: URL(fileURLWithPath: "/tmp/reports/plan.html")), title: "Plan")
        _ = list.open(BrowserPageAddress(url: URL(string: "https://old.test/a")!), title: "Old A")
        _ = list.open(BrowserPageAddress(url: URL(string: "https://old.test/b")!), title: "Old B")
        _ = list.close(list.tabs[3].id)  // Old A closed first
        _ = list.close(list.tabs[3].id)  // then Old B
        return list
    }

    @Test
    func test_emptySearch_showsOpenTabsInOrderAndClosedNewestFirst() {
        // Act
        let contents = WebviewTabPickerContents(tabList: Self.list(), query: "")

        // Assert
        #expect(contents.openRows.map(\.tab.title) == ["Guide", "Morning News", "Plan"])
        #expect(contents.closedRows.map(\.tab.title) == ["Old B", "Old A"])
        // Closing the active last tab (Old B) made the previous one active (R31).
        #expect(contents.openRows.filter(\.isActive).map(\.tab.title) == ["Plan"])
    }

    @Test
    func test_search_matchesTitleCaseInsensitively_inBothLists() {
        // Act
        let contents = WebviewTabPickerContents(tabList: Self.list(), query: "old b")

        // Assert
        #expect(contents.openRows.isEmpty)
        #expect(contents.closedRows.map(\.tab.title) == ["Old B"])
    }

    @Test
    func test_search_matchesAddress_includingLocalFilePath() {
        // Act
        let byHost = WebviewTabPickerContents(tabList: Self.list(), query: "news.test")
        let byPath = WebviewTabPickerContents(tabList: Self.list(), query: "reports/plan")

        // Assert: a title that doesn't contain the text still matches by address.
        #expect(byHost.openRows.map(\.tab.title) == ["Morning News"])
        #expect(byPath.openRows.map(\.tab.title) == ["Plan"])
    }

    @Test
    func test_keyboardMovement_reachesEveryRowAcrossBothSections_andClamps() {
        // Arrange: the fixture has three open tabs and two closed ones.
        let contents = WebviewTabPickerContents(tabList: Self.list(), query: "")
        let titleByRow = Dictionary(
            uniqueKeysWithValues: (contents.openRows.map { ($0.id, $0.tab.title) })
                + contents.closedRows.map { ($0.id, $0.tab.title) })
        var visited: [String] = []
        var current = contents.firstRowId

        // Act: two moves more than there are rows.
        for _ in 0..<7 {
            if let current, let title = titleByRow[current] { visited.append(title) }
            current = contents.rowId(movedBy: 1, from: current)
        }

        // Assert: Open Tabs in order, then Recently Closed newest first, then
        // clamped on the last row.
        #expect(visited == ["Guide", "Morning News", "Plan", "Old B", "Old A", "Old A", "Old A"])
        #expect(contents.rowId(movedBy: -1, from: contents.firstRowId) == contents.firstRowId)
    }

    @Test
    func test_retainedHighlight_keepsShownRow_otherwiseFirstRow() {
        // Arrange
        let list = Self.list()
        let all = WebviewTabPickerContents(tabList: list, query: "")
        let filtered = WebviewTabPickerContents(tabList: list, query: "plan")
        let planRow = filtered.openRows[0].id

        // Assert
        #expect(all.retainedRowId(planRow) == planRow)
        #expect(filtered.retainedRowId(all.firstRowId) == planRow)
    }
}
