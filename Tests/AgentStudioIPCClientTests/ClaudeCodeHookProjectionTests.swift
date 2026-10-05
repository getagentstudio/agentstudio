import Foundation
import Testing

@testable import AgentStudioIPCClientCore
@testable import AgentStudioProgrammaticControl

/// Loads the recorded and schema-derived Claude Code hook documents next to
/// this suite. See `Fixtures/claude-code-2.1/README.md` for their provenance.
enum ClaudeCodeHookFixture {
    static func payload(_ event: String, file: String = #filePath) throws -> ClaudeCodeHookPayload {
        try JSONDecoder().decode(ClaudeCodeHookPayload.self, from: try data(event, file: file))
    }

    static func data(_ event: String, file: String = #filePath) throws -> Data {
        try Data(contentsOf: directory(file: file).appending(path: "\(event).json"))
    }

    static func directory(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/claude-code-2.1")
    }
}

/// One fixed identifier, so a projection difference is never a fresh UUID.
private let claudeCodeFixtureIdentifier = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

@Suite("Claude Code hook projection")
struct ClaudeCodeHookProjectionTests {
    private static let stableIdentifier = claudeCodeFixtureIdentifier

    private func project(
        _ event: String,
        freshOccurrenceIdentifier: () -> UUID = { claudeCodeFixtureIdentifier }
    ) throws -> ClaudeCodeHookProjectionOutcome {
        ClaudeCodeHookProjection.project(
            announcedEvent: event,
            payload: try ClaudeCodeHookFixture.payload(event),
            providerVersion: "2.1.274",
            correlationIdentifier: Self.stableIdentifier,
            freshOccurrenceIdentifier: freshOccurrenceIdentifier
        )
    }

    private func projectedParams(_ event: String) throws -> IPCSessionEventParams {
        guard case .projected(let params) = try project(event) else {
            Issue.record("\(event) did not project")
            throw ClaudeCodeHookInvocationError.reportRejected
        }
        return params
    }

    @Test("Each installed hook event projects its lifecycle capability")
    func projectsEveryInstalledEvent() throws {
        // Arrange
        let expected: [String: IPCSessionEventName] = [
            "SessionStart": .sessionStart,
            "UserPromptSubmit": .turnStart,
            "PreToolUse": .toolActivity,
            "PermissionRequest": .permission,
            "SubagentStart": .subagentActivity,
            "SubagentStop": .subagentActivity,
            "Stop": .turnDone,
            "SessionEnd": .sessionEnd,
        ]

        // Act
        let projected = try expected.keys.map { try ($0, projectedParams($0)) }

        // Assert
        for (event, params) in projected {
            #expect(params.event.name == expected[event])
            #expect(params.handle == "self")
            #expect(params.provider.identifier == "claude-code")
            #expect(params.provider.version == "2.1.274")
            #expect(params.provider.mode == ClaudeCodeProviderIdentity.operatingMode)
            #expect(params.event.conversationId == "11111111-2222-4333-8444-555555555555")
            #expect(ClaudeCodeProviderIdentity.projectedEventNames.contains(params.event.name))
        }
        // `prompt_id` is the turn: absent at session start, shared by the rest.
        #expect(projected.first { $0.0 == "SessionStart" }?.1.event.turnId == nil)
        let turnScoped = projected.filter { $0.0 != "SessionStart" }.map { $0.1.event.turnId }
        #expect(turnScoped.allSatisfy { $0 == "e58db972-d5f6-4cd5-950f-529703d0cd0a" })
    }

    @Test("A permission request carries the tool invocation as its request identity")
    func permissionCarriesRequestIdentifier() throws {
        // Arrange / Act
        let params = try projectedParams("PermissionRequest")

        // Assert
        #expect(params.event.requestId == "toolu_01PermissionFixture")
        #expect(params.event.toolId == nil)
        #expect(params.event.subagentId == nil)
    }

    @Test("Tool and subagent activity carry their own subject identity")
    func subjectIdentitiesStaySeparate() throws {
        // Arrange / Act
        let tool = try projectedParams("PreToolUse")
        let subagent = try projectedParams("SubagentStop")

        // Assert
        #expect(tool.event.toolId == "toolu_0168ei78ayanEUNCpUBhJRum")
        #expect(tool.event.requestId == nil)
        #expect(subagent.event.subagentId == "agent-8f1c2d34")
        #expect(subagent.event.toolId == nil)
    }

    @Test("A tool invocation identifier makes the occurrence identity deterministic")
    func occurrenceIsDeterministicWithToolUseIdentifier() throws {
        // Arrange
        var freshCallCount = 0
        let fresh: () -> UUID = {
            freshCallCount += 1
            return UUID()
        }

        // Act
        guard case .projected(let first) = try project("PreToolUse", freshOccurrenceIdentifier: fresh),
            case .projected(let second) = try project("PreToolUse", freshOccurrenceIdentifier: fresh)
        else {
            Issue.record("PreToolUse did not project")
            return
        }

        // Assert
        #expect(first.event.occurrenceId == second.event.occurrenceId)
        #expect(freshCallCount == 0)
        // RFC 4122 version 5: version nibble 5, variant bits 10.
        #expect(first.event.occurrenceId.uuidString.split(separator: "-")[2].first == "5")
    }

    @Test("Without a tool invocation identifier each occurrence is freshly generated")
    func occurrenceIsFreshWithoutToolUseIdentifier() throws {
        // Arrange
        var issued: [UUID] = []
        let fresh: () -> UUID = {
            let identifier = UUID()
            issued.append(identifier)
            return identifier
        }

        // Act
        guard case .projected(let first) = try project("Stop", freshOccurrenceIdentifier: fresh),
            case .projected(let second) = try project("Stop", freshOccurrenceIdentifier: fresh)
        else {
            Issue.record("Stop did not project")
            return
        }

        // Assert
        #expect(first.event.occurrenceId != second.event.occurrenceId)
        #expect(issued == [first.event.occurrenceId, second.event.occurrenceId])
    }

    @Test("Unprojected Claude Code events produce no call")
    func unprojectedEventsAreRefused() throws {
        // Arrange / Act
        let notification = try project("Notification")

        // Assert
        #expect(notification == .refused(.unprojectedEvent("Notification")))
    }

    @Test("A hook document disagreeing with its announced event is refused")
    func announcedEventMismatchIsRefused() throws {
        // Arrange
        let payload = try ClaudeCodeHookFixture.payload("Stop")

        // Act
        let outcome = ClaudeCodeHookProjection.project(
            announcedEvent: "SessionEnd",
            payload: payload,
            providerVersion: "2.1.274",
            correlationIdentifier: Self.stableIdentifier,
            freshOccurrenceIdentifier: { Self.stableIdentifier }
        )

        // Assert
        #expect(outcome == .refused(.announcedEventMismatch(announced: "SessionEnd", reported: "Stop")))
    }

    @Test("A report-only permission without a call id still projects conservatively")
    func permissionWithoutRequestIdentifierIsReported() {
        // Arrange
        let payload = ClaudeCodeHookPayload(
            sessionId: "session-1",
            hookEventName: "PermissionRequest",
            promptId: "turn-1",
            toolUseId: nil,
            agentId: nil
        )

        // Act
        let outcome = ClaudeCodeHookProjection.project(
            announcedEvent: "PermissionRequest",
            payload: payload,
            providerVersion: "2.1.274",
            correlationIdentifier: Self.stableIdentifier,
            freshOccurrenceIdentifier: { Self.stableIdentifier }
        )

        // Assert
        guard case .projected(let params) = outcome else {
            Issue.record("Keyless PermissionRequest must be reported")
            return
        }
        #expect(params.event.name == .permission)
        #expect(params.event.requestId == nil)
    }
}

@Suite("Claude Code hook invocation")
struct ClaudeCodeHookInvocationTests {
    private func inputs(
        arguments: [String],
        environment: [String: String],
        standardInput: @escaping () throws -> Data = { Data() },
        diagnostics: @escaping (String) -> Void = { _ in }
    ) -> ClaudeCodeHookInvocationInputs {
        ClaudeCodeHookInvocationInputs(
            arguments: arguments,
            environment: environment,
            standardInput: standardInput,
            identifierGenerator: { UUID() },
            diagnosticSink: diagnostics
        )
    }

    @Test("Arguments for another command are not claimed")
    func unrelatedArgumentsAreNotClaimed() {
        // Arrange / Act
        let outcome = ClaudeCodeHookInvocation.handle(
            inputs(arguments: ["session.query"], environment: [:])
        )

        // Assert
        #expect(outcome == nil)
    }

    @Test("Outside an Agent Studio pane the hook exits silently without reading stdin")
    func environmentGuardExitsSilently() throws {
        // Arrange
        var standardInputReads = 0
        var diagnostics: [String] = []
        let guarded = inputs(
            arguments: ["hook", "claude", "SessionStart"],
            environment: ["AGENTSTUDIO_PANE_TOKEN": "token"],
            standardInput: {
                standardInputReads += 1
                return try ClaudeCodeHookFixture.data("SessionStart")
            },
            diagnostics: { diagnostics.append($0) }
        )

        // Act
        let outcome = ClaudeCodeHookInvocation.handle(guarded)

        // Assert
        #expect(outcome == 0)
        #expect(standardInputReads == 0)
        #expect(diagnostics.isEmpty)
    }

    @Test("A pane without a credential exits silently")
    func missingPaneTokenExitsSilently() {
        // Arrange
        var diagnostics: [String] = []
        let guarded = inputs(
            arguments: ["hook", "claude", "SessionStart"],
            environment: ["AGENTSTUDIO_CLI": "/tmp/agentstudio"],
            diagnostics: { diagnostics.append($0) }
        )

        // Act
        let outcome = ClaudeCodeHookInvocation.handle(guarded)

        // Assert
        #expect(outcome == 0)
        #expect(diagnostics.isEmpty)
    }

    @Test("An unreachable app reports one line on stderr and still exits zero")
    func unreachableAppStillExitsZero() throws {
        // Arrange
        var diagnostics: [String] = []
        let unreachable = inputs(
            arguments: ["hook", "claude", "SessionStart", "--provider-version", "2.1.274"],
            environment: [
                "AGENTSTUDIO_CLI": "/tmp/agentstudio",
                "AGENTSTUDIO_PANE_TOKEN": "token",
                "AGENTSTUDIO_IPC_SOCKET": FileManager.default.temporaryDirectory
                    .appending(path: "agentstudio-absent-\(UUID().uuidString).sock").path,
            ],
            standardInput: { try ClaudeCodeHookFixture.data("SessionStart") },
            diagnostics: { diagnostics.append($0) }
        )

        // Act
        let outcome = ClaudeCodeHookInvocation.handle(unreachable)

        // Assert
        #expect(outcome == 0)
        #expect(diagnostics == ["agentstudio hook claude: SessionStart not reported"])
    }

    @Test("A malformed hook document reports one line and never echoes its content")
    func malformedDocumentIsNotEchoed() {
        // Arrange
        var diagnostics: [String] = []
        let malformed = inputs(
            arguments: ["hook", "claude", "Stop"],
            environment: [
                "AGENTSTUDIO_CLI": "/tmp/agentstudio",
                "AGENTSTUDIO_PANE_TOKEN": "token",
                "AGENTSTUDIO_IPC_SOCKET": "/tmp/agentstudio-absent.sock",
            ],
            standardInput: { Data(#"{"secret":"do not echo"}"#.utf8) },
            diagnostics: { diagnostics.append($0) }
        )

        // Act
        let outcome = ClaudeCodeHookInvocation.handle(malformed)

        // Assert
        #expect(outcome == 0)
        #expect(diagnostics == ["agentstudio hook claude: Stop not reported"])
        #expect(diagnostics.allSatisfy { !$0.contains("do not echo") })
    }
}
