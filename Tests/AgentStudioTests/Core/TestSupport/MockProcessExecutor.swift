import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

enum MockExecutorError: Error {
    case noResponseQueued
}

/// Mock executor that records calls and returns canned responses.
final class MockProcessExecutor: ProcessExecutor, @unchecked Sendable {
    struct Call: Equatable {
        let command: String
        let args: [String]
        let environment: [String: String]?
    }

    private enum QueuedOutcome {
        case result(ProcessResult)
        case failure(any Error)
    }

    var calls: [Call] = []
    private var queuedOutcomes: [QueuedOutcome] = []
    private var responseIndex = 0

    /// Present for existing callers that read queued responses directly;
    /// `enqueueThrow` entries are omitted since they carry no `ProcessResult`.
    var responses: [ProcessResult] {
        queuedOutcomes.compactMap {
            if case .result(let result) = $0 { return result }
            return nil
        }
    }

    /// Queue a response for the next `execute` call.
    func enqueue(_ result: ProcessResult) {
        queuedOutcomes.append(.result(result))
    }

    /// Queue `execute` throwing `error` instead of returning a result — for
    /// example `ProcessError.timedOut`, to prove a caller distinguishes a
    /// timeout from every other execution outcome.
    func enqueueThrow(_ error: any Error) {
        queuedOutcomes.append(.failure(error))
    }

    /// Queue a successful response with given stdout.
    func enqueueSuccess(_ stdout: String = "") {
        enqueue(ProcessResult(exitCode: 0, stdout: stdout, stderr: ""))
    }

    /// Queue a failure response.
    func enqueueFailure(_ stderr: String = "error") {
        enqueue(ProcessResult(exitCode: 1, stdout: "", stderr: stderr))
    }

    func execute(
        command: String,
        args: [String],
        cwd: URL?,
        environment: [String: String]?
    ) async throws -> ProcessResult {
        calls.append(Call(command: command, args: args, environment: environment))

        guard responseIndex < queuedOutcomes.count else {
            Issue.record(
                "MockProcessExecutor: no response queued for call #\(responseIndex + 1): \(command) \(args)"
            )
            throw MockExecutorError.noResponseQueued
        }

        let outcome = queuedOutcomes[responseIndex]
        responseIndex += 1
        switch outcome {
        case .result(let result):
            return result
        case .failure(let error):
            throw error
        }
    }
}
