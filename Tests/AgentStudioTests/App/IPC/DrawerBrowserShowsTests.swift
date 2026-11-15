import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio

/// Records browser notices; `unread` is what the person would see.
@MainActor
private final class RecordingDrawerBrowserNotices: DrawerBrowserNoticePosting {
    private(set) var unread: Set<UUID> = []
    private(set) var posted: [UUID] = []
    var postSucceeds = true

    func postNotice(messageId: UUID, in _: UUID, browserPaneId _: UUID, body _: String) async -> Bool {
        guard postSucceeds else { return false }
        posted.append(messageId)
        unread.insert(messageId)
        return true
    }

    func withdrawNotice(messageId: UUID, in _: UUID, browserPaneId _: UUID) async {
        unread.remove(messageId)
    }
}

private struct OpenFailed: Error {}

/// R21 and the show queue: opens for one pane run one at a time, each
/// success leaves exactly one unread browser notice, and a failed open
/// releases the queue without dropping the notice it would have replaced.
@MainActor
@Suite
struct DrawerBrowserShowsTests {
    private let parent = UUIDv7.generate()
    private let browser = UUIDv7.generate()

    private func opened(_ tab: DrawerBrowserTabOutcome) -> DrawerBrowserOpenResult {
        DrawerBrowserOpenResult(childPaneId: browser, tab: tab)
    }

    @Test
    func test_overlappingShows_runInOrder_andLeaveOneUnreadNotice() async throws {
        // Arrange: the first open is held mid-sequence.
        let notices = RecordingDrawerBrowserNotices()
        let shows = DrawerBrowserShows(notices: notices)
        let firstOpen = HeldStep<Void>("first drawer browser open")
        var secondOpenStarted = false

        // Act: both shows arrive before either finishes.
        let first = Task { @MainActor in
            try await shows.show(parentPaneId: parent, noticeBody: "first") {
                try await firstOpen.arrive(())
                return opened(.newBrowser)
            }
        }
        let second = Task { @MainActor in
            try await shows.show(parentPaneId: parent, noticeBody: "second") {
                secondOpenStarted = true
                return opened(.newTab)
            }
        }
        try await firstOpen.firstArrival()
        let secondStartedWhileFirstHeld = secondOpenStarted
        firstOpen.release()
        let firstShown = try await first.value
        let secondShown = try await second.value

        // Assert
        #expect(!secondStartedWhileFirstHeld, "the second open ran while the first was still held")
        #expect(firstShown.opened.tab == .newBrowser)
        #expect(secondShown.opened.tab == .newTab)
        #expect(notices.posted.count == 2)
        #expect(notices.unread == [notices.posted[1]])
    }

    @Test
    func test_failedOpen_releasesQueue_andKeepsNoticeUntilNextSuccess() async throws {
        // Arrange: an earlier open left notice A.
        let notices = RecordingDrawerBrowserNotices()
        let shows = DrawerBrowserShows(notices: notices)
        _ = try await shows.show(parentPaneId: parent, noticeBody: "a") { opened(.newBrowser) }
        let noticeA = try #require(notices.posted.first)
        let failingOpen = HeldStep<Void>("failing drawer browser open")

        // Act: a failing open is held while a successor queues behind it.
        let failing = Task { @MainActor in
            try await shows.show(parentPaneId: parent, noticeBody: "fails") {
                try await failingOpen.arrive(())
                return opened(.newTab)
            }
        }
        let successor = Task { @MainActor in
            try await shows.show(parentPaneId: parent, noticeBody: "b") { opened(.newTab) }
        }
        try await failingOpen.firstArrival()
        #expect(notices.unread == [noticeA])
        failingOpen.fail(OpenFailed())
        await #expect(throws: OpenFailed.self) { try await failing.value }
        let shown = try await successor.value

        // Assert: the failure kept A; the successor replaced it with B.
        #expect(shown.noticePosted)
        #expect(notices.posted.count == 2)
        #expect(notices.unread == [notices.posted[1]])
    }

    @Test
    func test_noticeFailure_keepsPageOpen_andReportsFailed() async throws {
        // Arrange
        let notices = RecordingDrawerBrowserNotices()
        let shows = DrawerBrowserShows(notices: notices)
        _ = try await shows.show(parentPaneId: parent, noticeBody: "a") { opened(.newBrowser) }
        notices.postSucceeds = false

        // Act
        let shown = try await shows.show(parentPaneId: parent, noticeBody: "b") { opened(.reusedTab) }

        // Assert: the open stands; the earlier notice was withdrawn and none replaced it.
        #expect(shown.opened.tab == .reusedTab)
        #expect(!shown.noticePosted)
        #expect(notices.unread.isEmpty)
    }

    // MARK: - Page admission (R15)

    @Test
    func test_pageAdmission_admitsWebAndExistingHTML_refusesTheRest() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "drawer-browse-admission-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(
            at: directory.appending(path: "folder.html"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = directory.appending(path: "page.html")
        try "<html></html>".write(to: page, atomically: true, encoding: .utf8)
        let notes = directory.appending(path: "notes.md")
        try "# notes".write(to: notes, atomically: true, encoding: .utf8)
        let fifo = directory.appending(path: "report.html")
        try #require(mkfifo(fifo.path, 0o600) == 0, "the test pipe was created")

        #expect(try await DrawerBrowserPageAdmission.admit(.web(url: "https://example.com/a")).host() == "example.com")
        #expect(try await DrawerBrowserPageAdmission.admit(.localHTML(path: page.path)).path == page.path)
        for (refused, reason) in [
            (IPCDrawerBrowserPage.web(url: "ftp://example.com/a.html"), AppIPCLayoutError.Reason.unsupportedPage),
            (.web(url: "https:///no-host"), .unsupportedPage),
            (.localHTML(path: notes.path), .unsupportedPage),
            (.localHTML(path: "relative/page.html"), .unsupportedPage),
            (.localHTML(path: directory.appending(path: "missing.html").path), .fileNotFound),
            (.localHTML(path: directory.appending(path: "folder.html").path), .fileNotFound),
            (.localHTML(path: fifo.path), .fileNotFound),
        ] {
            await #expect(throws: AppIPCLayoutError(reason: reason), "\(refused)") {
                _ = try await DrawerBrowserPageAdmission.admit(refused)
            }
        }
    }
}
