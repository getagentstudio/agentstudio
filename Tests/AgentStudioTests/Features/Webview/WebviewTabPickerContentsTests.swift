import Foundation
import Testing

@testable import AgentStudioWebview

/// Picker contents from the Specification: R7 (search filters both lists by
/// title or address), R30 (Open Tabs in tab order, Recently Closed newest
/// first), R36 (no-match state), R37 (a local file's address shows the home
/// folder as `~`) and R39 (only open rows can be closed).
@Suite
struct WebviewTabPickerContentsTests {
    private static let home = "/Users/tester"

    private static func list() -> WebviewTabList {
        var list = WebviewTabList(
            firstTab: WebviewTab(id: .generate(), url: URL(string: "https://docs.test/guide")!, title: "Guide")
        )
        _ = list.open(BrowserPageAddress(url: URL(string: "https://news.test/")!), title: "Morning News")
        _ = list.open(BrowserPageAddress(url: URL(fileURLWithPath: "\(home)/reports/plan.html")), title: "Plan")
        _ = list.open(BrowserPageAddress(url: URL(string: "https://old.test/a")!), title: "Old A")
        _ = list.open(BrowserPageAddress(url: URL(string: "https://old.test/b")!), title: "Old B")
        _ = list.close(list.tabs[3].id)  // Old A closed first
        _ = list.close(list.tabs[3].id)  // then Old B
        return list
    }

    private static func contents(_ query: String) -> WebviewTabPickerContents {
        WebviewTabPickerContents(request: WebviewTabPickerRequest(tabList: list(), query: query, homeDirectory: home))
    }

    @Test
    func test_emptySearch_showsOpenTabsInOrderAndClosedNewestFirst() {
        // Act
        let contents = Self.contents("")

        // Assert
        #expect(contents.openRows.map(\.title) == ["Guide", "Morning News", "Plan"])
        #expect(contents.closedRows.map(\.title) == ["Old B", "Old A"])
        // Closing the active last tab (Old B) made the previous one active (R31).
        #expect(contents.openRows.filter(\.isActive).map(\.title) == ["Plan"])
        #expect(!contents.showsNoMatches)
    }

    @Test
    func test_search_matchesTitleCaseInsensitively_inBothLists() {
        // Act
        let contents = Self.contents("old b")

        // Assert
        #expect(contents.openRows.isEmpty)
        #expect(contents.closedRows.map(\.title) == ["Old B"])
    }

    @Test
    func test_search_matchesAddress_asShownOrInFull() {
        // Act
        let byHost = Self.contents("news.test")
        let byShownPath = Self.contents("~/reports")
        let byFullPath = Self.contents("/Users/tester/reports")

        // Assert: a title that doesn't contain the text still matches by address.
        #expect(byHost.openRows.map(\.title) == ["Morning News"])
        #expect(byShownPath.openRows.map(\.title) == ["Plan"])
        #expect(byFullPath.openRows.map(\.title) == ["Plan"])
    }

    @Test
    func test_noMatch_showsNoRowsAndNoMatchState() {
        // Act
        let contents = Self.contents("nothing like this")

        // Assert
        #expect(contents.openRows.isEmpty && contents.closedRows.isEmpty)
        #expect(contents.showsNoMatches)
        #expect(contents.keyboardItems.isEmpty)
    }

    @Test
    func test_localFileAddress_showsHomeFolderAsTilde_webAddressUnchanged() {
        // Act
        let rows = Self.contents("").openRows

        // Assert
        #expect(rows.map(\.displayAddress) == ["https://docs.test/guide", "https://news.test/", "~/reports/plan.html"])
        #expect(
            WebviewTabPickerContents.displayAddress(URL(fileURLWithPath: "/tmp/page.html"), homeDirectory: Self.home)
                == "/tmp/page.html")
        #expect(
            WebviewTabPickerContents.displayAddress(
                URL(fileURLWithPath: "/Users/testerish/page.html"), homeDirectory: Self.home)
                == "/Users/testerish/page.html")
    }

    @Test
    func test_keyboardItems_followDisplayOrder_andOnlyOpenRowsClose() {
        // Act
        let contents = Self.contents("")

        // Assert: the fixture's five rows, Open Tabs then Recently Closed.
        let titleById = Dictionary(
            uniqueKeysWithValues: (contents.openRows + contents.closedRows).map { ($0.id, $0.title) })
        #expect(
            contents.keyboardItems.map { titleById[$0.id] } == ["Guide", "Morning News", "Plan", "Old B", "Old A"])
        #expect(contents.keyboardItems.map(\.supportsAuxiliaryAction) == [true, true, true, false, false])
        #expect(contents.closedRows.allSatisfy { $0.closesTab == nil })
    }
}
