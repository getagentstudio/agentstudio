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
        // Arrange
        let contents = WebviewTabPickerContents(tabList: Self.list(), query: "")
        var visited: [WebviewTabPickerContents.RowId] = []
        var current = contents.firstRowId

        // Act
        for _ in 0..<contents.rowIds.count + 2 {
            if let current { visited.append(current) }
            current = contents.rowId(movedBy: 1, from: current)
        }

        // Assert
        #expect(Array(visited.prefix(contents.rowIds.count)) == contents.rowIds)
        #expect(visited.last == contents.rowIds.last)
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
