import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

/// The `drawer browse` command table in the drawer browser Specification:
/// flags (R16, R17), page admission (R15), and each output line.
@Suite
struct DrawerBrowseCLITests {
    private static let paneId = UUID(uuidString: "01A1B2C3-0000-7000-8000-000000000001")!
    private static let cwd = URL(fileURLWithPath: "/work/project")
    private static let existing: Set<String> = ["/work/project/report.html", "/work/project/docs/page.htm"]

    private func parse(
        _ arguments: [String], environment: [String: String] = [:]
    ) -> Result<DrawerBrowseCLI.Request, DrawerBrowseCLI.Refusal> {
        do {
            return .success(
                try DrawerBrowseCLI.parse(
                    ["drawer", "browse"] + arguments, environment: environment, currentDirectory: Self.cwd,
                    isRegularFile: { Self.existing.contains($0) }))
        } catch {
            return .failure(error)
        }
    }

    @Test
    func test_webPage_withTarget_isAccepted() {
        let result = parse(["https://example.com/a", "--target", Self.paneId.uuidString])
        #expect(result == .success(.init(page: .web(url: "https://example.com/a"), parentPaneId: Self.paneId)))
    }

    @Test
    func test_relativeHTMLPath_isMadeAbsoluteAgainstWorkingDirectory() {
        let result = parse(
            ["docs/page.htm", "--target-env"], environment: ["AGENTSTUDIO_PANE_ID": Self.paneId.uuidString])
        #expect(
            result == .success(.init(page: .localHTML(path: "/work/project/docs/page.htm"), parentPaneId: Self.paneId)))
    }

    @Test(arguments: [
        (["https://example.com"], DrawerBrowseCLI.Refusal.targetFlags),
        (["https://example.com", "--target", "x", "--target-env"], .targetFlags),
        (["https://example.com", "--target-env"], .missingEnvironment),
        (["notes.md", "--target", paneId.uuidString], .unsupportedPage),
        (["ftp://example.com/a.html", "--target", paneId.uuidString], .unsupportedPage),
        (["missing.html", "--target", paneId.uuidString], .fileNotFound(path: "/work/project/missing.html")),
    ])
    func test_refusals(arguments: [String], expected: DrawerBrowseCLI.Refusal) {
        #expect(parse(arguments) == .failure(expected))
    }

    /// The CLI's own precheck: a pipe named like a page is not a page file.
    @Test
    func test_specialFileNamedLikeAPage_isRefusedAsNotFound() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "drawer-browse-cli-fifo-\(ProcessInfo.processInfo.globallyUniqueString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appending(path: "report.html")
        try #require(mkfifo(fifo.path, 0o600) == 0, "the test pipe was created")

        var refusal: DrawerBrowseCLI.Refusal?
        do {
            _ = try DrawerBrowseCLI.parse(
                ["drawer", "browse", fifo.path, "--target", Self.paneId.uuidString], environment: [:],
                currentDirectory: Self.cwd)
        } catch {
            refusal = error
        }

        #expect(refusal == .fileNotFound(path: fifo.path))
    }

    @Test
    func test_refusalLines_matchTheCommandTable() {
        #expect(DrawerBrowseCLI.Refusal.unsupportedPage.line == "not supported: only HTML files and URLs")
        #expect(DrawerBrowseCLI.Refusal.fileNotFound(path: "/a.html").line == "not found: /a.html")
        #expect(DrawerBrowseCLI.Refusal.targetFlags.line == "choose one of --target or --target-env")
        #expect(DrawerBrowseCLI.Refusal.missingEnvironment.line == "AGENTSTUDIO_PANE_ID is not set; use --target")
        #expect(DrawerBrowseCLI.Refusal.paneNotFound("p").line == "pane not found: p")
        #expect(DrawerBrowseCLI.Refusal.notOwnPane("p").line == "not your pane: p")
        #expect(DrawerBrowseCLI.Refusal.noOpenWindow.line == "Agent Studio has no open window")
        #expect(DrawerBrowseCLI.Refusal.unreachable.line == "Agent Studio is not reachable")
    }

    @Test(arguments: [
        (
            IPCDrawerBrowseTabOutcome.newBrowser, IPCDrawerBrowseNotice.posted,
            "opened in a new drawer browser; notice posted"
        ),
        (.newTab, .posted, "opened in a new browser tab; notice posted"),
        (.reusedTab, .posted, "reused the open browser tab; notice posted"),
        (.newTab, .failed, "opened in a new browser tab; notice failed"),
    ])
    func test_successLines(tab: IPCDrawerBrowseTabOutcome, notice: IPCDrawerBrowseNotice, expected: String) {
        let result = IPCDrawerBrowseResult(
            parentPaneId: Self.paneId, childPaneId: UUID(), tab: tab, notice: notice, correlationId: nil)
        #expect(DrawerBrowseCLI.line(for: result) == expected)
    }
}
