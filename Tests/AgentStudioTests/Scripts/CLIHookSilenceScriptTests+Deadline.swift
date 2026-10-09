import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import AgentStudioTestSupport
import Darwin
import Foundation
import Synchronization
import Testing

extension CLIHookSilenceScriptTests {
    @Test(
        "a held or trickling real input pipe exhausts the argv-selected hook total",
        arguments: HookInputDeadlineCase.matrix, [false, true])
    func heldStandardInputExhaustsHookTotal(
        invocation: HookInputDeadlineCase, hasPartialInput: Bool
    ) async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try HookSilenceProcessFixture(condition: .up)
            defer { fixture.removeFiles() }
            let pipe = Pipe()
            defer {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
            if hasPartialInput {
                try pipe.fileHandleForWriting.write(contentsOf: Data("{\"session_id\":\"unfinished".utf8))
            }
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            let flagsBefore = Darwin.fcntl(descriptor, F_GETFL)
            let timing = HookInputDeadlineTiming(
                inputDescriptor: descriptor,
                readsPartialInput: hasPartialInput,
                partialInputCost: invocation.partialInputCost)
            let streams = Mutex<[String]>([])
            let ordinaryInputReads = Mutex(0)
            let status = AgentStudioIPCClientCommandLineRunner.run(
                props: .init(
                    arguments: ["hook", invocation.provider, invocation.event],
                    environment: fixture.environment(
                        executable: URL(fileURLWithPath: "/fixture/agentstudio-cli"), storeSetting: .fresh),
                    executablePath: "/fixture/agentstudio-cli", bundleExecutableURL: nil,
                    standardInput: {
                        ordinaryInputReads.withLock { $0 += 1 }
                        return Data()
                    },
                    identifierGenerator: { UUIDv7.generate() },
                    standardOutputSink: { line in streams.withLock { $0.append(line) } },
                    standardErrorSink: { line in streams.withLock { $0.append(line) } },
                    standardInputFileDescriptor: descriptor, deadlineTiming: timing))
            return HookInputObservation(
                exitCode: status, streamLines: streams.withLock { $0 }, waitBudgets: timing.waits,
                controlledElapsed: timing.elapsed, inputFlagsRestored: Darwin.fcntl(descriptor, F_GETFL) == flagsBefore,
                storeOutcome: try fixture.storeOutcome(), ordinaryInputReadCount: ordinaryInputReads.withLock { $0 },
                inputWaitEvents: timing.inputWaitEvents)
        }
        #expect(observed.exitCode == 0)
        #expect(observed.streamLines.isEmpty)
        #expect(observed.controlledElapsed == invocation.totalLimit)
        #expect(
            observed.waitBudgets
                == (hasPartialInput
                    ? [invocation.totalLimit, invocation.totalLimit - invocation.partialInputCost]
                    : [invocation.totalLimit]))
        #expect(observed.inputFlagsRestored)
        #expect(!observed.storeOutcome.exists)
        #expect(observed.storeOutcome.creatorFiles.isEmpty)
        #expect(observed.ordinaryInputReadCount == 0)
        #expect(observed.inputWaitEvents.allSatisfy { $0 == Int16(POLLIN) })
    }

    @Test("Codex SessionEnd input and refusal use one argv-selected 250 ms total")
    func sessionEndRefusalSharesIngressTotal() async throws {
        let fixture = try HookSilenceProcessFixture(condition: .up)
        defer { fixture.removeFiles() }
        let observed: HookTotalObservation
        do {
            observed = try await valueFromDedicatedThread {
                try fixture.start()
                let pipe = Pipe()
                defer {
                    try? pipe.fileHandleForReading.close()
                    try? pipe.fileHandleForWriting.close()
                }
                try pipe.fileHandleForWriting.write(contentsOf: Data(#"{"session_id":""}"#.utf8))
                try pipe.fileHandleForWriting.close()
                let descriptor = pipe.fileHandleForReading.fileDescriptor
                let timing = HookInputDeadlineTiming(
                    inputDescriptor: descriptor,
                    readsPartialInput: true,
                    completedInput: true,
                    partialInputCost: .milliseconds(200),
                    networkReadyCount: 2,
                    networkTimeoutReadIndex: 1,
                    networkReadinessWait: { readIndex in try fixture.waitForNetworkResponse(readIndex) })
                let streams = Mutex<[String]>([])
                let ordinaryInputReads = Mutex(0)
                let status = AgentStudioIPCClientCommandLineRunner.run(
                    props: .init(
                        arguments: ["hook", "codex", "SessionEnd"],
                        environment: fixture.environment(
                            executable: URL(fileURLWithPath: "/fixture/agentstudio-cli"), storeSetting: .fresh),
                        executablePath: "/fixture/agentstudio-cli", bundleExecutableURL: nil,
                        standardInput: {
                            ordinaryInputReads.withLock { $0 += 1 }
                            return Data()
                        },
                        identifierGenerator: { UUIDv7.generate() },
                        standardOutputSink: { line in streams.withLock { $0.append(line) } },
                        standardErrorSink: { line in streams.withLock { $0.append(line) } },
                        standardInputFileDescriptor: descriptor, deadlineTiming: timing))
                return HookTotalObservation(
                    exitCode: status, streamLines: streams.withLock { $0 }, controlledElapsed: timing.elapsed,
                    networkWaitBudgets: timing.networkWaits, ordinaryInputReadCount: ordinaryInputReads.withLock { $0 },
                    inputWaitEvents: timing.inputWaitEvents)
            }
        } catch {
            await fixture.shutdown()
            throw error
        }
        let requests = fixture.requests
        await fixture.shutdown()

        #expect(observed.exitCode == 0)
        #expect(observed.streamLines.isEmpty)
        #expect(observed.controlledElapsed == .milliseconds(250))
        #expect(observed.networkWaitBudgets.allSatisfy { $0 <= .milliseconds(50) })
        #expect(observed.networkWaitBudgets.contains(.milliseconds(50)))
        #expect(observed.ordinaryInputReadCount == 0)
        #expect(observed.inputWaitEvents.allSatisfy { $0 == Int16(POLLIN) })
        #expect(!requests.contains { $0.method == "session.event" })
        let refusalRequest = try #require(requests.first { $0.method == "session.refusal" })
        let refusal = try JSONDecoder().decode(
            IPCSessionRefusalParams.self,
            from: JSONEncoder().encode(try #require(refusalRequest.params)))
        #expect(refusal.reason == .noSessionId)
        #expect(refusal.event == "SessionEnd")
    }

    @Test("Codex SessionEnd reaches a slow app and stays within its controlled 250 ms limit")
    func sessionEndSlowAppSharesControlledIngressTotal() async throws {
        let fixture = try HookSilenceProcessFixture(condition: .slow)
        defer { fixture.removeFiles() }
        let observed: HookTotalObservation
        do {
            observed = try await valueFromDedicatedThread {
                try fixture.start()
                let pipe = Pipe()
                defer {
                    try? pipe.fileHandleForReading.close()
                    try? pipe.fileHandleForWriting.close()
                }
                let sessionID = UUIDv7.generate().uuidString
                let payload = try JSONSerialization.data(withJSONObject: [
                    "session_id": sessionID,
                    "hook_event_name": CodexHookEventName.sessionEnd.rawValue,
                ])
                try pipe.fileHandleForWriting.write(contentsOf: payload)
                try pipe.fileHandleForWriting.close()
                let descriptor = pipe.fileHandleForReading.fileDescriptor
                let timing = HookInputDeadlineTiming(
                    inputDescriptor: descriptor,
                    readsPartialInput: true,
                    completedInput: true,
                    partialInputCost: .milliseconds(100),
                    networkReadyCount: 1,
                    networkTimeoutReadIndex: 0,
                    networkReadinessWait: { readIndex in
                        guard readIndex == 0 else { return }
                        try fixture.waitForSlowRequestRecorded()
                    })
                let streams = Mutex<[String]>([])
                let ordinaryInputReads = Mutex(0)
                let status = AgentStudioIPCClientCommandLineRunner.run(
                    props: .init(
                        arguments: ["hook", "codex", "SessionEnd"],
                        environment: fixture.environment(
                            executable: URL(fileURLWithPath: "/fixture/agentstudio-cli"), storeSetting: .fresh),
                        executablePath: "/fixture/agentstudio-cli", bundleExecutableURL: nil,
                        standardInput: {
                            ordinaryInputReads.withLock { $0 += 1 }
                            return Data()
                        },
                        identifierGenerator: { UUIDv7.generate() },
                        standardOutputSink: { line in streams.withLock { $0.append(line) } },
                        standardErrorSink: { line in streams.withLock { $0.append(line) } },
                        standardInputFileDescriptor: descriptor, deadlineTiming: timing))
                return HookTotalObservation(
                    exitCode: status, streamLines: streams.withLock { $0 }, controlledElapsed: timing.elapsed,
                    networkWaitBudgets: timing.networkWaits, ordinaryInputReadCount: ordinaryInputReads.withLock { $0 },
                    inputWaitEvents: timing.inputWaitEvents)
            }
        } catch {
            await fixture.shutdown()
            throw error
        }
        let requests = fixture.requests
        await fixture.shutdown()

        #expect(observed.exitCode == 0)
        #expect(observed.streamLines.isEmpty)
        #expect(observed.controlledElapsed == CLIPolicy.synchronousLifecycleHookLimit)
        #expect(observed.networkWaitBudgets == [.milliseconds(150)])
        #expect(requests.map(\.method) == ["auth.login"])
        #expect(!requests.contains { $0.method == "session.event" })
    }
}

struct HookInputDeadlineCase: Sendable {
    let provider: String
    let event: String
    let totalLimit: Duration
    let partialInputCost: Duration

    static let matrix = [
        Self(provider: "claude", event: "SessionStart", totalLimit: .seconds(2), partialInputCost: .seconds(1)),
        Self(provider: "codex", event: "SessionStart", totalLimit: .seconds(2), partialInputCost: .seconds(1)),
        Self(
            provider: "codex", event: "SessionEnd", totalLimit: .milliseconds(250),
            partialInputCost: .milliseconds(100)),
    ]
}
