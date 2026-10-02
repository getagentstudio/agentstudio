import AgentStudioTestHarness
import Darwin
import Foundation
import Testing

@MainActor
@Suite("ExpectationLog", .serialized)
struct ExpectationLogTests {
    @Test("an unwritable log path emits one stderr unavailability line across both loggers")
    func unwritableLogReportsOnce() throws {
        let missingPath = "/nonexistent-agentstudio-log-parent-\(getpid())/events.log"
        let stderrText = try captureStandardError {
            let log = ExpectationLog(path: missingPath)
            let firstID = log.expecting(expectedCase: "first", scope: "scope", test: "Suite", callSite: "File:1")
            log.settled(firstID, outcome: .ended)
            HeldStepEventLog(path: missingPath).recordWaiting(
                instanceID: 1, waiterID: 1, stepName: "step", test: "Suite")
        }

        let lines = stderrText.split(separator: "\n")
        #expect(lines.count == 1)
        #expect(lines.first?.hasPrefix("[agentstudio-test-log] unavailable path=\(missingPath) errno=") == true)
    }

    @Test("pending and settled records escape fields, cap descriptions and use unique ids")
    func recordsAreEscapedAndUnique() throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstudio-expectation-\(getpid())-\(#function).log")
        defer { try? FileManager.default.removeItem(at: logURL) }
        let log = ExpectationLog(path: logURL.path)
        let longCase = String(repeating: "x", count: 220) + "\tignored"

        let firstID = log.expecting(
            expectedCase: longCase, scope: "scope\tfirst", test: "Suite\ncase", callSite: "File.swift:4"
        )
        let secondID = log.expecting(
            expectedCase: "closing", scope: "scope", test: "Suite case", callSite: "File.swift:5"
        )
        log.settled(firstID, outcome: .matched)
        log.settled(secondID, outcome: .lost)

        let lines = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").map {
            $0.split(separator: "\t", omittingEmptySubsequences: false).dropLast().joined(separator: "\t")
        }
        #expect(lines.count == 4)
        #expect(firstID != secondID)
        #expect(firstID.hasPrefix("\(getpid())-"))
        #expect(
            lines[0].contains(
                "expecting\t\(firstID)\t\(String(repeating: "x", count: 200))\tscope\\tfirst\tSuite\\ncase\tFile.swift:4"
            ))
        #expect(lines[1] == "expecting\t\(secondID)\tclosing\tscope\tSuite case\tFile.swift:5")
        #expect(lines[2] == "settled\t\(firstID)\tmatched")
        #expect(lines[3] == "settled\t\(secondID)\tlost")
    }

    @Test("recorder expectations write pending and terminal outcomes")
    func recorderWritesExpectationLifecycle() async throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstudio-recorder-log-\(getpid())-\(#function).log")
        defer { try? FileManager.default.removeItem(at: logURL) }
        let recorder = FactRecorder(
            vocabulary: FactVocabulary<String, String>(
                describeScope: { $0 }, describeFact: { $0 }, isClosing: { _, _ in false }
            ),
            expectationLog: ExpectationLog(path: logURL.path)
        )
        recorder.append(scope: "scope", fact: "actual")

        await #expect(throws: UnexpectedFact.self) {
            try await recorder.expectNext(in: "scope", "expected")
        }
        try await recorder.finish()

        let lines = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").map {
            $0.split(separator: "\t", omittingEmptySubsequences: false).dropLast().joined(separator: "\t")
        }
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("expecting\t"))
        #expect(lines[0].contains("\texpected\tscope\t"))
        #expect(lines[1].hasSuffix("\tunexpected"))
    }

    private func captureStandardError(_ body: () -> Void) throws -> String {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw CocoaError(.fileReadUnknown) }
        let savedStderr = dup(STDERR_FILENO)
        guard savedStderr >= 0 else {
            close(descriptors[0])
            close(descriptors[1])
            throw CocoaError(.fileReadUnknown)
        }
        _ = dup2(descriptors[1], STDERR_FILENO)
        close(descriptors[1])
        body()
        _ = dup2(savedStderr, STDERR_FILENO)
        close(savedStderr)
        let output = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true).readDataToEndOfFile()
        guard let text = String(bytes: output, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return text
    }
}
