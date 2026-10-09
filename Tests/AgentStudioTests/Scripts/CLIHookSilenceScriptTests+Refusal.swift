import AgentStudioDeadlineTestSupport
import AgentStudioIPCClientCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudio

extension CLIHookSilenceScriptTests {
    @Test(
        "real refused hooks stay silent without binding, activity or a CLI store",
        arguments: HookRefusalProcessCase.matrix)
    func hookRefusalProcess(invocation: HookRefusalProcessCase) async throws {
        let submissions = Mutex(0)
        let harness = try await SessionsVerticalHarness.make(
            installActivityClock: true, activitySubmissionObserver: { _ in submissions.withLock { $0 += 1 } })
        do {
            let executable = try hookSilenceExecutableURL()
            let payloadURL = harness.rootDirectory.appending(path: "refused-hook-input.json")
            try Data(invocation.payload.utf8).write(to: payloadURL)
            let storeURL = harness.rootDirectory.appending(path: "unused-refusal-store/cli.sqlite")
            let paneToken = try #require(harness.boundPaneToken)
            var environment = [
                "AGENTSTUDIO_CLI": executable.path, "AGENTSTUDIO_IPC_SOCKET": harness.socketPath,
                "AGENTSTUDIO_CLI_STORE": storeURL.path, "AGENTSTUDIO_CLI_STORE_CHANNEL": "debug",
            ]
            if invocation.condition != .outsidePane { environment["AGENTSTUDIO_PANE_TOKEN"] = paneToken.rawValue }
            if invocation.condition == .down {
                await harness.appDelegate.stopAcceptingAppIPCConnections()
                await harness.appDelegate.drainAppIPCCredentialPersistence()
            }
            let output = try await runProcessToExit(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c", #"input=$1; executable=$2; shift 2; exec "$executable" "$@" < "$input""#,
                    "hook-refusal-test", payloadURL.path, executable.path, "hook", invocation.provider, "SessionStart",
                ],
                environment: environment)
            #expect(output.terminationStatus == 0)
            #expect(output.standardOutput.isEmpty)
            #expect(output.standardError.isEmpty)
            #expect(submissions.withLock { $0 } == 0)
            #expect(!FileManager.default.fileExists(atPath: storeURL.deletingLastPathComponent().path))
            if invocation.condition != .down {
                let query = try await harness.sessionQuery(paneId: harness.boundPaneId)
                #expect(query.sourceHealth == .unbound)
                #expect(query.session == nil)
                if invocation.condition == .outsidePane {
                    #expect(query.lastRefusal == nil)
                }
            }
            await harness.tearDown()
        } catch {
            await harness.tearDown()
            throw error
        }
    }

    @Test(
        "controlled hooks deliver the exact refusal to the real Sessions owner",
        arguments: HookRefusalProcessCase.matrix.filter { $0.condition == .up })
    func controlledHookRefusalIsRecorded(invocation: HookRefusalProcessCase) async throws {
        let submissions = Mutex(0)
        let harness = try await SessionsVerticalHarness.make(
            installActivityClock: true, activitySubmissionObserver: { _ in submissions.withLock { $0 += 1 } })
        do {
            let paneToken = try #require(harness.boundPaneToken)
            let storeURL = harness.rootDirectory.appending(path: "unused-refusal-store/cli.sqlite")
            let environment = [
                "AGENTSTUDIO_CLI": "/fixture/agentstudio-cli", "AGENTSTUDIO_IPC_SOCKET": harness.socketPath,
                "AGENTSTUDIO_PANE_TOKEN": paneToken.rawValue,
                "AGENTSTUDIO_CLI_STORE": storeURL.path, "AGENTSTUDIO_CLI_STORE_CHANNEL": "debug",
            ]
            let observed = try await valueFromDedicatedThread {
                let driver = ControlledDeadlineDriver()
                defer { driver.close() }
                let pipe = Pipe()
                defer {
                    try? pipe.fileHandleForReading.close()
                    try? pipe.fileHandleForWriting.close()
                }
                try pipe.fileHandleForWriting.write(contentsOf: Data(invocation.payload.utf8))
                try pipe.fileHandleForWriting.close()
                let streams = Mutex<[String]>([])
                let exitCode = AgentStudioIPCClientCommandLineRunner.run(
                    props: .init(
                        arguments: ["hook", invocation.provider, "SessionStart"],
                        environment: environment, executablePath: "/fixture/agentstudio-cli", bundleExecutableURL: nil,
                        standardInput: { Data() }, identifierGenerator: { UUIDv7.generate() },
                        standardOutputSink: { line in streams.withLock { $0.append(line) } },
                        standardErrorSink: { line in streams.withLock { $0.append(line) } },
                        standardInputFileDescriptor: pipe.fileHandleForReading.fileDescriptor,
                        deadlineTiming: driver.timing))
                return (exitCode: exitCode, streamLines: streams.withLock { $0 })
            }
            #expect(observed.exitCode == 0)
            #expect(observed.streamLines.isEmpty)
            // The real refusal reply follows the owner's awaited recording;
            // the controlled clock cannot cut that exchange short under load.
            let query = try await harness.sessionQuery(paneId: harness.boundPaneId)
            let refusal = try #require(query.lastRefusal)
            #expect(refusal.reason == invocation.reason)
            #expect(refusal.event == "SessionStart")
            #expect(query.sourceHealth == .unbound)
            #expect(query.session == nil)
            #expect(submissions.withLock { $0 } == 0)
            #expect(!FileManager.default.fileExists(atPath: storeURL.deletingLastPathComponent().path))
            await harness.tearDown()
        } catch {
            await harness.tearDown()
            throw error
        }
    }
}

struct HookRefusalProcessCase: Sendable {
    let provider: String
    let payload: String
    let reason: IPCSessionLastRefusalReason
    let condition: HookSilenceCondition

    static var matrix: [Self] {
        ["claude", "codex"].flatMap { provider in
            [HookSilenceCondition.up, .down, .outsidePane].flatMap { condition in
                [
                    Self(
                        provider: provider, payload: #"{"hook_event_name":"SessionStart"}"#,
                        reason: .noSessionId, condition: condition),
                    Self(
                        provider: provider, payload: #"{"hook_event_name":"SessionStart","session_id":null}"#,
                        reason: .noSessionId, condition: condition),
                    Self(
                        provider: provider, payload: #"{"hook_event_name":"SessionStart","session_id":""}"#,
                        reason: .noSessionId, condition: condition),
                    Self(provider: provider, payload: "not json", reason: .undecodablePayload, condition: condition),
                ]
            }
        }
    }
}
