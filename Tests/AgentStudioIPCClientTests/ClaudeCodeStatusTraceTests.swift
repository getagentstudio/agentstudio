import AgentStudioIPCTransport
import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

@Suite("Claude Code status traces")
struct ClaudeCodeStatusTraceTests {
    @Test(
        "every newly wired status hook projects its real captured payload",
        arguments: ["PostToolUse", "PostToolUseFailure", "StopFailure", "Elicitation", "ElicitationResult"])
    func recordedEventProjects(event: String) throws {
        let projected = try RecordedClaudeStatusTrace.project(event)
        let payload = try RecordedClaudeStatusTrace.payload(event)
        #expect(projected.provider.version == "2.1.286")
        #expect(projected.event.conversationId == payload.sessionId)
        #expect(projected.event.turnId == payload.promptId)
    }

    @Test("AskUserQuestion's real questions survive decoding and permission needs no tool ID")
    func recordedQuestionRoundTrip() throws {
        let before = try RecordedClaudeStatusTrace.project("AskUserQuestion.PreToolUse")
        let permission = try RecordedClaudeStatusTrace.project("AskUserQuestion.PermissionRequest")
        let after = try RecordedClaudeStatusTrace.project("AskUserQuestion.PostToolUse")
        #expect(before.event.name == .question)
        #expect(permission.event.name == .permission)
        #expect(before.event.toolId == "toolu_01Sdbu5R1M1ugZsCEXvGquF9")
        #expect(after.event.toolId == before.event.toolId)
        #expect(permission.event.requestId == nil)
        let beforeFields = try RecordedClaudeStatusTrace.fields(before)
        let permissionFields = try RecordedClaudeStatusTrace.fields(permission)
        #expect(beforeFields.toolName == "AskUserQuestion")
        #expect(permissionFields.toolName == "AskUserQuestion")
        let questions = try #require(beforeFields.questions)
        #expect(questions.count == 1)
        #expect(questions.first?.question == "Choose a fixture option?")
        #expect(questions.first?.header == "Choice")
        #expect(questions.first?.multiSelect == false)
        #expect(questions.first?.options.map(\.label) == ["Option A", "Option B"])
        #expect(questions == permissionFields.questions)
    }

    @Test("report-only permission with no tool_use_id projects conservatively")
    func recordedPermissionHasNoCallIdentity() throws {
        let payload = try RecordedClaudeStatusTrace.payload("PermissionRequest")
        #expect(payload.toolUseId == nil)
        let projected = try RecordedClaudeStatusTrace.project("PermissionRequest")
        #expect(projected.event.name == .permission)
        #expect(projected.event.requestId == nil)
        #expect(try RecordedClaudeStatusTrace.fields(projected).toolName != nil)
    }

    @Test("StopFailure uses the error category, never the assistant message")
    func recordedFailureSummary() throws {
        let projected = try RecordedClaudeStatusTrace.project("StopFailure")
        #expect(projected.event.name.rawValue == "turnFailed")
        #expect(try RecordedClaudeStatusTrace.fields(projected).failureSummary == "authentication_failed")
    }

    @Test("no-ID elicitation preserves ambiguity and the required prompt metadata")
    func recordedElicitationHasNoInventedIdentity() throws {
        let opened = try RecordedClaudeStatusTrace.project("Elicitation")
        let result = try RecordedClaudeStatusTrace.project("ElicitationResult")
        let openFields = try RecordedClaudeStatusTrace.fields(opened)
        let resultFields = try RecordedClaudeStatusTrace.fields(result)
        #expect(opened.event.name == .elicitation)
        #expect(result.event.name.rawValue == "elicitationResult")
        #expect(openFields.elicitationId == nil)
        #expect(resultFields.elicitationId == nil)
        #expect(openFields.message == "Choose a fixture color.")
    }

    @Test("new keyed completion hooks retain occurrence identity on re-invocation")
    func completionOccurrenceIsStable() throws {
        for event in ["PostToolUse", "PostToolUseFailure", "AskUserQuestion.PostToolUse"] {
            let first = try RecordedClaudeStatusTrace.project(event)
            let repeatEvent = try RecordedClaudeStatusTrace.project(event)
            #expect(first.event.occurrenceId == repeatEvent.event.occurrenceId)
        }
    }

    @Test(
        "recorded provider forms and answers stay off the status wire and pass real schema admission",
        arguments: ["Elicitation", "ElicitationResult"])
    func elicitationProjectsOnlyStatusFields(fixture: String) throws {
        guard
            case .object(let sourceFields) = try JSONDecoder().decode(
                JSONValue.self, from: RecordedClaudeStatusTrace.data(fixture))
        else {
            throw ClaudeCodeHookInvocationError.reportRejected
        }
        let sourceKey = fixture == "Elicitation" ? "requested_schema" : "content"
        #expect(sourceFields[sourceKey] != nil)
        let projected = try RecordedClaudeStatusTrace.project(fixture)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encodedParams = try encoder.encode(projected)
        let roundTripped = try IPCSessionEventParams.ipcSchema().decode(IPCSessionEventParams.self, from: encodedParams)
        #expect(roundTripped == projected)
        guard
            case .object(let eventFields) = try JSONDecoder().decode(
                JSONValue.self, from: encoder.encode(roundTripped.event))
        else {
            throw ClaudeCodeHookInvocationError.reportRejected
        }
        #expect(eventFields["requestedSchema"] == nil)
        #expect(eventFields["content"] == nil)
        #expect(eventFields["mcpServerName"] == nil)
        #expect(eventFields["action"] == nil)
        #expect(eventFields["message"] == sourceFields["message"])
        #expect(try encoder.encode(roundTripped) == encodedParams)
    }
}

enum RecordedClaudeStatusTrace {
    static func data(_ fixture: String) throws -> Data {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(
            path: "Fixtures/claude-code-2.1.286")
        return try Data(contentsOf: directory.appending(path: "\(fixture).json"))
    }

    static func payload(_ fixture: String) throws -> ClaudeCodeHookPayload {
        try JSONDecoder().decode(ClaudeCodeHookPayload.self, from: data(fixture))
    }

    static func project(_ fixture: String) throws -> IPCSessionEventParams {
        let decoded = try payload(fixture)
        let result = ClaudeCodeHookProjection.project(
            announcedEvent: decoded.hookEventName, payload: decoded, providerVersion: "2.1.286",
            correlationIdentifier: UUIDv7.generate(), freshOccurrenceIdentifier: { UUIDv7.generate() })
        guard case .projected(let params) = result else {
            Issue.record("Recorded \(fixture) was refused: \(result)")
            throw ClaudeCodeHookInvocationError.reportRejected
        }
        return params
    }

    static func fields(_ params: IPCSessionEventParams) throws -> RecordedStatusEventFields {
        try JSONDecoder().decode(RecordedStatusEventFields.self, from: JSONEncoder().encode(params.event))
    }
}

struct RecordedStatusEventFields: Decodable {
    let toolName: String?
    let questions: [RecordedQuestion]?
    let failureSummary: String?
    let elicitationId: String?
    let message: String?
}

struct RecordedQuestion: Decodable, Equatable {
    let question: String
    let header: String
    let options: [RecordedQuestionOption]
    let multiSelect: Bool
}

struct RecordedQuestionOption: Decodable, Equatable {
    let label: String
    let description: String
}
