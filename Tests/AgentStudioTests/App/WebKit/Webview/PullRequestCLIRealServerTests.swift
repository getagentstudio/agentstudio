import AgentStudioDeadlineTestSupport
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioIPCClientCore

private struct PullRequestCLIRun: Equatable, Sendable {
    let exitCode: Int32
    let output: [String]
    let errors: [String]
}

private final class PullRequestCLILines: Sendable {
    private let captured = Mutex<[String]>([])
    func append(_ line: String) { captured.withLock { $0.append(line) } }
    var all: [String] { captured.withLock { $0 } }
}

extension WebKitSerializedTests.WebviewPaneControllerTests {
    @Test("pr CLI writes the target pane through real auth and storage; only its author removes it")
    func pullRequestCLIRecordsCrossPaneAddAndOwnRemoval() async throws {
        let harness = try await PaneAgentControlHarness.make(channel: .debug)
        do {
            let target = harness.otherPaneId.uuidString
            let before = harness.workspaceFacts()
            let sourceEnvironment = Self.pullRequestEnvironment(harness, source: harness.mainPaneId)
            let otherEnvironment = Self.pullRequestEnvironment(harness, source: harness.otherPaneId)
            let add = try await Self.runPullRequestCLI(
                ["pr", "add", "Owner/Repo#7", "--target", target], environment: sourceEnvironment)
            #expect(add == .init(exitCode: 0, output: ["added owner/repo#7 to the pane"], errors: []))
            let duplicate = try await Self.runPullRequestCLI(
                ["pr", "add", "owner/repo#7", "--target", target], environment: sourceEnvironment)
            #expect(duplicate == .init(exitCode: 0, output: ["owner/repo#7 is already on the pane"], errors: []))

            let service = try #require(harness.commandHarness.coordinator.paneContextService)
            let rows = try await service.listPullRequests(paneId: PaneId(existingUUID: harness.otherPaneId))
            #expect(rows.count == 1)
            #expect(
                rows.first?.contributions.map(\.author) == [
                    .paneAgent(sourcePaneId: PaneId(existingUUID: harness.mainPaneId), conversation: nil)
                ])
            #expect(try await service.listPullRequests(paneId: PaneId(existingUUID: harness.mainPaneId)).isEmpty)

            let otherRemoval = try await Self.runPullRequestCLI(
                ["pr", "remove", "owner/repo#7", "--target-env"], environment: otherEnvironment)
            #expect(
                otherRemoval
                    == .init(exitCode: 1, output: [], errors: ["owner/repo#7 was added by someone else; not removed"]))
            let listed = try await Self.runPullRequestCLI(
                ["pr", "list", "--target", target], environment: sourceEnvironment)
            #expect(listed.exitCode == 0 && listed.errors.isEmpty)
            #expect(listed.output.count == 1 && listed.output.first?.contains("owner/repo#7") == true)
            let removed = try await Self.runPullRequestCLI(
                ["pr", "remove", "owner/repo#7", "--target", target], environment: sourceEnvironment)
            #expect(removed == .init(exitCode: 0, output: ["removed owner/repo#7 from the pane"], errors: []))
            let absent = try await Self.runPullRequestCLI(
                ["pr", "remove", "owner/repo#7", "--target", target], environment: sourceEnvironment)
            #expect(absent == .init(exitCode: 0, output: ["owner/repo#7 is not on this pane"], errors: []))
            let empty = try await Self.runPullRequestCLI(
                ["pr", "list", "--target", target], environment: sourceEnvironment)
            #expect(empty == .init(exitCode: 0, output: ["no pull requests on this pane"], errors: []))
            #expect(harness.workspaceFacts() == before)
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test("pr CLI refusal lines and exits match the specification without moving the workspace")
    func pullRequestCLIRefusalTable() async throws {
        let harness = try await PaneAgentControlHarness.make(channel: .debug)
        do {
            let environment = Self.pullRequestEnvironment(harness, source: harness.mainPaneId)
            let target = harness.otherPaneId.uuidString
            let unknown = UUIDv7.generate().uuidString
            let before = harness.workspaceFacts()
            let cases: [([String], String, Int32)] = [
                (
                    ["pr", "add", "https://gitlab.com/o/r/pull/7", "--target", target],
                    "not a GitHub pull request: https://gitlab.com/o/r/pull/7", 1
                ),
                (["pr", "add", "o/r#7"], "choose one of --target or --target-env", 2),
                (
                    ["pr", "add", "o/r#7", "--target", target, "--target-env"],
                    "choose one of --target or --target-env", 2
                ),
                (["pr", "add", "o/r#7", "--target", unknown], "pane not found: \(unknown)", 1),
                (
                    ["pr", "add", "o/r#7", "--target", harness.drawerChildPaneId.uuidString],
                    "not a main pane: \(harness.drawerChildPaneId.uuidString)", 1
                ),
            ]
            for (arguments, line, exitCode) in cases {
                let run = try await Self.runPullRequestCLI(arguments, environment: environment)
                #expect(run == .init(exitCode: exitCode, output: [], errors: [line]))
            }
            var missingEnvironment = environment
            missingEnvironment.removeValue(forKey: "AGENTSTUDIO_PANE_ID")
            #expect(
                try await Self.runPullRequestCLI(
                    ["pr", "add", "o/r#7", "--target-env"], environment: missingEnvironment)
                    == .init(exitCode: 2, output: [], errors: ["AGENTSTUDIO_PANE_ID is not set; use --target"]))
            var noCredential = environment
            noCredential.removeValue(forKey: "AGENTSTUDIO_PANE_TOKEN")
            #expect(
                try await Self.runPullRequestCLI(["pr", "add", "o/r#7", "--target", target], environment: noCredential)
                    == .init(exitCode: 1, output: [], errors: ["Agent Studio refused the call: no credential"]))
            var unreachable = environment
            unreachable["AGENTSTUDIO_IPC_SOCKET"] = harness.rootDirectory.appending(path: "missing.sock").path
            #expect(
                try await Self.runPullRequestCLI(["pr", "add", "o/r#7", "--target", target], environment: unreachable)
                    == .init(exitCode: 1, output: [], errors: ["Agent Studio is not reachable"]))
            #expect(harness.workspaceFacts() == before)
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test("Separately authenticated CLI exchanges retain one automation author; another credential cannot remove it")
    func pullRequestCLIRetainsCredentialAuthorAcrossLogins() async throws {
        let harness = try await PaneAgentControlHarness.make(channel: .debug)
        do {
            let token = UUIDv7.generate().uuidString
            let generation = harness.appDelegate.appIPCPrincipalRegistry.installDiagnosticCredential(
                verifierSHA256: Data(SHA256.hash(data: Data(token.utf8))))
            let environment = ["AGENTSTUDIO_IPC_SOCKET": harness.socketPath, "AGENTSTUDIO_PANE_TOKEN": token]
            let target = harness.otherPaneId.uuidString
            let arguments = ["pr", "add", "owner/repo#8", "--target", target]
            #expect(
                try await Self.runPullRequestCLI(arguments, environment: environment)
                    == .init(exitCode: 0, output: ["added owner/repo#8 to the pane"], errors: []))
            #expect(
                try await Self.runPullRequestCLI(arguments, environment: environment)
                    == .init(exitCode: 0, output: ["owner/repo#8 is already on the pane"], errors: []))
            let service = try #require(harness.commandHarness.coordinator.paneContextService)
            let rows = try await service.listPullRequests(paneId: PaneId(existingUUID: harness.otherPaneId))
            #expect(
                rows.first?.contributions.map(\.author) == [
                    .client(credentialKey: "diagnostic:\(generation.uuidString)")
                ])
            #expect(
                try await Self.runPullRequestCLI(
                    ["pr", "remove", "owner/repo#8", "--target", target], environment: environment)
                    == .init(exitCode: 0, output: ["removed owner/repo#8 from the pane"], errors: []))
            _ = try await Self.runPullRequestCLI(arguments, environment: environment)
            let replacement = UUIDv7.generate().uuidString
            _ = harness.appDelegate.appIPCPrincipalRegistry.installDiagnosticCredential(
                verifierSHA256: Data(SHA256.hash(data: Data(replacement.utf8))))
            let replacementEnvironment = [
                "AGENTSTUDIO_IPC_SOCKET": harness.socketPath, "AGENTSTUDIO_PANE_TOKEN": replacement,
            ]
            #expect(
                try await Self.runPullRequestCLI(
                    ["pr", "remove", "owner/repo#8", "--target", target], environment: replacementEnvironment)
                    == .init(exitCode: 1, output: [], errors: ["owner/repo#8 was added by someone else; not removed"]))
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test("Target-env adds successfully, the 21st PR prints the cap refusal, and no-window keeps drawer semantics")
    func pullRequestCLICapAndNoWindow() async throws {
        let harness = try await PaneAgentControlHarness.make(channel: .debug)
        do {
            let environment = Self.pullRequestEnvironment(harness, source: harness.mainPaneId)
            #expect(
                try await Self.runPullRequestCLI(
                    ["pr", "add", "owner/repo#1", "--target-env"], environment: environment)
                    == .init(exitCode: 0, output: ["added owner/repo#1 to the pane"], errors: []))
            let service = try #require(harness.commandHarness.coordinator.paneContextService)
            let pane = PaneId(existingUUID: harness.mainPaneId)
            for number in 2...20 {
                _ = try await service.addPullRequest(
                    paneId: pane,
                    identity: ForgePullRequestIdentity(
                        host: "github.com", owner: "owner", repository: "repo", number: number), author: .person)
            }
            #expect(
                try await Self.runPullRequestCLI(
                    ["pr", "add", "owner/repo#21", "--target-env"], environment: environment)
                    == .init(exitCode: 1, output: [], errors: ["the pane already has 20 pull requests"]))
            let listed = try await Self.runPullRequestCLI(["pr", "list", "--target-env"], environment: environment)
            #expect(listed.exitCode == 0 && listed.output.count == 20 && listed.errors.isEmpty)
            harness.commandHarness.windowLifecycleStore.recordWindowRegistered(UUIDv7.generate())
            try #require(harness.commandHarness.windowLifecycleStore.preferredWorkspaceWindowId == nil)
            #expect(
                try await Self.runPullRequestCLI(
                    ["pr", "add", "owner/repo#22", "--target-env"], environment: environment)
                    == .init(exitCode: 1, output: [], errors: ["Agent Studio has no open window"]))
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test("The real server refuses forged authors, other forges and unauthenticated writes without records")
    func pullRequestCLIRejectsForgedAuthorAtServer() async throws {
        let harness = try await PaneAgentControlHarness.make(channel: .debug)
        do {
            let token = try harness.agentToken(boundTo: harness.mainPaneId)
            let parameters: [String: JSONValue] = [
                "targetPaneHandle": .string(harness.otherPaneId.uuidString),
                "pullRequest": .object([
                    "host": .string("github.com"), "owner": .string("owner"), "repository": .string("repo"),
                    "number": .number(7),
                ]),
                "correlationId": .string(UUIDv7.generate().uuidString),
            ]
            let unauthenticated = try await harness.unauthenticatedResponse(
                method: "pane.pullRequest.add", params: .object(parameters))
            #expect(unauthenticated.error?.code == -32_001)
            var forged = parameters
            forged["author"] = .object(["kind": .string("person")])
            let rejected = try await harness.response(
                token: token, method: "pane.pullRequest.add", params: .object(forged))
            #expect(rejected.error?.code == -32_602)
            var otherForge = parameters
            otherForge["pullRequest"] = .object([
                "host": .string("gitlab.com"), "owner": .string("owner"), "repository": .string("repo"),
                "number": .number(7),
            ])
            let notGitHub = try await harness.response(
                token: token, method: "pane.pullRequest.add", params: .object(otherForge))
            #expect(notGitHub.error?.code == -32_602 && notGitHub.error?.message == "notGitHub")
            let service = try #require(harness.commandHarness.coordinator.paneContextService)
            #expect(try await service.listPullRequests(paneId: PaneId(existingUUID: harness.otherPaneId)).isEmpty)
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    private static func pullRequestEnvironment(_ harness: PaneAgentControlHarness, source: UUID) -> [String: String] {
        var environment = harness.appDelegate.appIPCWorkspaceSurfaceLifecycle().environment(
            source, harness.store.identityAtom.workspaceId)
        environment["AGENTSTUDIO_IPC_SOCKET"] = harness.socketPath
        return environment
    }

    private static func runPullRequestCLI(_ arguments: [String], environment: [String: String]) async throws
        -> PullRequestCLIRun
    {
        let driver = ControlledDeadlineDriver()
        defer { driver.close() }
        let output = PullRequestCLILines()
        let errors = PullRequestCLILines()
        let props = AgentStudioIPCClientCommandLineRunner.Props(
            arguments: arguments, environment: environment, executablePath: "/isolated-fixture/agentstudio",
            bundleExecutableURL: nil, standardInput: { Data() }, identifierGenerator: { UUIDv7.generate() },
            standardOutputSink: { output.append($0) }, standardErrorSink: { errors.append($0) },
            deadlineTiming: driver.timing)
        let exitCode = await valueFromDedicatedThread { AgentStudioIPCClientCommandLineRunner.run(props: props) }
        return .init(exitCode: exitCode, output: output.all, errors: errors.all)
    }
}
