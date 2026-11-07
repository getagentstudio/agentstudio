import AgentStudioDeadlineTestSupport
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioIPCClientCore

/// What one `drawer browse` run printed and returned.
private struct DrawerBrowseRun: Equatable, Sendable {
    let exitCode: Int32
    let standardOutput: [String]
    let standardError: [String]
}

/// Lines a sink received, readable after the run.
private final class CapturedLines: Sendable {
    private let lines = Mutex<[String]>([])
    func append(_ line: String) { lines.withLock { $0.append(line) } }
    var all: [String] { lines.withLock { $0 } }
}

/// The Specification's `drawer browse` refusal lines, produced by the real CLI
/// against the real App IPC server: the server's reply has to survive the
/// client's decoder for the CLI to print the documented line.
extension WebKitSerializedTests.WebviewPaneControllerTests {
    @Test("drawer browse prints pane not found for an id that names no pane, including a window id")
    func drawerBrowseCLINamesUnknownTargetsAsPaneNotFound() async throws {
        // Arrange
        let harness = try await PaneAgentControlHarness.make(channel: .debug)
        let pageDirectory = try Self.makePageDirectory()
        defer { try? FileManager.default.removeItem(at: pageDirectory) }
        do {
            let page = pageDirectory.appending(path: "alpha.html")
            try "<html><title>alpha</title></html>".write(to: page, atomically: true, encoding: .utf8)
            let before = harness.workspaceFacts()
            let unknownPaneId = UUIDv7.generate()

            // Act
            var runs: [DrawerBrowseRun] = []
            for target in [unknownPaneId, harness.workspaceWindowId] {
                runs.append(
                    try await Self.runDrawerBrowse(
                        ["drawer", "browse", page.path, "--target", target.uuidString], harness: harness))
            }

            // Assert
            #expect(
                runs
                    == [unknownPaneId, harness.workspaceWindowId].map { target in
                        DrawerBrowseRun(
                            exitCode: 1, standardOutput: [], standardError: ["pane not found: \(target.uuidString)"])
                    })
            #expect(harness.workspaceFacts() == before)
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test("drawer browse prints the no-window line when the app has no current window")
    func drawerBrowseCLIPrintsNoOpenWindow() async throws {
        // Arrange: a second registered window, neither focused nor key, leaves
        // the app with no current workspace window.
        let harness = try await PaneAgentControlHarness.make(channel: .debug)
        let pageDirectory = try Self.makePageDirectory()
        defer { try? FileManager.default.removeItem(at: pageDirectory) }
        do {
            let page = pageDirectory.appending(path: "alpha.html")
            try "<html><title>alpha</title></html>".write(to: page, atomically: true, encoding: .utf8)
            harness.commandHarness.windowLifecycleStore.recordWindowRegistered(UUIDv7.generate())
            try #require(harness.commandHarness.windowLifecycleStore.preferredWorkspaceWindowId == nil)
            let before = harness.workspaceFacts()

            // Act
            let run = try await Self.runDrawerBrowse(
                ["drawer", "browse", page.path, "--target-env"], harness: harness)

            // Assert
            #expect(
                run
                    == DrawerBrowseRun(
                        exitCode: 1, standardOutput: [], standardError: ["Agent Studio has no open window"]))
            #expect(harness.workspaceFacts() == before)
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test("the server's own page refusals reach the CLI's documented lines")
    func drawerBrowseCLIPrintsServerPageRefusals() async throws {
        // Arrange: requests the CLI's own checks would have refused, sent anyway,
        // so only the server's replies decide the lines.
        let harness = try await PaneAgentControlHarness.make(channel: .debug)
        let pageDirectory = try Self.makePageDirectory()
        defer { try? FileManager.default.removeItem(at: pageDirectory) }
        do {
            let notes = pageDirectory.appending(path: "notes.md")
            try "# notes".write(to: notes, atomically: true, encoding: .utf8)
            let missing = pageDirectory.appending(path: "missing.html").path
            let before = harness.workspaceFacts()

            // Act
            var runs: [DrawerBrowseRun] = []
            for page in [
                IPCDrawerBrowserPage.localHTML(path: missing), .localHTML(path: notes.path),
                .web(url: "https:///no-host"),
            ] {
                runs.append(
                    try await Self.callDrawerBrowse(
                        DrawerBrowseCLI.Request(page: page, parentPaneId: harness.mainPaneId), harness: harness))
            }

            // Assert
            #expect(
                runs == [
                    DrawerBrowseRun(exitCode: 1, standardOutput: [], standardError: ["not found: \(missing)"]),
                    DrawerBrowseRun(
                        exitCode: 1, standardOutput: [], standardError: ["not supported: only HTML files and URLs"]),
                    DrawerBrowseRun(
                        exitCode: 1, standardOutput: [], standardError: ["not supported: only HTML files and URLs"]),
                ])
            #expect(harness.workspaceFacts() == before)
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    // MARK: - Running the CLI

    private static func makePageDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "drawer-browse-cli-\(UUIDv7.generate().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The environment the App hands the main pane's terminal.
    private static func mainPaneEnvironment(_ harness: PaneAgentControlHarness) -> [String: String] {
        var environment = harness.appDelegate.appIPCWorkspaceSurfaceLifecycle()
            .environment(harness.mainPaneId, harness.store.identityAtom.workspaceId)
        environment["AGENTSTUDIO_IPC_SOCKET"] = harness.socketPath
        return environment
    }

    private static func props(
        _ arguments: [String], environment: [String: String], timing: any CallDeadlineTiming,
        output: CapturedLines, error: CapturedLines
    ) -> AgentStudioIPCClientCommandLineRunner.Props {
        AgentStudioIPCClientCommandLineRunner.Props(
            arguments: arguments, environment: environment,
            executablePath: "/isolated-fixture/agentstudio", bundleExecutableURL: nil,
            standardInput: { Data() }, identifierGenerator: { UUIDv7.generate() },
            standardOutputSink: { line in output.append(line) },
            standardErrorSink: { line in error.append(line) },
            deadlineTiming: timing)
    }

    /// The whole command line, as an agent's terminal runs it.
    private static func runDrawerBrowse(
        _ arguments: [String], harness: PaneAgentControlHarness
    ) async throws -> DrawerBrowseRun {
        let environment = mainPaneEnvironment(harness)
        let driver = ControlledDeadlineDriver()
        defer { driver.close() }
        let output = CapturedLines()
        let error = CapturedLines()
        let props = props(arguments, environment: environment, timing: driver.timing, output: output, error: error)
        let exitCode = await valueFromDedicatedThread { AgentStudioIPCClientCommandLineRunner.run(props: props) }
        return DrawerBrowseRun(
            exitCode: exitCode, standardOutput: output.all, standardError: error.all)
    }

    /// One request sent past the CLI's own page checks.
    private static func callDrawerBrowse(
        _ request: DrawerBrowseCLI.Request, harness: PaneAgentControlHarness
    ) async throws -> DrawerBrowseRun {
        let environment = mainPaneEnvironment(harness)
        let driver = ControlledDeadlineDriver()
        defer { driver.close() }
        let output = CapturedLines()
        let error = CapturedLines()
        let arguments = ["drawer", "browse", "unused.html", "--target-env"]
        let props = props(arguments, environment: environment, timing: driver.timing, output: output, error: error)
        let global = try AgentStudioIPCClientArguments.parseGlobal(
            arguments, environment: environment, standardInputProvider: { Data() })
        let runner = DrawerBrowseCLIRunner(
            props: props, global: global,
            deadline: CallDeadline(limit: CLIPolicy.ordinaryCallLimit, timing: driver.timing))
        let exitCode = try await valueFromDedicatedThread { try runner.call(request) }
        return DrawerBrowseRun(
            exitCode: exitCode, standardOutput: output.all, standardError: error.all)
    }
}
