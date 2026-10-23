import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@Suite("RunToExit process")
struct RunToExitProcessTests {
    @Test("an explicit environment cannot restore omitted ambient values")
    func explicitEnvironmentRemainsReplacement() async throws {
        let output = try await runProcessToExit(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: [],
            environment: ["FIXTURE_OWNED_VALUE": "owned"])
        let environment = try #require(String(data: output.standardOutput, encoding: .utf8))
        let expectedEnvironment = [
            "FIXTURE_OWNED_VALUE=owned",
            "GIT_CONFIG_COUNT=2",
            "GIT_CONFIG_KEY_0=maintenance.auto",
            "GIT_CONFIG_VALUE_0=false",
            "GIT_CONFIG_KEY_1=gc.auto",
            "GIT_CONFIG_VALUE_1=0",
        ]
        #expect(output.terminationStatus == 0)
        #expect(environment.split(separator: "\n").map(String.init).sorted() == expectedEnvironment.sorted())
    }

    @Test("cancellation before process launch leaves no child")
    func cancellationBeforeProcessLaunchLeavesNoChild() async throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appending(path: "run-to-exit-before-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let launchMarker = fixtureDirectory.appending(path: "launched")
        let launchStep = HeldStep<Void>("before-process-launch", cancellation: .holdThroughCancellation)

        let processTask = Task {
            try await launchStep.arrive(())
            return try await runProcessToExit(
                executableURL: URL(fileURLWithPath: "/usr/bin/touch"),
                arguments: [launchMarker.path]
            )
        }
        _ = try await launchStep.firstArrival()

        processTask.cancel()
        try await launchStep.cancellationObserved()
        launchStep.release()

        await #expect(throws: CancellationError.self) {
            try await processTask.value
        }
        #expect(!FileManager.default.fileExists(atPath: launchMarker.path))
    }

    @Test("cancellation after child launch terminates a process blocked on open stdin")
    func cancellationAfterChildLaunchTerminatesBlockedProcess() async throws {
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf ready; exec /bin/cat"]
        process.standardInput = standardInput.fileHandleForReading
        process.standardOutput = standardOutput.fileHandleForWriting

        let (readinessEvents, readinessContinuation) = AsyncStream.makeStream(of: Data.self)
        let standardOutputReader = standardOutput.fileHandleForReading
        standardOutputReader.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                readinessContinuation.finish()
            } else {
                readinessContinuation.yield(data)
            }
        }
        defer {
            standardOutputReader.readabilityHandler = nil
            readinessContinuation.finish()
            if process.isRunning {
                process.terminate()
            }
            try? standardInput.fileHandleForReading.close()
            try? standardInput.fileHandleForWriting.close()
            try? standardOutput.fileHandleForReading.close()
            try? standardOutput.fileHandleForWriting.close()
        }

        let processTask = Task { try await awaitProcessExit(process) }
        var readinessOutput = Data()
        let readyBytes = Data("ready".utf8)
        for await chunk in readinessEvents {
            readinessOutput.append(chunk)
            if readinessOutput.suffix(readyBytes.count).elementsEqual(readyBytes) {
                break
            }
        }

        processTask.cancel()
        await #expect(throws: CancellationError.self) {
            try await processTask.value
        }
        #expect(readinessOutput.suffix(readyBytes.count).elementsEqual(readyBytes))
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(!process.isRunning)
    }
}
